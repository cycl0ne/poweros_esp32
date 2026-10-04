// SPDX-License-Identifier: MPL-2.0
//! The debug exception: what a breakpoint, a watchpoint, a single step
//! or a `BREAK` instruction arrives as, and the core registers behind
//! them.
//!
//! The LX7 has two instruction breakpoints (`IBREAKA0`, `IBREAKA1`,
//! turned on a bit each in `IBREAKENABLE`) and two data ones
//! (`DBREAKA0/1` with `DBREAKC0/1`), and counts instructions in `ICOUNT`
//! to step. All four are the core's own: nothing is written into the
//! code, which could not be done anyway - it is in flash, mapped for
//! reading.
//!
//! **Going on from a breakpoint is not just returning.** The address is
//! still the one the core stops at, so a return would stop again at
//! once. What happens instead is the dance every debugger does: turn
//! that breakpoint off, step the one instruction, turn it back on, and
//! only then run on. `stepping_over` is which breakpoint that is, and
//! the step it causes is the one visit to this handler that does not
//! stop for the person at the console.

const std = @import("std");
const exec = @import("../../rom/libs/exec/exec.zig");
const debug = @import("../../rom/libs/exec/debug/_debug.zig");
const cpu = @import("cpu.zig");
const trap = @import("trap.zig");

/// What `DEBUGCAUSE` says happened.
pub const ICOUNT_BIT: u32 = 1 << 0;
pub const IBREAK_BIT: u32 = 1 << 1;
pub const DBREAK_BIT: u32 = 1 << 2;
pub const BREAK_BIT: u32 = 1 << 3;
pub const BREAKN_BIT: u32 = 1 << 4;
pub const DEBUGINT_BIT: u32 = 1 << 5;

/// How many of each the core has.
pub const breakpoints = 2;
pub const watchpoints = 2;

/// `ICOUNT` counts up and traps as it reaches zero. Two below it is one
/// instruction: the `RFI` that leaves this handler is counted at the
/// level it returns to, and the instruction after it is the one that
/// was asked for.
const one_step: u32 = @bitCast(@as(i32, -2));

/// A breakpoint held off for one instruction because it is at the very
/// address about to run: returning to it would stop again before
/// anything had moved. It goes back on at the step that follows.
var held_slot: ?u32 = null;
var held_at: usize = 0;
/// A step the person asked for, which does stop.
var stepping = false;
/// The frame of the visit going on now.
var current: ?*trap.Frame = null;
/// What was enabled before a step, put back after it.
var saved_intenable: u32 = 0;
var masked_for_step = false;

/// Counting happens at every level the code being stepped might be at.
/// `Disable` and a spinlock raise the level themselves, so a step through
/// them must still count; what keeps the step from wandering into an
/// interrupt is that none can be taken, not that the level is high.
const count_level: u32 = 5;

// --- the core's registers ---------------------------------------------------

inline fn ibreakenable() u32 {
    return asm volatile ("rsr %[r], ibreakenable"
        : [r] "=r" (-> u32),
    );
}

inline fn setIbreakenable(value: u32) void {
    asm volatile (
        \\wsr %[v], ibreakenable
        \\isync
        :
        : [v] "r" (value),
    );
}

inline fn setIbreaka(comptime which: u32, address: u32) void {
    switch (which) {
        0 => asm volatile (
            \\wsr %[v], ibreaka0
            \\isync
            :
            : [v] "r" (address),
        ),
        else => asm volatile (
            \\wsr %[v], ibreaka1
            \\isync
            :
            : [v] "r" (address),
        ),
    }
}

inline fn setDbreak(comptime which: u32, address: u32, control: u32) void {
    switch (which) {
        0 => asm volatile (
            \\wsr %[a], dbreaka0
            \\wsr %[c], dbreakc0
            \\isync
            :
            : [a] "r" (address),
              [c] "r" (control),
        ),
        else => asm volatile (
            \\wsr %[a], dbreaka1
            \\wsr %[c], dbreakc1
            \\isync
            :
            : [a] "r" (address),
              [c] "r" (control),
        ),
    }
}

inline fn setIcount(value: u32, level: u32) void {
    asm volatile (
        \\wsr %[l], icountlevel
        \\wsr %[v], icount
        \\isync
        :
        : [v] "r" (value),
          [l] "r" (level),
    );
}

// --- what the debugger asks for ---------------------------------------------

/// A breakpoint at `address`, or off when `address` is null. Which one,
/// or null when both are taken.
pub fn setBreakpoint(slot: u32, address: ?usize) void {
    var enabled = ibreakenable();
    if (address) |at| {
        switch (slot) {
            0 => setIbreaka(0, @truncate(at)),
            else => setIbreaka(1, @truncate(at)),
        }
        enabled |= @as(u32, 1) << @truncate(slot);
    } else {
        enabled &= ~(@as(u32, 1) << @truncate(slot));
    }
    setIbreakenable(enabled);
}

/// Where a breakpoint is, for the debugger to list.
pub fn breakpointAt(slot: u32) ?usize {
    if (ibreakenable() & (@as(u32, 1) << @truncate(slot)) == 0) return null;
    return switch (slot) {
        0 => asm volatile ("rsr %[r], ibreaka0"
            : [r] "=r" (-> u32),
        ),
        else => asm volatile ("rsr %[r], ibreaka1"
            : [r] "=r" (-> u32),
        ),
    };
}

/// A watchpoint on `size` bytes at `address`, on reading, on writing or
/// on both; off when `address` is null.
///
/// The core watches a range whose size is a power of two and whose
/// address is a multiple of it, which is what the mask in `DBREAKC`
/// says: the bits of the address that must match.
pub fn setWatchpoint(slot: u32, address: ?usize, size: u32, on_read: bool, on_write: bool) void {
    const at = address orelse {
        switch (slot) {
            0 => setDbreak(0, 0, 0),
            else => setDbreak(1, 0, 0),
        }
        return;
    };
    var mask: u32 = 0x3F;
    var span: u32 = 1;
    while (span < size and span < 64) : (span <<= 1) {}
    mask = 0x3F & ~(span - 1);
    var control = mask;
    if (on_read) control |= 1 << 30;
    if (on_write) control |= 1 << 31;
    const aligned = at & ~@as(usize, span - 1);
    switch (slot) {
        0 => setDbreak(0, @truncate(aligned), control),
        else => setDbreak(1, @truncate(aligned), control),
    }
}

/// The next instruction only, then back here.
pub fn step() void {
    const frame = current orelse return;
    // The breakpoint that stopped us is at the instruction about to
    // run, so it is held off for it, exactly as going on does.
    _ = holdBreakpointAt(frame.pc);
    stepping = true;
    maskForStep();
    setIcount(one_step, count_level);
}

/// Nothing may be taken while one instruction runs, or the step lands
/// in whichever interrupt was next and tells nobody anything about the
/// code they were reading. The stopped code's own interrupt level is
/// not touched: it may be inside a `Disable`, and putting a level back
/// that the code itself had changed would undo its work.
fn maskForStep() void {
    if (masked_for_step) return;
    saved_intenable = cpu.intenable();
    cpu.setIntenable(0);
    masked_for_step = true;
}

fn unmaskAfterStep() void {
    if (!masked_for_step) return;
    masked_for_step = false;
    cpu.setIntenable(saved_intenable);
}

/// Everything turned off, for going on without stopping again.
pub fn clearAll() void {
    unmaskAfterStep();
    setIbreakenable(0);
    setDbreak(0, 0, 0);
    setDbreak(1, 0, 0);
    setIcount(0, 0);
    stepping = false;
    held_slot = null;
}

/// The breakpoint at `pc`, if there is one, held off for the one
/// instruction about to run.
fn holdBreakpointAt(pc: usize) bool {
    var slot: u32 = 0;
    while (slot < breakpoints) : (slot += 1) {
        const at = breakpointAt(slot) orelse continue;
        if (at != pc) continue;
        held_slot = slot;
        held_at = at;
        setBreakpoint(slot, null);
        return true;
    }
    held_slot = null;
    return false;
}

/// The held breakpoint put back where it was.
fn releaseHeld() void {
    const slot = held_slot orelse return;
    held_slot = null;
    setBreakpoint(slot, held_at);
}

/// Going on from where the debugger stopped. A breakpoint at the address
/// about to run is carried over its own instruction: held off, stepped
/// past, put back - and that step is the one visit here that says
/// nothing to anybody.
pub fn resumeFrom(pc: usize) void {
    stepping = false;
    if (!holdBreakpointAt(pc)) {
        setIcount(0, 0);
        return;
    }
    maskForStep();
    setIcount(one_step, count_level);
}

/// What `DEBUGCAUSE` said, in words.
pub fn causeName(what: u32) [:0]const u8 {
    if (what & ICOUNT_BIT != 0) return "stepped";
    if (what & IBREAK_BIT != 0) return "breakpoint";
    if (what & DBREAK_BIT != 0) return "watchpoint";
    if (what & (BREAK_BIT | BREAKN_BIT) != 0) return "a BREAK instruction";
    if (what & DEBUGINT_BIT != 0) return "the debug interrupt";
    return "stopped";
}

/// The debug exception. Returns without stopping when it is the step
/// that carries a breakpoint over its own address; otherwise the
/// debugger is given the machine.
/// Whether the debugger already has the machine. A breakpoint or a
/// watchpoint that goes off inside the debugger itself would call it
/// again on top of itself, and it would never come back.
var inside = false;

export fn xtensa_debug(frame: *trap.Frame) callconv(.c) void {
    const cause = frame.exccause;
    if (inside) {
        // Everything off and straight back: a debugger that stops
        // itself stops for good, and a watchpoint on memory the
        // debugger touches would do exactly that.
        clearAll();
        return;
    }
    current = frame;
    if (cause & ICOUNT_BIT != 0) {
        setIcount(0, 0);
        releaseHeld();
        unmaskAfterStep();
        if (!stepping) {
            // The step was only there to carry a breakpoint over its
            // own address. Nobody is told it happened.
            return;
        }
    }
    stepping = false;
    setIcount(0, 0);
    inside = true;
    defer inside = false;
    debug.enter(.stopped, frame, cause);
}

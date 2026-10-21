// SPDX-License-Identifier: MPL-2.0
//! The core's self-hosted debug, for the ROM debugger: breakpoints,
//! watchpoints and a single step, each arriving as a debug exception at
//! EL1 through the ordinary vectors, as a `brk` does.
//!
//! An A76 has six breakpoints (DBGBVRn_EL1, DBGBCRn_EL1), each an address
//! match on an instruction, and four watchpoints (DBGWVRn_EL1,
//! DBGWCRn_EL1), each a match on a load or a store over a doubleword's
//! bytes or a power of two of them; the debugger uses `breakpoints` and
//! `watchpoints` of them. A step is the architecture's own: MDSCR_EL1.SS
//! with SPSR.SS set in the frame the debugger goes on to, and the core
//! takes a software step exception after the one instruction.
//!
//! Debug exceptions are taken at EL1 from EL1 only with MDSCR_EL1.KDE and
//! MDE set, the OS lock open, and PSTATE.D clear. Taking any exception
//! sets D, and eret puts back the one it interrupted; so none fires
//! inside an exception - the debugger itself included - and tasks, which
//! run with D clear, are stopped. `init` opens it all up on each core.
//!
//! A watchpoint stops the core before its load or store, so going on from
//! one is stepping the access with the watchpoint off. Going on from a
//! breakpoint is the same: the address is the one the core stops at, so
//! that breakpoint is held off, the one instruction stepped, the
//! breakpoint put back, and only then does the code run on - the step
//! that does so stops for nobody. While a step runs the stepped frame has
//! its IRQs masked (SPSR.I), so the step lands in the code being looked
//! at and not in whichever interrupt was next; its own mask is put back
//! after.
//!
//! **Every core stops at them.** Each core's debug registers are its own
//! and only that core can write them, so what the debugger asks for is
//! kept here, in one table for the machine with a count of its changes.
//! The core the debugger runs on loads it at once; the others, which the
//! debugger holds parked meanwhile, load it as they leave the park
//! (rendezvous.zig). A visit and a step are each core's own, so two
//! cores that stop at once take the debugger in turn.

const std = @import("std");
const exec = @import("../../rom/libs/exec/exec.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const debug = @import("../../rom/libs/exec/debug/_debug.zig");
const cpu = @import("cpu.zig");
const trap = @import("trap.zig");

/// The slots the debugger is given.
pub const breakpoints = 4;
pub const watchpoints = 2;

/// MDSCR_EL1: software step on (SS), debug exceptions at the kernel's own
/// level (KDE), breakpoints and watchpoints on (MDE).
const MDSCR_SS: u64 = 1 << 0;
const MDSCR_KDE: u64 = 1 << 13;
const MDSCR_MDE: u64 = 1 << 15;

/// SPSR: the step to take one instruction (SS), and the IRQ mask (I).
const SPSR_SS: u64 = 1 << 21;
const SPSR_I: u64 = 1 << 7;

/// DBGBCR: on, at EL1, an A64 instruction's address.
const BCR_EL1_INSTRUCTION: u64 = 1 | 0b01 << 1 | 0b1111 << 5;
/// DBGWCR: on, at EL1; on loads, on stores; the bytes of a doubleword
/// (BAS), or the low bits of the address left out (MASK).
const WCR_EL1: u64 = 1 | 0b01 << 1;
const WCR_LOAD: u64 = 0b01 << 3;
const WCR_STORE: u64 = 0b10 << 3;
const WCR_BAS_SHIFT: u6 = 5;
const WCR_MASK_SHIFT: u6 = 24;

/// What stopped the core, for the debugger to name: a breakpoint, a
/// watchpoint, the step, or a `brk`.
pub const Cause = enum(u32) { breakpoint = 1, watchpoint = 2, stepped = 3, brk = 4, stopped = 0 };

// --- the registers ------------------------------------------------------------

fn writeBreakpoint(comptime n: u32, value: u64, control: u64) void {
    const n_text = std.fmt.comptimePrint("{d}", .{n});
    asm volatile ("msr dbgbcr" ++ n_text ++ "_el1, xzr" ::: .{ .memory = true });
    if (control == 0) return;
    asm volatile ("msr dbgbvr" ++ n_text ++ "_el1, %[v]"
        :
        : [v] "r" (value),
        : .{ .memory = true });
    asm volatile ("msr dbgbcr" ++ n_text ++ "_el1, %[c]"
        :
        : [c] "r" (control),
        : .{ .memory = true });
}

fn writeWatchpoint(comptime n: u32, value: u64, control: u64) void {
    const n_text = std.fmt.comptimePrint("{d}", .{n});
    asm volatile ("msr dbgwcr" ++ n_text ++ "_el1, xzr" ::: .{ .memory = true });
    if (control == 0) return;
    asm volatile ("msr dbgwvr" ++ n_text ++ "_el1, %[v]"
        :
        : [v] "r" (value),
        : .{ .memory = true });
    asm volatile ("msr dbgwcr" ++ n_text ++ "_el1, %[c]"
        :
        : [c] "r" (control),
        : .{ .memory = true });
}

fn setBreakpointRegister(slot: u32, address: ?usize) void {
    const control: u64 = if (address != null) BCR_EL1_INSTRUCTION else 0;
    const value: u64 = (address orelse 0) & ~@as(u64, 3);
    switch (slot) {
        inline 0...breakpoints - 1 => |n| writeBreakpoint(n, value, control),
        else => {},
    }
}

fn setWatchpointRegister(slot: u32, set: ?Watch) void {
    const watch = set orelse Watch{ .control = 0, .address = 0 };
    switch (slot) {
        inline 0...watchpoints - 1 => |n| writeWatchpoint(n, watch.address, watch.control),
        else => {},
    }
}

fn mdscr() u64 {
    return asm volatile ("mrs %[r], mdscr_el1"
        : [r] "=r" (-> u64),
    );
}

fn setMdscr(value: u64) void {
    asm volatile ("msr mdscr_el1, %[v]; isb"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

/// This core's debug opened up: the OS lock released, debug exceptions
/// at EL1 on. Every breakpoint and watchpoint off until the table says.
pub fn init() void {
    asm volatile (
        \\msr osdlr_el1, xzr
        \\msr oslar_el1, xzr
        \\isb
        ::: .{ .memory = true });
    var slot: u32 = 0;
    while (slot < breakpoints) : (slot += 1) setBreakpointRegister(slot, null);
    slot = 0;
    while (slot < watchpoints) : (slot += 1) setWatchpointRegister(slot, null);
    setMdscr((mdscr() & ~MDSCR_SS) | MDSCR_KDE | MDSCR_MDE);
    load(here());
}

// --- what the debugger asks for --------------------------------------------------

/// What the debugger asked for, for every core: the breakpoints'
/// addresses, the watchpoints, and how many times any of it has changed.
var breakpoint_at: [breakpoints]?usize = @splat(null);
var watch_at: [watchpoints]?Watch = @splat(null);
var changes: u32 = 0;

/// A watchpoint as its registers take it.
const Watch = struct { control: u64, address: u64 };

/// One core's part: its visit, its step, and which change of the table its
/// registers hold.
const Core = struct {
    /// A step the person asked for, which does stop; and a breakpoint or
    /// watchpoint held off for the one instruction at its own address.
    stepping: bool = false,
    held_slot: ?u32 = null,
    held_watches: bool = false,
    /// A step is running, and the stepped frame's own IRQ mask.
    in_step: bool = false,
    saved_irq_mask: u64 = 0,
    /// The frame of the visit going on now, and what stopped it.
    current: ?*trap.Frame = null,
    last_cause: Cause = .stopped,
    /// Whether the debugger already has this core: a debug exception
    /// cannot come inside an exception, but a `brk` in code it calls could.
    inside: bool = false,
    loaded: u32 = 0,
};

var cores: [exec_base.max_cores]Core = @splat(.{});

/// The core this runs on. Everything here runs in an exception or with
/// interrupts masked, so it stays on it.
fn here() *Core {
    return &cores[cpu.coreId()];
}

/// This core's registers made what the table says, but for a breakpoint
/// it holds off for one instruction, and the watchpoints while a step
/// carries one over.
fn load(core: *Core) void {
    core.loaded = @atomicLoad(u32, &changes, .acquire);
    var slot: u32 = 0;
    while (slot < breakpoints) : (slot += 1) {
        const at = if (core.held_slot == slot) null else breakpoint_at[slot];
        setBreakpointRegister(slot, at);
    }
    slot = 0;
    while (slot < watchpoints) : (slot += 1) {
        setWatchpointRegister(slot, if (core.held_watches) null else watch_at[slot]);
    }
    asm volatile ("isb" ::: .{ .memory = true });
}

/// The table changed: counted for the other cores, loaded on this one.
fn changed() void {
    @atomicStore(u32, &changes, changes +% 1, .release);
    load(here());
}

/// The table loaded if it changed since this core last did: another
/// core's turn, as it leaves the park the debugger held it in.
pub fn catchUp() void {
    const core = here();
    if (core.loaded == @atomicLoad(u32, &changes, .acquire)) return;
    load(core);
}

/// A breakpoint at `address`, or off when `address` is null.
pub fn setBreakpoint(slot: u32, address: ?usize) void {
    if (slot >= breakpoints) return;
    breakpoint_at[slot] = address;
    changed();
}

/// Where a breakpoint is, for the debugger to list.
pub fn breakpointAt(slot: u32) ?usize {
    if (slot >= breakpoints) return null;
    return breakpoint_at[slot];
}

/// A watchpoint on `size` bytes at `address`, on reading, on writing or on
/// both; off when `address` is null. Within one doubleword the bytes
/// themselves are watched; more, a power of two of them aligned to its
/// size, up to 2 GiB.
pub fn setWatchpoint(slot: u32, address: ?usize, size: u32, on_read: bool, on_write: bool) void {
    if (slot >= watchpoints) return;
    const at = address orelse {
        watch_at[slot] = null;
        return changed();
    };
    var control: u64 = WCR_EL1;
    if (on_read) control |= WCR_LOAD;
    if (on_write) control |= WCR_STORE;
    const length: u64 = @max(size, 1);
    const offset = at & 7;
    var base: u64 = at;
    if (offset + length <= 8) {
        const bytes: u64 = (@as(u64, 1) << @intCast(length)) - 1;
        control |= (bytes << @intCast(offset)) << WCR_BAS_SHIFT;
        base = at & ~@as(u64, 7);
    } else {
        // The smallest aligned power of two that holds all of it.
        var bits: u6 = 3;
        while (bits < 31) : (bits += 1) {
            base = at & ~((@as(u64, 1) << bits) - 1);
            if (base + (@as(u64, 1) << bits) >= at + length) break;
        }
        control |= @as(u64, 0xFF) << WCR_BAS_SHIFT | @as(u64, bits) << WCR_MASK_SHIFT;
    }
    watch_at[slot] = .{ .control = control, .address = base };
    changed();
}

/// The next instruction only, then back to the debugger.
pub fn step() void {
    const core = here();
    const frame = core.current orelse return;
    holdAt(core, frame.elr);
    core.stepping = true;
    stepFrom(core, frame);
}

/// Going on from where the debugger stopped. A breakpoint at the address
/// about to run, or the watchpoint that stopped it, is carried over its
/// own instruction: held off, stepped past, put back - a step that stops
/// for nobody.
pub fn resumeFrom(pc: usize) void {
    const core = here();
    core.stepping = false;
    holdAt(core, pc);
    if (core.held_slot == null and !core.held_watches) return;
    const frame = core.current orelse return;
    stepFrom(core, frame);
}

/// One instruction stepped from `frame` as it goes on: its step bits set,
/// and its IRQs held off meanwhile.
fn stepFrom(core: *Core, frame: *trap.Frame) void {
    if (!core.in_step) {
        core.saved_irq_mask = frame.spsr & SPSR_I;
        core.in_step = true;
    }
    frame.spsr |= SPSR_SS | SPSR_I;
    setMdscr(mdscr() | MDSCR_SS);
}

/// The step over: the frame's own IRQ mask put back, the held breakpoint
/// and the watchpoints back in their registers.
fn endStep(core: *Core, frame: *trap.Frame) void {
    setMdscr(mdscr() & ~MDSCR_SS);
    frame.spsr &= ~SPSR_SS;
    if (core.in_step) {
        frame.spsr = (frame.spsr & ~SPSR_I) | core.saved_irq_mask;
        core.in_step = false;
    }
    core.held_slot = null;
    core.held_watches = false;
    load(core);
}

/// The breakpoint at `pc`, if there is one, held off on this core for the
/// one instruction about to run - and the watchpoints, when one stopped it
/// there.
fn holdAt(core: *Core, pc: usize) void {
    core.held_slot = null;
    var slot: u32 = 0;
    while (slot < breakpoints) : (slot += 1) {
        if (breakpoint_at[slot] != pc) continue;
        core.held_slot = slot;
        break;
    }
    core.held_watches = core.last_cause == .watchpoint;
    load(core);
}

/// Everything turned off, on every core, for going on without stopping
/// again.
pub fn clearAll() void {
    const core = here();
    core.stepping = false;
    breakpoint_at = @splat(null);
    watch_at = @splat(null);
    @atomicStore(u32, &changes, changes +% 1, .release);
    core.held_slot = null;
    core.held_watches = false;
    setMdscr(mdscr() & ~MDSCR_SS);
    load(core);
}

/// What stopped the core, in words.
pub fn causeName(what: u32) [:0]const u8 {
    return switch (what) {
        @intFromEnum(Cause.breakpoint) => "breakpoint",
        @intFromEnum(Cause.watchpoint) => "watchpoint",
        @intFromEnum(Cause.stepped) => "stepped",
        @intFromEnum(Cause.brk) => "a BRK instruction",
        else => "stopped",
    };
}

// --- the debug exceptions ------------------------------------------------------------

/// A debug exception or a `brk`, from trap.zig, by its class. Returns
/// without stopping when it is the step that carries a breakpoint or a
/// watchpoint over its own instruction; otherwise the debugger is given
/// the machine, and a `brk` is gone past when it goes on.
pub fn onDebug(frame: *trap.Frame, class: trap.Class) void {
    const core = here();
    if (core.inside) {
        clearAll();
        if (class == .brk) frame.elr += 4;
        return;
    }
    core.current = frame;
    const cause: Cause = switch (class) {
        .step => blk: {
            endStep(core, frame);
            if (!core.stepping) return; // only carried a breakpoint over itself
            break :blk .stepped;
        },
        .breakpoint => .breakpoint,
        .watchpoint => .watchpoint,
        else => blk: {
            frame.elr += 4;
            break :blk .brk;
        },
    };
    core.stepping = false;
    core.last_cause = cause;
    core.inside = true;
    defer core.inside = false;
    debug.enter(.stopped, frame, @intFromEnum(cause));
}

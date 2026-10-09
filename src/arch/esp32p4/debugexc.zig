// SPDX-License-Identifier: MPL-2.0
//! The core's debug triggers, for the ROM debugger: breakpoints,
//! watchpoints and a single step, each arriving as a breakpoint exception
//! (mcause 3) through the ordinary trap entry, as an `ebreak` does.
//!
//! The HP core has three triggers, each an address match (`mcontrol`) on
//! an instruction's fetch or on a load or a store: no instruction counter.
//! Two are breakpoints, the third a watchpoint, and a step borrows the
//! third: the next instruction's address is worked out from the stopped
//! one - a jump's target, a branch's taken or not by its registers in the
//! frame, the compressed forms - and the trigger set there. A watchpoint
//! that was set is off for that one instruction and back after it.
//!
//! Triggers fire in machine mode only while `tcontrol.MTE` is set; a trap
//! moves it to MPTE and clears it, mret puts it back. So none fires inside
//! a trap - the debugger itself included. Setting one from inside a trap
//! sets MPTE, for the stopped code to have them once it goes on; from task
//! level - the debugger called, not trapped into - MTE itself, as no mret
//! will, and the next trap keeps it in MPTE.
//!
//! A watchpoint fires before its load or store, so going on from one is
//! the same carrying over: the access stepped with the watchpoint off.
//!
//! **Going on from a breakpoint is not just returning.** The address is
//! the one the core stops at, so a return would stop again at once: that
//! breakpoint is held off, the one instruction stepped, the breakpoint put
//! back, and only then does the code run on - the step that does so stops
//! for nobody. While a step runs, the interrupt controller's threshold
//! keeps every interrupt off, so the step lands in the code being looked
//! at and not in whichever interrupt was next; the stopped code's own
//! interrupt state is not touched.

const exec = @import("../../rom/libs/exec/exec.zig");
const debug = @import("../../rom/libs/exec/debug/_debug.zig");
const trap = @import("trap.zig");
const reg = @import("sdk").hardware.mmio.reg;

/// The slots: breakpoints on triggers 0 and 1, the watchpoint and the step
/// on trigger 2.
pub const breakpoints = 2;
pub const watchpoints = 1;
const watch_trigger = 2;
const step_trigger = 2;

// tdata1 as mcontrol: the type (2), and what it matches.
const mcontrol: u32 = 2 << 28;
const match_napot: u32 = 1 << 7;
const in_machine_mode: u32 = 1 << 6;
const on_execute: u32 = 1 << 2;
const on_store: u32 = 1 << 1;
const on_load: u32 = 1 << 0;
const hit: u32 = 1 << 20;
// tcontrol: triggers on in machine mode now (MTE), and after the trap
// returns (MPTE).
const tcontrol_mte: u32 = 1 << 3;
const tcontrol_mpte: u32 = 1 << 7;

/// Whether this core is inside a trap: exec counts them.
fn inTrap() bool {
    return exec.initialized and exec.SysBase.cpu().int_depth != 0;
}
/// The largest range a watchpoint covers.
const largest_watch = 256;

/// What stopped the core, for the debugger to name: the trigger that hit,
/// or an `ebreak`.
pub const Cause = enum(u32) { breakpoint = 1, watchpoint = 2, stepped = 3, ebreak = 4, stopped = 0 };

/// This core's interrupt threshold, raised to hold every line off.
const clic_threshold: usize = 0x2080_0008;
const threshold_all: u32 = 0xFF << 24;

// --- the triggers ------------------------------------------------------------

fn select(trigger: u32) void {
    asm volatile ("csrw tselect, %[v]"
        :
        : [v] "r" (trigger),
    );
}

fn readData1() u32 {
    return asm volatile ("csrr %[r], tdata1"
        : [r] "=r" (-> u32),
    );
}

fn readData2() u32 {
    return asm volatile ("csrr %[r], tdata2"
        : [r] "=r" (-> u32),
    );
}

fn write(trigger: u32, data1: u32, data2: u32) void {
    select(trigger);
    asm volatile ("csrw tdata1, zero");
    if (data1 == 0) return;
    asm volatile ("csrw tdata2, %[v]"
        :
        : [v] "r" (data2),
    );
    asm volatile ("csrw tdata1, %[v]"
        :
        : [v] "r" (data1),
    );
    asm volatile ("csrs 0x7A5, %[v]"
        :
        : [v] "r" (if (inTrap()) tcontrol_mpte else tcontrol_mpte | tcontrol_mte),
    );
}

fn executeAt(trigger: u32, address: usize) void {
    write(trigger, mcontrol | in_machine_mode | on_execute, @intCast(address));
}

/// The trigger that hit, its mark cleared; null for none.
fn takeHit() ?u32 {
    var trigger: u32 = 0;
    while (trigger < 3) : (trigger += 1) {
        select(trigger);
        const data1 = readData1();
        if (data1 & hit == 0) continue;
        asm volatile ("csrw tdata1, %[v]"
            :
            : [v] "r" (data1 & ~hit),
        );
        return trigger;
    }
    return null;
}

// --- what the debugger asks for --------------------------------------------------

/// The breakpoints' addresses, kept here: the trigger's tdata2 is all the
/// core keeps, and a held one has none.
var breakpoint_at: [breakpoints]?usize = .{ null, null };

/// A breakpoint at `address`, or off when `address` is null.
pub fn setBreakpoint(slot: u32, address: ?usize) void {
    if (slot >= breakpoints) return;
    breakpoint_at[slot] = address;
    if (address) |at| executeAt(slot, at) else write(slot, 0, 0);
}

/// Where a breakpoint is, for the debugger to list.
pub fn breakpointAt(slot: u32) ?usize {
    if (slot >= breakpoints) return null;
    return breakpoint_at[slot];
}

/// A watchpoint on `size` bytes at `address`, on reading, on writing or on
/// both; off when `address` is null. The core watches a power of two up to
/// 256 bytes, aligned to its size (NAPOT: the low bits of the address say
/// how many).
pub fn setWatchpoint(slot: u32, address: ?usize, size: u32, on_read: bool, on_write: bool) void {
    if (slot >= watchpoints) return;
    const at = address orelse {
        watch = null;
        return write(watch_trigger, 0, 0);
    };
    var span: u32 = 1;
    while (span < size and span < largest_watch) span <<= 1;
    var control: u32 = mcontrol | in_machine_mode;
    if (on_read) control |= on_load;
    if (on_write) control |= on_store;
    var pattern: u32 = @intCast(at);
    if (span > 1) {
        control |= match_napot;
        pattern = (pattern & ~(span - 1)) | ((span - 1) >> 1);
    }
    watch = .{ .control = control, .pattern = pattern };
    write(watch_trigger, control, pattern);
}

/// The watchpoint as set, put back after a step has had its trigger.
const Watch = struct { control: u32, pattern: u32 };
var watch: ?Watch = null;

/// A step the person asked for, which does stop; and a breakpoint held off
/// for the one instruction at its own address.
var stepping = false;
var held_slot: ?u32 = null;
/// The frame of the visit going on now, and what stopped it.
var current: ?*trap.Frame = null;
var last_cause: Cause = .stopped;
/// The interrupt threshold before a step, put back after it.
var saved_threshold: u32 = 0;
var held_off_interrupts = false;

/// The next instruction only, then back to the debugger.
pub fn step() void {
    const frame = current orelse return;
    holdBreakpointAt(frame.mepc);
    stepping = true;
    stepFrom(frame);
}

/// Going on from where the debugger stopped. A breakpoint at the address
/// about to run is carried over its own instruction: held off, stepped
/// past, put back - a step that stops for nobody.
pub fn resumeFrom(pc: usize) void {
    stepping = false;
    holdBreakpointAt(pc);
    if (held_slot == null and last_cause != .watchpoint) return;
    const frame = current orelse return;
    stepFrom(frame);
}

fn stepFrom(frame: *trap.Frame) void {
    executeAt(step_trigger, nextPc(frame));
    if (!held_off_interrupts) {
        saved_threshold = reg(clic_threshold).*;
        reg(clic_threshold).* = threshold_all;
        // Read back: the new threshold holds once the write has landed.
        _ = reg(clic_threshold).*;
        held_off_interrupts = true;
    }
}

fn endStep() void {
    if (watch) |set| write(watch_trigger, set.control, set.pattern) else write(step_trigger, 0, 0);
    if (held_off_interrupts) {
        reg(clic_threshold).* = saved_threshold;
        held_off_interrupts = false;
    }
    if (held_slot) |slot| {
        held_slot = null;
        if (breakpoint_at[slot]) |at| executeAt(slot, at);
    }
}

/// The breakpoint at `pc`, if there is one, held off for the one
/// instruction about to run.
fn holdBreakpointAt(pc: usize) void {
    held_slot = null;
    for (breakpoint_at, 0..) |maybe, slot| {
        if (maybe != pc) continue;
        held_slot = @intCast(slot);
        write(@intCast(slot), 0, 0);
        return;
    }
}

/// Everything turned off, for going on without stopping again.
pub fn clearAll() void {
    stepping = false;
    endStep();
    var trigger: u32 = 0;
    while (trigger < 3) : (trigger += 1) write(trigger, 0, 0);
    breakpoint_at = .{ null, null };
    watch = null;
}

/// What stopped the core, in words.
pub fn causeName(what: u32) [:0]const u8 {
    return switch (what) {
        @intFromEnum(Cause.breakpoint) => "breakpoint",
        @intFromEnum(Cause.watchpoint) => "watchpoint",
        @intFromEnum(Cause.stepped) => "stepped",
        @intFromEnum(Cause.ebreak) => "an EBREAK instruction",
        else => "stopped",
    };
}

// --- the next instruction ------------------------------------------------------------

fn register(frame: *const trap.Frame, number: u32) u32 {
    return if (number == 0) 0 else frame.x[number & 31];
}

fn signExtend(value: u32, comptime bits: u5) u32 {
    const shift: u5 = 32 - @as(u6, bits);
    return @bitCast(@as(i32, @bitCast(value << shift)) >> shift);
}

/// Where the instruction at the frame's pc goes on to: past it, or where
/// a jump or a taken branch sends it.
pub fn nextPc(frame: *const trap.Frame) usize {
    const pc: u32 = frame.mepc;
    const low: u16 = @as(*const volatile u16, @ptrFromInt(pc)).*;
    if (low & 3 != 3) return compressedNext(frame, pc, low);
    const high: u32 = @as(*const volatile u16, @ptrFromInt(pc + 2)).*;
    const word: u32 = high << 16 | low;
    const opcode = word & 0x7F;
    const rs1 = register(frame, (word >> 15) & 31);
    const rs2 = register(frame, (word >> 20) & 31);
    switch (opcode) {
        0x6F => { // jal
            const imm = (word >> 31) << 20 | ((word >> 12) & 0xFF) << 12 | ((word >> 20) & 1) << 11 | ((word >> 21) & 0x3FF) << 1;
            return pc +% signExtend(imm, 21);
        },
        0x67 => return (rs1 +% signExtend(word >> 20, 12)) & ~@as(u32, 1), // jalr
        0x63 => { // branches
            const imm = (word >> 31) << 12 | ((word >> 7) & 1) << 11 | ((word >> 25) & 0x3F) << 5 | ((word >> 8) & 0xF) << 1;
            const taken = switch ((word >> 12) & 7) {
                0 => rs1 == rs2,
                1 => rs1 != rs2,
                4 => @as(i32, @bitCast(rs1)) < @as(i32, @bitCast(rs2)),
                5 => @as(i32, @bitCast(rs1)) >= @as(i32, @bitCast(rs2)),
                6 => rs1 < rs2,
                7 => rs1 >= rs2,
                else => false,
            };
            return if (taken) pc +% signExtend(imm, 13) else pc + 4;
        },
        else => return pc + 4,
    }
}

fn compressedNext(frame: *const trap.Frame, pc: u32, half: u16) usize {
    const word: u32 = half;
    const op = word & 3;
    const funct3 = (word >> 13) & 7;
    if (op == 1 and (funct3 == 5 or funct3 == 1)) { // c.j, c.jal
        const imm = ((word >> 12) & 1) << 11 | ((word >> 8) & 1) << 10 | ((word >> 9) & 3) << 8 |
            ((word >> 6) & 1) << 7 | ((word >> 7) & 1) << 6 | ((word >> 2) & 1) << 5 |
            ((word >> 11) & 1) << 4 | ((word >> 3) & 7) << 1;
        return pc +% signExtend(imm, 12);
    }
    if (op == 1 and (funct3 == 6 or funct3 == 7)) { // c.beqz, c.bnez
        const rs1 = register(frame, 8 + ((word >> 7) & 7));
        const imm = ((word >> 12) & 1) << 8 | ((word >> 5) & 3) << 6 | ((word >> 2) & 1) << 5 |
            ((word >> 10) & 3) << 3 | ((word >> 3) & 3) << 1;
        const taken = if (funct3 == 6) rs1 == 0 else rs1 != 0;
        return if (taken) pc +% signExtend(imm, 9) else pc + 2;
    }
    if (op == 2 and funct3 == 4 and (word >> 2) & 31 == 0 and (word >> 7) & 31 != 0) { // c.jr, c.jalr
        return register(frame, (word >> 7) & 31) & ~@as(u32, 1);
    }
    return pc + 2;
}

// --- the breakpoint exception ------------------------------------------------------------

/// Whether the debugger already has the machine: a trigger cannot fire
/// inside a trap, but an `ebreak` in code it calls could.
var inside = false;

/// The breakpoint exception, from trap.zig. Returns without stopping when
/// it is the step that carries a breakpoint over its own address;
/// otherwise the debugger is given the machine, and an `ebreak` is gone
/// past when it goes on.
pub fn onBreakpoint(frame: *trap.Frame) void {
    const trigger = takeHit();
    if (inside) {
        clearAll();
        if (trigger == null) frame.mepc += instructionLength(frame.mepc);
        return;
    }
    current = frame;
    var cause: Cause = .stopped;
    if (trigger) |which| {
        const was_step = held_off_interrupts and which == step_trigger;
        if (was_step) {
            endStep();
            if (!stepping) return; // only carried a breakpoint over itself
            cause = .stepped;
        } else {
            cause = if (which == watch_trigger) .watchpoint else .breakpoint;
        }
    } else {
        cause = .ebreak;
        frame.mepc += instructionLength(frame.mepc);
    }
    stepping = false;
    last_cause = cause;
    inside = true;
    defer inside = false;
    debug.enter(.stopped, frame, @intFromEnum(cause));
}

fn instructionLength(pc: u32) u32 {
    const low: u16 = @as(*const volatile u16, @ptrFromInt(pc)).*;
    return if (low & 3 == 3) 4 else 2;
}

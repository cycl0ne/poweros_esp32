// SPDX-License-Identifier: MPL-2.0
//! Exception and interrupt dispatch. start.S saves the interrupted context
//! into a `Frame` and calls `xtensa_exception` for every level-1 exception,
//! including level-1 interrupts.

const std = @import("std");
const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const timer = @import("timer.zig");

/// The CPU's level-1 software interrupt line, used for exec's Cause. It is
/// dispatched after the hardware lines, so software interrupts run after
/// hardware interrupts.
pub const software_line = 7;

/// Layout shared with start.S.
pub const Frame = extern struct {
    pc: u32,
    ps: u32,
    sar: u32,
    exccause: u32,
    excvaddr: u32,
    lbeg: u32,
    lend: u32,
    lcount: u32,
    a: [16]u32,
};

comptime {
    std.debug.assert(@sizeOf(Frame) == 96);
}

/// The frame sits this far below the interrupted stack pointer (start.S
/// FRAME_OFFSET).
pub const frame_offset = 128;

const Cause = enum(u32) {
    illegal_instruction = 0,
    syscall = 1,
    instruction_fetch_error = 2,
    load_store_error = 3,
    level1_interrupt = 4,
    alloca = 5,
    integer_divide_by_zero = 6,
    privileged = 8,
    load_store_alignment = 9,
    instr_pif_data_error = 12,
    load_store_pif_data_error = 13,
    instr_pif_addr_error = 14,
    load_store_pif_addr_error = 15,
    inst_tlb_miss = 16,
    inst_tlb_multi_hit = 17,
    inst_fetch_privilege = 18,
    inst_fetch_prohibited = 20,
    load_store_tlb_miss = 24,
    load_store_tlb_multi_hit = 25,
    load_store_privilege = 26,
    load_prohibited = 28,
    store_prohibited = 29,
    _,
};

/// Gets the CPU interrupt line that fired.
pub const Handler = *const fn (irq: u5) void;
var handlers: [32]?Handler = @splat(null);

pub fn setHandler(irq: u5, handler: Handler) void {
    handlers[irq] = handler;
}

pub const Syscall = enum(u32) {
    ping = 0,
    ticks = 1,
    uptime_ms = 2,
    /// Enter the kernel so exec can switch tasks on the way out.
    reschedule = 3,
    /// End a task exception: resume the frame in `arg` instead.
    leave_exception = 4,
    _,
};

/// Set by the leave_exception syscall.
var resume_frame: ?*Frame = null;

/// Trap into the kernel with `syscall`; the result comes back in a2.
pub fn syscall(nr: u32, arg: u32) u32 {
    return asm volatile ("syscall"
        : [ret] "={a2}" (-> u32),
        : [nr] "{a2}" (nr),
          [arg] "{a3}" (arg),
        : .{ .memory = true });
}

/// Called by start.S for every level-1 exception. Returns the frame to
/// resume: `frame` itself, or another task's when exec switched tasks.
export fn xtensa_exception(frame: *Frame) callconv(.c) *Frame {
    if (!exec.initialized) {
        handle(frame);
        return frame;
    }
    exec.interruptEnter(exec.SysBase);
    handle(frame);
    const current = resume_frame orelse frame;
    resume_frame = null;
    return @ptrCast(@alignCast(exec.interruptExit(exec.SysBase, current)));
}

fn handle(frame: *Frame) void {
    switch (@as(Cause, @enumFromInt(frame.exccause))) {
        .level1_interrupt => dispatchInterrupts(),
        .syscall => {
            frame.a[2] = handleSyscall(@enumFromInt(frame.a[2]), frame.a[3]);
            frame.pc += 3; // skip the syscall instruction
        },
        else => {
            // Before exec is up there is nobody to ask.
            if (!exec.initialized) fatal(frame);
            var info: exec.TrapInfo = .{
                .number = frame.exccause,
                .pc = frame.pc,
                .address = frame.excvaddr,
                .frame = frame,
            };
            exec.dispatchTrap(exec.SysBase, &info); // returns only if the trap code handled it
            frame.pc = @intCast(info.pc);
        },
    }
}

fn dispatchInterrupts() void {
    const all = cpu.interrupt() & cpu.intenable();
    const soft = all & (@as(u32, 1) << software_line);
    var pending = all & ~soft;
    while (pending != 0) {
        const irq: u5 = @intCast(@ctz(pending));
        pending &= pending - 1;
        dispatchLine(irq);
    }
    if (soft != 0) dispatchLine(software_line);
}

fn dispatchLine(irq: u5) void {
    if (handlers[irq]) |handler| {
        handler(irq);
    } else {
        cpu.disableInterrupt(irq);
        exec.kprintf("\n[trap] spurious interrupt %d, disabled\n", .{irq});
    }
}

fn handleSyscall(nr: Syscall, arg: u32) u32 {
    return switch (nr) {
        .ping => arg +% 1,
        .ticks => timer.tickCount(),
        .uptime_ms => @truncate(timer.uptimeUs() / 1000),
        .reschedule => 0,
        .leave_exception => blk: {
            resume_frame = @ptrFromInt(arg);
            break :blk 0;
        },
        _ => 0xFFFF_FFFF,
    };
}

/// Name of an exception cause (EXCCAUSE).
pub fn causeName(exccause: u32) [:0]const u8 {
    return std.enums.tagName(Cause, @enumFromInt(exccause)) orelse "unknown";
}

/// Exceptions before exec is up: dump and halt.
fn fatal(f: *const Frame) noreturn {
    _ = cpu.setIntlevel(15);
    exec.kprintf("\n*** FATAL EXCEPTION %d (%s)\n", .{ f.exccause, causeName(f.exccause) });
    dumpFrame(f);
    exec.kprintf("*** system halted\n", .{});
    cpu.halt();
}

/// The saved registers of an exception.
pub fn dumpFrame(f: *const Frame) void {
    exec.kprintf("  PC       0x%08x  PS  0x%08x  SAR    0x%08x\n", .{ f.pc, f.ps, f.sar });
    exec.kprintf("  EXCVADDR 0x%08x  LBEG 0x%08x LEND 0x%08x LCOUNT 0x%08x\n", .{ f.excvaddr, f.lbeg, f.lend, f.lcount });
    for (0..4) |row| {
        exec.kprintf(" ", .{});
        for (0..4) |col| {
            const i = row * 4 + col;
            exec.kprintf(" A%-2d 0x%08x", .{ i, f.a[i] });
        }
        exec.kprintf("\n", .{});
    }
    // a0 holds the return address with the call size in its top two bits.
    const caller = (f.a[0] & 0x3FFF_FFFF) | (f.pc & 0xC000_0000);
    exec.kprintf("  caller   0x%08x\n", .{caller});
}

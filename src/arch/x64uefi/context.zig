// SPDX-License-Identifier: MPL-2.0
//! Task contexts for exec on an x86-64 machine. A switched-out task is its
//! exception frame (trap.Frame), right below its stack pointer: the
//! general registers, the five words an `iretq` takes and the SSE state. A
//! task's context is the frame's address.
//!
//! **A task starts as if it had been called.** The frame is built so that
//! the `iretq` out of the exception enters `entry` with `arg` in the
//! register the first argument is in, on a stack whose top word is a
//! return address of zero - so a return from a task's code faults where it
//! happened instead of wandering off - and with the stack pointer where a
//! called function expects to find it. The frame itself sits below that,
//! on sixteen bytes, which is what FXRSTOR wants of the SSE state in it.
//!
//! **The SSE state of a task that has not run yet** is not all zeroes: a
//! zeroed control word would leave every floating-point exception unmasked
//! and the first inexact result would trap. The two control words are set
//! to what the architecture starts a core with.

const std = @import("std");
const cpu = @import("cpu.zig");
const desc = @import("desc.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const trap = @import("trap.zig");

pub const hardware: exec.TaskHardware = .{
    .init_context = initContext,
    .switch_now = switchNow,
    .idle = idle,
    .push_exception = pushException,
    .leave_exception = leaveException,
    .call_on_stack = callOnStack,
    .leaving = &task_leaving,
};

/// The task each core's dispatcher is switching away from, until start.S
/// has moved to the next task's stack, and clears it.
export var task_leaving: [exec_base.max_cores]usize = @splat(0);

/// RFLAGS of a task that has not run yet: bit 1 is always set, and the
/// interrupts are on.
const RFLAGS_START: u64 = 0x2 | cpu.FLAGS_IF;

/// The x87 control word a core starts with: extended precision, every
/// exception masked.
const FCW_START: u16 = 0x037F;
/// The SSE control word a core starts with: every exception masked, no
/// flush to zero, round to nearest.
const MXCSR_START: u32 = 0x1F80;
/// Where the two sit in FXSAVE's area.
const FX_FCW = 0;
const FX_MXCSR = 24;

/// A task's first context. Resuming it enters `entry` with `arg` as its
/// first argument, on the stack that ends at `stack_upper`, with this
/// core's interrupts on and the SSE state as new.
fn initContext(stack_upper: usize, entry: *const anyopaque, arg: *anyopaque) *anyopaque {
    const top = std.mem.alignBackward(usize, stack_upper, 16);
    const sp = top - 8;
    @as(*volatile usize, @ptrFromInt(sp)).* = 0; // a return from entry faults at 0
    const frame: *trap.Frame = @ptrFromInt(std.mem.alignBackward(usize, sp - trap.frame_offset, 16));
    frame.* = std.mem.zeroes(trap.Frame);
    frame.rip = @intFromPtr(entry);
    frame.cs = desc.GDT_CODE;
    frame.rflags = RFLAGS_START;
    frame.rsp = sp;
    frame.ss = desc.GDT_DATA;
    frame.rdi = @intFromPtr(arg);
    frame.rbp = 0; // the frame-pointer chain ends here
    writeWord(frame, FX_FCW, FCW_START);
    writeLong(frame, FX_MXCSR, MXCSR_START);
    return frame;
}

fn writeWord(frame: *trap.Frame, at: usize, value: u16) void {
    frame.fx[at] = @truncate(value);
    frame.fx[at + 1] = @truncate(value >> 8);
}

fn writeLong(frame: *trap.Frame, at: usize, value: u32) void {
    for (0..4) |byte| frame.fx[at + byte] = @truncate(value >> @intCast(8 * byte));
}

extern fn x64_call_on_stack(stack_upper: usize, code: *const anyopaque, arg: ?*anyopaque) callconv(.c) i32;

/// exec's NewStackRun: `code(arg)` on the stack that ends at `stack_upper`.
fn callOnStack(stack_upper: usize, code: *const anyopaque, arg: ?*anyopaque) i32 {
    return x64_call_on_stack(stack_upper, code, arg);
}

/// From task level: a syscall enters the kernel, and exec switches on the
/// way out.
fn switchNow() void {
    _ = trap.syscall(@intFromEnum(trap.Syscall.reschedule), 0);
}

/// The idle task's sleep. The core's counter runs through `hlt` on every
/// machine this system runs on - it counts at a fixed rate whatever the
/// core is doing, which is what makes it this machine's clock as well - so
/// the time asleep is counted to the idle task, which is where it belongs,
/// and nothing has to be credited back the way it is on a chip whose
/// counter stops.
fn idle() void {
    cpu.waitForInterrupt();
}

/// A task exception: a first context as for a new task, whose stack starts
/// right below the frame of where the task was, so that frame stays
/// untouched.
fn pushException(context: *anyopaque, entry: *const anyopaque) *anyopaque {
    return initContext(@intFromPtr(context), entry, context);
}

/// The kernel drops the exception's context and resumes `context`.
fn leaveException(context: *anyopaque) noreturn {
    _ = trap.syscall(@intFromEnum(trap.Syscall.leave_exception), @intFromPtr(context));
    unreachable;
}

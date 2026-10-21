// SPDX-License-Identifier: MPL-2.0
//! Task contexts for exec on an AArch64 machine at EL1. A switched-out
//! task is its exception frame (trap.Frame), right below its stack
//! pointer: the general registers, the exception's registers and the
//! FPU's. A task's context is the frame's address.

const std = @import("std");
const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const timer = @import("timer.zig");
const trap = @import("trap.zig");
const systimer = @import("sdk").hardware.systimer;

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

/// A task's first context. Resuming it (eret) enters `entry` with `arg`
/// as its first argument, on a stack whose top is `stack_upper` rounded
/// down to 16 bytes, at EL1 with interrupts on and the FPU as new.
fn initContext(stack_upper: usize, entry: *const anyopaque, arg: *anyopaque) *anyopaque {
    const sp = std.mem.alignBackward(usize, stack_upper, 16);
    const frame: *trap.Frame = @ptrFromInt(sp - trap.frame_offset);
    frame.* = std.mem.zeroes(trap.Frame);
    frame.elr = @intFromPtr(entry);
    frame.spsr = cpu.SPSR_EL1H;
    frame.x[31] = sp;
    frame.x[30] = 0; // link register: entry never returns
    frame.x[29] = 0; // frame pointer: the chain ends here
    frame.x[0] = @intFromPtr(arg);
    return frame;
}

extern fn a64_call_on_stack(stack_upper: usize, code: *const anyopaque, arg: ?*anyopaque) callconv(.c) i32;

/// exec's NewStackRun: `code(arg)` on the stack that ends at `stack_upper`.
fn callOnStack(stack_upper: usize, code: *const anyopaque, arg: ?*anyopaque) i32 {
    return a64_call_on_stack(stack_upper, code, arg);
}

/// From task level: a syscall enters the kernel, and exec switches on the
/// way out.
fn switchNow() void {
    _ = trap.syscall(@intFromEnum(trap.Syscall.reschedule), 0);
}

/// The idle task's sleep. exec counts a core's time in cycles, and a
/// core's cycle counter may stop in `wfi`, so the sleep is timed on the
/// system counter as well and what the cycle counter missed counted to
/// idle (exec's `idleSlept`) - with the interrupts masked over it, so
/// before the interrupt that ends it is taken. `wfi` wakes for any
/// pending interrupt, masked or not. Where the counter runs on, it
/// misses nothing.
fn idle() void {
    _ = cpu.disableInterrupts();
    const time_before = timer.now();
    const cycles_before = exec_base.cycles();
    cpu.waitForInterrupt();
    const counted = exec_base.cycles() -% cycles_before;
    const slept = (timer.now() -% time_before) * timer.cpu_hz / systimer.timebase_hz;
    if (slept > counted) exec.idleSlept(exec.SysBase, @intCast(@min(slept - counted, std.math.maxInt(u32))));
    cpu.enableInterrupts();
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

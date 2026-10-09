// SPDX-License-Identifier: MPL-2.0
//! Task contexts for exec on the ESP32-P4's RISC-V cores. A switched-out
//! task is its trap frame (trap.Frame), right below its stack pointer: the
//! integer registers, the trap's CSRs and, when the task has used the FPU,
//! the FPU's registers. A task's context is the frame's address.

const std = @import("std");
const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
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
export var task_leaving: [2]usize = .{ 0, 0 };

/// A task's first context. Resuming it (mret) enters `entry` with `arg`
/// as its first argument, on a stack whose top is `stack_upper` rounded
/// down to 16 bytes, in machine mode with interrupts on and the FPU unused.
fn initContext(stack_upper: usize, entry: *const anyopaque, arg: *anyopaque) *anyopaque {
    const sp = std.mem.alignBackward(usize, stack_upper, 16);
    const frame: *trap.Frame = @ptrFromInt(sp - trap.frame_offset);
    frame.* = std.mem.zeroes(trap.Frame);
    frame.mepc = @intCast(@intFromPtr(entry));
    frame.mstatus = cpu.MSTATUS_MPP_M | cpu.MSTATUS_MPIE | cpu.MSTATUS_FS_INITIAL;
    frame.mcause = cpu.MCAUSE_MPP_M | cpu.MCAUSE_MPIE;
    frame.x[2] = @intCast(sp);
    frame.x[1] = 0; // return address: entry never returns
    frame.x[10] = @intCast(@intFromPtr(arg));
    return frame;
}

extern fn riscv_call_on_stack(stack_upper: usize, code: *const anyopaque, arg: ?*anyopaque) callconv(.c) i32;

/// exec's NewStackRun: `code(arg)` on the stack that ends at `stack_upper`.
fn callOnStack(stack_upper: usize, code: *const anyopaque, arg: ?*anyopaque) i32 {
    return riscv_call_on_stack(stack_upper, code, arg);
}

/// From task level: a syscall enters the kernel, and exec switches on the
/// way out.
fn switchNow() void {
    _ = trap.syscall(@intFromEnum(trap.Syscall.reschedule), 0);
}

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
    _ = trap.syscall(@intFromEnum(trap.Syscall.leave_exception), @intCast(@intFromPtr(context)));
    unreachable;
}

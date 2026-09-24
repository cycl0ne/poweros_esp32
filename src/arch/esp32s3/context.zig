// SPDX-License-Identifier: MPL-2.0
//! Task contexts for exec on the Xtensa LX7 (windowed ABI). A switched-out
//! task is its exception frame (trap.Frame, frame_offset below its stack
//! pointer) plus its call chain, which start.S spilled to its stack.

const std = @import("std");
const cpu = @import("cpu.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const trap = @import("trap.zig");

const ps_excm: u32 = 1 << 4;
const ps_um: u32 = 1 << 5;
/// PS.CALLINC = 1: `entry` rotates the window as after a call4.
const ps_callinc_4: u32 = 1 << 16;
const ps_woe: u32 = 1 << 18;

pub const hardware: exec.TaskHardware = .{
    .init_context = initContext,
    .switch_now = switchNow,
    .idle = idle,
    .push_exception = pushException,
    .leave_exception = leaveException,
    .call_on_stack = callOnStack,
};

/// A task's first context. Resuming it (rfe) enters `entry` as if called
/// with call4 from a frame whose stack pointer is the top of the task's
/// stack, with `arg` as the first argument and interrupts enabled. That
/// calling frame's window stays live, so spills of `entry`'s frame find a
/// valid caller stack pointer.
fn initContext(stack_upper: usize, entry: *const anyopaque, arg: *anyopaque) *anyopaque {
    const sp = std.mem.alignBackward(usize, stack_upper, 16);
    const frame: *trap.Frame = @ptrFromInt(sp - trap.frame_offset);
    frame.* = std.mem.zeroes(trap.Frame);
    frame.pc = @intCast(@intFromPtr(entry));
    frame.ps = ps_excm | ps_um | ps_callinc_4 | ps_woe;
    frame.a[1] = @intCast(sp);
    frame.a[4] = 0; // return address: entry never returns
    frame.a[6] = @intCast(@intFromPtr(arg)); // becomes entry's a2
    return frame;
}

extern fn xtensa_call_on_stack(stack_upper: usize, code: *const anyopaque, arg: ?*anyopaque) callconv(.c) i32;

/// exec's NewStackRun: `code(arg)` on the stack that ends at
/// `stack_upper` (stack.S: the windows spilled first, a1 moved around the
/// call).
fn callOnStack(stack_upper: usize, code: *const anyopaque, arg: ?*anyopaque) i32 {
    return xtensa_call_on_stack(stack_upper, code, arg);
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
/// right below the frame of where the task was, so that frame and the
/// task's spilled windows above it stay untouched.
fn pushException(context: *anyopaque, entry: *const anyopaque) *anyopaque {
    return initContext(@intFromPtr(context), entry, context);
}

/// The kernel drops the exception's context and resumes `context`
/// (start.S spills the exception's windows first, as for a task switch).
fn leaveException(context: *anyopaque) noreturn {
    _ = trap.syscall(@intFromEnum(trap.Syscall.leave_exception), @intCast(@intFromPtr(context)));
    unreachable;
}

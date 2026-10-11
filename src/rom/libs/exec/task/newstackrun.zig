// SPDX-License-Identifier: MPL-2.0
//! NewStackRun: runs a function on a stack of its own, for code that needs
//! more stack than the task has. The task's stack bounds are moved for the
//! call and put back after it, so a stack check sees the right ones - and
//! the check is off while the bounds and the stack pointer disagree: from
//! the moment the bounds move until the code runs on the new stack, and
//! from its return until they are back.

const sdk = @import("sdk");
const _task = @import("_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Runs a function on a stack of its own, and comes back.
///
/// SYNOPSIS:
/// ```zig
/// fn NewStackRun(base: *ExecBase, code: sdk.exec.StackFn, arg: ?*anyopaque,
///     stack_size: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -420.
///
/// INPUTS:
/// - `code` - what to run. It is handed `arg` and answers an `i32`.
/// - `arg` - passed through untouched.
/// - `stack_size` - bytes of stack to allocate, at least a task's smallest.
///
/// RESULT:
/// What `code` answered, or -1 if there was no memory for the stack.
///
/// BEHAVIOR:
/// The running task's `sp_lower` and `sp_upper` follow the new stack while
/// the code runs and are put back afterwards, so anything that checks how
/// much stack is left sees the right one.
///
/// It is a call, not a task: the same task runs `code`, on different
/// memory, and control comes back when it returns.
///
/// **The new stack is guarded** as a task's is (`AddTask`): the dispatcher
/// checks its bottom words while `code` runs, and this call checks them
/// once more before it gives the stack back. A stack `code` ran past the
/// end of is a dead-end alert, `AN_StackProbe`, rather than memory quietly
/// written over below it. The dispatcher's check is on only while `code`
/// itself runs: in the instructions that move the stack pointer to the new
/// stack and back the task's bounds already say one stack while it is on
/// the other, and a switch there is no overrun.
///
/// CONTEXT:
/// - Waits: only if `code` does.
/// - Interrupts: no. It allocates.
/// - Locks: none needed.
/// - Process: whatever `code` needs. It stays the same task, so a Process
///   is still a Process inside it.
///
/// OWNERSHIP:
/// The stack is allocated and freed here. `code` must leave nothing
/// pointing into it: the memory is gone when this returns.
///
/// NOTES:
/// This is how a command gets a big stack without being a task of its own -
/// dos's `RunCommand` is the caller that matters.
///
/// A stack cannot simply be swapped under compiled code here, because the
/// register windows have to be spilled and the caller's save area moved
/// with the stack pointer. That is done in `src/arch/esp32s3/stack.S` around one
/// call, which is why this is a call and not a pair of "set the stack" and
/// "put it back" functions.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateTask`, `AddTask`
///
/// EXAMPLES:
/// ```zig
/// const rc = sys.NewStackRun(&runIt, ctx, 16 * 1024);
/// ```
pub fn NewStackRun(base: *ExecBase, code: sdk.exec.StackFn, arg: ?*anyopaque, stack_size: u32) i32 {
    const size = _task.alignUp(@max(stack_size, _task.min_stack_size), 16);
    const sys = base.iface();
    const stack = sys.AllocMem(size, sdk.exec.MEMF_ANY) orelse return -1;
    defer sys.FreeMem(stack, size);
    const task = sys.FindTask(null).?;
    // Volatile, in this order: an interrupt on this core may switch the
    // task away between any two of these stores and check what it finds.
    const flags: *volatile u8 = &task.flags;
    const sp_lower: *volatile usize = &task.sp_lower;
    const sp_upper: *volatile usize = &task.sp_upper;
    const lower = sp_lower.*;
    const upper = sp_upper.*;
    const guarded = flags.* & sdk.exec.TF_GUARDED;
    flags.* &= ~sdk.exec.TF_GUARDED;
    _task.writeGuard(@intFromPtr(stack));
    sp_lower.* = @intFromPtr(stack);
    sp_upper.* = @intFromPtr(stack) + size;
    var run: OnNewStack = .{ .code = code, .arg = arg, .flags = flags };
    const result = _task.task_hardware.call_on_stack(@intFromPtr(stack) + size, @ptrCast(&onNewStack), &run);
    sp_lower.* = lower;
    sp_upper.* = upper;
    flags.* = (flags.* & ~sdk.exec.TF_GUARDED) | guarded;
    if (!_task.guardIntact(@intFromPtr(stack))) {
        _task.stackOverrun(@intFromPtr(stack));
    }
    return result;
}

/// What the first frame on the new stack needs: the code and its argument,
/// and the task's flags, whose stack check it turns on and off.
const OnNewStack = struct {
    code: sdk.exec.StackFn,
    arg: ?*anyopaque,
    flags: *volatile u8,
};

/// The code, on the new stack: the dispatcher checks the task against its
/// new bounds from here, where the stack pointer is in them, until just
/// before it leaves them again.
fn onNewStack(arg: ?*anyopaque) callconv(.c) i32 {
    const run: *const OnNewStack = @ptrCast(@alignCast(arg.?));
    run.flags.* |= sdk.exec.TF_GUARDED;
    const result = run.code(run.arg);
    run.flags.* &= ~sdk.exec.TF_GUARDED;
    return result;
}

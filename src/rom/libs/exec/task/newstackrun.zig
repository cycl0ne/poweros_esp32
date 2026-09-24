// SPDX-License-Identifier: MPL-2.0
//! NewStackRun: runs a function on a stack of its own, for code that needs
//! more stack than the task has. The task's stack bounds are moved for the
//! call and put back after it, so a stack check sees the right ones.

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
/// CONTEXT:
/// - Waits: only if `code` does.
/// - Interrupts: no. It allocates.
/// - Forbid: not needed.
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
    const lower = task.sp_lower;
    const upper = task.sp_upper;
    task.sp_lower = @intFromPtr(stack);
    task.sp_upper = task.sp_lower + size;
    defer {
        task.sp_lower = lower;
        task.sp_upper = upper;
    }
    return _task.task_hardware.call_on_stack(task.sp_upper, @ptrCast(code), arg);
}

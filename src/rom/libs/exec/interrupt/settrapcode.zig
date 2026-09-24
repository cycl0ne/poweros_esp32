// SPDX-License-Identifier: MPL-2.0
//! SetTrapCode: gives the running task the code a CPU exception goes to,
//! and the data handed to it.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const TrapFn = sdk.exec.TrapFn;

/// Sets the running task's trap code, which takes its CPU exceptions.
///
/// SYNOPSIS:
/// ```zig
/// fn SetTrapCode(base: *ExecBase, code: ?TrapFn, data: ?*anyopaque) ?TrapFn
/// ```
///
/// SINCE: 1.0. LVO -156.
///
/// INPUTS:
/// - `code` - called with a `TrapInfo` and `data` when this task takes a
///   CPU exception; null to have none. It answers non-zero if it dealt with
///   the exception.
/// - `data` - passed to `code` untouched.
///
/// RESULT:
/// The trap code that was there, to be put back.
///
/// BEHAVIOR:
/// It is the **running** task's that is set, so a task can only do this to
/// itself.
///
/// When an exception arrives the trap code runs, and answering non-zero
/// means "handled": execution then carries on at `info.pc`, which the trap
/// code may have changed to step over the instruction that faulted. Any
/// other answer, or no trap code at all, ends in a dead-end alert.
///
/// CONTEXT:
/// - Waits: no. **The trap code itself must not wait**: it runs in the
///   exception, not on the task's own time.
/// - Interrupts: no - it reads the running task, and an interrupt has none
///   of its own.
/// - Forbid: not needed. The field belongs to the one task that can write
///   it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. `data` stays the caller's and must outlive the
/// trap code's time installed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Alert`, `AddTask`
///
/// EXAMPLES:
/// ```zig
/// const old = sys.SetTrapCode(&myTrap, self);
/// defer _ = sys.SetTrapCode(old, null);
/// ```
pub fn SetTrapCode(base: *ExecBase, code: ?TrapFn, data: ?*anyopaque) ?TrapFn {
    const task = base.iface().FindTask(null).?;
    const old = task.trap_code;
    task.trap_code = code;
    task.trap_data = data;
    return old;
}

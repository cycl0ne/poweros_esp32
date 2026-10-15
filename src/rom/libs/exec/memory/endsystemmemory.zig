// SPDX-License-Identifier: MPL-2.0
//! EndSystemMemory: the end of a BeginSystemMemory.

const ExecBase = @import("../exec.zig").ExecBase;

/// Ends a `BeginSystemMemory`.
///
/// SYNOPSIS:
/// ```zig
/// fn EndSystemMemory(base: *ExecBase) void
/// ```
///
/// SINCE: 1.11. LVO -552.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The calling task's count (`Task.system_memory_nest`) goes down by one;
/// at 0 what it allocates is its own again. Without a `BeginSystemMemory`
/// to end it does nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no: it is the calling task's.
/// - Locks: none taken, none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands: blocks allocated inside the pair stay the
/// system's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BeginSystemMemory`
///
/// EXAMPLES:
/// ```zig
/// sys.BeginSystemMemory();
/// defer sys.EndSystemMemory();
/// ```
pub fn EndSystemMemory(base: *ExecBase) void {
    if (base.boot_task == null) return;
    const task = base.iface().FindTask(null) orelse return;
    if (task.system_memory_nest != 0) task.system_memory_nest -= 1;
}

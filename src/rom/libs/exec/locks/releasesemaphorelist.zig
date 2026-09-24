// SPDX-License-Identifier: MPL-2.0
//! ReleaseSemaphoreList: gives up one hold on every semaphore of a list.

const sdk = @import("sdk");
const _locks = @import("_locks.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const List = sdk.exec.List;

/// Gives back every semaphore on a list.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseSemaphoreList(base: *ExecBase, list: *List) void
/// ```
///
/// SINCE: 1.0. LVO -260.
///
/// INPUTS:
/// - `list` - the list that was obtained. It must hold **the same
///   semaphores**: one that joined it since is released too, and one that
///   left is not.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Each is released in turn, and each may hand itself to its next waiter.
/// A semaphore on the list that this task does not hold raises
/// `AN_SemCorrupt`, which is how a list that changed under the holder makes
/// itself known.
///
/// CONTEXT:
/// - Waits: no, but it may signal and so may switch.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here.
/// - Process: a Task will do, and it must be the task that obtained them.
///
/// OWNERSHIP:
/// Every hold is given back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainSemaphoreList`, `ReleaseSemaphore`
///
/// EXAMPLES:
/// ```zig
/// defer sys.ReleaseSemaphoreList(&li.lock_list);
/// ```
pub fn ReleaseSemaphoreList(base: *ExecBase, list: *List) void {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    const task = sys.FindTask(null).?;
    var it = list.iterator();
    while (it.next()) |node| _locks.leave(base, _locks.semaphoreOf(node), task);
}

// SPDX-License-Identifier: MPL-2.0
//! ExecList: one of exec's own lists, by number.
//!
//! ExecBase is opaque to everything outside the kernel, so without this a
//! program could not walk a system list at all: `FindName` needs a list
//! pointer there is no other way to get. What it hands back is exec's own
//! state, not a copy, which is the bargain: reading it is cheap and
//! truthful, and the caller takes on the locking. Hold Forbid - Disable
//! for the task queues - write nothing, and keep no pointer past the lock.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const List = sdk.exec.List;

/// Hands back one of exec's own lists.
///
/// SYNOPSIS:
/// ```zig
/// fn ExecList(base: *ExecBase, which: u32) ?*List
/// ```
///
/// SINCE: 1.0. LVO -428.
///
/// INPUTS:
/// - `which` - `EXECLIST_MEMORY`, `_LIBRARIES`, `_DEVICES`, `_RESOURCES`,
///   `_PORTS`, `_SEMAPHORES`, `_TASK_READY`, `_TASK_WAIT` or
///   `_MEM_HANDLERS`.
///
/// RESULT:
/// The list, or null for a number exec has no list for - which is how a
/// program built against a later version degrades rather than faults.
///
/// BEHAVIOR:
/// It is the live list. Nothing is copied and nothing is locked.
///
/// **The caller's side of the bargain**: hold Forbid while walking, or
/// Disable for the two task queues, since those are what a switch touches.
/// Write nothing. Keep no node past the lock - copy out the fields wanted
/// and let go before doing anything with them.
///
/// That last rule is not advice. Printing reaches a file system, a file
/// system is a process, and a process cannot run while the scheduler is
/// held - so a listing that prints as it walks stops the machine. It is why
/// every listing in this tree copies a node's fields out under the lock and
/// prints them after.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe - it returns a pointer and reads nothing.
/// - Forbid: not taken here. The caller's, and required for the walk.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. Everything on the list belongs to whoever put it
/// there.
///
/// NOTES:
/// `C:Show` is what this was added for.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindName`, `IntVector`, `ResModules`, `Forbid`
///
/// EXAMPLES:
/// ```zig
/// sys.Forbid();
/// var it = sys.ExecList(EXECLIST_LIBRARIES).?.iterator();
/// while (it.next()) |node| {
///     // ... copy out what is wanted ...
/// }
/// sys.Permit();
/// // ... print it now ...
/// ```
pub fn ExecList(base: *ExecBase, which: u32) ?*List {
    return switch (which) {
        sdk.exec.EXECLIST_MEMORY => &base.mem_list,
        sdk.exec.EXECLIST_LIBRARIES => &base.lib_list,
        sdk.exec.EXECLIST_DEVICES => &base.device_list,
        sdk.exec.EXECLIST_RESOURCES => &base.resource_list,
        sdk.exec.EXECLIST_PORTS => &base.port_list,
        sdk.exec.EXECLIST_SEMAPHORES => &base.sem_list,
        sdk.exec.EXECLIST_TASK_READY => &base.task_ready,
        sdk.exec.EXECLIST_TASK_WAIT => &base.task_wait,
        sdk.exec.EXECLIST_MEM_HANDLERS => &base.mem_handlers,
        else => null,
    };
}

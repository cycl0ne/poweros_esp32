// SPDX-License-Identifier: MPL-2.0
//! LockExecList: one of exec's own lists, by number, with its lock taken.
//!
//! ExecBase is opaque to everything outside the kernel, so without this a
//! program could not walk a system list at all: `FindName` needs a list
//! pointer there is no other way to get. What it hands back is exec's own
//! state, not a copy, which is the bargain: reading it is cheap and
//! truthful, and the lock it took is held until `UnlockExecList`.

const sdk = @import("sdk");
const _list = @import("_list.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const List = sdk.exec.List;

/// Hands back one of exec's own lists, its lock taken.
///
/// SYNOPSIS:
/// ```zig
/// fn LockExecList(base: *ExecBase, which: u32) ?*List
/// ```
///
/// SINCE: 1.6. LVO -428.
///
/// INPUTS:
/// - `which` - `EXECLIST_MEMORY`, `_LIBRARIES`, `_DEVICES`, `_RESOURCES`,
///   `_PORTS`, `_SEMAPHORES`, `_TASK_READY`, `_TASK_WAIT` or
///   `_MEM_HANDLERS`.
///
/// RESULT:
/// The list, or null - with nothing taken - for a number exec has no list
/// for, which is how a program built against a later version degrades
/// rather than faults.
///
/// BEHAVIOR:
/// It is the live list, held still by the lock exec keeps it under:
///
/// - the libraries, devices and resources: exec's library list, a
///   semaphore, held shared - other walkers walk beside, nothing is added,
///   taken off or expunged until `UnlockExecList`;
/// - the memory handlers: their semaphore, held shared;
/// - the memory regions, the public ports and the public semaphores: a
///   spinlock each (exec's memory, port and semaphore locks). This core
///   switches no task while it is held, and the port lock masks its
///   interrupts;
/// - the two task queues: Disable.
///
/// **The caller's side of the bargain**: write nothing, and keep no node
/// past `UnlockExecList` - copy out the fields wanted and give the list back
/// before doing anything with them. Under a spinlock or Disable nothing may
/// wait: no printing, no allocating, no file. That is why every listing in
/// this tree copies a node's fields out under the lock and prints them
/// after.
///
/// CONTEXT:
/// - Waits: for the library list or the memory handlers' semaphore while
///   another task changes them. The others spin or mask.
/// - Interrupts: no.
/// - Locks: takes the list's own lock (BEHAVIOR). No spinlock may be held for
///   the lists under a semaphore; one held must come before the spinlock in the
///   lock order for the others.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The lock is held until `UnlockExecList(which)`.
/// Everything on the list belongs to whoever put it there.
///
/// NOTES:
/// `C:ShowInfo` is what this was added for.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnlockExecList`, `FindName`, `IntVector`, `ResModules`
///
/// EXAMPLES:
/// ```zig
/// const list = sys.LockExecList(EXECLIST_LIBRARIES) orelse return;
/// var it = list.iterator();
/// while (it.next()) |node| {
///     // ... copy out what is wanted ...
/// }
/// sys.UnlockExecList(EXECLIST_LIBRARIES);
/// // ... print it now ...
/// ```
pub fn LockExecList(base: *ExecBase, which: u32) ?*List {
    const found = _list.execList(base, which) orelse return null;
    const sys = base.iface();
    switch (found.lock) {
        .libraries => sys.ObtainSemaphoreShared(&base.sem_libraries),
        .mem_handlers => sys.ObtainSemaphoreShared(&base.sem_memhandlers),
        .memory => sys.AcquireLock(&base.lock_memory),
        .ports => sys.AcquireLock(&base.lock_ports),
        .semaphores => sys.AcquireLock(&base.lock_semaphores),
        .tasks => sys.Disable(),
    }
    return found.list;
}

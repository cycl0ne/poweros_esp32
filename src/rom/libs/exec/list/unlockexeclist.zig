// SPDX-License-Identifier: MPL-2.0
//! UnlockExecList: gives back the lock LockExecList took on one of exec's
//! lists.

const sdk = @import("sdk");
const _list = @import("_list.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Gives back the lock `LockExecList` took on list `which`.
///
/// SYNOPSIS:
/// ```zig
/// fn UnlockExecList(base: *ExecBase, which: u32) void
/// ```
///
/// SINCE: 1.6. LVO -528.
///
/// INPUTS:
/// - `which` - the number `LockExecList` was given.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The lock is the list's own (`LockExecList` lists them): its semaphore is
/// released, its spinlock let go - and a switch that came due meanwhile
/// taken - or the Disable ended. A number exec has no list for does
/// nothing, as `LockExecList` took nothing for it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: gives back the lock `LockExecList` took.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// No node of the list may be read after this.
///
/// NOTES:
/// One `UnlockExecList` for every `LockExecList` that answered a list,
/// with the same number.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockExecList`
///
/// EXAMPLES:
/// ```zig
/// const list = sys.LockExecList(EXECLIST_PORTS) orelse return;
/// const count = countNodes(list);
/// sys.UnlockExecList(EXECLIST_PORTS);
/// ```
pub fn UnlockExecList(base: *ExecBase, which: u32) void {
    const found = _list.execList(base, which) orelse return;
    const sys = base.iface();
    switch (found.lock) {
        .libraries => sys.ReleaseSemaphore(&base.sem_libraries),
        .mem_handlers => sys.ReleaseSemaphore(&base.sem_memhandlers),
        .memory => sys.ReleaseLock(&base.lock_memory),
        .ports => sys.ReleaseLock(&base.lock_ports),
        .semaphores => sys.ReleaseLock(&base.lock_semaphores),
        .tasks => sys.Enable(),
    }
}

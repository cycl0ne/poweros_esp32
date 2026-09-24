// SPDX-License-Identifier: MPL-2.0
//! LockDosList: locks the device list, or parts of it.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _doslist = @import("_doslist.zig");
const semaphores = _doslist.semaphores;
const validFlags = _doslist.validFlags;
const DosList = dos.DosList;

/// Locks the device list for reading or writing.
///
/// SYNOPSIS:
/// ```zig
/// fn LockDosList(db: *DosBase, flags: u32) ?*DosList
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `flags` - what to lock: any of LDF_DEVICES, LDF_VOLUMES, LDF_ASSIGNS
///   (or LDF_ALL) for the list, LDF_ENTRY while a handler is being started,
///   LDF_DELETE while a node is being removed; with exactly one of LDF_READ
///   and LDF_WRITE.
///
/// RESULT:
/// The list's head node, to start FindDosEntry and NextDosEntry at; null
/// for flags without exactly one of LDF_READ and LDF_WRITE, or with an
/// unknown bit.
///
/// BEHAVIOR:
/// Up to three semaphores are taken, always in the same order - the list,
/// the entry lock, the delete lock - shared for LDF_READ and exclusive for
/// LDF_WRITE. Any of the three type flags selects the one list semaphore:
/// the types are not locked apart. The head node is a private node, never
/// found by FindDosEntry.
///
/// CONTEXT:
/// - Waits: yes, for the device list's semaphores.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The locks are the caller's until UnLockDosList with the same flags. The
/// nodes stay dos's.
///
/// NOTES:
/// A handler must not take the list with LDF_WRITE while it could be asked
/// something by a process that holds it; AttemptLockDosList is for that.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnLockDosList`, `AttemptLockDosList`, `FindDosEntry`, `NextDosEntry`
///
/// EXAMPLES:
/// ```zig
/// const flags = dos.LDF_VOLUMES | dos.LDF_READ;
/// const list = dos_lib.LockDosList(flags) orelse return;
/// defer dos_lib.UnLockDosList(flags);
/// var node = dos_lib.NextDosEntry(list, dos.LDF_VOLUMES);
/// ```
pub fn LockDosList(db: *DosBase, flags: u32) ?*DosList {
    if (!validFlags(flags)) return null;
    const shared = flags & dos.LDF_READ != 0;
    for (semaphores(db)) |s| {
        if (flags & s.bits == 0) continue;
        if (shared) db.sys_base.ObtainSemaphoreShared(s.sem) else db.sys_base.ObtainSemaphore(s.sem);
    }
    return &db.dos_list;
}

// SPDX-License-Identifier: MPL-2.0
//! AttemptLockDosList: LockDosList without waiting.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _doslist = @import("_doslist.zig");
const semaphores = _doslist.semaphores;
const validFlags = _doslist.validFlags;
const DosList = dos.DosList;

/// Locks the device list only if that can be done without waiting.
///
/// SYNOPSIS:
/// ```zig
/// fn AttemptLockDosList(db: *DosBase, flags: u32) ?*DosList
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `flags` - as for LockDosList.
///
/// RESULT:
/// The list's head node, or null for bad flags or when a semaphore is held
/// by someone else.
///
/// BEHAVIOR:
/// The semaphores are tried in LockDosList's order, shared for LDF_READ and
/// exclusive for LDF_WRITE. When one can't be had, those already taken are
/// released again, so a null result holds nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: allowed.
/// - Process: a Task will do; this is the form for a handler, which must
///   not wait for the list.
///
/// OWNERSHIP:
/// On success, as LockDosList.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockDosList`, `UnLockDosList`
///
/// EXAMPLES:
/// ```zig
/// const flags = dos.LDF_VOLUMES | dos.LDF_WRITE;
/// const list = dos_lib.AttemptLockDosList(flags) orelse return retryLater();
/// defer dos_lib.UnLockDosList(flags);
/// ```
pub fn AttemptLockDosList(db: *DosBase, flags: u32) ?*DosList {
    const dos_lib = db.iface();
    if (!validFlags(flags)) return null;
    const shared = flags & dos.LDF_READ != 0;
    var taken: u32 = flags & (dos.LDF_READ | dos.LDF_WRITE);
    for (semaphores(db)) |s| {
        if (flags & s.bits == 0) continue;
        const got = if (shared) db.sys_base.AttemptSemaphoreShared(s.sem) else db.sys_base.AttemptSemaphore(s.sem);
        if (!got) {
            dos_lib.UnLockDosList(taken);
            return null;
        }
        taken |= s.bits;
    }
    return &db.dos_list;
}

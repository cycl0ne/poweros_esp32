// SPDX-License-Identifier: MPL-2.0
//! RemAssignList: removes one directory from a plain assign.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _doslist = @import("_doslist.zig");
const AssignList = dos.AssignList;
const fail = _doslist.fail;
const write = _doslist.write;
const FileLock = dos.FileLock;

/// Removes one directory from an assign.
///
/// SYNOPSIS:
/// ```zig
/// fn RemAssignList(db: *DosBase, name: [*:0]const u8, lock: *FileLock) bool
/// ```
///
/// SINCE: 1.0. LVO -332.
///
/// INPUTS:
/// - `name` - the assign's name, without the colon.
/// - `lock` - a lock on the directory to remove; any lock that SameLock
///   finds the same will do.
///
/// RESULT:
/// True when the directory was removed. False otherwise, with IoErr set:
/// ERROR_OBJECT_NOT_FOUND when there is no assign of that name or the
/// directory isn't one of its, ERROR_OBJECT_WRONG_TYPE for a late or
/// non-binding assign.
///
/// BEHAVIOR:
/// The first directory can be removed too: the next one moves up to take
/// its place. When the last directory goes, the assign goes with it. The
/// removed directory's own lock - dos's, not `lock` - is unlocked.
///
/// CONTEXT:
/// - Waits: yes. It takes the device list's lock for writing, and SameLock
///   and UnLock send packets.
/// - Interrupts: not callable.
/// - Forbid: must not be held.
/// - Process: a Task will do; only a process gets IoErr.
///
/// OWNERSHIP:
/// `lock` stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AssignAdd`, `AssignLock`, `SameLock`
///
/// EXAMPLES:
/// ```zig
/// const dir = dos_lib.Lock("RAM:c", dos.SHARED_LOCK) orelse return false;
/// defer dos_lib.UnLock(dir);
/// _ = dos_lib.RemAssignList("C", dir);
/// ```
pub fn RemAssignList(db: *DosBase, name: [*:0]const u8, lock: *FileLock) bool {
    const dos_lib = db.iface();
    const start = dos_lib.LockDosList(write).?;
    defer dos_lib.UnLockDosList(write);
    const node = dos_lib.FindDosEntry(start, name, dos.LDF_ASSIGNS) orelse return fail(db, dos.ERROR_OBJECT_NOT_FOUND);
    if (node.type != .directory) return fail(db, dos.ERROR_OBJECT_WRONG_TYPE);
    if (dos_lib.SameLock(node.lock, lock) == dos.LOCK_SAME) {
        dos_lib.UnLock(node.lock);
        node.lock = null;
        const first = node.misc.assign.list orelse {
            _ = dos_lib.RemDosEntry(node);
            dos_lib.FreeDosEntry(node);
            return true;
        };
        node.lock = first.lock;
        node.task = if (first.lock) |l| l.task else null;
        node.misc.assign.list = first.next;
        db.sys_base.FreeVec(first);
        return true;
    }
    var link: *?*AssignList = &node.misc.assign.list;
    while (link.*) |entry| : (link = &entry.next) {
        if (dos_lib.SameLock(entry.lock, lock) != dos.LOCK_SAME) continue;
        link.* = entry.next;
        dos_lib.UnLock(entry.lock);
        db.sys_base.FreeVec(entry);
        return true;
    }
    return fail(db, dos.ERROR_OBJECT_NOT_FOUND);
}

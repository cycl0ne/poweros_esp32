// SPDX-License-Identifier: MPL-2.0
//! AssignAdd: adds a directory to a plain assign, after the others.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _doslist = @import("_doslist.zig");
const AssignList = dos.AssignList;
const fail = _doslist.fail;
const write = _doslist.write;
const FileLock = dos.FileLock;

/// Adds a directory to an assign, after the ones it has.
///
/// SYNOPSIS:
/// ```zig
/// fn AssignAdd(db: *DosBase, name: [*:0]const u8, lock: *FileLock) bool
/// ```
///
/// SINCE: 1.0. LVO -328.
///
/// INPUTS:
/// - `name` - the assign's name, without the colon.
/// - `lock` - the directory to add.
///
/// RESULT:
/// True on success. False otherwise, with IoErr set: ERROR_OBJECT_NOT_FOUND
/// when there is no assign of that name, ERROR_OBJECT_WRONG_TYPE for a late
/// or non-binding assign, ERROR_NO_FREE_STORE when there is no memory for
/// the entry.
///
/// BEHAVIOR:
/// The directory goes at the end of the assign's list, so a name looked up
/// through the assign is tried in it last. The assign must already exist;
/// AssignLock makes one.
///
/// CONTEXT:
/// - Waits: yes. It takes the device list's lock for writing.
/// - Interrupts: not callable.
/// - Forbid: must not be held.
/// - Process: a Task will do; only a process gets IoErr.
///
/// OWNERSHIP:
/// On success dos keeps `lock` and unlocks it when the directory or the
/// assign goes; on failure it stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AssignLock`, `RemAssignList`, `GetDeviceProc`
///
/// EXAMPLES:
/// ```zig
/// const more = dos_lib.Lock("RAM:c", dos.SHARED_LOCK) orelse return false;
/// if (!dos_lib.AssignAdd("C", more)) dos_lib.UnLock(more);
/// ```
pub fn AssignAdd(db: *DosBase, name: [*:0]const u8, lock: *FileLock) bool {
    const dos_lib = db.iface();
    const start = dos_lib.LockDosList(write).?;
    defer dos_lib.UnLockDosList(write);
    const node = dos_lib.FindDosEntry(start, name, dos.LDF_ASSIGNS) orelse return fail(db, dos.ERROR_OBJECT_NOT_FOUND);
    if (node.type != .directory) return fail(db, dos.ERROR_OBJECT_WRONG_TYPE);
    const block = db.sys_base.AllocVec(@sizeOf(AssignList), exec.MEMF_CLEAR) orelse
        return fail(db, dos.ERROR_NO_FREE_STORE);
    const added: *AssignList = @ptrCast(@alignCast(block));
    added.* = .{ .lock = lock };
    var link: *?*AssignList = &node.misc.assign.list;
    while (link.*) |entry| link = &entry.next;
    link.* = added;
    return true;
}

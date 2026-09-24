// SPDX-License-Identifier: MPL-2.0
//! AssignLock: makes a name an assign to a directory, or removes it.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _doslist = @import("_doslist.zig");
const setAssign = _doslist.setAssign;
const FileLock = dos.FileLock;

/// Makes a name an assign to a directory, or removes the assign.
///
/// SYNOPSIS:
/// ```zig
/// fn AssignLock(db: *DosBase, name: [*:0]const u8, lock: ?*FileLock) bool
/// ```
///
/// SINCE: 1.0. LVO -316.
///
/// INPUTS:
/// - `name` - the assign's name, without the colon, 1 to 30 characters.
/// - `lock` - the directory it stands for; null removes the assign.
///
/// RESULT:
/// True on success, removing an assign that isn't there included. False
/// otherwise, with IoErr set: ERROR_INVALID_COMPONENT_NAME for an empty or
/// too long name, ERROR_OBJECT_EXISTS when a device or volume has the name,
/// ERROR_NO_FREE_STORE when there is no memory for the node.
///
/// BEHAVIOR:
/// An assign of that name is replaced: its locks are unlocked (unless one
/// is `lock` itself), its further directories and any late or non-binding
/// path freed. Without one a new node is made and added to the device list.
/// A null lock takes the assign off the list and frees it.
///
/// CONTEXT:
/// - Waits: yes. It takes the device list's lock for writing, and unlocking
///   a replaced assign's locks sends packets.
/// - Interrupts: not callable.
/// - Forbid: must not be held.
/// - Process: a Task will do; only a process gets IoErr.
///
/// OWNERSHIP:
/// On success dos keeps `lock` and unlocks it when the assign goes; on
/// failure it stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AssignLate`, `AssignPath`, `AssignAdd`, `RemAssignList`,
/// `GetDeviceProc`
///
/// EXAMPLES:
/// ```zig
/// const dir = dos_lib.Lock("RAM:work", dos.SHARED_LOCK) orelse return false;
/// if (!dos_lib.AssignLock("WORK", dir)) dos_lib.UnLock(dir);
/// ```
pub fn AssignLock(db: *DosBase, name: [*:0]const u8, lock: ?*FileLock) bool {
    return setAssign(db, name, .directory, lock, null);
}

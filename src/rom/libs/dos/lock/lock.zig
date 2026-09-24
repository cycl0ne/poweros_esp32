// SPDX-License-Identifier: MPL-2.0
//! Lock: a lock on a file or directory, found by its name.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const nameAction = _lock.nameAction;
const asLock = _lock.asLock;
const FileLock = dos.FileLock;

/// Locks a file or directory by name.
///
/// SYNOPSIS:
/// ```zig
/// fn Lock(db: *DosBase, name: [*:0]const u8, mode: i32) ?*FileLock
/// ```
///
/// SINCE: 1.0. LVO -144.
///
/// INPUTS:
/// - `name` - the object: "DEV:path", "ASSIGN:path", ":path" (the current
///   volume's root) or a path from the current directory. At most 255
///   characters.
/// - `mode` - SHARED_LOCK (others may lock it too) or EXCLUSIVE_LOCK
///   (nobody else may).
///
/// RESULT:
/// The lock, or null with IoErr() saying why: ERROR_LINE_TOO_LONG,
/// ERROR_OBJECT_NOT_FOUND, ERROR_OBJECT_IN_USE, ERROR_DEVICE_NOT_MOUNTED,
/// ERROR_NO_FREE_STORE, or whatever the handler answers.
///
/// BEHAVIOR:
/// GetDeviceProc finds the name's handler and the directory the name is
/// relative to, and the handler is sent ACTION_LOCATE_OBJECT with that
/// directory's lock, the whole name (device part included) and `mode`. On a
/// multi-directory assign, a directory that answers ERROR_OBJECT_NOT_FOUND
/// passes the question to the assign's next directory; any other error ends
/// the search.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer to a packet.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; a process gets IoErr().
///
/// OWNERSHIP:
/// The lock belongs to the caller, who gives it back with UnLock. The
/// handler allocated it; dos never frees one itself.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnLock`, `DupLock`, `CreateDir`, `GetDeviceProc`, `Examine`
///
/// EXAMPLES:
/// ```zig
/// const dir = dos_lib.Lock("SYS:c", dos.SHARED_LOCK) orelse return dos_lib.IoErr();
/// defer dos_lib.UnLock(dir);
/// ```
pub fn Lock(db: *DosBase, name: [*:0]const u8, mode: i32) ?*FileLock {
    return asLock(nameAction(db, name, .locate_object, .{ .arg3 = mode }));
}

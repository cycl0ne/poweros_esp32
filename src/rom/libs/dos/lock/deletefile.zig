// SPDX-License-Identifier: MPL-2.0
//! DeleteFile: deletes a file or an empty directory.

const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const nameAction = _lock.nameAction;

/// Deletes a file or an empty directory.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteFile(db: *DosBase, name: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.0. LVO -172.
///
/// INPUTS:
/// - `name` - the object, as for Lock.
///
/// RESULT:
/// True if it is gone; false with IoErr() (ERROR_OBJECT_NOT_FOUND,
/// ERROR_DIRECTORY_NOT_EMPTY, ERROR_OBJECT_IN_USE, ERROR_DELETE_PROTECTED,
/// the handler's error).
///
/// BEHAVIOR:
/// The name's handler is sent ACTION_DELETE_OBJECT with the directory the
/// name is relative to and the whole name, along a multi-directory assign
/// while the object isn't found.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer to a packet.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; a process gets IoErr().
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateDir`, `Rename`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.DeleteFile("T:work")) _ = dos_lib.PrintFault(dos_lib.IoErr(), "Delete");
/// ```
pub fn DeleteFile(db: *DosBase, name: [*:0]const u8) bool {
    return nameAction(db, name, .delete_object, .{}) != 0;
}

// SPDX-License-Identifier: MPL-2.0
//! AssignPath: makes a name an assign whose path is locked on each use.

const DosBase = @import("../dos_base.zig").DosBase;
const _doslist = @import("_doslist.zig");
const setAssign = _doslist.setAssign;
const copyPath = _doslist.copyPath;

/// Makes a name a non-binding assign to a path.
///
/// SYNOPSIS:
/// ```zig
/// fn AssignPath(db: *DosBase, name: [*:0]const u8, path: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.0. LVO -324.
///
/// INPUTS:
/// - `name` - the assign's name, without the colon, 1 to 30 characters.
/// - `path` - the path it stands for, as Lock takes one.
///
/// RESULT:
/// True on success. False otherwise, with IoErr set:
/// ERROR_INVALID_COMPONENT_NAME for an empty or too long name,
/// ERROR_OBJECT_EXISTS when a device or volume has the name,
/// ERROR_NO_FREE_STORE when there is no memory for the copy or the node.
///
/// BEHAVIOR:
/// The path is not looked at now. Each time the assign is used,
/// GetDeviceProc locks the path afresh, so the assign follows whatever the
/// path names at that moment - another disk in the same drive, say. An
/// assign of the same name is replaced and its locks unlocked. dos keeps a
/// copy of `path`.
///
/// CONTEXT:
/// - Waits: yes. It takes the device list's lock for writing, and unlocking
///   a replaced assign's locks sends packets.
/// - Interrupts: not callable.
/// - Forbid: must not be held.
/// - Process: a Task will do; only a process gets IoErr.
///
/// OWNERSHIP:
/// `path` stays the caller's; dos's copy goes with the assign.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AssignLock`, `AssignLate`, `AssignPath`, `GetDeviceProc`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.AssignPath("C", "SYS:c")) return false;
/// ```
pub fn AssignPath(db: *DosBase, name: [*:0]const u8, path: [*:0]const u8) bool {
    const copy = copyPath(db, path) orelse return false;
    return setAssign(db, name, .nonbinding, null, copy);
}

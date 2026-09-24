// SPDX-License-Identifier: MPL-2.0
//! AssignLate: makes a name an assign whose path is locked on first use.

const DosBase = @import("../dos_base.zig").DosBase;
const _doslist = @import("_doslist.zig");
const setAssign = _doslist.setAssign;
const copyPath = _doslist.copyPath;

/// Makes a name a late-binding assign to a path.
///
/// SYNOPSIS:
/// ```zig
/// fn AssignLate(db: *DosBase, name: [*:0]const u8, path: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.0. LVO -320.
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
/// The path is not looked at now. The first time the assign is used,
/// GetDeviceProc locks the path and the assign becomes a plain assign to
/// that directory; until then a path that doesn't exist costs nothing. An
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
/// if (!dos_lib.AssignLate("C", "SYS:c")) return false;
/// ```
pub fn AssignLate(db: *DosBase, name: [*:0]const u8, path: [*:0]const u8) bool {
    const copy = copyPath(db, path) orelse return false;
    return setAssign(db, name, .late, null, copy);
}

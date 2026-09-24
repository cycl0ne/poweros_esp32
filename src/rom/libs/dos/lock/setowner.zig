// SPDX-License-Identifier: MPL-2.0
//! SetOwner: sets an object's owner (user and group).

const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const bitsArg = _lock.bitsArg;

/// Sets an object's owner.
///
/// SYNOPSIS:
/// ```zig
/// fn SetOwner(db: *DosBase, name: [*:0]const u8, owner_info: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -364.
///
/// INPUTS:
/// - `name` - the object, as for Lock.
/// - `owner_info` - the owner, the user in the high 16 bits and the group
///   in the low 16.
///
/// RESULT:
/// True when the handler made the change. False otherwise, with IoErr set:
/// ERROR_LINE_TOO_LONG for a name over 255 characters,
/// ERROR_DEVICE_NOT_MOUNTED for a node with no handler, ERROR_NO_FREE_STORE
/// when the packet could not be sent, or the handler's own answer -
/// ERROR_OBJECT_NOT_FOUND, ERROR_ACTION_NOT_KNOWN from a handler that
/// doesn't keep this.
///
/// BEHAVIOR:
/// ACTION_SET_OWNER carries `owner_info` as it is. The name is resolved
/// with GetDeviceProc and the packet sent as (the directory's lock, `name`,
/// the value); along a multi-assign each directory is tried in turn while
/// the object isn't found.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer.
/// - Interrupts: not callable.
/// - Forbid: must not be held.
/// - Process: a Task will do; only a process gets IoErr.
///
/// OWNERSHIP:
/// Nothing is kept by dos. The value stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Examine`, `Lock`, `Rename`
///
/// EXAMPLES:
/// ```zig
/// _ = dos_lib.SetOwner("RAM:notes", (uid << 16) | gid);
/// ```
pub fn SetOwner(db: *DosBase, name: [*:0]const u8, owner_info: u32) bool {
    return _lock.nameAction(db, name, .set_owner, .{ .arg3 = bitsArg(owner_info) }) != 0;
}

// SPDX-License-Identifier: MPL-2.0
//! SetComment: sets or removes an object's comment.

const DosBase = @import("../dos_base.zig").DosBase;
const locks = @import("_lock.zig");
const asArg = locks.asArg;

/// Sets or removes an object's comment.
///
/// SYNOPSIS:
/// ```zig
/// fn SetComment(db: *DosBase, name: [*:0]const u8, comment: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.0. LVO -356.
///
/// INPUTS:
/// - `name` - the object, as for Lock.
/// - `comment` - the new comment, at most 79 characters; "" removes it.
///
/// RESULT:
/// True when the handler made the change. False otherwise, with IoErr set:
/// ERROR_LINE_TOO_LONG for a name over 255 characters,
/// ERROR_DEVICE_NOT_MOUNTED for a node with no handler, ERROR_NO_FREE_STORE
/// when the packet could not be sent, or the handler's own answer -
/// ERROR_OBJECT_NOT_FOUND, ERROR_ACTION_NOT_KNOWN from a handler that
/// doesn't keep this, ERROR_COMMENT_TOO_BIG for one over 79 characters.
///
/// BEHAVIOR:
/// ACTION_SET_COMMENT carries the comment's address; the handler copies it
/// and refuses one that is too long. The name is resolved with
/// GetDeviceProc and the packet sent as (the directory's lock, `name`, the
/// value); along a multi-assign each directory is tried in turn while the
/// object isn't found.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer.
/// - Interrupts: not callable.
/// - Forbid: must not be held.
/// - Process: a Task will do; only a process gets IoErr.
///
/// OWNERSHIP:
/// Nothing is kept by dos. The string stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Examine`, `Lock`, `Rename`
///
/// EXAMPLES:
/// ```zig
/// _ = dos_lib.SetComment("RAM:notes", "shopping list");
/// ```
pub fn SetComment(db: *DosBase, name: [*:0]const u8, comment: [*:0]const u8) bool {
    return locks.nameAction(db, name, .set_comment, .{ .arg3 = asArg(comment) }) != 0;
}

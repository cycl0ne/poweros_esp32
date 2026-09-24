// SPDX-License-Identifier: MPL-2.0
//! SetFileDate: sets an object's date to a DateStamp.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const locks = @import("_lock.zig");
const asArg = locks.asArg;

/// Sets an object's date.
///
/// SYNOPSIS:
/// ```zig
/// fn SetFileDate(db: *DosBase, name: [*:0]const u8, date: *const dos.DateStamp) bool
/// ```
///
/// SINCE: 1.0. LVO -360.
///
/// INPUTS:
/// - `name` - the object, as for Lock.
/// - `date` - the new date, a DateStamp as DateStamp() fills one.
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
/// ACTION_SET_DATE carries the DateStamp's address; the handler copies the
/// stamp. The name is resolved with GetDeviceProc and the packet sent as
/// (the directory's lock, `name`, the value); along a multi-assign each
/// directory is tried in turn while the object isn't found.
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
/// var now: dos.DateStamp = undefined;
/// _ = dos_lib.SetFileDate("RAM:notes", dos_lib.DateStamp(&now));
/// ```
pub fn SetFileDate(db: *DosBase, name: [*:0]const u8, date: *const dos.DateStamp) bool {
    return locks.nameAction(db, name, .set_date, .{ .arg3 = asArg(date) }) != 0;
}

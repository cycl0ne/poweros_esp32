// SPDX-License-Identifier: MPL-2.0
//! SetProtection: sets an object's protection bits (FIBF_*).

const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const bitsArg = _lock.bitsArg;

/// Sets an object's protection bits.
///
/// SYNOPSIS:
/// ```zig
/// fn SetProtection(db: *DosBase, name: [*:0]const u8, bits: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -352.
///
/// INPUTS:
/// - `name` - the object, as for Lock.
/// - `bits` - the protection bits (FIBF_*); the low four (read, write,
///   execute, delete) forbid when set.
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
/// ACTION_SET_PROTECT carries the bits as they are, all 32 of them. The
/// name is resolved with GetDeviceProc and the packet sent as (the
/// directory's lock, `name`, the value); along a multi-assign each
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
/// if (!dos_lib.SetProtection("RAM:notes", dos.FIBF_DELETE)) return false; // can't be deleted
/// ```
pub fn SetProtection(db: *DosBase, name: [*:0]const u8, bits: u32) bool {
    return _lock.nameAction(db, name, .set_protect, .{ .arg3 = bitsArg(bits) }) != 0;
}

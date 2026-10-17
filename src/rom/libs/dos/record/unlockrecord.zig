// SPDX-License-Identifier: MPL-2.0
//! UnLockRecord: a range LockRecord locked given back.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _record = @import("_record.zig");
const FileHandle = dos.FileHandle;

/// Gives back a lock `LockRecord` took.
///
/// SYNOPSIS:
/// ```zig
/// fn UnLockRecord(db: *DosBase, file: ?*FileHandle, offset: u64, length: u64) bool
/// ```
///
/// SINCE: 1.7. LVO -580.
///
/// INPUTS:
/// - `file` - the handle the lock was taken through.
/// - `offset` - the offset it was taken with.
/// - `length` - the length it was taken with.
///
/// RESULT:
/// True when the lock is given back. False with `IoErr()` saying why:
/// `ERROR_RECORD_NOT_LOCKED` (the handle holds no lock at that offset and
/// length), `ERROR_INVALID_LOCK` (no handle), `ERROR_ACTION_NOT_KNOWN` (a
/// handler without record locks).
///
/// BEHAVIOR:
/// `ACTION_FREE_RECORD` to the file's handler, which gives back one lock
/// the handle holds at exactly this offset and length - one of several, if
/// it took the same range more than once - and then tries the locks that
/// wait on the file again.
///
/// CONTEXT:
/// - Waits: yes, for the handler.
/// - Interrupts: no.
/// - Locks: no spinlock may be held around it: it waits.
/// - Process: a Task will do; the answer comes back on a port of its own.
///
/// OWNERSHIP:
/// The lock is the handler's to free.
///
/// NOTES:
/// - Closing a handle gives back every lock it still holds.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockRecord`, `UnLockRecords`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.LockRecord(fh, 0, 512, dos.record.REC_SHARED, 50)) {
///     // read the header
///     _ = dos_lib.UnLockRecord(fh, 0, 512);
/// }
/// ```
pub fn UnLockRecord(db: *DosBase, file: ?*FileHandle, offset: u64, length: u64) bool {
    var args: dos.PacketArgs = .{ .raw = @splat(0) };
    args.free_record = .{ .fh = file, .offset = offset, .length = length };
    return _record.send(db, file, .free_record, args);
}

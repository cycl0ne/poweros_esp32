// SPDX-License-Identifier: MPL-2.0
//! LockRecord: a range of an open file's bytes held, shared or exclusive.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _record = @import("_record.zig");
const FileHandle = dos.FileHandle;

/// Locks a range of an open file's bytes.
///
/// SYNOPSIS:
/// ```zig
/// fn LockRecord(db: *DosBase, file: ?*FileHandle, offset: u64, length: u64, mode: u32, timeout: u32) bool
/// ```
///
/// SINCE: 1.7. LVO -572.
///
/// INPUTS:
/// - `file` - the handle the lock is taken through, and belongs to.
/// - `offset` - where the range starts in the file; 64 bits on every
///   machine.
/// - `length` - its bytes.
/// - `mode` - `REC_EXCLUSIVE` or `REC_SHARED` (`dos.record`), each also
///   as `_IMMED`, which does not wait.
/// - `timeout` - how long to wait for the range, in ticks of 1/50 s; 0
///   does not wait.
///
/// RESULT:
/// True when the handle holds the range. False with `IoErr()` saying why:
/// `ERROR_LOCK_COLLISION` (an `_IMMED` mode, and the range is held),
/// `ERROR_LOCK_TIMEOUT` (the time ran out first), `ERROR_BAD_NUMBER` (a
/// mode past `REC_SHARED_IMMED`), `ERROR_INVALID_LOCK` (no handle, or it
/// was closed while it waited), `ERROR_ACTION_NOT_KNOWN` (a handler without
/// record locks: con, pipe, NIL:).
///
/// BEHAVIOR:
/// `ACTION_LOCK_RECORD` to the file's handler. An exclusive lock keeps
/// every other handle's locks off its bytes, a shared one only the
/// exclusive ones; a handle never stands in its own way, so it may lock
/// the same bytes as often as it likes, in either mode. When the range is
/// held by another handle, a mode that waits waits up to `timeout`, and
/// the waiting locks are tried again in the order they asked as others
/// are given back. Each lock is given back by its own `UnLockRecord`, or
/// when the handle is closed.
///
/// CONTEXT:
/// - Waits: yes, for the handler, and up to `timeout` for the range.
/// - Interrupts: no.
/// - Locks: no spinlock may be held around it: it waits.
/// - Process: a Task will do; the answer comes back on a port of its own.
///
/// OWNERSHIP:
/// The lock is the handle's: the handle gives it back, by `UnLockRecord`
/// or by being closed.
///
/// NOTES:
/// - The locks are cooperative: they keep other record locks out, not
///   `Read` or `Write`.
/// - RAM:, the flash file system and fat-handler keep record locks.
/// - Programs that lock several ranges should lock them in one order, so
///   that two of them never wait for each other; `LockRecords` takes them
///   in the order of its array.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockRecords`, `UnLockRecord`, `UnLockRecords`
///
/// EXAMPLES:
/// ```zig
/// // The 64-byte entry `index` of a shared file, waiting up to 2 s.
/// const at = @as(u64, index) * 64;
/// if (!dos_lib.LockRecord(fh, at, 64, dos.record.REC_EXCLUSIVE, 100)) return dos_lib.IoErr();
/// defer _ = dos_lib.UnLockRecord(fh, at, 64);
/// ```
pub fn LockRecord(db: *DosBase, file: ?*FileHandle, offset: u64, length: u64, mode: u32, timeout: u32) bool {
    var args: dos.PacketArgs = .{ .raw = @splat(0) };
    args.lock_record = .{ .fh = file, .offset = offset, .length = length, .mode = mode, .timeout = timeout };
    return _record.send(db, file, .lock_record, args);
}

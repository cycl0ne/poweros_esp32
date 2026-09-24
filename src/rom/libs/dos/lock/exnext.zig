// SPDX-License-Identifier: MPL-2.0
//! ExNext: the next entry of a directory being examined.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const asArg = _lock.asArg;
const clearOwner = _lock.clearOwner;
const fail = _lock.fail;
const FileLock = dos.FileLock;

/// Fills in a FileInfoBlock with the next entry of a directory.
///
/// SYNOPSIS:
/// ```zig
/// fn ExNext(db: *DosBase, lock: ?*FileLock, fib: *dos.FileInfoBlock) bool
/// ```
///
/// SINCE: 1.0. LVO -236.
///
/// INPUTS:
/// - `lock` - the directory, as given to `Examine`. Null fails with
///   ERROR_INVALID_LOCK.
/// - `fib` - the block `Examine` filled in, and each ExNext after it; the
///   handler keeps its place there.
///
/// RESULT:
/// True with the next entry in `fib`; false at the end, with IoErr
/// ERROR_NO_MORE_ENTRIES, or on an error.
///
/// BEHAVIOR:
/// ACTION_EXAMINE_NEXT to the lock's handler, the owner fields zeroed
/// first.
///
/// CONTEXT:
/// - Waits: yes, for the handler.
/// - Interrupts: no.
/// - Forbid: never under Forbid.
/// - Process: a Process, for IoErr.
///
/// OWNERSHIP:
/// Nothing is allocated. The block and the lock stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Examine`, `ExAll`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.Examine(dir, fib)) return false;
/// while (dos_lib.ExNext(dir, fib)) {
///     // fib.file_name is the entry
/// }
/// if (dos_lib.IoErr() != dos.ERROR_NO_MORE_ENTRIES) return false;
/// ```
pub fn ExNext(db: *DosBase, lock: ?*FileLock, fib: *dos.FileInfoBlock) bool {
    const l = lock orelse return fail(db, dos.ERROR_INVALID_LOCK);
    clearOwner(fib);
    return _lock.lockAction(db, l, .examine_next, asArg(l), asArg(fib)) != 0;
}

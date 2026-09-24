// SPDX-License-Identifier: MPL-2.0
//! ExamineFH: what an open file is, into a FileInfoBlock.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const packets = @import("../packet/_packet.zig");
const buffered = @import("../file/_file.zig");
const asArg = _lock.asArg;
const ActionCode = dos.ActionCode;
const clearOwner = _lock.clearOwner;
const fail = _lock.fail;
const FileHandle = dos.FileHandle;

/// Fills in a FileInfoBlock about an open file.
///
/// SYNOPSIS:
/// ```zig
/// fn ExamineFH(db: *DosBase, file: ?*FileHandle, fib: *dos.FileInfoBlock) bool
/// ```
///
/// SINCE: 1.0. LVO -240.
///
/// INPUTS:
/// - `file` - the open file; null, or one with no handler, fails with
///   ERROR_INVALID_LOCK.
/// - `fib` - the block to fill in.
///
/// RESULT:
/// True with `fib` filled in; false with IoErr set.
///
/// BEHAVIOR:
/// The file's buffer is written out first, so the size the handler gives
/// counts what was written with FWrite and FPutC. Then ACTION_EXAMINE_FH,
/// the owner fields zeroed before.
///
/// CONTEXT:
/// - Waits: yes, for the handler.
/// - Interrupts: no.
/// - Forbid: never under Forbid.
/// - Process: a Process, for IoErr.
///
/// OWNERSHIP:
/// Nothing is allocated. The block and the handle stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Examine`, `Flush`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.ExamineFH(fh, fib)) {
///     const size = fib.size;
///     _ = size;
/// }
/// ```
pub fn ExamineFH(db: *DosBase, file: ?*FileHandle, fib: *dos.FileInfoBlock) bool {
    const fh = file orelse return fail(db, dos.ERROR_INVALID_LOCK);
    const port = fh.task orelse return fail(db, dos.ERROR_INVALID_LOCK);
    if (!buffered.flush(db, fh)) return false;
    clearOwner(fib);
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(ActionCode.examine_fh), .{ asArg(fh), asArg(fib), 0, 0, 0 }) orelse
        return fail(db, dos.ERROR_NO_FREE_STORE);
    if (answer.res1 == 0) return fail(db, answer.res2);
    return true;
}

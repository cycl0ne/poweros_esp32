// SPDX-License-Identifier: MPL-2.0
//! Seek: moves a file's position, and says where it was.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const rawSeek = _file.rawSeek;
const failWith = _file.failWith;
const FileHandle = dos.FileHandle;

/// Moves a file's position.
///
/// SYNOPSIS:
/// ```zig
/// fn Seek(db: *DosBase, file: ?*FileHandle, position: isize, mode: i32) isize
/// ```
///
/// SINCE: 1.0. LVO -208.
///
/// INPUTS:
/// - `file` - the handle.
/// - `position` - the offset, which may be negative.
/// - `mode` - what it counts from: `OFFSET_BEGINNING`, `OFFSET_CURRENT` or
///   `OFFSET_END`.
///
/// RESULT:
/// The position before the move, or -1 with `IoErr()` set
/// (`ERROR_INVALID_LOCK`, `ERROR_SEEK_ERROR` from the handler for a place
/// before the start or past the end, ...).
///
/// BEHAVIOR:
/// The handle's buffer is flushed first - waiting bytes written, read-ahead
/// given back - so the handler's position is the caller's. Then
/// `ACTION_SEEK` moves it. `Seek(fh, 0, OFFSET_CURRENT)` is how the
/// position is read.
///
/// CONTEXT:
/// - Waits: yes: it sends the handler a packet and waits for the answer.
/// - Interrupts: no. It waits.
/// - Forbid: not taken, and never to be held around it: it waits.
/// - Process: a Task will do; the answer comes back on a port of its own.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Read`, `Write`, `SetFileSize`, `Flush`
///
/// EXAMPLES:
/// ```zig
/// const old = dos_lib.Seek(fh, 0, dos.OFFSET_END);
/// const size = dos_lib.Seek(fh, old, dos.OFFSET_BEGINNING);
/// ```
pub fn Seek(db: *DosBase, file: ?*FileHandle, position: isize, mode: i32) isize {
    const fh = file orelse return failWith(db, dos.ERROR_INVALID_LOCK, -1);
    if (!_file.flush(db, fh)) return -1;
    return rawSeek(db, fh, position, mode);
}

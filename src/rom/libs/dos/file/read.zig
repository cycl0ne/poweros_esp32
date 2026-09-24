// SPDX-License-Identifier: MPL-2.0
//! Read: reads bytes from a file into the caller's memory, without going
//! through the handle's buffer for more than it already holds.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const failWith = _file.failWith;
const FileHandle = dos.FileHandle;

/// Reads up to `length` bytes from a file.
///
/// SYNOPSIS:
/// ```zig
/// fn Read(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, length: isize) isize
/// ```
///
/// SINCE: 1.0. LVO -200.
///
/// INPUTS:
/// - `file` - the handle to read from.
/// - `buffer` - where the bytes go; `length` bytes of room.
/// - `length` - how many bytes are wanted.
///
/// RESULT:
/// The number of bytes read; 0 at the end of the file; -1 on an error, with
/// `IoErr()` set (`ERROR_INVALID_LOCK` for a null handle or one without a
/// handler, `ERROR_NO_FREE_STORE`, or the handler's code).
///
/// BEHAVIOR:
/// What the handle already holds comes first: pushed-back characters, then
/// bytes read ahead by the buffered calls. The rest is one `ACTION_READ` to
/// the handler, straight into `buffer`. A console gives what the buffer
/// held and stops there, so a line typed is not waited past. Bytes waiting
/// to be written are written out before anything is read.
///
/// The count can be less than `length` without the end being reached - a
/// console answers with what has been typed.
///
/// CONTEXT:
/// - Waits: yes: it sends the handler a packet and waits for the answer.
/// - Interrupts: no. It waits.
/// - Forbid: not taken, and never to be held around it: it waits.
/// - Process: a Task will do; the answer comes back on a port of its own.
///
/// OWNERSHIP:
/// Nothing is allocated. The bytes are the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Write`, `FRead`, `Seek`
///
/// EXAMPLES:
/// ```zig
/// var buf: [256]u8 = undefined;
/// const n = dos_lib.Read(fh, &buf, buf.len);
/// if (n < 0) return dos_lib.IoErr();
/// ```
pub fn Read(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, length: isize) isize {
    const fh = file orelse return failWith(db, dos.ERROR_INVALID_LOCK, -1);
    return _file.readThrough(db, fh, buffer, length);
}

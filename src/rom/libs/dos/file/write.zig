// SPDX-License-Identifier: MPL-2.0
//! Write: writes bytes from the caller's memory to a file, in one packet,
//! past the handle's buffer.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const rawWrite = _file.rawWrite;
const failWith = _file.failWith;
const FileHandle = dos.FileHandle;

/// Writes `length` bytes to a file.
///
/// SYNOPSIS:
/// ```zig
/// fn Write(db: *DosBase, file: ?*FileHandle, buffer: [*]const u8, length: isize) isize
/// ```
///
/// SINCE: 1.0. LVO -204.
///
/// INPUTS:
/// - `file` - the handle to write to.
/// - `buffer` - the bytes.
/// - `length` - how many.
///
/// RESULT:
/// The number of bytes written, or -1 with `IoErr()` set
/// (`ERROR_INVALID_LOCK`, `ERROR_NO_FREE_STORE`, or the handler's code,
/// e.g. `ERROR_DISK_FULL`). A count below `length` is what the handler
/// managed.
///
/// BEHAVIOR:
/// The handle is made ready first: bytes waiting in its buffer are written
/// out, and bytes read ahead are given back by seeking over them, so the
/// write lands where the caller's position is. A console keeps what it read
/// ahead, since it has no position to give back. Then one `ACTION_WRITE`
/// carries the bytes.
///
/// CONTEXT:
/// - Waits: yes: it sends the handler a packet and waits for the answer.
/// - Interrupts: no. It waits.
/// - Forbid: not taken, and never to be held around it: it waits.
/// - Process: a Task will do; the answer comes back on a port of its own.
///
/// OWNERSHIP:
/// Nothing is allocated. The bytes stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Read`, `FWrite`, `Flush`
///
/// EXAMPLES:
/// ```zig
/// const text = "hello\n";
/// if (dos_lib.Write(fh, text, text.len) != text.len) return dos_lib.IoErr();
/// ```
pub fn Write(db: *DosBase, file: ?*FileHandle, buffer: [*]const u8, length: isize) isize {
    const fh = file orelse return failWith(db, dos.ERROR_INVALID_LOCK, -1);
    if (!_file.beforeWrite(db, fh)) return -1;
    return rawWrite(db, fh, buffer, length);
}

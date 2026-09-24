// SPDX-License-Identifier: MPL-2.0
//! FWrite: writes bytes to a file through the handle's buffer.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const lineBuffered = _file.lineBuffered;
const drain = _file.drain;
const bufferSize = _file.bufferSize;
const stdio = dos.stdio;
const flush = _file.flush;
const failWith = _file.failWith;
const FileHandle = dos.FileHandle;

/// Writes `length` bytes to a file through its buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn FWrite(db: *DosBase, file: ?*FileHandle, buffer: [*]const u8, length: isize) isize
/// ```
///
/// SINCE: 1.0. LVO -424.
///
/// INPUTS:
/// - `file` - the handle.
/// - `buffer` - the bytes.
/// - `length` - how many. 0 or less writes nothing.
///
/// RESULT:
/// `length` (0 for 0 or less), or -1 with `IoErr()` set
/// (`ERROR_INVALID_LOCK`, `ERROR_NO_FREE_STORE`, `ERROR_DISK_FULL`, the
/// handler's code).
///
/// BEHAVIOR:
/// Bytes are copied into the buffer, which is written out whenever it
/// fills, and at the end when the bytes held a '\n' or '\r' and the handle
/// is a line-buffered console. With `BUF_NONE`, or `length` the buffer's
/// size or more, the buffer is written out and the bytes go straight to the
/// handler. A reading handle turns around first as for `FPutC`; on a
/// console the bytes go straight out.
///
/// CONTEXT:
/// - Waits: only when the buffer has to go to or come from the handler;
///   then it sends a packet and waits for the answer.
/// - Interrupts: no. It may wait.
/// - Forbid: not taken, and never to be held around it: it may wait.
/// - Process: a Task will do. One handle is one caller's: two tasks sharing
///   a handle take turns themselves.
///
/// OWNERSHIP:
/// The first buffered call on a handle allocates its buffer; `Close` frees
/// it. The bytes stay the caller's.
///
/// NOTES:
/// When the bytes go straight to the handler the answer is the handler's
/// count, which can be less than `length`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FRead`, `Write`, `FPuts`, `Flush`
///
/// EXAMPLES:
/// ```zig
/// const line = "a line\n";
/// if (dos_lib.FWrite(fh, line, line.len) < 0) return dos_lib.IoErr();
/// ```
pub fn FWrite(db: *DosBase, file: ?*FileHandle, buffer: [*]const u8, length: isize) isize {
    const fh = file orelse return failWith(db, dos.ERROR_INVALID_LOCK, -1);
    if (length <= 0) return 0;
    const len: usize = @intCast(length);
    if (fh.state == .read) {
        if (fh.interactive) return _file.rawWrite(db, fh, buffer, length);
        if (!flush(db, fh)) return -1;
    }
    if (fh.buf_mode == stdio.BUF_NONE or len >= bufferSize(fh)) {
        if (fh.state == .write and !drain(db, fh)) return -1;
        return _file.rawWrite(db, fh, buffer, length);
    }
    const b = _file.bufferOf(db, fh) orelse return -1;
    var done: usize = 0;
    while (done < len) {
        if (fh.pos == fh.buf_size and !drain(db, fh)) return -1;
        const n: usize = @min(len - done, fh.buf_size - fh.pos);
        @memcpy(b[fh.pos..][0..n], buffer[done..][0..n]);
        fh.pos += @intCast(n);
        done += n;
        fh.state = .write;
    }
    const newline = lineBuffered(fh) and for (buffer[0..len]) |c| {
        if (c == '\n' or c == '\r') break true;
    } else false;
    if ((fh.pos == fh.buf_size or newline) and !drain(db, fh)) return -1;
    return length;
}

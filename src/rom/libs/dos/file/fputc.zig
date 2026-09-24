// SPDX-License-Identifier: MPL-2.0
//! FPutC: writes one byte to a file through the handle's buffer.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const lineBuffered = _file.lineBuffered;
const stdio = dos.stdio;
const drain = _file.drain;
const bufferOf = _file.bufferOf;
const flush = _file.flush;
const failWith = _file.failWith;
const FileHandle = dos.FileHandle;

/// Writes one byte to a file.
///
/// SYNOPSIS:
/// ```zig
/// fn FPutC(db: *DosBase, file: ?*FileHandle, character: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -416.
///
/// INPUTS:
/// - `file` - the handle.
/// - `character` - the byte, in the low 8 bits.
///
/// RESULT:
/// The byte written (0 to 255), or -1 with `IoErr()` set
/// (`ERROR_INVALID_LOCK` for a null handle, `ERROR_NO_FREE_STORE`,
/// `ERROR_DISK_FULL`, the handler's code).
///
/// BEHAVIOR:
/// The byte goes into the buffer, which is written out when it is full, at
/// once with `BUF_NONE`, and at '\n' or '\r' when the handle is line
/// buffered and a console. A handle that was reading turns around first:
/// read-ahead is given back by seeking over it - except on a console, where
/// the byte goes straight out and what was read ahead stays to be read.
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
/// it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FPuts`, `FWrite`, `Flush`, `SetVBuf`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.FPutC(fh, '\n') < 0) return dos_lib.IoErr();
/// ```
pub fn FPutC(db: *DosBase, file: ?*FileHandle, character: i32) i32 {
    const fh = file orelse return @intCast(failWith(db, dos.ERROR_INVALID_LOCK, -1));
    const c: u8 = @truncate(@as(u32, @bitCast(character)));
    if (fh.state == .read) {
        if (fh.interactive) return if (_file.rawWrite(db, fh, @ptrCast(&c), 1) < 0) -1 else c;
        if (!flush(db, fh)) return -1;
    }
    const b = bufferOf(db, fh) orelse return -1;
    if (fh.pos == fh.buf_size and !drain(db, fh)) return -1;
    b[fh.pos] = c;
    fh.pos += 1;
    fh.state = .write;
    const out = fh.pos == fh.buf_size or fh.buf_mode == stdio.BUF_NONE or
        (lineBuffered(fh) and (c == '\n' or c == '\r'));
    if (out and !drain(db, fh)) return -1;
    return c;
}

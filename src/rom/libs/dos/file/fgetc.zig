// SPDX-License-Identifier: MPL-2.0
//! FGetC: reads one byte from a file through the handle's buffer.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const refill = _file.refill;
const drain = _file.drain;
const failWith = _file.failWith;
const FileHandle = dos.FileHandle;

/// Reads the next byte of a file.
///
/// SYNOPSIS:
/// ```zig
/// fn FGetC(db: *DosBase, file: ?*FileHandle) i32
/// ```
///
/// SINCE: 1.0. LVO -408.
///
/// INPUTS:
/// - `file` - the handle.
///
/// RESULT:
/// The byte, 0 to 255; -1 at the end of the file (a pushed-back end
/// included), with `IoErr()` 0, or on
/// an error, with `IoErr()` the reason (`ERROR_INVALID_LOCK` for a null
/// handle, `ERROR_NO_FREE_STORE` when no buffer can be had, the handler's
/// code).
///
/// BEHAVIOR:
/// A character pushed back with `UnGetC` comes first, the last pushed
/// first. Then the buffer; when it is empty it is refilled with one
/// `ACTION_READ` of the buffer's size (one byte with `BUF_NONE`). Bytes
/// waiting to be written are written out before reading. The end is not
/// remembered: after -1 the next call asks the handler again, so a console
/// can be read on after an end of input.
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
/// `UnGetC`, `FGets`, `FRead`, `Read`
///
/// EXAMPLES:
/// ```zig
/// while (true) {
///     const c = dos_lib.FGetC(fh);
///     if (c < 0) break;
///     _ = dos_lib.FPutC(out, c);
/// }
/// ```
pub fn FGetC(db: *DosBase, file: ?*FileHandle) i32 {
    const fh = file orelse return @intCast(failWith(db, dos.ERROR_INVALID_LOCK, -1));
    if (fh.unget_count > 0) {
        fh.unget_count -= 1;
        fh.unget_backed &= ~(@as(u8, 1) << @intCast(fh.unget_count));
        fh.last = fh.unget[fh.unget_count];
        // An end is an end however it came: IoErr says it is no error.
        if (fh.last < 0) _ = failWith(db, 0, -1);
        return fh.last;
    }
    if (fh.state == .write and !drain(db, fh)) return -1;
    if (fh.state != .read or fh.pos == fh.end) {
        if (refill(db, fh) <= 0) return -1;
    }
    const c = fh.buf.?[fh.pos];
    fh.pos += 1;
    fh.last = c;
    return c;
}

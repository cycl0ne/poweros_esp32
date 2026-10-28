// SPDX-License-Identifier: MPL-2.0
//! SetVBuf: sets how a handle buffers, and the buffer it uses.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const flush = _file.flush;
const stdio = dos.stdio;
const failWith = _file.failWith;
const FileHandle = dos.FileHandle;

/// Sets a file handle's buffering and buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn SetVBuf(db: *DosBase, file: ?*FileHandle, buffer: ?[*]u8, mode: i32, size: isize) i32
/// ```
///
/// SINCE: 1.0; `BUF_ASYNC` 1.15. LVO -436.
///
/// INPUTS:
/// - `file` - the handle.
/// - `buffer` - the caller's memory for the buffer, or null to have one
///   allocated. Not looked at when `size` is -1.
/// - `mode` - `BUF_LINE` (written out at a line's end on a console),
///   `BUF_FULL` (written out when full), `BUF_NONE` (every byte written
///   at once) or `BUF_ASYNC` (two halves: one read ahead or written behind
///   while the caller uses the other).
/// - `size` - the buffer's size in bytes - with `BUF_ASYNC` both halves',
///   2 or more - or -1 to keep the buffer and change the mode only.
///
/// RESULT:
/// 0, or -1 with `IoErr()` set: `ERROR_INVALID_LOCK` for a null handle,
/// `ERROR_BAD_NUMBER` for another mode, a size of 0, below -1 or over 32
/// bits, or one too small to halve; `ERROR_NO_FREE_STORE` (no memory, or
/// no signal for `BUF_ASYNC`'s request), or what `Flush` failed with.
///
/// BEHAVIOR:
/// The handle is flushed first: waiting bytes are written, and bytes read
/// ahead, and pushed-back characters that stand for bytes the file gave,
/// are given back by seeking over them - on a console, where there is
/// nothing to seek, they are dropped. Then the mode is set and, unless
/// `size` is -1, the new buffer put in; a buffer dos had allocated for the
/// handle is freed. There is no smallest size.
///
/// `BUF_ASYNC` splits the buffer in two halves - the new one, or with -1
/// the one the handle has, allocated now when it has none - and gives the
/// handle a request (`DOS_REQUEST`) on a port of its own, one of the
/// calling task's signals. `FRead`, `FGetC`, `Read` and the rest then find
/// the next half read already, and `FWrite`, `FPutC` and `Write` fill one
/// while the other is written; the halves are the copy every buffered
/// call has. Leaving `BUF_ASYNC` frees the request, and with -1 joins the
/// halves again. On a console `BUF_ASYNC` is `BUF_LINE`: reading ahead
/// there would wait for a line nobody typed.
///
/// CONTEXT:
/// - Waits: only when the buffer has to go to or come from the handler;
///   then it sends a packet and waits for the answer.
/// - Interrupts: no. It may wait.
/// - Locks: none taken; no spinlock may be held around it: it may wait.
/// - Process: a Task will do. One handle is one caller's: two tasks sharing
///   a handle take turns themselves. `BUF_ASYNC`'s request signals the
///   task that set it: only that task reads ahead and writes behind, and it
///   closes the handle, or sets another mode before handing it on.
///
/// OWNERSHIP:
/// A buffer the caller gives stays the caller's and must outlive the handle
/// - until `Close`, or a later `SetVBuf`. One allocated here is freed by
/// `Close`, and so is `BUF_ASYNC`'s request.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Flush`, `FWrite`, `FGetC`, `StartRead`
///
/// EXAMPLES:
/// ```zig
/// var big: [8192]u8 = undefined;
/// if (dos_lib.SetVBuf(fh, &big, dos.stdio.BUF_FULL, big.len) < 0) return dos_lib.IoErr();
///
/// // Read ahead in two halves of 128 KiB, dos's memory.
/// if (dos_lib.SetVBuf(in, null, dos.stdio.BUF_ASYNC, 256 << 10) < 0) return dos_lib.IoErr();
/// ```
pub fn SetVBuf(db: *DosBase, file: ?*FileHandle, buffer: ?[*]u8, mode: i32, size: isize) i32 {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    const fh = file orelse return @intCast(failWith(db, dos.ERROR_INVALID_LOCK, -1));
    const bad_size = size == 0 or size < -1 or @as(i64, size) > std.math.maxInt(u32);
    if (mode < stdio.BUF_LINE or mode > stdio.BUF_ASYNC or bad_size)
        return @intCast(failWith(db, dos.ERROR_BAD_NUMBER, -1));
    const kept = if (mode == stdio.BUF_ASYNC and fh.interactive) stdio.BUF_LINE else mode;
    const halved = kept == stdio.BUF_ASYNC;
    if (halved and size == 1) return @intCast(failWith(db, dos.ERROR_BAD_NUMBER, -1));
    if (!flush(db, fh)) return -1;
    if (size == -1 and halved == (fh.ahead != null)) {
        fh.buf_mode = @intCast(kept);
        return 0;
    }
    // A new buffer, or the handle's split or joined. A lent argument line
    // is not the handle's to split.
    const old = _file.wholeBuffer(fh);
    const taken = size == -1 and old.ptr != null and !fh.lent;
    const want: u32 = if (size != -1) @intCast(size) else if (taken) old.size else stdio.BUFFER_SIZE;
    if (halved and want < 2) return @intCast(failWith(db, dos.ERROR_BAD_NUMBER, -1));
    const request: ?*dos.DosRequest = if (!halved) null else fh.ahead orelse
        @ptrCast(@alignCast(dos_lib.AllocDosObject(dos.DOS_REQUEST, null) orelse
            return @intCast(failWith(db, dos.ERROR_NO_FREE_STORE, -1))));
    const given = if (size == -1) null else buffer;
    const new: [*]u8 = if (taken) old.ptr.? else given orelse @ptrCast(sys.AllocVec(want, exec.MEMF_ANY) orelse {
        if (request != fh.ahead) dos_lib.FreeDosObject(dos.DOS_REQUEST, request);
        return @intCast(failWith(db, dos.ERROR_NO_FREE_STORE, -1));
    });
    if (!taken) {
        if (fh.buf_owned) {
            if (old.ptr) |b| sys.FreeVec(b);
        }
        fh.buf_owned = given == null;
        fh.lent = false;
    }
    if (!halved and fh.ahead != null) dos_lib.FreeDosObject(dos.DOS_REQUEST, fh.ahead);
    fh.buf_mode = @intCast(kept);
    fh.ahead = request;
    fh.buf = new;
    fh.buf_size = if (halved) want / 2 else want;
    fh.other = if (halved) new + want / 2 else null;
    return 0;
}

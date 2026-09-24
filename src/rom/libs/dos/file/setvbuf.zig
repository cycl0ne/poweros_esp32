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
/// SINCE: 1.0. LVO -436.
///
/// INPUTS:
/// - `file` - the handle.
/// - `buffer` - the caller's memory for the buffer, or null to have one
///   allocated. Not looked at when `size` is -1.
/// - `mode` - `BUF_LINE` (written out at a line's end on a console),
///   `BUF_FULL` (written out when full) or `BUF_NONE` (every byte written
///   at once).
/// - `size` - the buffer's size in bytes, or -1 to keep the buffer and
///   change the mode only.
///
/// RESULT:
/// 0, or -1 with `IoErr()` set: `ERROR_INVALID_LOCK` for a null handle,
/// `ERROR_BAD_NUMBER` for another mode or a size of 0, below -1 or over 32
/// bits, `ERROR_NO_FREE_STORE`, or what `Flush` failed with.
///
/// BEHAVIOR:
/// The handle is flushed first: waiting bytes are written, and bytes read
/// ahead, and pushed-back characters that stand for bytes the file gave,
/// are given back by seeking over them - on a console, where there is
/// nothing to seek, they are dropped. Then the mode is set and, unless
/// `size` is -1, the new buffer put in; a buffer dos had allocated for the
/// handle is freed. There is no smallest size.
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
/// A buffer the caller gives stays the caller's and must outlive the handle
/// - until `Close`, or a later `SetVBuf`. One allocated here is freed by
/// `Close`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Flush`, `FWrite`, `FGetC`
///
/// EXAMPLES:
/// ```zig
/// var big: [8192]u8 = undefined;
/// if (dos_lib.SetVBuf(fh, &big, dos.stdio.BUF_FULL, big.len) < 0) return dos_lib.IoErr();
/// ```
pub fn SetVBuf(db: *DosBase, file: ?*FileHandle, buffer: ?[*]u8, mode: i32, size: isize) i32 {
    const fh = file orelse return @intCast(failWith(db, dos.ERROR_INVALID_LOCK, -1));
    const bad_size = size == 0 or size < -1 or @as(i64, size) > std.math.maxInt(u32);
    if (mode < stdio.BUF_LINE or mode > stdio.BUF_NONE or bad_size)
        return @intCast(failWith(db, dos.ERROR_BAD_NUMBER, -1));
    if (!flush(db, fh)) return -1;
    fh.buf_mode = @intCast(mode);
    if (size == -1) return 0;
    const new: [*]u8 = buffer orelse @ptrCast(db.sys_base.AllocVec(@intCast(size), exec.MEMF_ANY) orelse
        return @intCast(failWith(db, dos.ERROR_NO_FREE_STORE, -1)));
    if (fh.buf_owned) {
        if (fh.buf) |b| db.sys_base.FreeVec(b);
    }
    fh.buf = new;
    fh.buf_size = @intCast(size);
    fh.buf_owned = buffer == null;
    return 0;
}

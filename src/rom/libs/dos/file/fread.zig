// SPDX-License-Identifier: MPL-2.0
//! FRead: reads bytes from a file through the handle's buffer.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const refill = _file.refill;
const bufferSize = _file.bufferSize;
const take = _file.take;
const drain = _file.drain;
const failWith = _file.failWith;
const FileHandle = dos.FileHandle;

/// Reads up to `length` bytes from a file through its buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn FRead(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, length: isize) isize
/// ```
///
/// SINCE: 1.0. LVO -420.
///
/// INPUTS:
/// - `file` - the handle.
/// - `buffer` - where the bytes go; `length` bytes of room.
/// - `length` - how many are wanted. 0 or less reads nothing.
///
/// RESULT:
/// The number read, which is less than `length` only at the end of the file
/// or from a console; 0 at the end (and for a `length` of 0 or less); -1 on
/// an error before any byte, with `IoErr()` set (`ERROR_INVALID_LOCK`,
/// `ERROR_NO_FREE_STORE`, the handler's code). An error after some bytes
/// answers the bytes, and `IoErr()` keeps the error.
///
/// BEHAVIOR:
/// Pushed-back characters come first, then the buffer. The rest is read in
/// a loop: a part of the buffer's size or more goes straight into `buffer`,
/// a smaller one through a refill. It stops at the end of the file, and on
/// a console as soon as it has anything, so a line typed is not waited
/// past. At the end `IoErr()` is 0.
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
/// `FWrite`, `Read`, `FGetC`
///
/// EXAMPLES:
/// ```zig
/// var buf: [512]u8 = undefined;
/// const n = dos_lib.FRead(fh, &buf, buf.len);
/// if (n < 0) return dos_lib.IoErr();
/// ```
pub fn FRead(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, length: isize) isize {
    const dos_lib = db.iface();
    const fh = file orelse return failWith(db, dos.ERROR_INVALID_LOCK, -1);
    if (length <= 0) return 0;
    const want: usize = @intCast(length);
    if (fh.state == .write and !drain(db, fh)) return -1;
    const taken = take(fh, buffer, want);
    var got = taken.count;
    var at_end = taken.end;
    while (got < want and !at_end and !(got > 0 and fh.interactive)) {
        const rest = want - got;
        const n = if (rest >= bufferSize(fh))
            _file.rawRead(db, fh, buffer + got, @intCast(rest))
        else
            refill(db, fh);
        if (n < 0) {
            if (got == 0) return -1;
            break;
        }
        if (n == 0) {
            _ = dos_lib.SetIoErr(0);
            at_end = true;
        } else if (rest >= bufferSize(fh)) {
            got += @intCast(n);
        } else {
            got += take(fh, buffer + got, rest).count;
        }
    }
    if (got > 0) {
        fh.last = buffer[got - 1];
    } else if (at_end) {
        fh.last = -1;
    }
    return @intCast(got);
}

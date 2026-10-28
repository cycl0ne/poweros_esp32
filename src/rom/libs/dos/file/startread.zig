// SPDX-License-Identifier: MPL-2.0
//! StartRead: a read sent to a file's handler, waited for later.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _request = @import("_request.zig");
const FileHandle = dos.FileHandle;
const DosRequest = dos.DosRequest;

/// Starts a read of an open file, and does not wait for it.
///
/// SYNOPSIS:
/// ```zig
/// fn StartRead(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, length: isize, request: ?*DosRequest) bool
/// ```
///
/// SINCE: 1.14. LVO -612.
///
/// INPUTS:
/// - `file` - the handle.
/// - `buffer` - where the bytes go.
/// - `length` - how many are wanted.
/// - `request` - from AllocDosObject(DOS_REQUEST), not out.
///
/// RESULT:
/// True when the read is out; WaitRequest then gives what Read would
/// have: the count, 0 at the end, or -1 with `IoErr()`. False with
/// `IoErr()` set and nothing sent: `ERROR_INVALID_LOCK` without a handle,
/// `ERROR_REQUIRED_ARG_MISSING` without a request, `ERROR_OBJECT_IN_USE`
/// for a request still out, or the error of giving up the handle's
/// buffer.
///
/// BEHAVIOR:
/// ACTION_READ goes to the handle's handler and the request is put last
/// on the handle's requests out. The handler serves them in the order
/// they were started, so each reads from where the one before ended. The
/// handle's buffer is given up first, as Seek gives it up: waiting bytes
/// are written, bytes read ahead seeked back over. On a console, what was
/// typed ahead is the answer instead - the request back at once, without
/// a packet, as Read gives it first.
///
/// Every other call that reads, writes, moves, asks about or closes the
/// handle - Read, Write, the buffered calls, Seek, SetFileSize, CopyFH,
/// ExamineFH, Flush, Close - waits for the handle's requests first, and
/// leaves their answers in them for WaitRequest.
///
/// CONTEXT:
/// - Waits: no, unless the handle's buffer has bytes to write or to seek
///   back over first.
/// - Interrupts: no.
/// - Locks: none taken.
/// - Process: a Task will do; the request answers at its own port.
///
/// OWNERSHIP:
/// `buffer` and `request` are the caller's, and must stay until the
/// request is back: WaitRequest, or CheckRequest answering true.
///
/// NOTES:
/// - A read started on a console waits for a line as Read does; a Close
///   of the console waits for that line too.
/// - Two handles on two handlers work at once: a copy reads the next piece
///   while it writes this one.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartWrite`, `CheckRequest`, `WaitRequest`, `Read`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.StartRead(in, next.ptr, next.len, request)) return dos_lib.IoErr();
/// _ = dos_lib.Write(out, this.ptr, this.len); // while the next is read
/// const got = dos_lib.WaitRequest(request);
/// ```
pub fn StartRead(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, length: isize, request: ?*DosRequest) bool {
    return _request.start(db, file, request, .read, buffer, length);
}

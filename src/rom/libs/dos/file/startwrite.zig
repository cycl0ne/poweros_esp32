// SPDX-License-Identifier: MPL-2.0
//! StartWrite: a write sent to a file's handler, waited for later.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _request = @import("_request.zig");
const FileHandle = dos.FileHandle;
const DosRequest = dos.DosRequest;

/// Starts a write to an open file, and does not wait for it.
///
/// SYNOPSIS:
/// ```zig
/// fn StartWrite(db: *DosBase, file: ?*FileHandle, buffer: [*]const u8, length: isize, request: ?*DosRequest) bool
/// ```
///
/// SINCE: 1.14. LVO -616.
///
/// INPUTS:
/// - `file` - the handle.
/// - `buffer` - the bytes.
/// - `length` - how many.
/// - `request` - from AllocDosObject(DOS_REQUEST), not out.
///
/// RESULT:
/// True when the write is out; WaitRequest then gives what Write would
/// have: the count written, or -1 with `IoErr()`. False with `IoErr()` set
/// and nothing sent, as StartRead.
///
/// BEHAVIOR:
/// ACTION_WRITE goes to the handle's handler and the request is put last
/// on the handle's requests out, which the handler serves in the order
/// they were started. What the handle's buffer holds goes first: waiting
/// bytes are written, bytes read ahead seeked back over (a console keeps
/// them). Every other call on the handle waits for its requests first, as
/// StartRead says.
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
/// request is back.
///
/// NOTES:
/// - A count short of `length` is a write that failed part way, as
///   Write's is: the disk full, for one.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartRead`, `CheckRequest`, `WaitRequest`, `Write`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.StartWrite(out, piece.ptr, piece.len, request)) return dos_lib.IoErr();
/// // ... the next piece read meanwhile ...
/// if (dos_lib.WaitRequest(request) != piece.len) return dos_lib.IoErr();
/// ```
pub fn StartWrite(db: *DosBase, file: ?*FileHandle, buffer: [*]const u8, length: isize, request: ?*DosRequest) bool {
    return _request.start(db, file, request, .write, @constCast(buffer), length);
}

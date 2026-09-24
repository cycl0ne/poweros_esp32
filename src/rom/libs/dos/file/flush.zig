// SPDX-License-Identifier: MPL-2.0
//! Flush: empties a handle's buffer, so that the file and the caller agree
//! on what has been written and where the position is.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const beforeWrite = _file.beforeWrite;
const failWith = _file.failWith;
const FileHandle = dos.FileHandle;

/// Empties a file handle's buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn Flush(db: *DosBase, file: ?*FileHandle) bool
/// ```
///
/// SINCE: 1.0. LVO -404.
///
/// INPUTS:
/// - `file` - the handle.
///
/// RESULT:
/// True when the buffer is empty and the handler's position is the
/// caller's. False with `IoErr()` set when writing the waiting bytes failed
/// (`ERROR_DISK_FULL`, the handler's code) or when seeking back over the
/// read-ahead failed; `ERROR_INVALID_LOCK` for a null handle.
///
/// BEHAVIOR:
/// Bytes waiting to be written are written; what doesn't go out stays at
/// the front of the buffer for the next try. Bytes read ahead, and
/// characters pushed back that stand for bytes the file gave, are given
/// back by seeking the handler back over them; a character the caller
/// pushed back that the file never gave is dropped. A console keeps what it read ahead: it has no position to seek,
/// and what was typed would otherwise be lost.
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
/// Nothing is allocated. The buffer stays with the handle.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Seek`, `SetVBuf`, `Close`, `FWrite`
///
/// EXAMPLES:
/// ```zig
/// _ = dos_lib.PutStr("Name: ");
/// _ = dos_lib.Flush(dos_lib.Output());
/// ```
pub fn Flush(db: *DosBase, file: ?*FileHandle) bool {
    const fh = file orelse return failWith(db, dos.ERROR_INVALID_LOCK, 0) != 0;
    return beforeWrite(db, fh);
}

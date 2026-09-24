// SPDX-License-Identifier: MPL-2.0
//! SetFileSize: cuts or grows an open file.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const fileAction = _file.fileAction;
const failWith = _file.failWith;
const FileHandle = dos.FileHandle;

/// Sets the size of an open file.
///
/// SYNOPSIS:
/// ```zig
/// fn SetFileSize(db: *DosBase, file: ?*FileHandle, offset: isize, mode: i32) isize
/// ```
///
/// SINCE: 1.0. LVO -368.
///
/// INPUTS:
/// - `file` - the handle.
/// - `offset` - where the new end is, counted from `mode`.
/// - `mode` - `OFFSET_BEGINNING`, `OFFSET_CURRENT` or `OFFSET_END`.
///
/// RESULT:
/// The new size, or -1 with `IoErr()` set (`ERROR_INVALID_LOCK`,
/// `ERROR_ACTION_NOT_KNOWN` from a handler without the packet, or its own
/// code).
///
/// BEHAVIOR:
/// The buffer is flushed first, so waiting bytes are in the file before it
/// is cut. Then `ACTION_SET_FILE_SIZE` goes to the handler; bytes a grown
/// file gains are 0.
///
/// CONTEXT:
/// - Waits: yes: it sends the handler a packet and waits for the answer.
/// - Interrupts: no. It waits.
/// - Forbid: not taken, and never to be held around it: it waits.
/// - Process: a Task will do; the answer comes back on a port of its own.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Seek`, `Flush`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.SetFileSize(fh, 0, dos.OFFSET_BEGINNING) < 0) return dos_lib.IoErr();
/// ```
pub fn SetFileSize(db: *DosBase, file: ?*FileHandle, offset: isize, mode: i32) isize {
    const fh = file orelse return failWith(db, dos.ERROR_INVALID_LOCK, -1);
    if (!_file.flush(db, fh)) return -1;
    return fileAction(db, fh, .set_file_size, offset, mode);
}

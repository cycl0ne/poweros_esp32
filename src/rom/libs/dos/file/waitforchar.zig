// SPDX-License-Identifier: MPL-2.0
//! WaitForChar: waits a bounded time for input on a console.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const consoleAction = _file.consoleAction;
const failWith = _file.failWith;
const FileHandle = dos.FileHandle;

/// Tells whether a console has input within a time.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitForChar(db: *DosBase, file: ?*FileHandle, timeout: isize) bool
/// ```
///
/// SINCE: 1.0. LVO -480.
///
/// INPUTS:
/// - `file` - the console's handle.
/// - `timeout` - how long to wait, in microseconds; 0 only asks.
///
/// RESULT:
/// True when there is input to read. False when the time ran out, or on an
/// error with `IoErr()` set (`ERROR_INVALID_LOCK`, `ERROR_NO_FREE_STORE`,
/// or the handler's code).
///
/// BEHAVIOR:
/// Bytes the handle already holds - read ahead or pushed back - answer true
/// at once. Otherwise `ACTION_WAIT_CHAR` goes to the handler, which answers
/// when input comes or the time is up. In cooked mode input means a whole
/// line.
///
/// CONTEXT:
/// - Waits: yes: up to `timeout`, for the handler's answer.
/// - Interrupts: no. It waits.
/// - Forbid: not taken, and never to be held around it: it waits.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// The packet names the time only, not the handle: a console handler
/// answers for the window or port it serves.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetMode`, `FGetC`, `Read`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.WaitForChar(dos_lib.Input(), 50_000)) {
///     const c = dos_lib.FGetC(dos_lib.Input());
///     _ = c;
/// }
/// ```
pub fn WaitForChar(db: *DosBase, file: ?*FileHandle, timeout: isize) bool {
    const fh = file orelse return failWith(db, dos.ERROR_INVALID_LOCK, 0) != 0;
    if (fh.state == .read and (fh.pos < fh.end or fh.unget_count > 0)) return true;
    return consoleAction(db, fh, .wait_char, timeout);
}

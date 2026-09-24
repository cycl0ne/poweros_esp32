// SPDX-License-Identifier: MPL-2.0
//! SetMode: switches a console between raw and cooked input.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const consoleAction = _file.consoleAction;
const failWith = _file.failWith;
const FileHandle = dos.FileHandle;

/// Sets a console's mode.
///
/// SYNOPSIS:
/// ```zig
/// fn SetMode(db: *DosBase, file: ?*FileHandle, mode: i32) bool
/// ```
///
/// SINCE: 1.0. LVO -476.
///
/// INPUTS:
/// - `file` - the console's handle.
/// - `mode` - 1 raw (bytes as typed, no echo or line editing), 0 cooked
///   (edited lines).
///
/// RESULT:
/// True when the console switched. False with `IoErr()` set:
/// `ERROR_INVALID_LOCK` for a null handle or one without a handler,
/// `ERROR_NO_FREE_STORE`, or the handler's code (`ERROR_ACTION_NOT_KNOWN`
/// from one that isn't a console).
///
/// BEHAVIOR:
/// Bytes waiting in the buffer are written first, so output given before
/// the switch appears before it. Then `ACTION_SCREEN_MODE` with `mode` goes
/// to the handler.
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
/// NOTES:
/// The packet names the mode only, not the handle: a console handler
/// answers for the window or port it serves, whichever of its handles
/// asked.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WaitForChar`, `IsInteractive`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.SetMode(dos_lib.Input(), 1)) return dos_lib.IoErr();
/// defer _ = dos_lib.SetMode(dos_lib.Input(), 0);
/// ```
pub fn SetMode(db: *DosBase, file: ?*FileHandle, mode: i32) bool {
    const fh = file orelse return failWith(db, dos.ERROR_INVALID_LOCK, 0) != 0;
    if (fh.state == .write and !_file.flush(db, fh)) return false;
    return consoleAction(db, fh, .screen_mode, mode);
}

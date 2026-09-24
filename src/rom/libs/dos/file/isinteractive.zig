// SPDX-License-Identifier: MPL-2.0
//! IsInteractive: whether a handle is a console.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const FileHandle = dos.FileHandle;

/// Tells whether a file is a console.
///
/// SYNOPSIS:
/// ```zig
/// fn IsInteractive(_: *DosBase, file: ?*FileHandle) bool
/// ```
///
/// SINCE: 1.0. LVO -228.
///
/// INPUTS:
/// - `file` - the handle, or null.
///
/// RESULT:
/// True when the handler marked the handle interactive at open - a console,
/// typed at by someone; false otherwise and for null.
///
/// BEHAVIOR:
/// Reads `fh_Interactive`, which the handler set when it opened the file;
/// no packet is sent.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe: it reads one field.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetMode`, `WaitForChar`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.IsInteractive(dos_lib.Input())) _ = dos_lib.PutStr("> ");
/// ```
pub fn IsInteractive(_: *DosBase, file: ?*FileHandle) bool {
    const fh = file orelse return false;
    return fh.interactive;
}

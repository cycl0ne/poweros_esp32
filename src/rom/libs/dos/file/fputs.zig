// SPDX-License-Identifier: MPL-2.0
//! FPuts: writes a C string to a file through the handle's buffer.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const FileHandle = dos.FileHandle;

/// Writes a string to a file.
///
/// SYNOPSIS:
/// ```zig
/// fn FPuts(db: *DosBase, file: ?*FileHandle, string: [*:0]const u8) i32
/// ```
///
/// SINCE: 1.0. LVO -432.
///
/// INPUTS:
/// - `file` - the handle.
/// - `string` - the string; its NUL is not written.
///
/// RESULT:
/// 0, or -1 with `IoErr()` set as for `FWrite`.
///
/// BEHAVIOR:
/// `FWrite` of the string's length.
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
/// Nothing is allocated. The string stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FWrite`, `PutStr`, `FGets`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.FPuts(fh, "done\n") < 0) return dos_lib.IoErr();
/// ```
pub fn FPuts(db: *DosBase, file: ?*FileHandle, string: [*:0]const u8) i32 {
    const dos_lib = db.iface();
    return if (dos_lib.FWrite(file, string, @intCast(db.utility_base.Strlen(string))) < 0) -1 else 0;
}

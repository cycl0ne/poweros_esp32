// SPDX-License-Identifier: MPL-2.0
//! PutStr: writes a C string to the process's output.

const DosBase = @import("../dos_base.zig").DosBase;

/// Writes a string to the process's output.
///
/// SYNOPSIS:
/// ```zig
/// fn PutStr(db: *DosBase, string: [*:0]const u8) i32
/// ```
///
/// SINCE: 1.0. LVO -448.
///
/// INPUTS:
/// - `string` - the string; its NUL is not written.
///
/// RESULT:
/// 0, or -1 with `IoErr()` set as for `FPuts` (`ERROR_INVALID_LOCK` from a
/// Task or a process without output).
///
/// BEHAVIOR:
/// `FPuts` to `Output()`, through its buffer.
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
/// `FPuts`, `WriteChars`, `Output`
///
/// EXAMPLES:
/// ```zig
/// _ = dos_lib.PutStr("Ready.\n");
/// ```
pub fn PutStr(db: *DosBase, string: [*:0]const u8) i32 {
    const dos_lib = db.iface();
    return dos_lib.FPuts(dos_lib.Output(), string);
}

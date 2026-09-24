// SPDX-License-Identifier: MPL-2.0
//! WriteChars: writes bytes to the process's output.

const DosBase = @import("../dos_base.zig").DosBase;

/// Writes bytes to the process's output.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteChars(db: *DosBase, buffer: [*]const u8, length: isize) isize
/// ```
///
/// SINCE: 1.0. LVO -452.
///
/// INPUTS:
/// - `buffer` - the bytes.
/// - `length` - how many.
///
/// RESULT:
/// As `FWrite`: `length`, or -1 with `IoErr()` set (`ERROR_INVALID_LOCK`
/// from a Task or a process without output).
///
/// BEHAVIOR:
/// `FWrite` to `Output()`, through its buffer.
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
/// Nothing is allocated. The bytes stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FWrite`, `PutStr`, `Output`
///
/// EXAMPLES:
/// ```zig
/// const word = "ok";
/// _ = dos_lib.WriteChars(word, word.len);
/// ```
pub fn WriteChars(db: *DosBase, buffer: [*]const u8, length: isize) isize {
    const dos_lib = db.iface();
    return dos_lib.FWrite(dos_lib.Output(), buffer, length);
}

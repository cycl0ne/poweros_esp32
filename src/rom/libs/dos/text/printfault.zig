// SPDX-License-Identifier: MPL-2.0
//! PrintFault: writes the text for an error code, and a newline, to
//! Output().

const DosBase = @import("../dos_base.zig").DosBase;

/// Writes the text for an error code, and a newline, to Output().
///
/// SYNOPSIS:
/// ```zig
/// fn PrintFault(db: *DosBase, code: i32, header: ?[*:0]const u8) bool
/// ```
///
/// SINCE: 1.0. LVO -488.
///
/// INPUTS:
/// - `code` - the error code, as for Fault.
/// - `header` - put before the text with ": " after it; null for none.
///
/// RESULT:
/// True when the line was written, or there was nothing to write (a code of
/// 0). False when the process has no Output() or the write fails.
///
/// BEHAVIOR:
/// The line is Fault's text, at most 254 characters, and a newline, written
/// with FWrite. IoErr is set to `code` afterwards whatever happened, so the
/// caller can report an error and still hand it on.
///
/// CONTEXT:
/// - Waits: yes, for the output's handler.
/// - Interrupts: not callable.
/// - Forbid: must not be held.
/// - Process: required for output; a plain task has no Output() and gets
///   false.
///
/// OWNERSHIP:
/// Nothing is kept.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Fault`, `IoErr`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.Lock(name, dos.SHARED_LOCK) == null) {
///     _ = dos_lib.PrintFault(dos_lib.IoErr(), name);
///     return dos.RETURN_FAIL;
/// }
/// ```
pub fn PrintFault(db: *DosBase, code: i32, header: ?[*:0]const u8) bool {
    const dos_lib = db.iface();
    defer _ = dos_lib.SetIoErr(code);
    var line: [256]u8 = undefined;
    const n: usize = @intCast(dos_lib.Fault(code, header, &line, line.len - 1));
    if (n == 0) return true;
    const out = dos_lib.Output() orelse return false;
    line[n] = '\n';
    return dos_lib.FWrite(out, &line, @intCast(n + 1)) >= 0;
}

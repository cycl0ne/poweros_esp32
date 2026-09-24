// SPDX-License-Identifier: MPL-2.0
//! VFPrintf: formats text with RawDoFmt's formats and writes it to a file
//! through the handle's buffer.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const Printing = _file.Printing;
const FileHandle = dos.FileHandle;

/// Writes formatted text to a file.
///
/// SYNOPSIS:
/// ```zig
/// fn VFPrintf(db: *DosBase, file: ?*FileHandle, format: [*:0]const u8, args: ?*const anyopaque) i32
/// ```
///
/// SINCE: 1.0. LVO -440.
///
/// INPUTS:
/// - `file` - the handle.
/// - `format` - the format: RawDoFmt's (`%d %u %x %c` for 32-bit values,
///   `%ld` for 64, `%s` for a string).
/// - `args` - the values, packed as RawDoFmt's data stream;
///   `sdk.dos.stdio.FPrintf` packs them from a tuple.
///
/// RESULT:
/// The number of bytes written, or -1 when a write failed (`IoErr()` as for
/// `FPutC`).
///
/// BEHAVIOR:
/// exec's `RawDoFmt` does the formatting and each character goes out
/// through `FPutC`. The NUL the format ends with is not written. After a
/// failed write the rest is formatted and dropped.
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
/// Nothing is allocated beyond the handle's buffer.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `VPrintf`, `FPuts`, `RawDoFmt`
///
/// EXAMPLES:
/// ```zig
/// const stream = sdk.exec.fmtStream(.{ count, name });
/// _ = dos_lib.VFPrintf(fh, "%d files in %s\n", &stream);
/// ```
pub fn VFPrintf(db: *DosBase, file: ?*FileHandle, format: [*:0]const u8, args: ?*const anyopaque) i32 {
    var p: Printing = .{ .db = db, .fh = file };
    _ = db.sys_base.RawDoFmt(format, args, &Printing.put, &p);
    return if (p.failed) -1 else p.count;
}

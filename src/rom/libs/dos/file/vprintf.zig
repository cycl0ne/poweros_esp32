// SPDX-License-Identifier: MPL-2.0
//! VPrintf: formats text with RawDoFmt's formats and writes it to the
//! process's output.

const sdk = @import("sdk");
const DosBase = @import("../dos_base.zig").DosBase;

/// Writes formatted text to the process's output.
///
/// SYNOPSIS:
/// ```zig
/// fn VPrintf(db: *DosBase, format: [*:0]const u8, args: ?*const anyopaque) i32
/// ```
///
/// SINCE: 1.0. LVO -444.
///
/// INPUTS:
/// - `format` - the format, as for `VFPrintf`.
/// - `args` - the values, packed as RawDoFmt's data stream;
///   `sdk.dos.stdio.Printf` packs them from a tuple.
///
/// RESULT:
/// As `VFPrintf`: the bytes written, or -1. -1 with `ERROR_INVALID_LOCK`
/// from a Task or a process without output.
///
/// BEHAVIOR:
/// `VFPrintf` to `Output()`.
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
/// Nothing is allocated beyond the output's buffer.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `VFPrintf`, `PutStr`, `Output`
///
/// EXAMPLES:
/// ```zig
/// const stream = sdk.exec.fmtStream(.{code});
/// _ = dos_lib.VPrintf("error %d\n", &stream);
/// ```
pub fn VPrintf(db: *DosBase, format: [*:0]const u8, args: ?*const anyopaque) i32 {
    const dos_lib = db.iface();
    return dos_lib.VFPrintf(dos_lib.Output(), format, args);
}

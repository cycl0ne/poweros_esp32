// SPDX-License-Identifier: MPL-2.0
//! RawMayGetChar: a character from the raw serial port, if one is waiting.
//! It never waits.

const _rawio = @import("_rawio.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Takes a character from exec's own console if one is waiting.
///
/// SYNOPSIS:
/// ```zig
/// fn RawMayGetChar(_: *ExecBase) i32
/// ```
///
/// SINCE: 1.0. LVO -380.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The character, or **-1** if none is waiting. It never waits, which is
/// what "may" means here.
///
/// BEHAVIOR:
/// The port is polled and has no buffer of its own, so a character that
/// arrives while nobody is asking is lost. That is acceptable for what this
/// is - a debug console typed at by a person - and is why serial.device,
/// which buffers on an interrupt, is what a program uses.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not needed.
/// - Process: a Task will do. It works with no task at all.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RawPutChar`, `RawIOInit`
///
/// EXAMPLES:
/// ```zig
/// const c = sys.RawMayGetChar();
/// if (c >= 0) { ... }
/// ```
pub fn RawMayGetChar(_: *ExecBase) i32 {
    if (!_rawio.raw_ready) return -1;
    return _rawio.raw_io_hardware.get() orelse -1;
}

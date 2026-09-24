// SPDX-License-Identifier: MPL-2.0
//! RawPutChar: one character out on the raw serial port. "\n" goes out as
//! "\r\n" and a NUL goes nowhere, so a terminal need not be in any
//! particular mode and RawDoFmt's terminating NUL costs nothing.

const _rawio = @import("_rawio.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Sends one character to exec's own console.
///
/// SYNOPSIS:
/// ```zig
/// fn RawPutChar(_: *ExecBase, character: u8) void
/// ```
///
/// SINCE: 1.0. LVO -376.
///
/// INPUTS:
/// - `ch` - the character. A NUL is dropped, so the terminating NUL that
///   `RawDoFmt` sends costs nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A newline goes out as carriage return and newline, so a terminal need
/// not be in any particular mode to be readable.
///
/// It is **polled**: the call returns when the character has been handed to
/// the hardware, which at the port's speed is slow enough to matter in a
/// tight loop. Nothing before `RawIOInit` goes anywhere.
///
/// CONTEXT:
/// - Waits: no, but it spins on the transmitter.
/// - Interrupts: safe, and that is why kernel output uses it: it needs no
///   task, no device and no memory.
/// - Forbid: not needed.
/// - Process: a Task will do. It works with no task at all.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// This is the kernel's output, not a program's. A program writes to its
/// own output stream, which reaches a console or a file; this always goes
/// to UART0 whatever else the machine is doing, which is what makes it
/// worth having when the rest has stopped.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RawDoFmt`, `RawMayGetChar`, `RawIOInit`
///
/// EXAMPLES:
/// ```zig
/// sys.RawPutChar('!');
/// ```
pub fn RawPutChar(_: *ExecBase, character: u8) void {
    _rawio.putChar(character);
}

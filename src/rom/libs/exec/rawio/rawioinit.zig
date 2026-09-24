// SPDX-License-Identifier: MPL-2.0
//! RawIOInit: sets the raw serial port up. exec's init calls it first of
//! all, and until then nothing goes out and nothing comes in - so a fault
//! before that point is silent.

const _rawio = @import("_rawio.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Sets exec's own console up, before anything can be printed.
///
/// SYNOPSIS:
/// ```zig
/// fn RawIOInit(_: *ExecBase) void
/// ```
///
/// SINCE: 1.0. LVO -384.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// exec's init does this **first**, before anything else it does, because
/// nothing printed before it goes anywhere - so a fault earlier than this
/// is silent, and that is worth keeping to as short a span as possible.
///
/// Whatever the boot ROM was still sending is let out before the port is
/// retimed, so its output and the kernel's do not run together.
///
/// CONTEXT:
/// - Waits: no, but it waits for the port to drain.
/// - Interrupts: safe.
/// - Forbid: not needed.
/// - Process: a Task will do. It runs before there are any.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// Calling it again re-times the port, which is how a machine whose clock
/// has changed keeps a readable console.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RawPutChar`, `RawDoFmt`
///
/// EXAMPLES:
/// ```zig
/// sys.RawIOInit();
/// ```
pub fn RawIOInit(_: *ExecBase) void {
    _rawio.raw_io_hardware.init();
    _rawio.raw_ready = true;
}

// SPDX-License-Identifier: MPL-2.0
//! ReadLog: copies bytes of the system log out of exec's ring.

const _log = @import("_log.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Reads the system log from a byte's running number on.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadLog(base: *ExecBase, position: *u64, buffer: [*]u8, size: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -468.
///
/// INPUTS:
/// - `position` - the running number of the first byte wanted: 0 for the
///   oldest the ring still holds. Moved past the last byte copied.
/// - `buffer` - where the bytes go.
/// - `size` - how many bytes `buffer` holds.
///
/// RESULT:
/// How many bytes were copied; 0 when there is nothing after `position`.
///
/// BEHAVIOR:
/// The log is everything written to the raw port - kprintf, RawPutChar -
/// since the boot, each line with its time and writer in front. exec keeps
/// the last 16 KiB of it. Every byte has a running number that never
/// wraps, so a reader keeps the number it has read up to and calls again
/// for what came after.
///
/// A reader that fell further behind than the ring holds gets the oldest
/// byte still kept: the new position less the count is where the copy
/// started, and that less the position asked for is how much was lost.
///
/// Any number of readers read beside each other; reading takes nothing
/// away.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not needed. It holds interrupts off while it copies.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bytes are copied into the caller's buffer; nothing is allocated.
///
/// NOTES:
/// The bytes are text but not NUL-terminated. A read may end in the middle
/// of a line.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetLogSignal`, `RawPutChar`
///
/// EXAMPLES:
/// ```zig
/// var position: u64 = 0;
/// var buffer: [512]u8 = undefined;
/// while (true) {
///     const count = sys.ReadLog(&position, &buffer, buffer.len);
///     if (count == 0) break;
///     _ = dl.Write(dl.Output(), &buffer, count);
/// }
/// ```
pub fn ReadLog(base: *ExecBase, position: *u64, buffer: [*]u8, size: u32) u32 {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    return @intCast(_log.copyOut(position, buffer[0..size]));
}

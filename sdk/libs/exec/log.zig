// SPDX-License-Identifier: MIT
//! The system log's levels and settings.
//!
//! Every line written to the raw port is kept in exec's log (`ReadLog`).
//! A line has a level: `kprintf`'s are `LOG_INFO`, and `klog` writes one
//! at the level it is given. A line below the level exec keeps
//! (`LogControl(LOGCTRL_LEVEL, ...)`) is not written at all - neither to
//! the port nor to the log - so a debug line costs nothing until it is
//! asked for. A line that is not information has its level after the
//! time and the writer: `[  12.345678 sdcard] W: no card`.
//!
//! The level travels with the line: a line that starts with `LOG_MARK`
//! and a level's digit ('1' to '4') is at that level, which is how `klog`
//! marks its lines. So it works through RawDoFmt and RawPutChar, from any
//! context, with nothing else to call.

/// A line's level, from the most to the least urgent.
pub const LOG_ERROR: u32 = 1;
pub const LOG_WARNING: u32 = 2;
pub const LOG_INFO: u32 = 3;
pub const LOG_DEBUG: u32 = 4;

/// What starts a line that names its level: this, then the level's digit.
pub const LOG_MARK: u8 = 0x01;

/// The marker that puts a line at `level`, to go in front of its format.
pub fn levelMark(comptime level: u32) *const [2:0]u8 {
    if (level < LOG_ERROR or level > LOG_DEBUG) @compileError("not a log level");
    return comptime &[2:0]u8{ LOG_MARK, '0' + @as(u8, @intCast(level)) };
}

/// A level's name, as `C:Log LEVEL` takes it; null for none.
pub fn levelName(level: u32) ?[*:0]const u8 {
    return switch (level) {
        LOG_ERROR => "error",
        LOG_WARNING => "warning",
        LOG_INFO => "info",
        LOG_DEBUG => "debug",
        else => null,
    };
}

/// LogControl's `what`.
/// The level kept: `LOG_ERROR` to `LOG_DEBUG`. A line below it is not
/// written.
pub const LOGCTRL_LEVEL: u32 = 1;
/// Whether the log is copied to the USB console: 1 or 0.
pub const LOGCTRL_MIRROR: u32 = 2;
/// The USB port has a driver now, which copies the log itself: exec stops
/// writing to the port. 1 tells it; usbserial.device does, as it starts.
pub const LOGCTRL_USBPORT: u32 = 3;

/// LogControl's `value` that changes nothing and only asks.
pub const LOGCTRL_ASK: isize = -1;

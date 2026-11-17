// SPDX-License-Identifier: MIT
//! What the settings say of an output: a line of `display.prefs`, as a
//! structure.
//!
//! The file is `ENVARC:Sys/display.prefs`, and `ENV:Sys/display.prefs`
//! for the running system: a line for a device or for an output, keys
//! and values.
//!
//!     DEVICE=pci.01:00.0 DRIVER=OFF
//!     OUTPUT=amd.0 MONITOR=DEL:A0C4:00012345 MODE=2560x1440@60 FIRST=YES MIRROR=X BRIGHTNESS=80
//!     OUTPUT=jh7110.0 TIMINGS=148500000,1920,88,44,148,1080,4,5,36,+H,+V
//!
//! - DEVICE: a device's name, as `GetRtgDevices` answers it. DRIVER=OFF:
//!   no driver from the disk is bound to it. BUFFERS: the most pictures
//!   at once on each of its boards. COMPOSE=YES or NO: whether its
//!   screens' windows each draw into a buffer of their own.
//! - OUTPUT: a board's name. MONITOR: the maker, the product and the
//!   serial number of the monitor the line is for, as the monitor says
//!   them; the line is passed over while another monitor is on the
//!   output, and a line without it is for a panel, or for whatever is
//!   there. MODE: the mode the display runs in, WIDTHxHEIGHT or
//!   WIDTHxHEIGHT@HZ. FIRST=YES: the board is the first. MIRROR: X, Y,
//!   XY or NONE. BRIGHTNESS: 0 to 100. RANGE: FULL or LIMITED, the
//!   colour range sent to a television. TIMINGS: for a monitor that says
//!   nothing of itself - the pixel clock in Hertz, then across the
//!   picture's width, the porch before the sync pulse, the pulse and the
//!   porch after it, the same four in lines, and the two pulses' ways,
//!   +H or -H and +V or -V.
//!
//! rtg.library reads and writes the file (`LoadBoardSettings`,
//! `SaveBoardSettings`); a program reads and changes one output's line
//! as an `RtgSettings` (`GetBoardSettings`, `SetBoardSettings`), and a
//! device's with `SetRtgDeviceDriver`.

const modes = @import("modes.zig");

/// The file for the running system, and the one kept over a restart.
pub const RTG_SETTINGS_ENV = "ENV:Sys/display.prefs";
pub const RTG_SETTINGS_ENVARC = "ENVARC:Sys/display.prefs";

/// One output's line.
pub const RtgSettings = extern struct {
    /// RTGSET_*: what the line says. A field whose flag is clear says
    /// nothing.
    flags: u32 = 0,
    /// With `RTGSET_MONITOR`: the monitor the line is for - its maker's
    /// three letters, NUL-terminated, the maker's number for the product
    /// and the serial number, as `GetBoardMonitor` answers them.
    maker: [4]u8 = @splat(0),
    product: u32 = 0,
    serial: u32 = 0,
    /// With `RTGSET_MODE`: the mode that is the board's default, which
    /// its display is put in when its first screen opens. A refresh of
    /// 0 leaves the refresh open.
    mode_width: u32 = 0,
    mode_height: u32 = 0,
    mode_refresh_mhz: u32 = 0,
    /// With `RTGSET_BRIGHTNESS`: 0 to 100.
    brightness: u32 = 0,
    /// With `RTGSET_TIMINGS`: the timings of a monitor that says nothing
    /// of itself.
    timings: modes.RtgTimings = .{},
};

/// RtgSettings.flags
/// The line is for one monitor, named in `maker`, `product` and `serial`.
pub const RTGSET_MONITOR: u32 = 1 << 0;
/// `mode_width`, `mode_height` and `mode_refresh_mhz` name the mode.
pub const RTGSET_MODE: u32 = 1 << 1;
/// The board is the first: `NextBoard(null)` answers it.
pub const RTGSET_FIRST: u32 = 1 << 2;
/// The line says how the picture is mirrored: about each axis whose flag
/// is set, and unturned with neither.
pub const RTGSET_MIRROR: u32 = 1 << 3;
pub const RTGSET_MIRROR_X: u32 = 1 << 4;
pub const RTGSET_MIRROR_Y: u32 = 1 << 5;
/// `brightness` is the backlight's.
pub const RTGSET_BRIGHTNESS: u32 = 1 << 6;
/// The line says the colour range: limited with `RTGSET_LIMITED_RANGE`,
/// else full. Without, the range is what the monitor asks for.
pub const RTGSET_RANGE: u32 = 1 << 7;
pub const RTGSET_LIMITED_RANGE: u32 = 1 << 8;
/// `timings` are the monitor's.
pub const RTGSET_TIMINGS: u32 = 1 << 9;

/// RtgBoardInfo.color_range: the range of the colours an output sends.
/// What the monitor asks for; every value a colour; 16 to 235, as a
/// television takes them.
pub const RTGRANGE_AUTO: u8 = 0;
pub const RTGRANGE_FULL: u8 = 1;
pub const RTGRANGE_LIMITED: u8 = 2;

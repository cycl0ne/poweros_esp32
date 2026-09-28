// SPDX-License-Identifier: MIT
//! fuelgauge.gadget: a bar that shows how far along something is.
//!
//! The gauge stands between `GAUGE_Min` and `GAUGE_Max` and is filled as
//! far as `GAUGE_Level` has come, across (`GAUGE_HORIZONTAL`) or up
//! (`GAUGE_VERTICAL`), in a sunk frame. Given a `GAUGE_Format` it writes a
//! number over the bar as well - the level, or how far along it is in
//! hundredths with `GAUGE_Percent` - and each character is in the fill's
//! text pen where it lies over the filled part and in the screen's text
//! pen where it does not, so the number is readable however far the bar
//! has come.
//!
//! It is never pressed: a press goes through it to the window.
//!
//!   const gauge = ib.NewObjectTagList(null, fg.GAUGE_CLASS, &.{
//!       .{ .tag = fg.GAUGE_Level, .data = 0 },
//!       .{ .tag = fg.GAUGE_Percent, .data = 1 },
//!       .{ .tag = fg.GAUGE_Format, .data = @intFromPtr("%ld%%") },
//!       .{},
//!   });
//!   // ... as the work goes on
//!   _ = ib.SetGadgetAttrsTagList(gauge, window, &.{
//!       .{ .tag = fg.GAUGE_Level, .data = done },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const GAUGE_LIBRARY = "gadgets/fuelgauge.gadget";
pub const GAUGE_CLASS = "fuelgauge.gadget";

pub const GAUGE_Dummy = gadgets.GADGETS_Dummy + 12 * gadgets.GADGETS_Step;
/// Where the gauge starts and ends (0 and 100 unless given). Made, set
/// and read; a level outside them is held at the nearer end.
pub const GAUGE_Min = GAUGE_Dummy + 0x01;
pub const GAUGE_Max = GAUGE_Dummy + 0x02;
/// How far along it is. Made, set and read.
pub const GAUGE_Level = GAUGE_Dummy + 0x03;
/// The RawDoFmt format the number over the bar is written through: one
/// number, `%ld` or `%d`, and any words round it. No number is shown
/// unless it is given. Not copied.
pub const GAUGE_Format = GAUGE_Dummy + 0x04;
/// Bool: the number written through the format is how far along the
/// gauge is in hundredths, not the level itself.
pub const GAUGE_Percent = GAUGE_Dummy + 0x05;
/// `TEXT_JUSTIFY_*`: where the number sits over the bar (in the middle
/// unless given).
pub const GAUGE_Justification = GAUGE_Dummy + 0x06;
/// `GAUGE_HORIZONTAL` or `GAUGE_VERTICAL`: which way it fills. Made only.
pub const GAUGE_Orientation = GAUGE_Dummy + 0x07;

/// Filled from the left; filled from the bottom.
pub const GAUGE_HORIZONTAL: u32 = 0;
pub const GAUGE_VERTICAL: u32 = 1;

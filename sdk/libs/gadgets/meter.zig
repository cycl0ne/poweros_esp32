// SPDX-License-Identifier: MIT
//! meter.gadget: a dial - a scale on an arc, a needle at the level.
//!
//! The scale runs clockwise from `METER_Start` over `METER_Sweep` degrees
//! (from the lower left round to the lower right unless given), with
//! `METER_Ticks` long ticks and `METER_Minor` short ones between each two,
//! numbers at the long ones when the dial is big enough, and, from
//! `METER_Band` on, the scale drawn in `METER_BandRGB` - a red end. The
//! needle and its hub are the style's indicator (`PART_INDICATOR`); a
//! new level swings the needle there over a quarter of a second on
//! motion.library's clock, or at once where nothing moves
//! (`GA_Animate`, `SA_Animate`). Given a `METER_Format` the level is
//! written under the hub. It is never pressed.
//!
//! Degrees are graphics.library's: 0 to the right, anticlockwise up.
//!
//!   const meter = ib.NewObjectTagList(null, mt.METER_CLASS, &.{
//!       .{ .tag = mt.METER_Max, .data = 120 },
//!       .{ .tag = mt.METER_Band, .data = 100 },
//!       .{ .tag = mt.METER_Format, .data = @intFromPtr("%ld km/h") },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const METER_LIBRARY = "gadgets/meter.gadget";
pub const METER_CLASS = "meter.gadget";

pub const METER_Dummy = gadgets.GADGETS_Dummy + 20 * gadgets.GADGETS_Step;
/// Where the scale starts and ends (0 and 100 unless given). Made, set and
/// read; a level outside them is held at the nearer end.
pub const METER_Min = METER_Dummy + 0x01;
pub const METER_Max = METER_Dummy + 0x02;
/// Where the needle points. Made, set and read.
pub const METER_Level = METER_Dummy + 0x03;
/// The angle of the scale's start, in degrees (225, the lower left).
/// Made and set.
pub const METER_Start = METER_Dummy + 0x04;
/// How many degrees the scale covers, clockwise from its start (270).
/// Made and set.
pub const METER_Sweep = METER_Dummy + 0x05;
/// How many parts the long ticks divide the scale into (10). Made and set.
pub const METER_Ticks = METER_Dummy + 0x06;
/// How many parts the short ticks divide each of those into (2; 1 for
/// none). Made and set.
pub const METER_Minor = METER_Dummy + 0x07;
/// The RawDoFmt format the level is written under the hub through: one
/// number, `%ld` or `%d`. None unless given. Not copied.
pub const METER_Format = METER_Dummy + 0x08;
/// The value from which the scale is drawn in the band colour; none
/// unless given. Made and set.
pub const METER_Band = METER_Dummy + 0x09;
/// The band's colour, 0xAARRGGBB (a red). Made and set.
pub const METER_BandRGB = METER_Dummy + 0x0A;

// SPDX-License-Identifier: MIT
//! slider.gadget: a slider that picks a whole number from `SLIDER_Min` to
//! `SLIDER_Max`, and may show it beside itself.
//!
//! The knob is one level wide and stops on a level when it is let go; a
//! press beside it moves it one level that way. Across (`PGA_Freedom`
//! `FREEHORIZ`, the default) the smallest level is at the left; up and
//! down (`FREEVERT`) it is at the bottom. While the knob moves, the target
//! hears `SLIDER_Level` with the gadget's `GA_ID` at every level it
//! passes; let go, the window hears `IDCMP_GADGETUP` with the level,
//! signed, as the code.
//!
//! Given `SLIDER_LevelFormat`, the level is shown beside the slider -
//! `SLIDER_LevelPlace` says which side - in room for `SLIDER_MaxLevelLen`
//! characters, or `SLIDER_MaxLevelPixels` pixels where that is wider. A `SLIDER_DispFunc` hook turns the level into the number
//! shown first.
//!
//!   const volume = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 4 },
//!       .{ .tag = sl.SLIDER_Max, .data = 64 },
//!       .{ .tag = sl.SLIDER_Level, .data = 32 },
//!       .{ .tag = sl.SLIDER_LevelFormat, .data = @intFromPtr("%ld") },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const SLIDER_LIBRARY = "gadgets/slider.gadget";
pub const SLIDER_CLASS = "slider.gadget";

pub const SLIDER_Dummy = gadgets.GADGETS_Dummy + 5 * gadgets.GADGETS_Step;
/// The smallest level and the largest, signed; 0 and 15 unless given. Made
/// and set. Given the wrong way round, they are swapped.
pub const SLIDER_Min = SLIDER_Dummy + 0x01;
pub const SLIDER_Max = SLIDER_Dummy + 0x02;
/// The level, signed. Made, set and read; told to the target as the knob
/// moves. Outside the range is the nearer end of it.
pub const SLIDER_Level = SLIDER_Dummy + 0x03;
/// The RawDoFmt format the level is shown through: one number, `%ld` or
/// `%d`. Without it nothing is shown. Made only; not copied.
pub const SLIDER_LevelFormat = SLIDER_Dummy + 0x04;
/// `SLIDER_PLACE_LEFT` or `SLIDER_PLACE_RIGHT`: which side the level is
/// shown on. Left unless given. Made only.
pub const SLIDER_LevelPlace = SLIDER_Dummy + 0x05;
/// How many characters the shown level has room for; 2 unless given. Made
/// only.
pub const SLIDER_MaxLevelLen = SLIDER_Dummy + 0x06;
/// Where the level sits in its room: `TEXT_JUSTIFY_LEFT`, `_RIGHT` or
/// `_CENTER` of text.gadget. Left unless given. Made only.
pub const SLIDER_LevelJustify = SLIDER_Dummy + 0x07;
/// A `*utility.Hook` that turns a level into the number shown: called with
/// the gadget as its object and a `*const i32`, the level, as its message,
/// and answers the number. Made only.
pub const SLIDER_DispFunc = SLIDER_Dummy + 0x08;
/// How many pixels the shown level has room for, as well as
/// `SLIDER_MaxLevelLen` characters: the wider of the two is what it gets.
/// 0, which is none, unless given. Made only. For a proportional font, in
/// which a count of characters says little about the width the widest
/// number needs.
pub const SLIDER_MaxLevelPixels = SLIDER_Dummy + 0x09;

pub const SLIDER_PLACE_LEFT: u32 = 0;
pub const SLIDER_PLACE_RIGHT: u32 = 1;

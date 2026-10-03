// SPDX-License-Identifier: MIT
//! chart.gadget: values over time as lines or bars, over an axis.
//!
//! The gadget keeps the values: a ring of `CHART_Capacity` for each of its
//! `CHART_Series` (1 to 4). A program adds to one with `CHART_Current` and
//! `CHART_Add` - repeated in one tag list for several values or several
//! series - and the oldest value of a full ring makes room, so the chart
//! scrolls to the left as a live plot does. The newest value is at the
//! right; a series with fewer values than room starts further right.
//!
//! The values run up a scale from `CHART_Min` to `CHART_Max`, or, with
//! `CHART_Auto`, from the smallest to the largest value held, widened to
//! round numbers. `CHART_Lines` lines across it, numbered at the left. Each
//! series is drawn as `CHART_Kind` says - a line through its values, or a
//! bar for each, the series' bars side by side - in its colour: the
//! style's indicator (`PART_INDICATOR`) for the first unless
//! `CHART_ColourRGB` gives one, and a red, a green and an orange for the
//! others. It is never pressed.
//!
//!   const plot = ib.NewObjectTagList(null, cr.CHART_CLASS, &.{
//!       .{ .tag = cr.CHART_Series, .data = 2 },
//!       .{ .tag = cr.CHART_Auto, .data = 1 },
//!       .{},
//!   });
//!   // each second:
//!   _ = ib.SetGadgetAttrsTagList(plot, window, &.{
//!       .{ .tag = cr.CHART_Current, .data = 0 },
//!       .{ .tag = cr.CHART_Add, .data = temperature },
//!       .{ .tag = cr.CHART_Current, .data = 1 },
//!       .{ .tag = cr.CHART_Add, .data = humidity },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const CHART_LIBRARY = "gadgets/chart.gadget";
pub const CHART_CLASS = "chart.gadget";

pub const CHART_Dummy = gadgets.GADGETS_Dummy + 27 * gadgets.GADGETS_Step;
/// How many series it holds, 1 to 4 (1). Made only.
pub const CHART_Series = CHART_Dummy + 0x01;
/// How many values each series keeps, 2 to 1024 (64). Made only.
pub const CHART_Capacity = CHART_Dummy + 0x02;
/// The scale's bottom and top (0 and 100), when not `CHART_Auto`. Made and
/// set.
pub const CHART_Min = CHART_Dummy + 0x03;
pub const CHART_Max = CHART_Dummy + 0x04;
/// Bool: the scale follows the values held (false). Made and set.
pub const CHART_Auto = CHART_Dummy + 0x05;
/// `CHART_LINES` or `CHART_BARS` (`CHART_LINES`). Made and set.
pub const CHART_Kind = CHART_Dummy + 0x06;
/// The series the `CHART_Add`, `CHART_Clear` and `CHART_ColourRGB` after
/// it in the list go to (0). Set.
pub const CHART_Current = CHART_Dummy + 0x07;
/// i32: a value added to the current series. Set.
pub const CHART_Add = CHART_Dummy + 0x08;
/// Anything: the current series emptied. Set.
pub const CHART_Clear = CHART_Dummy + 0x09;
/// The current series' colour, 0xAARRGGBB. Made and set.
pub const CHART_ColourRGB = CHART_Dummy + 0x0A;
/// How many lines go across the scale, numbered (4; 0 for none). Made and
/// set.
pub const CHART_Lines = CHART_Dummy + 0x0B;
/// How many values the current series holds. Read only.
pub const CHART_Count = CHART_Dummy + 0x0C;

/// `CHART_Kind`.
pub const CHART_LINES: u32 = 0;
pub const CHART_BARS: u32 = 1;

/// The most series a chart holds.
pub const CHART_MAX_SERIES = 4;

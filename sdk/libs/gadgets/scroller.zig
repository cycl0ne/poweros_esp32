// SPDX-License-Identifier: MIT
//! scroller.gadget: a scroll bar for a view of `SCROLLER_Total` things of
//! which `SCROLLER_Visible` fit, the first shown being `SCROLLER_Top`.
//!
//! The knob is as big as the view is of the whole and sits where the view
//! is. Dragged, it moves the top with it; a press beside it pages, keeping
//! one thing of the old view in the new one. With `SCROLLER_Arrows` it has
//! two arrow buttons at its end, that many pixels long each: held, one
//! steps the top by one, and after a moment keeps stepping. The target
//! hears `SCROLLER_Top` with the gadget's `GA_ID` at every change - which
//! is what a view follows - and when a press ends, the window hears
//! `IDCMP_GADGETUP` with the top as the code.
//!
//! Across (`PGA_Freedom` `FREEHORIZ`, the default) or up and down
//! (`FREEVERT`).
//!
//!   const bar = ib.NewObjectTagList(null, sc.SCROLLER_CLASS, &.{
//!       .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
//!       .{ .tag = sc.SCROLLER_Total, .data = 200 },
//!       .{ .tag = sc.SCROLLER_Visible, .data = 20 },
//!       .{ .tag = sc.SCROLLER_Arrows, .data = 12 },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const SCROLLER_LIBRARY = "gadgets/scroller.gadget";
pub const SCROLLER_CLASS = "scroller.gadget";

pub const SCROLLER_Dummy = gadgets.GADGETS_Dummy + 6 * gadgets.GADGETS_Step;
/// The first thing shown. Made, set and read; told to the target as it
/// changes. Never past where the view would run off the end.
pub const SCROLLER_Top = SCROLLER_Dummy + 0x01;
/// How many things there are. Made and set.
pub const SCROLLER_Total = SCROLLER_Dummy + 0x02;
/// How many of them the view shows. Made and set.
pub const SCROLLER_Visible = SCROLLER_Dummy + 0x03;
/// How long each arrow button is, in pixels along the bar; none without
/// it. Made only.
pub const SCROLLER_Arrows = SCROLLER_Dummy + 0x04;

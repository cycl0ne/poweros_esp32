// SPDX-License-Identifier: MIT
//! clicktab.gadget: a row of tabs, one of them the one in front.
//!
//! Each of `CLICKTAB_Labels` is a tab across the top of the row. A press
//! on one, let go over it, makes it `CLICKTAB_Current`: its window hears
//! `IDCMP_GADGETUP` with its number as the code and its target hears
//! `CLICKTAB_Current` with the gadget's `GA_ID`. The key that works it -
//! its `GA_Key`, or the `_` in a layout's label for it - takes the next
//! tab, and the one before with Shift held. The labels themselves are
//! drawn as they are, `_` and all: the row is one gadget with one key,
//! not a key for every tab.
//!
//! Tabs that do not all fit in the row are shown from
//! `CLICKTAB_FirstShown` on, with two arrows at the right end that move
//! the row along one tab at a time.
//!
//! The tabs are cards standing on a line along the bottom of the row,
//! drawn in the style's look for a button, sharing the row's width; the
//! one in front opens into what is below it.
//!
//! A row of tabs over pages is a `page.gadget`'s `PAGE_Tabs`: the page
//! gadget holds the row along its top, frames the pages below it - the
//! row's line is the frame's top edge - and turns the page as a tab is
//! pressed, without the program hearing anything. The row works on its
//! own too, over anything a program changes when it hears the row's
//! `IDCMP_GADGETUP`, or through its `ICA_TARGET`.
//!
//!   const tabs = ib.NewObjectTagList(null, ct.CLICKTAB_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 1 },
//!       .{ .tag = ct.CLICKTAB_Labels, .data = @intFromPtr(&names) },
//!       .{},
//!   });
//!   const book = ib.NewObjectTagList(null, pg.PAGE_CLASS, &.{
//!       .{ .tag = pg.PAGE_Pages, .data = @intFromPtr(&pages) },
//!       .{ .tag = pg.PAGE_Tabs, .data = @intFromPtr(tabs) },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const CLICKTAB_LIBRARY = "gadgets/clicktab.gadget";
pub const CLICKTAB_CLASS = "clicktab.gadget";

pub const CLICKTAB_Dummy = gadgets.GADGETS_Dummy + 15 * gadgets.GADGETS_Step;
/// The tabs: an array of C strings ending in a null
/// (`[*:null]const ?[*:0]const u8`), not copied, which the program keeps
/// for as long as the gadget has it. Made and set.
pub const CLICKTAB_Labels = CLICKTAB_Dummy + 0x01;
/// The tab in front, counted from 0. Made, set and read.
pub const CLICKTAB_Current = CLICKTAB_Dummy + 0x02;
/// The leftmost tab shown, when they do not all fit. Made, set and read.
pub const CLICKTAB_FirstShown = CLICKTAB_Dummy + 0x03;
/// How many tabs there are. Read only.
pub const CLICKTAB_NumLabels = CLICKTAB_Dummy + 0x04;

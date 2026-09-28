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
//! A row of tabs is a `page.gadget` above what it shows: the page is the
//! tab row's `ICA_TARGET`, and `ICA_MAP` turns `CLICKTAB_Current` into
//! `PAGE_Current`, so a tab press changes the page without the program
//! hearing anything.
//!
//!   const map = [_]TagItem{ .{ .tag = ct.CLICKTAB_Current, .data = pg.PAGE_Current }, .{} };
//!   const tabs = ib.NewObjectTagList(null, ct.CLICKTAB_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 1 },
//!       .{ .tag = ct.CLICKTAB_Labels, .data = @intFromPtr(&names) },
//!       .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(pages) },
//!       .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&map) },
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

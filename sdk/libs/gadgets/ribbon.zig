// SPDX-License-Identifier: MIT
//! ribbon.gadget: a program's commands in tabs and named groups, across
//! the top of its window, as an office program has them.
//!
//! Along the top is a row of flat tabs, `RIBBON_Tabs`; below it the page
//! of the tab in front, its groups side by side, each with its name under
//! it and a line between it and the next. A group's entries are gadgets
//! of any class - tool buttons (`toolbutton.gadget`) above all, a chooser,
//! a number, a check box. A large tool button stands the whole height of
//! the page; everything else stands in columns of up to three, one above
//! the other, in the order given, each column as wide as its widest entry.
//! A medium tool button fills its column's width, so a column of them
//! lines up.
//!
//! The ribbon is as tall as its tallest page needs and never changes
//! height when the tab does, and as wide as its widest page.
//!
//! Every entry reports in its own name, as it would in a layout: a tool
//! button pressed reaches the window as `IDCMP_GADGETUP` with the
//! button's `GA_ID`, which is the command. A press on a tab turns the page
//! at once; the window hears `IDCMP_GADGETUP` with the ribbon's `GA_ID`
//! and the tab's number as the code, and the target `RIBBON_Current`.
//! The `_` in a tab's name marks the key that turns to it; the keys of
//! the entries work only on the page in front. The wheel over the row of
//! tabs turns the pages.
//!
//! The entries go with the ribbon: disposing of it disposes of every
//! entry of every tab, as a layout disposes of its children.
//!
//!   const clipboard = [_:null]?*Object{ paste, cut, copy };
//!   const font = [_:null]?*Object{ bold, italic, underline };
//!   const home = [_]rb.RibbonGroup{
//!       .{ .label = "Clipboard", .items = &clipboard },
//!       .{ .label = "Font", .items = &font },
//!       .{},
//!   };
//!   const tabs = [_]rb.RibbonTab{ .{ .label = "_Home", .groups = &home }, .{} };
//!   const ribbon = ib.NewObjectTagList(null, rb.RIBBON_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = ID_RIBBON },
//!       .{ .tag = rb.RIBBON_Tabs, .data = @intFromPtr(&tabs) },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");
const classes = @import("../intuition/classes.zig");
const Object = classes.Object;

/// What a program opens, and the class it then asks for.
pub const RIBBON_LIBRARY = "gadgets/ribbon.gadget";
pub const RIBBON_CLASS = "ribbon.gadget";

pub const RIBBON_Dummy = gadgets.GADGETS_Dummy + 34 * gadgets.GADGETS_Step;
/// `[*]const RibbonTab`: the tabs, ending in one whose `label` is null.
/// Not copied: the program keeps the tabs and groups for as long as the
/// ribbon has them. The entries in them are the ribbon's from when it is
/// made, and go with it. Made only.
pub const RIBBON_Tabs = RIBBON_Dummy + 0x01;
/// The tab in front, counted from 0. Made, set and read; told to the
/// target, with the gadget's `GA_ID`, when a press, a key or the wheel
/// turns it.
pub const RIBBON_Current = RIBBON_Dummy + 0x02;
/// How many tabs there are. Read only.
pub const RIBBON_NumTabs = RIBBON_Dummy + 0x03;

/// A group of entries on a tab's page.
pub const RibbonGroup = extern struct {
    /// Its name, under its entries.
    label: ?[*:0]const u8 = null,
    /// Its entries: gadgets, ending in a null.
    items: ?[*]const ?*Object = null,
};

/// A tab and its page.
pub const RibbonTab = extern struct {
    /// Its name in the row, its `_` marking the key that turns to it;
    /// null ends the tabs.
    label: ?[*:0]const u8 = null,
    /// Its page's groups, ending in one whose `label` is null.
    groups: ?[*]const RibbonGroup = null,
};

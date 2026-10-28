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
//! **Narrower than that, groups are made smaller**, one step at a time:
//! large tool buttons become medium ones, then every tool button small,
//! and last a group is folded into one large button with its name and
//! picture (`RibbonGroup.image`), whose press drops the whole group down
//! under it, as it would stand, in a popup over the window. A step that
//! saves nothing is passed over. Groups with a higher `reduce` go first;
//! among equal ones, from the right. A group folded and still too wide is
//! not shown, nor any after it.
//!
//! A group with a `launcher` has a small button at the right of its name,
//! the corner of a box with an arrow out of it, for the dialog with more
//! of the same: it reports in the launcher's number as a tool button does.
//!
//! **Minimized** (`RIBBON_Minimized`) the ribbon is its row of tabs alone.
//! A press on a tab then drops that tab's page down over the window, as a
//! popup that goes once a command of it is used or the pointer is pressed
//! anywhere else. The mark at the right end of the row minimizes the
//! ribbon and brings it back, and so does a double-click on a tab while
//! it is not minimized; either way the window hears `IDCMP_GADGETUP` with
//! the ribbon's `GA_ID` and the code `RBCODE_MINIMIZED`, and the target
//! `RIBBON_Minimized`. Its height has changed: a window object's program
//! sends `WM_RETHINK` then. `RIBBON_MinimizeBelow` minimizes it by itself
//! in a window lower than that.
//!
//! A contextual tab (`RibbonTab.contextual`) is not in the row until the
//! program shows it - while a table is picked, say - with `RIBBON_ShowTab`,
//! and goes again with `RIBBON_HideTab`. A strip of its colour runs along
//! its top.
//!
//! **Tabs the row has no room for** are behind a » before the mark at its
//! end: a press on it drops down a list of their names, and the one taken
//! is turned to as a pressed tab is, with its number as the code. The tab
//! in front always stands in the row, the others from the left making
//! room for it. A contextual tab out of the row gives the » its strip.
//! Since 1.2; the ribbon is no narrower than its widest tab, the » and
//! the mark.
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
/// Bool: the row of tabs alone, a tab's page dropped down over the window
/// when the tab is pressed. Made, set and read; told to the target, with
/// the gadget's `GA_ID`, when the mark at the row's end or a double-click
/// changes it. The ribbon's height changes with it.
pub const RIBBON_Minimized = RIBBON_Dummy + 0x04;
/// The height of the window's room under which the ribbon is minimized by
/// itself, whatever `RIBBON_Minimized` says - one above what the window
/// needs with the ribbon whole, so that the window can be made that low.
/// 0, the default, for none. Made and set.
pub const RIBBON_MinimizeBelow = RIBBON_Dummy + 0x05;
/// The `id` of a contextual tab to show in the row, after the tabs before
/// it. Set only.
pub const RIBBON_ShowTab = RIBBON_Dummy + 0x06;
/// The `id` of a contextual tab to take out of the row again; when it was
/// in front, the first tab is. Set only.
pub const RIBBON_HideTab = RIBBON_Dummy + 0x07;
/// Bool: the row of tabs. Without it (false) the ribbon is the page of
/// the tab in front in a frame closed all round, and nothing turns it -
/// what a ribbon drops down as a folded group's or a minimized ribbon's
/// page. True by default. Made only.
pub const RIBBON_Row = RIBBON_Dummy + 0x08;
/// Bool: whether the entries are the ribbon's, to dispose of with it.
/// True by default; a ribbon that shows entries another ribbon has is
/// made with false. Made only.
pub const RIBBON_OwnsEntries = RIBBON_Dummy + 0x09;

/// The code the window hears from the ribbon when it was minimized or
/// brought back by the pointer; any other code is a tab's number.
pub const RBCODE_MINIMIZED: i32 = -1;

/// A group of entries on a tab's page.
pub const RibbonGroup = extern struct {
    /// Its name, under its entries.
    label: ?[*:0]const u8 = null,
    /// Its entries: gadgets, ending in a null.
    items: ?[*]const ?*Object = null,
    /// The `GA_ID` its launcher reports with - the command that opens the
    /// dialog with more of the same; 0 for none.
    launcher: u32 = 0,
    /// How early it is made smaller when the ribbon is too narrow: a
    /// group with a higher number before one with a lower.
    reduce: u32 = 0,
    /// The picture of the button it is folded into: an imageclass image,
    /// drawn as a tool button's. It stays the program's, which disposes
    /// of it after the ribbon. Without one, the button is its name.
    image: ?*Object = null,
};

/// A tab and its page.
pub const RibbonTab = extern struct {
    /// Its name in the row, its `_` marking the key that turns to it;
    /// null ends the tabs.
    label: ?[*:0]const u8 = null,
    /// Its page's groups, ending in one whose `label` is null.
    groups: ?[*]const RibbonGroup = null,
    /// What `RIBBON_ShowTab` and `RIBBON_HideTab` name it by.
    id: u32 = 0,
    /// Bool: a contextual tab, out of the row until it is shown.
    contextual: u32 = 0,
    /// The colour of a contextual tab's strip, as `0xAARRGGBB`; 0 for the
    /// ribbon's own.
    colour: u32 = 0,
};

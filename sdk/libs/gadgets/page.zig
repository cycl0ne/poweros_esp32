// SPDX-License-Identifier: MIT
//! page.gadget: several gadgets in one place, one of them shown.
//!
//! Every one of `PAGE_Pages` - a layout, as a rule - is given the whole
//! of the page gadget's box, and `PAGE_Current` says which of them is
//! drawn and worked. The gadget is as big as the largest page needs, so
//! that turning to another page never changes a window's size, and each
//! page is laid out when the gadget is, so that turning to one draws it
//! and nothing more.
//!
//! The pages go with the gadget: disposing of it disposes of them, as a
//! layout disposes of its children.
//!
//! Given a `clicktab.gadget` (`PAGE_Tabs`), the gadget holds the row of
//! tabs along its top and draws a frame round the pages below it, in the
//! style's look for a button; the tab in front opens into the frame. A
//! press on a tab turns the page, a page turned with `PAGE_Current` is
//! shown in the row, and the row's `IDCMP_GADGETUP` reaches the window
//! in the row's own name, as it does anywhere else.
//!
//!   const names = [_:null]?[*:0]const u8{ "General", "Network", "About" };
//!   const pages = [_:null]?*Object{ general, network, about };
//!   const tabs = ib.NewObjectTagList(null, ct.CLICKTAB_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = ID_TABS },
//!       .{ .tag = ct.CLICKTAB_Labels, .data = @intFromPtr(&names) },
//!       .{},
//!   });
//!   const book = ib.NewObjectTagList(null, pg.PAGE_CLASS, &.{
//!       .{ .tag = pg.PAGE_Pages, .data = @intFromPtr(&pages) },
//!       .{ .tag = pg.PAGE_Tabs, .data = @intFromPtr(tabs) },
//!       .{},
//!   });
//!
//! Without one it is the pages alone, with no frame, set from any gadget
//! (`ICA_TARGET`, `ICA_MAP`) or by hand.

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const PAGE_LIBRARY = "gadgets/page.gadget";
pub const PAGE_CLASS = "page.gadget";

pub const PAGE_Dummy = gadgets.GADGETS_Dummy + 16 * gadgets.GADGETS_Step;
/// The pages: an array of objects ending in a null
/// (`[*:null]const ?*Object`), not copied, which the program keeps for as
/// long as the gadget has it. The objects are disposed of with the page
/// gadget. Made and set.
pub const PAGE_Pages = PAGE_Dummy + 0x01;
/// The page shown, counted from 0. Made, set and read.
pub const PAGE_Current = PAGE_Dummy + 0x02;
/// How many pages there are. Read only.
pub const PAGE_NumPages = PAGE_Dummy + 0x03;
/// A `clicktab.gadget` (`*Object`) to stand along the top, its tabs the
/// pages', with a frame round the pages below it. The page gadget points
/// the row's `ICA_TARGET` at itself, keeps the row's `CLICKTAB_Current`
/// the page shown, and disposes of the row with itself. Made only.
pub const PAGE_Tabs = PAGE_Dummy + 0x04;

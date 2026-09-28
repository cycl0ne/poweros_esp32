// SPDX-License-Identifier: MIT
//! chooser.gadget: a button that pops up a list to pick from.
//!
//! It shows one of `CHOOSER_Labels` and a mark at its right end. A press
//! opens a panel under it - over it when there is more room there -
//! listing the labels, with the one it shows already picked out. Dragging
//! over the panel moves the pick, letting go takes it; letting go on the
//! button itself leaves the panel up, so that a press on a line takes it
//! instead. A press anywhere else closes the panel and takes nothing.
//! A list longer than the screen has room for scrolls while the pointer
//! is held past the panel's top or bottom.
//!
//! The panel is a layer over the screen, as a menu's is: what it covers
//! comes back when it closes, and a program drawing into a window under
//! it draws around it.
//!
//! Its window hears `IDCMP_GADGETUP` with the number of the label taken as
//! the code, and its target hears `CHOOSER_Active` with the gadget's
//! `GA_ID`. The key that works it - `_` in a layout's label - takes the
//! next label without opening the panel, and the one before with Shift
//! held, as a cycle gadget does.
//!
//! A program opens `gadgets/chooser.gadget`, which opens layers.library
//! for the panel.
//!
//!   const keymaps = [_:null]?[*:0]const u8{ "deutsch", "usa", "usa2" };
//!   const which = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 1 },
//!       .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&keymaps) },
//!       .{ .tag = ch.CHOOSER_Active, .data = 0 },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const CHOOSER_LIBRARY = "gadgets/chooser.gadget";
pub const CHOOSER_CLASS = "chooser.gadget";

pub const CHOOSER_Dummy = gadgets.GADGETS_Dummy + 14 * gadgets.GADGETS_Step;
/// The labels: an array of C strings ending in a null
/// (`[*:null]const ?[*:0]const u8`), not copied, which the program keeps
/// for as long as the gadget has it. Made and set; setting it holds the
/// number shown inside the new list.
pub const CHOOSER_Labels = CHOOSER_Dummy + 0x01;
/// Which label is shown, counted from 0. Made, set and read; told to the
/// target when a pick changes it, and the code of the window's
/// `IDCMP_GADGETUP`.
pub const CHOOSER_Active = CHOOSER_Dummy + 0x02;
/// How many labels the panel shows at once at the most (all of them
/// unless given). A longer list scrolls while the pointer is held past
/// the panel's end. Made and set.
pub const CHOOSER_MaxPanelLines = CHOOSER_Dummy + 0x03;
/// How many labels there are. Read only.
pub const CHOOSER_NumLabels = CHOOSER_Dummy + 0x04;

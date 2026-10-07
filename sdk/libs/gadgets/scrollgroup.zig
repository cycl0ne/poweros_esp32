// SPDX-License-Identifier: MIT
//! scrollgroup.gadget: a gadget larger than the room it has, seen through
//! that room and moved under it by scrollers.
//!
//! `SCROLLGROUP_Contents` - a layout, as a rule - is laid out at the size
//! it asks for, or the room's when that is larger, and the scroll group
//! shows the part of it that fits: with a scroller down its right where the
//! contents are taller than the room, and one along its bottom where they
//! are wider. Nothing of the contents is drawn outside that view - a
//! gadget half in it is drawn half - and the pointer, the keys and the
//! wheel reach only what shows. The wheel over a part of the contents that
//! takes no wheel itself moves the view, three lines a notch.
//!
//! Put in a window's layout, it asks for the contents' size, so a window
//! that has the room shows everything and no scroller; on a screen too
//! small for that, the window is as large as the screen allows and the
//! rest is scrolled to.
//!
//! **Scrollers in the window's border** instead of its own: made with
//! `SCROLLGROUP_Scrollers` false, the scroll group is the view alone, and
//! tells its target where its view is - `SCROLLGROUP_Top` and
//! `SCROLLGROUP_Left`, the contents' `SCROLLGROUP_TotalHeight` and
//! `SCROLLGROUP_TotalWidth`, the view's `SCROLLGROUP_VisibleHeight` and
//! `SCROLLGROUP_VisibleWidth`, all in pixels - each time one of them
//! changes. A scroller in the border whose `ICA_TARGET` is the scroll
//! group and whose `ICA_MAP` turns `SCROLLER_Top` into `SCROLLGROUP_Top`
//! (or `SCROLLGROUP_Left`) moves the view as it is dragged; the program
//! sets the scroller's total, visible and top from what it is told.
//!
//! The contents go with it: disposing of the scroll group disposes of
//! them, as a layout disposes of its children.
//!
//!   const form = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &.{
//!       .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
//!       // ... rows that need more room than a small screen has
//!       .{},
//!   });
//!   const view = ib.NewObjectTagList(null, sg.SCROLLGROUP_CLASS, &.{
//!       .{ .tag = sg.SCROLLGROUP_Contents, .data = @intFromPtr(form) },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const SCROLLGROUP_LIBRARY = "gadgets/scrollgroup.gadget";
pub const SCROLLGROUP_CLASS = "scrollgroup.gadget";

pub const SCROLLGROUP_Dummy = gadgets.GADGETS_Dummy + 30 * gadgets.GADGETS_Step;
/// The gadget that is looked at - a layout, as a rule. Made only; it is
/// disposed of with the scroll group.
pub const SCROLLGROUP_Contents = SCROLLGROUP_Dummy + 0x01;
/// How far down the contents the view starts, in pixels. Made, set and
/// read; held between 0 and the contents' height less the view's.
pub const SCROLLGROUP_Top = SCROLLGROUP_Dummy + 0x02;
/// How far across, in the same way.
pub const SCROLLGROUP_Left = SCROLLGROUP_Dummy + 0x03;
/// Bool, made only: its own scrollers, at its right and along its bottom
/// as they are needed. True unless said otherwise; false for a program
/// that puts scrollers in the window's border and joins them to the view.
pub const SCROLLGROUP_Scrollers = SCROLLGROUP_Dummy + 0x04;
/// How large the contents are laid out, and how much of them the view
/// shows, in pixels. Read only; told to the target, with the top and the
/// left, when any of them changes.
pub const SCROLLGROUP_TotalWidth = SCROLLGROUP_Dummy + 0x05;
pub const SCROLLGROUP_TotalHeight = SCROLLGROUP_Dummy + 0x06;
pub const SCROLLGROUP_VisibleWidth = SCROLLGROUP_Dummy + 0x07;
pub const SCROLLGROUP_VisibleHeight = SCROLLGROUP_Dummy + 0x08;

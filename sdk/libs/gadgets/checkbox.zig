// SPDX-License-Identifier: MIT
//! checkbox.gadget: a box that is ticked or not. A press turns it over;
//! let go over the box, its window hears `IDCMP_GADGETUP` with the new
//! state, 1 or 0, as the code, and its target `CHECKBOX_Checked`.
//!
//! The box is sized to the font; a layout that gives the gadget more room
//! keeps the box its size, at the left and in the middle of the height.
//! `CHECKBOX_Scaled` makes it fill the room instead, which is what a
//! touch screen wants: a box a line of text high is smaller than a
//! fingertip.
//! It has no label of its own: a layout's `CHILDA_Label` places one.
//!
//!   const lib = sys.OpenLibrary(cb.CHECKBOX_LIBRARY, 0) orelse return;
//!   defer sys.CloseLibrary(lib);
//!   const box = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 1 },
//!       .{ .tag = cb.CHECKBOX_Checked, .data = 1 },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const CHECKBOX_LIBRARY = "gadgets/checkbox.gadget";
pub const CHECKBOX_CLASS = "checkbox.gadget";

pub const CHECKBOX_Dummy = gadgets.GADGETS_Dummy + 0 * gadgets.GADGETS_Step;
/// Bool: ticked. Made, set and read; told to the target when a press
/// changes it.
pub const CHECKBOX_Checked = CHECKBOX_Dummy + 0x01;
/// Bool, made only: the box is as big as the room a layout gives it,
/// rather than a line of the font. It stays the shape it is, so a box in
/// a wide gadget is as tall as the gadget and no wider than it.
pub const CHECKBOX_Scaled = CHECKBOX_Dummy + 0x02;

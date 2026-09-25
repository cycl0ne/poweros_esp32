// SPDX-License-Identifier: MIT
//! palette.gadget: a grid of colour boxes, of which one is picked.
//!
//! A pen here is a whole colour, not a number in a screen's table, so the
//! gadget shows a table of colours - `PALETTE_ColorTable`, or without one
//! the screen's own pens (its DrawInfo's) - and what is picked is a box's
//! number in that table, from 0. The colour itself is `PALETTE_Pen`.
//!
//! The boxes are laid out in the rows and columns that make them most
//! nearly square in the gadget's box. A press picks the box under the
//! pointer, and the pick follows the pointer while the button is held;
//! let go, the window hears `IDCMP_GADGETUP` with the box's number as the
//! code, and the target `PALETTE_Color`. The right button while choosing
//! puts the old pick back and ends it, saying nothing.
//!
//!   const colours = [_]graphics.Pen{ red, green, blue, yellow };
//!   const pick = ib.NewObjectTagList(null, pa.PALETTE_CLASS, &.{
//!       .{ .tag = pa.PALETTE_ColorTable, .data = @intFromPtr(&colours) },
//!       .{ .tag = pa.PALETTE_NumColors, .data = colours.len },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const PALETTE_LIBRARY = "gadgets/palette.gadget";
pub const PALETTE_CLASS = "palette.gadget";

pub const PALETTE_Dummy = gadgets.GADGETS_Dummy + 8 * gadgets.GADGETS_Step;
/// The colours shown: a `[*]const graphics.Pen`, not copied. The screen's
/// pens without it. Made and set.
pub const PALETTE_ColorTable = PALETTE_Dummy + 0x01;
/// How many colours the table has. Made and set; all of the screen's pens
/// without a table.
pub const PALETTE_NumColors = PALETTE_Dummy + 0x02;
/// The picked box's number in the table. Made, set and read; told to the
/// target when a press changes it.
pub const PALETTE_Color = PALETTE_Dummy + 0x03;
/// Read only: the picked colour from the table, a `graphics.Pen`. The
/// screen's pens are the screen's to say, so without a table there is
/// nothing to read here.
pub const PALETTE_Pen = PALETTE_Dummy + 0x04;

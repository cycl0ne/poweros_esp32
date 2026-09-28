// SPDX-License-Identifier: MIT
//! integer.gadget: a number to type, held in a range, with arrows that
//! step it.
//!
//! It is a `string.gadget` number field with two arrow buttons at its
//! right end: the field takes digits and a sign and nothing else, the up
//! arrow adds `INTEGER_Step` and the down arrow takes it away, and a
//! number outside `INTEGER_Min` to `INTEGER_Max` is brought back to the
//! nearer end as soon as the field is done with. An arrow held down
//! steps again while it is held.
//!
//! Its window hears `IDCMP_GADGETUP` with the number as the code, and its
//! target hears `INTEGER_Number` with the gadget's `GA_ID` whenever the
//! number changes. `STRINGA_` attributes go to the field, so
//! `STRINGA_MaxChars` and `STRINGA_Justification` are its own.
//!
//! A program opens `gadgets/integer.gadget`, which opens
//! `gadgets/string.gadget` for the field it makes.
//!
//!   const port = ib.NewObjectTagList(null, ig.INTEGER_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 1 },
//!       .{ .tag = ig.INTEGER_Min, .data = 1 },
//!       .{ .tag = ig.INTEGER_Max, .data = 65535 },
//!       .{ .tag = ig.INTEGER_Number, .data = 23 },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const INTEGER_LIBRARY = "gadgets/integer.gadget";
pub const INTEGER_CLASS = "integer.gadget";

pub const INTEGER_Dummy = gadgets.GADGETS_Dummy + 13 * gadgets.GADGETS_Step;
/// The number. Made, set and read; told to the target when it changes,
/// and the code of the window's `IDCMP_GADGETUP`.
pub const INTEGER_Number = INTEGER_Dummy + 0x01;
/// The smallest and largest it may be (0 and 2147483647 unless given).
/// Made, set and read; a number outside them is brought to the nearer
/// end.
pub const INTEGER_Min = INTEGER_Dummy + 0x02;
pub const INTEGER_Max = INTEGER_Dummy + 0x03;
/// How much an arrow moves the number (1 unless given). Made and set.
pub const INTEGER_Step = INTEGER_Dummy + 0x04;
/// Bool, made only: the arrows at the right end (true unless given).
/// Without them the gadget is a number field and nothing more.
pub const INTEGER_Arrows = INTEGER_Dummy + 0x05;

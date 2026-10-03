// SPDX-License-Identifier: MIT
//! barcode.gadget: a text as a barcode, its text beneath.
//!
//! `BARCODE_Text` is written as `BARCODE_Type`: Code 128 - any printable
//! ASCII up to 80 characters, written compactly when it is an even run of
//! digits - or EAN-13, 12 digits to which it adds the check digit or 13
//! with the right one. The bars are a whole number of pixels a module, as
//! wide as the box allows with the quiet zones either side, in the
//! style's text colour on its background; the text, or for EAN-13 its 13
//! digits, is written under them unless `BARCODE_ShowText` is off. A text
//! the type cannot write shows nothing. It is never pressed.
//!
//!   const label = ib.NewObjectTagList(null, bc.BARCODE_CLASS, &.{
//!       .{ .tag = bc.BARCODE_Type, .data = bc.BARCODE_EAN13 },
//!       .{ .tag = bc.BARCODE_Text, .data = @intFromPtr("400638133393") },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const BARCODE_LIBRARY = "gadgets/barcode.gadget";
pub const BARCODE_CLASS = "barcode.gadget";

pub const BARCODE_Dummy = gadgets.GADGETS_Dummy + 26 * gadgets.GADGETS_Step;
/// The text, NUL-terminated, copied. Made and set.
pub const BARCODE_Text = BARCODE_Dummy + 0x01;
/// `BARCODE_CODE128` or `BARCODE_EAN13` (`BARCODE_CODE128`). Made and set;
/// set before `BARCODE_Text` in the same list.
pub const BARCODE_Type = BARCODE_Dummy + 0x02;
/// Bool: the text is written under the bars (true). Made and set.
pub const BARCODE_ShowText = BARCODE_Dummy + 0x03;
/// Bool: the text could be written as the type. Read only.
pub const BARCODE_Valid = BARCODE_Dummy + 0x04;

/// `BARCODE_Type`.
pub const BARCODE_CODE128: u32 = 0;
pub const BARCODE_EAN13: u32 = 1;

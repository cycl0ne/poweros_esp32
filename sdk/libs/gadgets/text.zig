// SPDX-License-Identifier: MIT
//! text.gadget: a line that shows a text or a number and cannot be
//! pressed. A status line, or the value beside a slider, that draws
//! itself whenever its window is drawn and at once when it is set.
//!
//! It shows `TEXT_Text`, or `TEXT_Number` written through `TEXT_Format`,
//! whichever was given last, in `TEXT_FrontPen` on `TEXT_BackPen`, against
//! the left, the right or in the middle (`TEXT_Justification`), in a sunk
//! frame with `TEXT_Border`. It is a line of the font high, and as wide as
//! its text unless it is given a width.
//!
//!   const status = ib.NewObjectTagList(null, tx.TEXT_CLASS, &.{
//!       .{ .tag = tx.TEXT_Number, .data = 42 },
//!       .{ .tag = tx.TEXT_Format, .data = @intFromPtr("%ld files") },
//!       .{ .tag = tx.TEXT_Border, .data = 1 },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const TEXT_LIBRARY = "gadgets/text.gadget";
pub const TEXT_CLASS = "text.gadget";

pub const TEXT_Dummy = gadgets.GADGETS_Dummy + 4 * gadgets.GADGETS_Step;
/// The text: a C string. Made, set and read. Not copied unless
/// `TEXT_CopyText` is true, when the gadget keeps a copy of its own.
pub const TEXT_Text = TEXT_Dummy + 0x01;
/// Bool, made only: `TEXT_Text` is copied, so the caller's may change or
/// go.
pub const TEXT_CopyText = TEXT_Dummy + 0x02;
/// A whole number, shown through `TEXT_Format`. Made, set and read.
pub const TEXT_Number = TEXT_Dummy + 0x03;
/// The RawDoFmt format the number is written through: one number, `%ld`
/// or `%d`, and any words round it. `%ld` unless given. Not copied.
pub const TEXT_Format = TEXT_Dummy + 0x04;
/// Bool: a sunk frame round it.
pub const TEXT_Border = TEXT_Dummy + 0x05;
/// `TEXT_JUSTIFY_*`: where the text sits in the box.
pub const TEXT_Justification = TEXT_Dummy + 0x06;
/// Bool: text too wide for the box is cut at its edge. Otherwise it is
/// drawn whole, past the edge.
pub const TEXT_Clipped = TEXT_Dummy + 0x07;
/// The text's colour and the ground's (`graphics.Pen`, whole colours).
/// The screen's text pen and background pen unless given.
pub const TEXT_FrontPen = TEXT_Dummy + 0x08;
pub const TEXT_BackPen = TEXT_Dummy + 0x09;
/// The font the text is drawn in (`*graphics.TextFont`), which the caller
/// keeps open for as long as the gadget has it; null for the window's.
/// Made and set; the gadget is as tall as a line of it.
pub const TEXT_Font = TEXT_Dummy + 0x0A;

pub const TEXT_JUSTIFY_LEFT: u32 = 0;
pub const TEXT_JUSTIFY_RIGHT: u32 = 1;
pub const TEXT_JUSTIFY_CENTER: u32 = 2;

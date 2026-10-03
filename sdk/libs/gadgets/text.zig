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
//! **Rich text.** Given `TEXT_Runs`, it shows runs of text each in its own
//! font, soft style and colour, one after another; with `TEXT_Markup`,
//! `TEXT_Text` is read as a small markup and turned into runs:
//!
//! - `<b>`, `<i>`, `<u>`: bold, italic, underlined
//! - `<c=#RRGGBB>`: in that colour
//! - `<s=N>`: in the gadget's font at N rows tall
//! - `</>` (or `</b>` and the like): the last of those ends
//! - `<br>`: a new line; `<<`: a `<`
//!
//! With `TEXT_Wrap` the runs are broken at spaces into lines as wide as
//! the gadget, each as tall as its tallest run, their baselines lined up;
//! the gadget is as tall as its lines when it is made. Without, they make
//! one line.
//!
//!   const help = ib.NewObjectTagList(null, tx.TEXT_CLASS, &.{
//!       .{ .tag = tx.TEXT_Text, .data = @intFromPtr("Press <b>OK</b> to go on, <c=#C03030>Cancel</c> to stop.") },
//!       .{ .tag = tx.TEXT_Markup, .data = 1 },
//!       .{ .tag = tx.TEXT_Wrap, .data = 1 },
//!       .{ .tag = gc.GA_Width, .data = 160 },
//!       .{},
//!   });
//!
//!   const status = ib.NewObjectTagList(null, tx.TEXT_CLASS, &.{
//!       .{ .tag = tx.TEXT_Number, .data = 42 },
//!       .{ .tag = tx.TEXT_Format, .data = @intFromPtr("%ld files") },
//!       .{ .tag = tx.TEXT_Border, .data = 1 },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");
const graphics = @import("../graphics/graphics.zig");

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
/// `[*]const TextRun`: runs of text shown in place of the text, ended by a
/// run whose text is null. Not copied: the caller keeps them, and the
/// fonts they name, for as long as the gadget has them. Made and set.
pub const TEXT_Runs = TEXT_Dummy + 0x0B;
/// Bool: `TEXT_Text` is markup, turned into runs when it is set (false).
/// Made only; give it before the text.
pub const TEXT_Markup = TEXT_Dummy + 0x0C;
/// Bool: runs are broken into lines as wide as the gadget (false). Made
/// and set.
pub const TEXT_Wrap = TEXT_Dummy + 0x0D;

/// A run of text in one look.
pub const TextRun = extern struct {
    /// The text; null ends the runs. A `\n` in it starts a new line.
    text: ?[*:0]const u8 = null,
    /// The font, or null for the gadget's.
    font: ?*graphics.TextFont = null,
    /// Soft styles, `graphics.FSF_BOLD` and the rest.
    style: u32 = 0,
    /// The colour, 0xAARRGGBB, or 0 for the front pen.
    colour: graphics.Pen = 0,
};

pub const TEXT_JUSTIFY_LEFT: u32 = 0;
pub const TEXT_JUSTIFY_RIGHT: u32 = 1;
pub const TEXT_JUSTIFY_CENTER: u32 = 2;

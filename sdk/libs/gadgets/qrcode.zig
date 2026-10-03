// SPDX-License-Identifier: MIT
//! qrcode.gadget: a text as a QR code.
//!
//! `QR_Text` is encoded in byte mode at `QR_Level`'s error correction, as
//! the smallest version (1 to 40) that holds it, when it is set; the code
//! is kept, so the text need not be. It is drawn as square modules - a
//! whole number of pixels each, as big as the box allows - with a quiet
//! zone four modules wide round it, centred in the box: the dark modules
//! in the style's text colour, the rest in its background. A text too long
//! for any version at the level shows nothing, and `QR_Version` reads 0.
//! It is never pressed.
//!
//!   const code = ib.NewObjectTagList(null, qc.QR_CLASS, &.{
//!       .{ .tag = qc.QR_Text, .data = @intFromPtr("https://example.org") },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const QR_LIBRARY = "gadgets/qrcode.gadget";
pub const QR_CLASS = "qrcode.gadget";

pub const QR_Dummy = gadgets.GADGETS_Dummy + 25 * gadgets.GADGETS_Step;
/// The text, NUL-terminated, encoded when it is set and not kept. Made and
/// set.
pub const QR_Text = QR_Dummy + 0x01;
/// The error correction, a `QR_LEVEL_` (`QR_LEVEL_M`). Made and set; set
/// before `QR_Text` in the same list, or the text is encoded again.
pub const QR_Level = QR_Dummy + 0x02;
/// The version the text was encoded as, 1 to 40; 0 for none. Read only.
pub const QR_Version = QR_Dummy + 0x03;

/// `QR_Level`: how much of the code may be lost and the text still read -
/// about 7, 15, 25 and 30 percent.
pub const QR_LEVEL_L: u32 = 0;
pub const QR_LEVEL_M: u32 = 1;
pub const QR_LEVEL_Q: u32 = 2;
pub const QR_LEVEL_H: u32 = 3;

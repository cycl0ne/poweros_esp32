// SPDX-License-Identifier: MIT
//! getfont.gadget: a font, named or asked for.
//!
//! A field with a button beside it. The field is a `string.gadget` and
//! shows the font's name and size; the button opens asl.library's font
//! requester, and what is picked goes into the field. A program reads
//! `GETFONT_TextAttr`, which is what `OpenFont` and `OpenDiskFont` take.
//!
//! The requester is opened on a process of its own, because the press
//! that asks for it arrives on the input handler, which may neither draw
//! nor wait. A program hears the answer through the gadget's
//! `ICA_TARGET`, so an `ICTARGET_IDCMP` gadget tells its window.
//!
//!   const field = ib.NewObjectTagList(null, gfo.GETFONT_CLASS, &.{
//!       .{ .tag = gfo.GETFONT_TitleText, .data = @intFromPtr("Which font?") },
//!       .{ .tag = gfo.GETFONT_Name, .data = @intFromPtr("pospaz.font") },
//!       .{ .tag = gfo.GETFONT_Size, .data = 8 },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const GETFONT_LIBRARY = "gadgets/getfont.gadget";
pub const GETFONT_CLASS = "getfont.gadget";

pub const GETFONT_Dummy = gadgets.GADGETS_Dummy + 18 * gadgets.GADGETS_Step;

/// What the requester is called. Made and set.
pub const GETFONT_TitleText = GETFONT_Dummy + 0x01;
/// Bool: the field cannot be typed in, only the button used.
pub const GETFONT_ReadOnly = GETFONT_Dummy + 0x02;
/// The font's name, copied. Made, set and read.
pub const GETFONT_Name = GETFONT_Dummy + 0x03;
/// How many rows tall it is. Made, set and read.
pub const GETFONT_Size = GETFONT_Dummy + 0x04;
/// `graphics.FSF_`: the styles asked of it. Made, set and read.
pub const GETFONT_Style = GETFONT_Dummy + 0x05;
/// The three together as a `*graphics.TextAttr`, which is what
/// `OpenFont` takes. Read only, and only good until the gadget changes.
pub const GETFONT_TextAttr = GETFONT_Dummy + 0x06;

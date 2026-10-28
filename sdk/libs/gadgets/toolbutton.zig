// SPDX-License-Identifier: MIT
//! toolbutton.gadget: a button with a picture and a label, as a tool bar
//! or a ribbon has them. A press and a let go over it is a command: its
//! window hears `IDCMP_GADGETUP`. A toggle stays down while it is on -
//! bold, italic, wrap - and its window hears the new state, 1 or 0, as
//! the code.
//!
//! It comes in three sizes (`TOOLBUTTON_Size`): large, the picture twice
//! the small one with the label under it on up to two lines; medium, the
//! small picture with the label beside it; small, the picture alone, its
//! label said only by its hint. The small picture is as tall as a line of
//! the font and never under 16 pixels, so the sizes follow the screen's
//! font. A button with no picture is its label in every size; one whose
//! label changes - a time, a count - keeps room for `TOOLBUTTON_RoomFor`'s
//! text, so it never grows.
//!
//! The picture is any imageclass image (`TOOLBUTTON_Image`), drawn to the
//! size with `IM_DRAWFRAME` - a drawn one, as a docklet or a command image
//! is, is sharp at every size - or an icon's (`TOOLBUTTON_IconName`),
//! made smaller to the size by icon.library.
//!
//! It is drawn as a part of its own, `imageclass.PART_TOOL`: under the
//! system's default flat at rest; under the pointer, pressed and on, a
//! one-pixel edge with round corners round a light ground blended from
//! the screen's pens, so a coloured picture keeps its colours. A style
//! may give it a border at rest - which a touch screen, with no pointer
//! to hover, may want.
//!
//!   const lib = sys.OpenLibrary(tb.TOOLBUTTON_LIBRARY, 0) orelse return;
//!   defer sys.CloseLibrary(lib);
//!   const bold = ib.NewObjectTagList(null, tb.TOOLBUTTON_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 3 },
//!       .{ .tag = gc.GA_Text, .data = @intFromPtr("_Bold") },
//!       .{ .tag = tb.TOOLBUTTON_Image, .data = @intFromPtr(bold_image) },
//!       .{ .tag = tb.TOOLBUTTON_Size, .data = tb.TBSIZE_SMALL },
//!       .{ .tag = tb.TOOLBUTTON_Kind, .data = tb.TBKIND_TOGGLE },
//!       .{ .tag = tb.TOOLBUTTON_Hint, .data = @intFromPtr("Make the text bold") },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const TOOLBUTTON_LIBRARY = "gadgets/toolbutton.gadget";
pub const TOOLBUTTON_CLASS = "toolbutton.gadget";

pub const TOOLBUTTON_Dummy = gadgets.GADGETS_Dummy + 33 * gadgets.GADGETS_Step;
/// `TBSIZE_`: how big it is. Made and set; `TBSIZE_MEDIUM` without.
pub const TOOLBUTTON_Size = TOOLBUTTON_Dummy + 0x01;
/// `*Object`: the picture, an imageclass image, drawn to the picture's
/// size with `IM_DRAWFRAME`. It stays the program's, which disposes of it
/// after the button. Made, set and read.
pub const TOOLBUTTON_Image = TOOLBUTTON_Dummy + 0x02;
/// `[*:0]const u8`: the picture of this icon instead - the file's name
/// without `.info` - when there is no `TOOLBUTTON_Image`. Read when it is
/// made; the icon is kept until the button goes. Made only.
pub const TOOLBUTTON_IconName = TOOLBUTTON_Dummy + 0x03;
/// `TBKIND_`: whether it is a command or a toggle. Made only;
/// `TBKIND_PUSH` without.
pub const TOOLBUTTON_Kind = TOOLBUTTON_Dummy + 0x04;
/// `[*:0]const u8`: what it does, in a sentence, for the tip shown while
/// the pointer rests on it. Not copied. Read back without one, it is the
/// label. The button has `GA_GadgetHelp` set, so its window hears
/// `IDCMP_GADGETHELP` for it once `HelpControl` turns help on. Made, set
/// and read.
pub const TOOLBUTTON_Hint = TOOLBUTTON_Dummy + 0x05;
/// Bool: a toggle that is on - the gadget's `GA_Selected`. Made, set and
/// read; told to the target, with the gadget's `GA_ID`, when a press or
/// its key turns it.
pub const TOOLBUTTON_Checked = TOOLBUTTON_Dummy + 0x06;
/// A C string: the label is given at least the room this text takes in
/// the button's font - `"-00:00"` for a time - so a label that changes
/// keeps the room the widest of them needs. Only where the label is shown.
/// Not copied. Made and set.
pub const TOOLBUTTON_RoomFor = TOOLBUTTON_Dummy + 0x07;

/// `TOOLBUTTON_Size`.
pub const TBSIZE_LARGE: u32 = 0;
pub const TBSIZE_MEDIUM: u32 = 1;
pub const TBSIZE_SMALL: u32 = 2;

/// `TOOLBUTTON_Kind`.
pub const TBKIND_PUSH: u32 = 0;
pub const TBKIND_TOGGLE: u32 = 1;

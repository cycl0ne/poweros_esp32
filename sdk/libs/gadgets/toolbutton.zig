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
//! to hover, may want. Disabled (`GA_Disabled`), its picture is drawn
//! disabled - in grey, faded into the ground - and its label in the
//! part's disabled text pen, which fades it as far; since 1.3, before
//! which a ghost was laid over the whole button.
//!
//! Two kinds drop a list down (`TOOLBUTTON_Labels`), with a mark - a
//! triangle pointing down - after the label. A drop-down button is the
//! list's way in and nothing else: a press opens it, and the label taken
//! is the command, its number the code. A split button is a command of
//! its own as well: the part with the mark opens the list, a large one's
//! label with it, and the rest is the command, its code `TBCODE_MAIN`.
//! The list is a panel over the screen, as a chooser's is. Without labels
//! the button drops down what its target puts up - a popup requester of
//! the target's own, as a ribbon's folded group has (`TOOLBUTTON_Dropped`).
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
/// Among a `GM_DOMAIN`'s `attrs`, the size to answer for instead of its
/// own - what a ribbon asks as it makes its groups smaller.
pub const TOOLBUTTON_Size = TOOLBUTTON_Dummy + 0x01;
/// `*Object`: the picture, an imageclass image, drawn to the picture's
/// size with `IM_DRAWFRAME`. It stays the program's, which disposes of it
/// after the button. Made, set and read.
pub const TOOLBUTTON_Image = TOOLBUTTON_Dummy + 0x02;
/// `[*:0]const u8`: the picture of this icon instead - the file's name
/// without `.info` - when there is no `TOOLBUTTON_Image`. Read when it is
/// made; the icon is kept until the button goes. Made only.
pub const TOOLBUTTON_IconName = TOOLBUTTON_Dummy + 0x03;
/// `TBKIND_`: a command, a toggle, a drop-down or a split button. Made
/// only; `TBKIND_PUSH` without.
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
/// The list a drop-down or a split button drops down: an array of C
/// strings ending in a null (`[*:null]const ?[*:0]const u8`), not copied,
/// which the program keeps for as long as the button has it. The label
/// taken is the window's code. Made and set.
pub const TOOLBUTTON_Labels = TOOLBUTTON_Dummy + 0x08;
/// Bool: a drop-down or a split button without labels has dropped down
/// what its target puts up. A press on the part with the mark sets it and
/// tells the target, with the gadget's `GA_ID` and while the press is
/// handled, so that the target can put a popup requester up from there;
/// the window hears nothing of that press. The button is drawn pressed
/// until the target sets it back to 0 - when its popup comes down. Set
/// and read.
pub const TOOLBUTTON_Dropped = TOOLBUTTON_Dummy + 0x09;

/// `TOOLBUTTON_Size`.
pub const TBSIZE_LARGE: u32 = 0;
pub const TBSIZE_MEDIUM: u32 = 1;
pub const TBSIZE_SMALL: u32 = 2;

/// `TOOLBUTTON_Kind`.
pub const TBKIND_PUSH: u32 = 0;
pub const TBKIND_TOGGLE: u32 = 1;
/// A press drops the list down; the label taken is the command.
pub const TBKIND_DROPDOWN: u32 = 2;
/// A command, with a part that drops the list down.
pub const TBKIND_SPLIT: u32 = 3;

/// The code a split button's window hears when the button's own command
/// was used, not a label of its list.
pub const TBCODE_MAIN: i32 = -1;

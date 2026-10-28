// SPDX-License-Identifier: MIT
//! command.image: the pictures of the commands a program's tool bar or
//! ribbon has - new, open, save, cut, paste, bold, sort - drawn and not
//! painted, so each is sharp at every size, from a menu's 16 pixels to a
//! large button's 48.
//!
//! Which picture an image is, is `COMMAND_Glyph`. It is drawn in colour,
//! in the palette of `gadgets.shapes`: a floppy disk blue, a folder
//! yellow, scissors with red handles, each shape with a darker rim, shaded
//! from light at the top, with a gloss and a soft shadow. Under 20 pixels
//! there is no shading, gloss or shadow, only the colours and their rims.
//! What stands on the ground - a letter, the lines of an alignment - is
//! the screen's text pen, so it reads on a light screen and on a dark one.
//! Drawn in a disabled state (`IDS_DISABLED`, `IDS_INACTIVEDISABLED`,
//! `IDS_SELECTEDDISABLED`), every colour is its grey, faded into the
//! screen's background.
//!
//! `IM_DRAWFRAME` draws the picture in the largest square that fits the
//! box, in its middle; `IM_DRAW` in the image's own box, 24 by 24 unless
//! `IA_Width` and `IA_Height` say otherwise. Both draw over what is there
//! and change nothing round the picture.
//!
//!   const cut = ib.NewObjectTagList(null, command.COMMAND_CLASS, &.{
//!       .{ .tag = command.COMMAND_Glyph, .data = command.CMD_CUT },
//!       .{},
//!   }) orelse return;
//!   defer ib.DisposeObject(cut);
//!   const button = ib.NewObjectTagList(null, tb.TOOLBUTTON_CLASS, &.{
//!       .{ .tag = gc.GA_Text, .data = @intFromPtr("Cu_t") },
//!       .{ .tag = tb.TOOLBUTTON_Image, .data = @intFromPtr(cut) },
//!       .{},
//!   });

const images = @import("images.zig");

/// What a program opens, and the class it then asks for.
pub const COMMAND_LIBRARY = "images/command.image";
pub const COMMAND_CLASS = "command.image";

pub const COMMAND_Dummy = images.IMAGES_Dummy + 0 * images.IMAGES_Step;
/// `CMD_`: which picture. Made, set and read; `CMD_NONE`, which draws
/// nothing, without. A number past the last is none.
pub const COMMAND_Glyph = COMMAND_Dummy + 0x01;

/// `COMMAND_Glyph`.
pub const CMD_NONE: u32 = 0;
/// A sheet of paper with a green plus.
pub const CMD_NEW: u32 = 1;
/// A yellow folder, open, a sheet in it.
pub const CMD_OPEN: u32 = 2;
/// A blue floppy disk.
pub const CMD_SAVE: u32 = 3;
/// A printer, a sheet going in and one coming out.
pub const CMD_PRINT: u32 = 4;
/// Scissors, open, with red handles.
pub const CMD_CUT: u32 = 5;
/// Two sheets, one over the other.
pub const CMD_COPY: u32 = 6;
/// A clipboard with a sheet on it.
pub const CMD_PASTE: u32 = 7;
/// A blue arrow turning back to the left.
pub const CMD_UNDO: u32 = 8;
/// The same turning on to the right.
pub const CMD_REDO: u32 = 9;
/// A magnifying glass.
pub const CMD_FIND: u32 = 10;
/// The letters of text's style, in the text pen: a bold B.
pub const CMD_BOLD: u32 = 11;
/// A slanting I.
pub const CMD_ITALIC: u32 = 12;
/// A U over a red line.
pub const CMD_UNDERLINE: u32 = 13;
/// Lines of text, in the text pen, flush left.
pub const CMD_ALIGN_LEFT: u32 = 14;
/// Centred.
pub const CMD_ALIGN_CENTRE: u32 = 15;
/// Flush right.
pub const CMD_ALIGN_RIGHT: u32 = 16;
/// Lines of text, the middle one an orange arrow turning down to the next.
pub const CMD_WRAP: u32 = 17;
/// A green sigma.
pub const CMD_SUM: u32 = 18;
/// Lines from short to long, and a violet arrow down.
pub const CMD_SORT: u32 = 19;
/// A table, a row picked out in green and a green plus.
pub const CMD_INSERT_ROW: u32 = 20;
/// The same in red with a red cross.
pub const CMD_DELETE_ROW: u32 = 21;
/// A cog with a teal hub.
pub const CMD_SETTINGS: u32 = 22;
/// The magnifying glass with a plus in it.
pub const CMD_ZOOM_IN: u32 = 23;
/// With a minus.
pub const CMD_ZOOM_OUT: u32 = 24;
/// A table, a column picked out in green and a green plus.
pub const CMD_INSERT_COLUMN: u32 = 25;
/// The same in red with a red cross.
pub const CMD_DELETE_COLUMN: u32 = 26;
/// The corner of a box and an arrow pointing out of it, down and right:
/// more of the same in a dialog of its own - what a ribbon group's name
/// line has at its end. In the ink, as a mark on the ground is.
pub const CMD_LAUNCHER: u32 = 27;
/// The last picture there is.
pub const CMD_LAST: u32 = CMD_LAUNCHER;

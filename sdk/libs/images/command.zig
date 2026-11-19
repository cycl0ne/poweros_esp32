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
//! screen's background. Since 1.3 there are the pictures a spreadsheet's
//! ribbon has besides: a number's format, a percent, money, a decimal
//! more and fewer, fill and clear. Since 1.4 a text editor's: line
//! numbers, highlighting, replace and select all. Since 1.6 a file
//! manager's: the parent, a new drawer, rename, delete, information,
//! update, the views (icons, a list, by date, by size), all files, clean
//! up, snap to the grid, snapshot, back and forward, and a shell. Since
//! 1.8 icons laid out again as their window is sized. Since 1.9 a paint
//! program's tools: a pencil, a brush, a line, a curve, a rectangle, an
//! ellipse, a polygon, a fill, an airbrush, a dropper, text, a brush cut
//! out, shapes filled, layers and a stencil. Since 1.10 what is round a
//! paint program's picture: a hand that moves it, a frame it fits, two
//! colours swapped, and a section folded and unfolded. Since 1.11 an
//! eraser and a smudging finger.
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
/// A blue `#`: a number's format. Since 1.3.
pub const CMD_NUMBER: u32 = 28;
/// An orange `%`. Since 1.3.
pub const CMD_PERCENT: u32 = 29;
/// A green banknote and a gold coin on it: money. Since 1.3.
pub const CMD_CURRENCY: u32 = 30;
/// `.0` in the ink and a green plus: a decimal more. Since 1.3.
pub const CMD_DECIMALS_MORE: u32 = 31;
/// `.0` and a red minus: a decimal fewer. Since 1.3.
pub const CMD_DECIMALS_LESS: u32 = 32;
/// A column of cells, the top one blue, and an orange arrow down: the
/// first copied over the rest. Since 1.3.
pub const CMD_FILL: u32 = 33;
/// An eraser, red with a white sleeve, on a line in the ink. Since 1.3.
pub const CMD_CLEAR: u32 = 34;
/// Lines of text in the ink beside a blue margin with a white mark for
/// each line's number. Since 1.4.
pub const CMD_LINE_NUMBERS: u32 = 35;
/// Lines of text whose words are of many colours: text highlighted as a
/// language's. Since 1.4.
pub const CMD_HIGHLIGHT: u32 = 36;
/// A red block, an orange arrow turning down from it, and a green block
/// where it points: one thing put in another's place. Since 1.4.
pub const CMD_REPLACE: u32 = 37;
/// Lines of text, picked out in light blue, inside a frame of blue
/// dashes: all of it selected. Since 1.4.
pub const CMD_SELECT_ALL: u32 = 38;
/// A closed yellow folder and a blue arrow up out of it: the drawer one
/// level up. Since 1.6.
pub const CMD_PARENT: u32 = 39;
/// A closed yellow folder and a green plus. Since 1.6.
pub const CMD_NEW_DRAWER: u32 = 40;
/// A name's field, its text dark, and a blue text cursor after it.
/// Since 1.6.
pub const CMD_RENAME: u32 = 41;
/// A bin, its lid and the lid's handle, ribbed. Since 1.6.
pub const CMD_DELETE: u32 = 42;
/// A blue disc with a white `i`. Since 1.6.
pub const CMD_INFORMATION: u32 = 43;
/// Two green arrows chasing each other round, clockwise: shown anew.
/// Since 1.6.
pub const CMD_UPDATE: u32 = 44;
/// Four icons, each a tile with its name in the ink under it: things
/// viewed as icons. Since 1.6.
pub const CMD_VIEW_ICONS: u32 = 45;
/// Three rows, each a small tile and a name in the ink beside it: things
/// viewed as a list. Since 1.6.
pub const CMD_VIEW_LIST: u32 = 46;
/// A calendar's page, its top red with the rings it hangs from: things
/// ordered by date. Since 1.6.
pub const CMD_VIEW_DATE: u32 = 47;
/// Three blue bars, low to high, standing on one line: things ordered
/// by size. Since 1.6.
pub const CMD_VIEW_SIZE: u32 = 48;
/// A sheet of paper and an eye before it: every file shown, an icon of
/// its own or not. Since 1.6.
pub const CMD_ALL_FILES: u32 = 49;
/// A broom, its handle brown and its bristles yellow: things put in
/// order. Since 1.6.
pub const CMD_CLEAN_UP: u32 = 50;
/// A red magnet over a grid of dots in the ink: things put on the grid.
/// Since 1.6.
pub const CMD_SNAP_GRID: u32 = 51;
/// A camera, its lens blue: where things are, kept. Since 1.6.
pub const CMD_SNAPSHOT: u32 = 52;
/// A blue arrow pointing left: back to where one was. Since 1.6.
pub const CMD_BACK: u32 = 53;
/// The same pointing right: on again. Since 1.6.
pub const CMD_FORWARD: u32 = 54;
/// A console: a dark window, a green prompt and the cursor after it.
/// Since 1.6.
pub const CMD_SHELL: u32 = 55;
/// A window with its icons in rows, and the arrow out of its corner that
/// sizes it: icons laid out again as the window is sized. Since 1.8.
pub const CMD_ARRANGE: u32 = 56;
/// A yellow pencil, its point down to the left, and a wave in the ink
/// beside it: drawn by hand, in one line. Since 1.9.
pub const CMD_PENCIL: u32 = 57;
/// A paint brush, its tip blue, and three blue dots beside it: drawn by
/// hand, the brush put down as it goes. Since 1.9.
pub const CMD_BRUSH: u32 = 58;
/// A straight line in the ink, a blue handle at each end. Since 1.9.
pub const CMD_LINE: u32 = 59;
/// A line bending one way and back, in the ink, a blue handle at each
/// end. Since 1.9.
pub const CMD_CURVE: u32 = 60;
/// A rectangle's outline in blue. Since 1.9.
pub const CMD_RECTANGLE: u32 = 61;
/// An ellipse's outline in blue. Since 1.9.
pub const CMD_ELLIPSE: u32 = 62;
/// The outline of a five-cornered shape in blue, a dot at each corner.
/// Since 1.9.
pub const CMD_POLYGON: u32 = 63;
/// A bucket tipped over, blue paint running out of it into a pool: an
/// area filled. Since 1.9.
pub const CMD_FLOOD_FILL: u32 = 64;
/// A red spray can, blue dots coming out of it. Since 1.9.
pub const CMD_AIRBRUSH: u32 = 65;
/// A dropper, its bulb red and blue in its glass: a colour picked up
/// from the picture. Since 1.9.
pub const CMD_PICK_COLOUR: u32 = 66;
/// An A in the ink and a blue text cursor: text put into the picture.
/// Since 1.9.
pub const CMD_TEXT: u32 = 67;
/// A frame of blue dashes round a sun over a green hill: a part of the
/// picture taken as a brush. Since 1.9.
pub const CMD_GRAB_BRUSH: u32 = 68;
/// A blue square and an orange disc over it, both filled: shapes drawn
/// filled rather than as outlines. Since 1.9.
pub const CMD_FILLED: u32 = 69;
/// Three sheets lying one over another, blue, green and orange: layers.
/// Since 1.9.
pub const CMD_LAYERS: u32 = 70;
/// A metal plate with a star cut out of it, blue showing through: a
/// stencil. Since 1.9.
pub const CMD_STENCIL: u32 = 71;
/// An open hand, its fingers up and its thumb out: the view moved by
/// dragging. Since 1.10.
pub const CMD_HAND: u32 = 72;
/// A sheet in the four corners of a frame: the picture made to fit the
/// view. Since 1.10.
pub const CMD_ZOOM_FIT: u32 = 73;
/// Two arrows, one to the right above one to the left: two things
/// swapped. Since 1.10.
pub const CMD_SWAP: u32 = 74;
/// A triangle pointing right, in the ink: a section folded away, which a
/// press unfolds. Since 1.10.
pub const CMD_FOLDED: u32 = 75;
/// A triangle pointing down, in the ink: a section unfolded. Since 1.10.
pub const CMD_UNFOLDED: u32 = 76;
/// A block eraser in its sleeve, at a slant, over the bare line it
/// leaves: paint taken away. Since 1.11.
pub const CMD_ERASER: u32 = 77;
/// A finger pointing down at a smear of colour: colours dragged along.
/// Since 1.11.
pub const CMD_SMUDGE: u32 = 78;
/// The last picture there is.
pub const CMD_LAST: u32 = CMD_SMUDGE;

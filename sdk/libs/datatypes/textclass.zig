// SPDX-License-Identifier: MIT
//! text.datatype: what every piece of text is, whatever file it came out
//! of.
//!
//! A format's class - ascii, markdown - reads its file, builds the text
//! and the runs it is made of, and hands both over with `TDTM_SETTEXT`.
//! From then on the text is this class's: it breaks it into lines, lays
//! them out for the room it is given, draws them, scrolls them, lets a
//! part of them be marked with the pointer and puts what is marked on
//! the clipboard. A format class therefore holds no text of its own and
//! knows nothing about drawing.
//!
//! **Text is runs, not characters.** A run is a stretch of the text
//! drawn one way: a font, a style, a pen, and where it leads when it is
//! pressed. Plain text is a single run; a marked-up document is
//! several. Everything that differs between formats is in the runs, and
//! everything that does not is here.
//!
//! The scroll units are pixels both ways, because a line of a heading
//! is taller than a line of prose and a unit that is sometimes eight
//! rows and sometimes sixteen is no unit at all.

const graphics = @import("../graphics/graphics.zig");
const classusr = @import("../intuition/classusr.zig");
const datatypesclass = @import("datatypesclass.zig");

/// What a program opens, and the class it then asks for.
pub const TEXT_LIBRARY = "datatypes/text.datatype";
pub const TEXTDTCLASS = "text.datatype";

pub const TDTA_Dummy = datatypesclass.DTA_Dummy + 300;

/// The text itself (`[*]const u8`) and how long it is. Read only; it
/// belongs to the object.
pub const TDTA_Buffer = TDTA_Dummy + 1;
pub const TDTA_BufferLen = TDTA_Dummy + 2;
/// The runs it is made of (`[*]const Piece`), and how many. Read only.
pub const TDTA_Pieces = TDTA_Dummy + 3;
pub const TDTA_NumPieces = TDTA_Dummy + 4;
/// Bool: a line too long for the room is broken at a space rather than
/// run off the edge. True unless given.
pub const TDTA_WordWrap = TDTA_Dummy + 5;
/// What is marked, as offsets into the text; equal when nothing is.
/// Set, and read.
pub const TDTA_MarkStart = TDTA_Dummy + 6;
pub const TDTA_MarkEnd = TDTA_Dummy + 7;
/// How many lines the text came to once it was laid out. Read only.
pub const TDTA_NumLines = TDTA_Dummy + 8;
/// The link the pointer was last let go on (`[*:0]const u8`), which is
/// what a program follows. Read only, and only good until the next
/// press.
pub const TDTA_Link = TDTA_Dummy + 9;
/// How many pixels a run's indent step is. Made and set.
pub const TDTA_IndentWidth = TDTA_Dummy + 10;

/// One stretch of the text drawn one way.
pub const Piece = extern struct {
    /// Where in the text it starts, and how many bytes it is.
    offset: u32 = 0,
    length: u32 = 0,
    /// `TDFONT_`: which of the object's fonts it is drawn in.
    font: u8 = TDFONT_NORMAL,
    /// How many indent steps in from the left margin the line it starts
    /// is drawn. Read from the first run of a line and no other.
    indent: u8 = 0,
    /// `graphics.FSF_`: bold, italic, underlined.
    style: u16 = 0,
    /// `TDPEN_`, or a pen of its own.
    pen: u32 = TDPEN_TEXT,
    /// Where in the text a press on it leads, and how long that name
    /// is; `length` 0 for a run that is not a link.
    link_offset: u32 = 0,
    link_length: u32 = 0,
};

/// Which font a run is drawn in.
pub const TDFONT_NORMAL: u8 = 0;
/// The one every character of which is the same width: a listing.
pub const TDFONT_FIXED: u8 = 1;
/// A size up from the normal one, and two sizes up. A size the family
/// does not have is drawn bold in the normal one instead, so a document
/// reads the same whatever fonts the machine has.
pub const TDFONT_LARGE: u8 = 2;
pub const TDFONT_LARGER: u8 = 3;
/// How many there are, which is how many the object opens.
pub const TDFONT_COUNT: u8 = 4;

/// The screen's own pens, rather than a colour of the run's choosing.
pub const TDPEN_TEXT: u32 = 0xFFFF_FFFF;
pub const TDPEN_SHINE: u32 = 0xFFFF_FFFE;
pub const TDPEN_SHADOW: u32 = 0xFFFF_FFFD;
pub const TDPEN_FILL: u32 = 0xFFFF_FFFC;
pub const TDPEN_HIGHLIGHTTEXT: u32 = 0xFFFF_FFFB;

// --- the methods ------------------------------------------------------------

pub const TDTM_Dummy: classusr.MethodID = 0x710;
/// The text and its runs given to the object, which takes them over.
pub const TDTM_SETTEXT: classusr.MethodID = 0x711;

/// `TDTM_SETTEXT`: what a format's class hands over.
///
/// Both blocks must have come from `AllocVec`, because the object frees
/// them when it is disposed of or when it is given other text. A class
/// that fails after allocating them frees them itself; once the method
/// has answered they are the object's.
pub const TdtSetText = extern struct {
    method_id: classusr.MethodID = TDTM_SETTEXT,
    /// The text, and how many bytes of it there are.
    buffer: ?[*]u8 = null,
    buffer_len: u32 = 0,
    /// The runs, in the order they are read, and how many.
    pieces: ?[*]Piece = null,
    piece_count: u32 = 0,
    /// What the text is written in, or null for the screen's font.
    text_attr: ?*const graphics.TextAttr = null,
};

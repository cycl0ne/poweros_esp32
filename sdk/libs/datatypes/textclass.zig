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
//! **A document is blocks of runs** (since 2): a paragraph, a heading,
//! an item of a list, a listing, a rule, a cell of a table - each with
//! the space round it, its indent among the lists and quotes it is in,
//! and what is drawn beside it: an item's mark, a quote's bar, a
//! listing's ground, a table's lines. A format class says what each
//! block is; how far apart they stand and how they are drawn is this
//! class's, after the way GitHub shows Markdown. Text handed over
//! without blocks is one block of plain lines, as before.
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
    /// is drawn. Read from the first run of a line and no other, and only
    /// in text without blocks.
    indent: u8 = 0,
    /// `graphics.FSF_`: bold, italic, underlined; and `TDSTYLE_`.
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
/// One and a half times the normal one, and twice it. A size the family
/// does not have is made from the nearest it has.
pub const TDFONT_LARGE: u8 = 2;
pub const TDFONT_LARGER: u8 = 3;
/// A quarter bigger than the normal one, and an eighth smaller (since
/// 2).
pub const TDFONT_BIG: u8 = 4;
pub const TDFONT_SMALL: u8 = 5;
/// How many there are.
pub const TDFONT_COUNT: u8 = 6;

/// `Piece.style` beyond graphics' own: drawn on a ground of its own with
/// round corners, a little wider than its letters - code inside a line -
/// and struck through (since 2).
pub const TDSTYLE_CODE: u16 = 0x100;
pub const TDSTYLE_STRUCK: u16 = 0x200;

/// The screen's own pens, rather than a colour of the run's choosing.
/// On a document's page (text with blocks) they are the page's: text,
/// links and what is set back are its colours, not the screen's.
pub const TDPEN_TEXT: u32 = 0xFFFF_FFFF;
pub const TDPEN_SHINE: u32 = 0xFFFF_FFFE;
pub const TDPEN_SHADOW: u32 = 0xFFFF_FFFD;
pub const TDPEN_FILL: u32 = 0xFFFF_FFFC;
pub const TDPEN_HIGHLIGHTTEXT: u32 = 0xFFFF_FFFB;
/// Text set back - a quote, a picture's name - and a link (since 2).
pub const TDPEN_MUTED: u32 = 0xFFFF_FFFA;
pub const TDPEN_LINK: u32 = 0xFFFF_FFF9;

/// One block of a document: a stretch of its runs laid out together.
///
/// A block's text ends with the character that ends it in the text - a
/// newline, or a tab after a cell that is not the last of its row - which
/// is not drawn, and is what a copy of several blocks is separated by. A
/// newline inside a block ends a line of it.
pub const Block = extern struct {
    /// Its runs: the first, and how many.
    first: u32 = 0,
    count: u32 = 0,
    /// `TDBLOCK_`.
    kind: u8 = TDBLOCK_PARAGRAPH,
    /// A heading's level, 1 to 6.
    level: u8 = 0,
    /// How many lists and quotes it is inside, the outermost first, and
    /// which of them are quotes: bit n for the n-th.
    depth: u8 = 0,
    quotes: u8 = 0,
    /// `TDMARK_`: what stands in front of the first block of an item, at
    /// its depth; `TDMARK_NONE` for every other.
    mark: u8 = TDMARK_NONE,
    /// `TDBF_`.
    flags: u8 = 0,
    /// A cell's `TDALIGN_`.
    alignment: u8 = TDALIGN_LEFT,
    pad: u8 = 0,
    /// The number an item of a numbered list shows; a cell's column,
    /// from 0.
    number: u32 = 0,
};

/// What a block is.
pub const TDBLOCK_PARAGRAPH: u8 = 0;
/// Its runs' fonts say how big it is; levels 1 and 2 have a line under
/// them.
pub const TDBLOCK_HEADING: u8 = 1;
/// Lines as they stand, never wrapped, on a ground of their own.
pub const TDBLOCK_LISTING: u8 = 2;
/// A line across, and nothing else.
pub const TDBLOCK_RULE: u8 = 3;
/// A cell of a table. A table is cells one after another, a row at a
/// time; `TDBF_ROW` starts a row, and `TDBF_TABLE` the table.
pub const TDBLOCK_CELL: u8 = 4;

/// What stands in front of an item.
pub const TDMARK_NONE: u8 = 0;
pub const TDMARK_DISC: u8 = 1;
pub const TDMARK_CIRCLE: u8 = 2;
pub const TDMARK_SQUARE: u8 = 3;
/// `number`, then a full stop.
pub const TDMARK_NUMBER: u8 = 4;
/// `number` in small roman numerals and in small letters.
pub const TDMARK_ROMAN: u8 = 5;
pub const TDMARK_LETTER: u8 = 6;
/// A box, empty or ticked: an item of a list of tasks.
pub const TDMARK_TASK: u8 = 7;
pub const TDMARK_DONE: u8 = 8;

/// A block that is one of a list's items, or inside one, of a list
/// whose items stand apart: as far as paragraphs do, rather than close.
pub const TDBF_LOOSE: u8 = 1;
/// A cell that starts a row, and a cell that starts a table.
pub const TDBF_ROW: u8 = 2;
pub const TDBF_TABLE: u8 = 4;
/// A cell of the table's head.
pub const TDBF_HEAD: u8 = 8;
/// The first block of a list's first item: a list that is not inside
/// another one stands as far from what was before it as a paragraph.
pub const TDBF_START: u8 = 16;

/// Where a cell's lines stand in its column.
pub const TDALIGN_LEFT: u8 = 0;
pub const TDALIGN_CENTRE: u8 = 1;
pub const TDALIGN_RIGHT: u8 = 2;

// --- the methods ------------------------------------------------------------

pub const TDTM_Dummy: classusr.MethodID = 0x710;
/// The text and its runs given to the object, which takes them over.
pub const TDTM_SETTEXT: classusr.MethodID = 0x711;

/// `TDTM_SETTEXT`: what a format's class hands over.
///
/// The text, the runs and the blocks must have come from `AllocVec`,
/// because the object frees them when it is disposed of or when it is
/// given other text. A class that fails after allocating them frees them
/// itself; once the method has answered they are the object's.
pub const TdtSetText = extern struct {
    method_id: classusr.MethodID = TDTM_SETTEXT,
    /// The text, and how many bytes of it there are.
    buffer: ?[*]u8 = null,
    buffer_len: u32 = 0,
    /// The runs, in the order they are read, and how many.
    pieces: ?[*]Piece = null,
    piece_count: u32 = 0,
    /// What the text is written in, or null for the font of documents
    /// the system's settings name (`font.prefs`'s DOCUMENT and CODE).
    text_attr: ?*const graphics.TextAttr = null,
    /// Its blocks, in order, from `AllocVec` too, and how many; null for
    /// text that is plain lines (since 2).
    blocks: ?[*]Block = null,
    block_count: u32 = 0,
};

// SPDX-License-Identifier: MIT
//! What text.datatype keeps, and the fonts, the page's colours and the
//! measuring every other part of it uses.
//!
//! **A document's fonts are two families**: the one it is read in and
//! the one its listings are in - `font.prefs`'s DOCUMENT and CODE, read
//! as an object is made, or the system's DEFAULT and FIXED fonts where
//! the file names none. Each size a run asks for (`TDFONT_`) is opened
//! from its family through diskfont.library, so an outline renders at
//! any size and a size a family lacks is scaled from one it has.
//!
//! **Bold and italic are faces of their own where the family has them**,
//! found by name: `go-bold.font`, `go-italic.font` and
//! `go-bolditalic.font` beside `go.font`. A face the family lacks is the
//! nearest one it has, with graphics' soft styles drawing the rest - so
//! a document reads the same whatever fonts the machine has, and looks
//! as it was meant to where it has them.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const sc = sdk.intuition.screens;
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const tdc = datatypes.textclass;
const font_prefs = sdk.prefs.font;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const DosBase = sdk.interface.dos.DosBase;
const Base = gadgets.Base;
const TagItem = utility.TagItem;

/// Where the libraries the class opens are in `Base.opened`.
pub const opened_iffparse = 1;
pub const opened_diskfont = 2;
pub const opened_dos = 3;

/// One stretch of one laid-out line: where its text is, which run says
/// how to draw it, and where it sits along the line.
pub const Fragment = extern struct {
    piece: u32 = 0,
    offset: u32 = 0,
    length: u32 = 0,
    left: i32 = 0,
    width: i32 = 0,
    /// How far in from `left` its letters start: code inside a line has
    /// a ground a little wider than its letters.
    inset: i32 = 0,
};

/// One line of the text as it was laid out.
pub const Line = extern struct {
    /// Its fragments: the first, and how many.
    first: u32 = 0,
    count: u32 = 0,
    /// Where its top sits in the whole text, how tall it is and how far
    /// down it the letters stand.
    top: i32 = 0,
    height: i32 = 0,
    baseline: i32 = 0,
    /// Where it starts and ends across.
    left: i32 = 0,
    right: i32 = 0,
};

/// Something on the page that is not text: a ground, a line, a mark.
pub const Deco = extern struct {
    /// `DECO_`.
    kind: u8 = DECO_FILL,
    /// `INK_`: which of the page's colours.
    ink: u8 = INK_BORDER,
    pad: [2]u8 = @splat(0),
    /// Its box; for a round mark its centre and radius (`width`); for a
    /// number, where it ends across and its baseline.
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    /// A round ground's radius; an item's number.
    number: u32 = 0,
};

pub const DECO_FILL: u8 = 0;
pub const DECO_ROUND: u8 = 1;
pub const DECO_DISC: u8 = 2;
pub const DECO_CIRCLE: u8 = 3;
pub const DECO_SQUARE: u8 = 4;
pub const DECO_TASK: u8 = 5;
pub const DECO_DONE: u8 = 6;
pub const DECO_NUMBER: u8 = 7;
pub const DECO_ROMAN: u8 = 8;
pub const DECO_LETTER: u8 = 9;

/// The page's colours, by what they are for.
pub const INK_PAGE: u8 = 0;
pub const INK_TEXT: u8 = 1;
pub const INK_MUTED: u8 = 2;
pub const INK_BORDER: u8 = 3;
/// The lines between a table's rows and the one under a heading.
pub const INK_RULE: u8 = 4;
/// A listing's ground, and every other row of a table.
pub const INK_SUBTLE: u8 = 5;
/// The ground of code inside a line.
pub const INK_CODE: u8 = 6;
pub const INK_LINK: u8 = 7;
/// What is drawn on a link's colour: a ticked box's tick.
pub const INK_ON_LINK: u8 = 8;
pub const ink_count = 9;

/// The page as GitHub shows Markdown: light, or dark on a screen whose
/// ground is dark. Opaque, so that the engine fills with them.
const light = [ink_count]graphics.Pen{ 0xFFFFFFFF, 0xFF1F2328, 0xFF59636E, 0xFFD1D9E0, 0xFFDDE3E8, 0xFFF6F8FA, 0xFFEFF1F3, 0xFF0969DA, 0xFFFFFFFF };
const dark = [ink_count]graphics.Pen{ 0xFF0D1117, 0xFFF0F6FC, 0xFF9198A1, 0xFF3D444D, 0xFF2F353D, 0xFF151B23, 0xFF1F232A, 0xFF4493F8, 0xFF0D1117 };

/// The page's colours on a screen whose ground is `ground`.
pub fn paperFor(ground: graphics.Pen) [ink_count]graphics.Pen {
    const r = (ground >> 16) & 0xFF;
    const g = (ground >> 8) & 0xFF;
    const b = ground & 0xFF;
    // How bright, as the eye has it: green counts most, blue least.
    return if (r * 299 + g * 587 + b * 114 >= 128 * 1000) light else dark;
}

/// The faces a size is drawn in.
pub const FACE_REGULAR = 0;
pub const FACE_BOLD = 1;
pub const FACE_ITALIC = 2;
pub const FACE_BOTH = 3;
pub const face_count = 4;

/// The face a run's style asks for.
pub fn faceOf(style: u16) u8 {
    const bold = style & graphics.FSF_BOLD != 0;
    const italic = style & graphics.FSF_ITALIC != 0;
    return if (bold and italic) FACE_BOTH else if (bold) FACE_BOLD else if (italic) FACE_ITALIC else FACE_REGULAR;
}

/// text.datatype's part of an object.
pub const Data = extern struct {
    /// The text, the runs it is made of and the blocks they are in, all
    /// the object's.
    buffer: ?[*]u8 = null,
    buffer_len: u32 = 0,
    pieces: ?[*]tdc.Piece = null,
    piece_count: u32 = 0,
    blocks: ?[*]tdc.Block = null,
    block_count: u32 = 0,
    /// What it came to when it was laid out.
    lines: ?[*]Line = null,
    line_count: u32 = 0,
    line_room: u32 = 0,
    fragments: ?[*]Fragment = null,
    fragment_count: u32 = 0,
    fragment_room: u32 = 0,
    decos: ?[*]Deco = null,
    deco_count: u32 = 0,
    deco_room: u32 = 0,
    /// Each size a run may ask for, in each face, opened when a run asks
    /// for it; and the styles graphics draws over a face that stands in
    /// for one the family lacks.
    fonts: [tdc.TDFONT_COUNT][face_count]?*graphics.TextFont = @splat(@splat(null)),
    soft: [tdc.TDFONT_COUNT][face_count]u8 = @splat(@splat(0)),
    /// The two families, as asked for: the document's and its code's.
    document: graphics.TextAttr = .{ .name = graphics.POSPAZNAME, .y_size = 8 },
    code: graphics.TextAttr = .{ .name = graphics.POSPAZNAME, .y_size = 8 },
    document_name: [font_prefs.value_len:0]u8 = @splat(0),
    code_name: [font_prefs.value_len:0]u8 = @splat(0),
    /// A RastPort of no display, for measuring text before there is one
    /// to draw into.
    measure: ?*graphics.RastPort = null,
    /// How wide the widest line came out, and how wide the room was
    /// when it was laid out.
    widest: i32 = 0,
    laid_for: i32 = 0,
    /// How tall the whole text came out.
    total: i32 = 0,
    /// A line too long for the room is broken at a space.
    wrap: u8 = 1,
    /// A press is being dragged across the text.
    dragging: u8 = 0,
    pad: [2]u8 = @splat(0),
    /// How many pixels one step of a run's indent is.
    indent_width: i32 = 16,
    /// What is marked, as offsets into the text.
    mark_start: u32 = 0,
    mark_end: u32 = 0,
    /// Where the press that is being dragged started.
    mark_from: u32 = 0,
    /// The link the pointer was last let go on, as a string of its own.
    link: [128]u8 = @splat(0),
};

/// How many fragments, lines and decorations are made room for at a
/// time. A document grows by whole blocks so that laying it out is not
/// one allocation a line.
pub const grow_by = 64;

fn diskfontOf(base: *Base) ?*DiskfontBase {
    return @ptrCast(base.opened[opened_diskfont] orelse return null);
}

/// The two families taken: `given` for the document where a program
/// gave one, else `font.prefs`'s DOCUMENT; its CODE for listings; and
/// the system's DEFAULT and FIXED fonts where it names neither.
pub fn chooseFamilies(base: *Base, own: *Data, given: ?*const graphics.TextAttr) void {
    var line: font_prefs.Line = .{};
    if (base.opened[opened_dos]) |lib| {
        const dl: *DosBase = @ptrCast(lib);
        if (sdk.prefs.loadWhole(base.sys_base, dl, font_prefs.ENV_FILE)) |read| {
            defer base.sys_base.FreeVec(read.ptr);
            if (sdk.prefs.firstLine(read)) |words| {
                if (font_prefs.parse(base.utility_base, words, &line) != null) line = .{};
            }
        }
    }
    if (given) |attr| {
        own.document = copyAttr(attr.*, &own.document_name);
    } else if (!fromLine(&line, .document, &own.document, &own.document_name)) {
        own.document = systemAttr(base, sc.SYSFONT_DEFAULT, &own.document_name);
    }
    if (!fromLine(&line, .code, &own.code, &own.code_name)) {
        own.code = systemAttr(base, sc.SYSFONT_FIXED, &own.code_name);
    }
}

fn fromLine(line: *const font_prefs.Line, which: font_prefs.Which, attr: *graphics.TextAttr, name: *[font_prefs.value_len:0]u8) bool {
    const text = line.get(which) orelse return false;
    attr.* = font_prefs.attrOf(text, name) orelse return false;
    attr.name = name;
    return true;
}

/// A TextAttr whose name is a copy the object keeps.
fn copyAttr(attr: graphics.TextAttr, name: *[font_prefs.value_len:0]u8) graphics.TextAttr {
    var n: usize = 0;
    while (attr.name[n] != 0 and n < name.len) : (n += 1) name[n] = attr.name[n];
    name[n] = 0;
    var copied = attr;
    copied.name = name;
    copied.tags = null;
    return copied;
}

/// One of the system's fonts, as the TextAttr that asks for it.
fn systemAttr(base: *Base, which: u32, name: *[font_prefs.value_len:0]u8) graphics.TextAttr {
    const font = base.intuition_base.OpenSystemFont(which) orelse
        return copyAttr(.{ .name = graphics.POSPAZNAME, .y_size = 8 }, name);
    defer base.graphics_base.CloseFont(font);
    return copyAttr(.{
        .name = font.node.name orelse graphics.POSPAZNAME,
        .y_size = font.image.height,
    }, name);
}

/// How many rows a size is, from its family's.
fn sizeOf(rows: u16, which: u8) u16 {
    const r: u32 = rows;
    const sized: u32 = switch (which) {
        tdc.TDFONT_LARGE => r * 3 / 2,
        tdc.TDFONT_LARGER => r * 2,
        tdc.TDFONT_BIG => (r * 5 + 2) / 4,
        tdc.TDFONT_SMALL => (r * 7 + 4) / 8,
        else => r,
    };
    return @intCast(@max(@min(sized, 999), 1));
}

/// A face's family name: `go.font` with `-bold` before its `.font`.
fn faceName(family: [*:0]const u8, suffix: []const u8, into: *[font_prefs.value_len + 16:0]u8) [*:0]const u8 {
    var n: usize = 0;
    while (family[n] != 0) n += 1;
    const ending = ".font";
    var stem = n;
    if (n >= ending.len and same(family[n - ending.len .. n], ending)) stem = n - ending.len;
    if (stem + suffix.len + ending.len >= into.len) return family;
    @memcpy(into[0..stem], family[0..stem]);
    @memcpy(into[stem..][0..suffix.len], suffix);
    @memcpy(into[stem + suffix.len ..][0..ending.len], ending);
    into[stem + suffix.len + ending.len] = 0;
    return into;
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x | 0x20 != y | 0x20) return false;
    }
    return true;
}

/// One face of a family at a size, from the disk; null where the family
/// has no such face.
fn openFace(base: *Base, attr: graphics.TextAttr, rows: u16, suffix: []const u8) ?*graphics.TextFont {
    var name: [font_prefs.value_len + 16:0]u8 = undefined;
    var ask = attr;
    ask.y_size = rows;
    ask.style = graphics.FS_NORMAL;
    ask.tags = null;
    ask.name = if (suffix.len == 0) attr.name else faceName(attr.name, suffix, &name);
    if (suffix.len != 0 and ask.name == attr.name) return null;
    if (diskfontOf(base)) |dfb| return dfb.OpenDiskFont(&ask);
    return base.graphics_base.OpenFont(&ask);
}

/// A size in a face opened, if it is not yet: the face of its own where
/// the family has one, else the nearest it has, with the soft styles for
/// the rest.
pub fn openSize(base: *Base, own: *Data, which: u8, face: u8) void {
    const slot = @min(which, tdc.TDFONT_COUNT - 1);
    if (own.fonts[slot][face] != null) return;
    const family = if (slot == tdc.TDFONT_FIXED) own.code else own.document;
    const rows = sizeOf(family.y_size, slot);
    const Try = struct { suffix: []const u8, soft: u8 };
    const bold: u8 = @intCast(graphics.FSF_BOLD);
    const italic: u8 = @intCast(graphics.FSF_ITALIC);
    const tries: []const Try = switch (face) {
        FACE_BOLD => &.{ .{ .suffix = "-bold", .soft = 0 }, .{ .suffix = "", .soft = bold } },
        FACE_ITALIC => &.{ .{ .suffix = "-italic", .soft = 0 }, .{ .suffix = "", .soft = italic } },
        FACE_BOTH => &.{
            .{ .suffix = "-bolditalic", .soft = 0 },
            .{ .suffix = "-bold", .soft = italic },
            .{ .suffix = "-italic", .soft = bold },
            .{ .suffix = "", .soft = bold | italic },
        },
        else => &.{.{ .suffix = "", .soft = 0 }},
    };
    for (tries) |t| {
        if (openFace(base, family, rows, t.suffix)) |font| {
            own.fonts[slot][face] = font;
            own.soft[slot][face] = t.soft;
            return;
        }
    }
    // A family that cannot be had at all: the ROM's own.
    own.fonts[slot][face] = base.graphics_base.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = if (rows >= 12) 16 else 8 });
    own.soft[slot][face] = switch (face) {
        FACE_BOLD => bold,
        FACE_ITALIC => italic,
        FACE_BOTH => bold | italic,
        else => 0,
    };
}

/// Every size and face the runs ask for opened, and the two every
/// document needs: the normal one and the fixed one.
pub fn openFonts(base: *Base, own: *Data) void {
    openSize(base, own, tdc.TDFONT_NORMAL, FACE_REGULAR);
    openSize(base, own, tdc.TDFONT_FIXED, FACE_REGULAR);
    const pieces = own.pieces orelse return;
    for (pieces[0..own.piece_count]) |*piece| openSize(base, own, piece.font, faceOf(piece.style));
}

/// The fonts given back.
pub fn closeFonts(base: *Base, own: *Data) void {
    const gb = base.graphics_base;
    for (&own.fonts) |*faces| {
        for (faces) |*font| {
            gb.CloseFont(font.*);
            font.* = null;
        }
    }
}

/// What a run is drawn in: the font, and the styles graphics draws over
/// it.
pub const Wear = struct { font: ?*graphics.TextFont, style: u16 };

pub fn wearOf(own: *const Data, piece: *const tdc.Piece) Wear {
    const slot = @min(piece.font, tdc.TDFONT_COUNT - 1);
    const face = faceOf(piece.style);
    if (own.fonts[slot][face]) |font| {
        return .{ .font = font, .style = (piece.style & graphics.FSF_UNDERLINED) | own.soft[slot][face] };
    }
    // Not opened: the regular face of the size, or the normal one, with
    // every style soft.
    const font = own.fonts[slot][FACE_REGULAR] orelse own.fonts[tdc.TDFONT_NORMAL][FACE_REGULAR];
    return .{ .font = font, .style = piece.style & 0xFF };
}

/// The font a size is drawn in, regular.
pub fn fontOf(own: *const Data, which: u8) ?*graphics.TextFont {
    const slot = @min(which, tdc.TDFONT_COUNT - 1);
    return own.fonts[slot][FACE_REGULAR] orelse own.fonts[tdc.TDFONT_NORMAL][FACE_REGULAR];
}

/// A RastPort made ready to measure or draw a run in: its font and its
/// style.
pub fn wearPiece(gb: *GraphicsBase, own: *const Data, rp: *graphics.RastPort, piece: *const tdc.Piece) void {
    const wear = wearOf(own, piece);
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(wear.font) },
        .{ .tag = graphics.RPTAG_TextStyle, .data = wear.style },
        .{},
    };
    gb.SetRPAttrs(rp, &tags);
}

/// How wide a stretch of a run is, in the font that run is drawn in.
pub fn widthOf(base: *Base, own: *const Data, piece: *const tdc.Piece, from: u32, length: u32) i32 {
    if (length == 0) return 0;
    const rp = own.measure orelse return 0;
    const buffer = own.buffer orelse return 0;
    wearPiece(base.graphics_base, own, rp, piece);
    return base.graphics_base.TextLength(rp, buffer + from, length);
}

/// How tall a run's font is, and how far down it the letters stand.
pub const Height = struct { height: i32, baseline: i32 };

pub fn heightOf(own: *const Data, piece: *const tdc.Piece) Height {
    const font = wearOf(own, piece).font orelse return .{ .height = 8, .baseline = 6 };
    return .{ .height = font.image.height, .baseline = font.image.baseline };
}

/// The normal font's height: what every space on the page is measured
/// in.
pub fn rowsOf(own: *const Data) i32 {
    const font = fontOf(own, tdc.TDFONT_NORMAL) orelse return 8;
    return @max(font.image.height, 4);
}

/// The text, the runs, the blocks and everything made from them given
/// back.
pub fn freeText(base: *Base, own: *Data) void {
    const sys = base.sys_base;
    if (own.buffer) |it| sys.FreeVec(it);
    if (own.pieces) |it| sys.FreeVec(it);
    if (own.blocks) |it| sys.FreeVec(it);
    if (own.lines) |it| sys.FreeVec(it);
    if (own.fragments) |it| sys.FreeVec(it);
    if (own.decos) |it| sys.FreeVec(it);
    own.buffer = null;
    own.pieces = null;
    own.blocks = null;
    own.lines = null;
    own.fragments = null;
    own.decos = null;
    own.buffer_len = 0;
    own.piece_count = 0;
    own.block_count = 0;
    own.line_count = 0;
    own.line_room = 0;
    own.fragment_count = 0;
    own.fragment_room = 0;
    own.deco_count = 0;
    own.deco_room = 0;
}

/// Room for one more of something that grows in blocks. False when
/// there is no memory for it.
pub fn makeRoom(base: *Base, comptime T: type, at: *?[*]T, room: *u32, wanted: u32) bool {
    if (wanted <= room.*) return true;
    const sys = base.sys_base;
    const bigger = @max(wanted, room.* + grow_by, room.* * 2);
    const memory = sys.AllocVec(bigger * @sizeOf(T), exec.MEMF_ANY) orelse return false;
    const into: [*]T = @ptrCast(@alignCast(memory));
    if (at.*) |old| {
        @memcpy(into[0..room.*], old[0..room.*]);
        sys.FreeVec(old);
    }
    at.* = into;
    room.* = bigger;
    return true;
}

// SPDX-License-Identifier: MIT
//! What text.datatype keeps, and the fonts and measuring every other
//! part of it uses.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const tdc = datatypes.textclass;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const Base = gadgets.Base;
const TagItem = utility.TagItem;

/// One stretch of one laid-out line: where its text is, which run says
/// how to draw it, and where it sits along the line.
pub const Fragment = extern struct {
    piece: u32 = 0,
    offset: u32 = 0,
    length: u32 = 0,
    left: i32 = 0,
    width: i32 = 0,
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
    width: i32 = 0,
};

/// text.datatype's part of an object.
pub const Data = extern struct {
    /// The text and the runs it is made of, both the object's.
    buffer: ?[*]u8 = null,
    buffer_len: u32 = 0,
    pieces: ?[*]tdc.Piece = null,
    piece_count: u32 = 0,
    /// What it came to when it was laid out.
    lines: ?[*]Line = null,
    line_count: u32 = 0,
    line_room: u32 = 0,
    fragments: ?[*]Fragment = null,
    fragment_count: u32 = 0,
    fragment_room: u32 = 0,
    /// The fonts the runs name, opened once.
    fonts: [tdc.TDFONT_COUNT]?*graphics.TextFont = @splat(null),
    /// A RastPort of no display, for measuring text before there is one
    /// to draw into.
    measure: ?*graphics.RastPort = null,
    /// How wide the widest line came out, and how wide the room was
    /// when it was laid out.
    widest: i32 = 0,
    laid_for: i32 = 0,
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

/// How many fragments and lines are made room for at a time. A document
/// grows by whole blocks so that laying it out is not one allocation a
/// line.
pub const grow_by = 64;

/// The font a run is drawn in, the normal one when that font could not
/// be opened.
pub fn fontOf(own: *const Data, which: u8) ?*graphics.TextFont {
    if (which < own.fonts.len) {
        if (own.fonts[which]) |font| return font;
    }
    return own.fonts[tdc.TDFONT_NORMAL];
}

/// A RastPort made ready to measure or draw a run in: its font and its
/// style.
pub fn wearPiece(gb: *GraphicsBase, own: *const Data, rp: *graphics.RastPort, piece: *const tdc.Piece) void {
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(fontOf(own, piece.font)) },
        .{ .tag = graphics.RPTAG_TextStyle, .data = piece.style },
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
pub fn heightOf(base: *Base, own: *const Data, piece: *const tdc.Piece) struct { height: i32, baseline: i32 } {
    const rp = own.measure orelse return .{ .height = 8, .baseline = 6 };
    wearPiece(base.graphics_base, own, rp, piece);
    var height: u32 = 0;
    var baseline: u32 = 0;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{},
    };
    base.graphics_base.GetRPAttrs(rp, &ask);
    return .{ .height = @intCast(height), .baseline = @intCast(baseline) };
}

/// The four fonts a document may ask for, opened from the one it names.
///
/// A size the family does not have comes back as the normal font, and
/// the run is drawn bold instead, so a document reads the same whatever
/// fonts the machine has. The fixed one is the family's own when it has
/// no widths of its own, and the system's otherwise.
pub fn openFonts(base: *Base, own: *Data, wanted: ?*const graphics.TextAttr) void {
    const gb = base.graphics_base;
    var attr = graphics.TextAttr{ .name = graphics.POSPAZNAME, .y_size = 8 };
    if (wanted) |given| attr = given.*;
    own.fonts[tdc.TDFONT_NORMAL] = gb.OpenFont(&attr);

    // A size up, and two: the nearest the family has, and null when
    // what comes back is the size we already have.
    const steps = [_]struct { which: u8, size: u16 }{
        .{ .which = tdc.TDFONT_LARGE, .size = attr.y_size + attr.y_size / 2 },
        .{ .which = tdc.TDFONT_LARGER, .size = attr.y_size * 2 },
    };
    for (steps) |step| {
        var bigger = attr;
        bigger.y_size = step.size;
        const font = gb.OpenFont(&bigger) orelse continue;
        if (font == own.fonts[tdc.TDFONT_NORMAL]) {
            gb.CloseFont(font);
            continue;
        }
        own.fonts[step.which] = font;
    }

    var fixed = graphics.TextAttr{ .name = graphics.POSPAZNAME, .y_size = attr.y_size };
    own.fonts[tdc.TDFONT_FIXED] = gb.OpenFont(&fixed);
}

/// The fonts given back.
pub fn closeFonts(base: *Base, own: *Data) void {
    const gb = base.graphics_base;
    for (&own.fonts) |*font| {
        gb.CloseFont(font.*);
        font.* = null;
    }
}

/// The text, the runs and everything made from them given back.
pub fn freeText(base: *Base, own: *Data) void {
    const sys = base.sys_base;
    if (own.buffer) |it| sys.FreeVec(it);
    if (own.pieces) |it| sys.FreeVec(it);
    if (own.lines) |it| sys.FreeVec(it);
    if (own.fragments) |it| sys.FreeVec(it);
    own.buffer = null;
    own.pieces = null;
    own.lines = null;
    own.fragments = null;
    own.buffer_len = 0;
    own.piece_count = 0;
    own.line_count = 0;
    own.line_room = 0;
    own.fragment_count = 0;
    own.fragment_room = 0;
}

/// Room for one more of something that grows in blocks. False when
/// there is no memory for it.
pub fn makeRoom(base: *Base, comptime T: type, at: *?[*]T, room: *u32, wanted: u32) bool {
    if (wanted <= room.*) return true;
    const sys = base.sys_base;
    const bigger = @max(wanted, room.* + grow_by);
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

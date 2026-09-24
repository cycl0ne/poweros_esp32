// SPDX-License-Identifier: MIT
//! Buffers and the shapes drawn into them.
//!
//! A buffer is memory with a width, a height, a pitch and a pixel format.
//! Its first seven fields are a drawing surface, in that order and with
//! those types, so the layer that draws and the layer that displays pass
//! one buffer between them by pointer and never by translation. The fields
//! past them are the library's and the board's: which board the memory
//! came from, where in that board's memory it starts, and what was taken
//! for it.
//!
//! `Surface` is the head on its own, and a comptime check holds the two
//! together: move a field of either and the build stops.

const nodes = @import("../exec/nodes.zig");

/// How the bytes of a picture are laid out. A buffer, a board's memory and
/// a shape's bits each say which of these they are.
pub const PixelFormat = enum(u8) {
    rgba32 = 0,
    bgra32 = 1,
    rgb24 = 2,
    bgr24 = 3,
    rgb565 = 4,
    argb1555 = 5,
    indexed8 = 6,
    gray8 = 7,
    /// One bit a pixel, the leftmost pixel in the most significant bit of
    /// a byte. A shape's bits, and the whole buffer of a panel that has
    /// two colours.
    mono1 = 8,
    _,
};

/// Bits a pixel. 0 for a format this build does not know.
pub fn formatBits(format: PixelFormat) u32 {
    return switch (format) {
        .rgba32, .bgra32 => 32,
        .rgb24, .bgr24 => 24,
        .rgb565, .argb1555 => 16,
        .indexed8, .gray8 => 8,
        .mono1 => 1,
        _ => 0,
    };
}

/// Bytes a pixel, for the formats that are whole bytes. 0 for mono1, whose
/// pixels are bits, and 0 for a format this build does not know - so a
/// caller that multiplies by it gets nothing rather than something wrong.
pub fn formatBytes(format: PixelFormat) u32 {
    return switch (format) {
        .rgba32, .bgra32 => 4,
        .rgb24, .bgr24 => 3,
        .rgb565, .argb1555 => 2,
        .indexed8, .gray8 => 1,
        else => 0,
    };
}

/// The bytes a row of `width` pixels of `format` needs, before any
/// rounding a board asks for. mono1 rounds up to the byte.
pub fn formatRowBytes(format: PixelFormat, width: u32) u32 {
    if (format == .mono1) return (width + 7) / 8;
    return width * formatBytes(format);
}

/// Where the buffer's memory came from and what may be done with it.
/// The first four are what a drawing surface already says about itself.
pub const PIXMAPF_SCREEN: u32 = 1 << 0;
pub const PIXMAPF_MEMORY: u32 = 1 << 1;
pub const PIXMAPF_ADDRMALLOC: u32 = 1 << 2;
pub const PIXMAPF_ADDRSHAREDMEM: u32 = 1 << 3;

/// The board can be given this buffer to show. AllocBitMap is told to make
/// one: it then comes out of memory the board can read, laid out as the
/// mode wants it.
pub const RTGBMF_DISPLAYABLE: u32 = 1 << 8;
/// It was allocated in a board's display memory.
pub const RTGBMF_BOARD_MEMORY: u32 = 1 << 9;
/// The memory is the caller's; FreeBitMap gives back only the handle.
pub const RTGBMF_ATTACHED: u32 = 1 << 10;
/// The board is reading it now. FreeBitMap refuses while this is set.
pub const RTGBMF_SHOWING: u32 = 1 << 11;
/// A mode change may take the memory away. Without it a mode change is
/// refused while the buffer is alive.
pub const RTGBMF_VOLATILE: u32 = 1 << 12;
/// The CPU reaches the memory through the cache, so what is written has to
/// be handed on with RefreshBitMap before the board reads it.
pub const RTGBMF_CACHED: u32 = 1 << 13;

/// The head of a buffer on its own: what a drawing surface is. Anything
/// that only draws needs no more than this.
pub const Surface = extern struct {
    pixels: ?[*]u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    /// Bytes from the start of one row to the start of the next.
    pitch: u32 = 0,
    size_bytes: usize = 0,
    format: PixelFormat = .rgb565,
    flags: u32 = 0,
};

/// A buffer: memory, its shape, and what the library knows about it.
pub const RtgBitMap = extern struct {
    // --- the surface, in a surface's order ---
    pixels: ?[*]u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    /// Bytes from the start of one row to the start of the next.
    pitch: u32 = 0,
    size_bytes: usize = 0,
    format: PixelFormat = .rgb565,
    flags: u32 = 0,

    // --- past the surface: the library's and the board's ---
    /// The buffers of one board, in the order they were made. ln_Name is
    /// the caller's name for it, if it gave one.
    node: nodes.Node = .{},
    /// The board whose memory this is, as an *RtgBoard.
    board: ?*anyopaque = null,
    /// Where it starts in that board's display memory (RTGBMF_BOARD_MEMORY
    /// only), and how many bytes were taken for it, alignment and all.
    offset: usize = 0,
    taken: usize = 0,
    /// The rows written since the last RefreshBitMap: `dirty_end` is one
    /// past the last. `dirty_end` 0 means none. They are gathered here
    /// only while `held` is not 0; otherwise a row is handed on as it is
    /// written and these stay empty. graphics.library's alone: every task
    /// drawing on the buffer shares them, so it changes them under Forbid
    /// and clears them as it takes them to hand on.
    dirty_top: u32 = 0,
    dirty_end: u32 = 0,
    /// How many batches are open on this buffer (graphics.library's
    /// BeginDraw). While it is not 0, rows written are gathered above
    /// rather than handed to the display, and the last EndDraw hands the
    /// lot on at once.
    held: u32 = 0,
    /// The caller's, untouched.
    user_data: ?*anyopaque = null,

    /// The first byte of a row. The caller has checked `y`.
    pub inline fn rowPtr(bm: *const RtgBitMap, y: u32) [*]u8 {
        return bm.pixels.? + @as(usize, y) * @as(usize, bm.pitch);
    }
};

comptime {
    // The surface's seven fields, where a surface has them. A field that
    // moves fails the build rather than quietly handing a caller that
    // knows only the head the wrong word.
    for (@typeInfo(Surface).@"struct".fields) |field| {
        if (@offsetOf(Surface, field.name) != @offsetOf(RtgBitMap, field.name)) {
            @compileError("RtgBitMap's " ++ field.name ++ " is not where a surface has it");
        }
    }
    if (@sizeOf(Surface) != @offsetOf(RtgBitMap, "node")) {
        @compileError("RtgBitMap's head is not a whole surface");
    }
}

/// A rectangle in a buffer's own coordinates. The far edge is not in it:
/// `x + width` is the first column past it.
pub const RtgRect = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
};

/// A copy: which rectangle of the source, and where in the destination its
/// top left corner lands.
pub const RtgCopy = extern struct {
    src_x: i32 = 0,
    src_y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    dest_x: i32 = 0,
    dest_y: i32 = 0,
};

/// A colour taken apart, eight bits a channel.
pub const RtgRGB = extern struct {
    red: u8 = 0,
    green: u8 = 0,
    blue: u8 = 0,
    alpha: u8 = 255,
};

/// A one-bit shape painted in two colours - a glyph, a cursor, a mask.
/// The bits are mono1 and `pitch` is their row stride.
pub const RtgTemplate = extern struct {
    bits: ?[*]const u8 = null,
    pitch: u32 = 0,
    /// Where in the bits the shape starts.
    src_x: u32 = 0,
    src_y: u32 = 0,
    /// The colour a set bit takes and the one a clear bit takes, each in
    /// the destination's format, right-aligned.
    fg: u32 = 0,
    bg: u32 = 0,
    flags: u32 = 0,
};

/// A one-bit tile repeated across a rectangle. It is anchored to the
/// buffer and not to the rectangle, so two rectangles of one pattern line
/// up where they meet.
pub const RtgPattern = extern struct {
    bits: ?[*]const u8 = null,
    pitch: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    fg: u32 = 0,
    bg: u32 = 0,
    flags: u32 = 0,
};

/// RtgTemplate.flags and RtgPattern.flags: a clear bit leaves the
/// destination alone rather than taking `bg`.
pub const RTGTF_TRANSPARENT: u32 = 1 << 0;
/// Set and clear swap.
pub const RTGTF_INVERT: u32 = 1 << 1;

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
const hooks = @import("../utility/hooks.zig");

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
    /// only), and how many bytes were taken for it, alignment and all; on a
    /// board with RTGRF_SYSTEM_MEMORY, the address and size of the block
    /// exec gave.
    offset: usize = 0,
    taken: usize = 0,
    /// The rows written since the last refresh: `dirty_end` is one past
    /// the last. `dirty_end` 0 means none; `dirty_left` and `dirty_right`
    /// are their columns. They are gathered here only while `held` is not
    /// 0; otherwise what is written is handed on at once and these stay
    /// empty. graphics.library's alone: every task drawing on the buffer
    /// shares them, so it changes them under its batches' lock and clears
    /// them as it takes them to hand on.
    dirty_top: u32 = 0,
    dirty_end: u32 = 0,
    /// How many batches are open on this buffer (graphics.library's
    /// BeginDraw). While it is not 0, rows written are gathered above
    /// rather than handed to the display, and the last EndDraw hands the
    /// lot on at once.
    held: u32 = 0,
    /// The caller's, untouched.
    user_data: ?*anyopaque = null,
    /// The columns of the rows gathered above (`dirty_top`): `dirty_right`
    /// is one past the last. Last, so that the fields before kept their
    /// places when these came.
    dirty_left: u32 = 0,
    dirty_right: u32 = 0,
    /// Told instead of the board when a rectangle of this buffer is handed
    /// on (RefreshRect, RefreshBitMap), or null. Its object is the buffer
    /// and its message the `*const RtgRect` written, cut to the buffer. A
    /// buffer nobody shows - a window's own, when its screen is composed
    /// - has nothing for the board to do, and whoever copies it on to a
    /// screen is the one to know what changed. Set by the buffer's owner.
    watch: ?*hooks.Hook = null,

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

/// Pixels of a caller's own, as BlendPixels and ScalePixels read them:
/// the picture's first byte, the bytes from one of its rows to the next,
/// its format, and the pixel the work starts from - the one that lands on
/// the area's top left corner. The library only reads them.
pub const RtgPixels = extern struct {
    pixels: ?[*]const u8 = null,
    pitch: u32 = 0,
    format: PixelFormat = .bgra32,
    /// `RTGPIXF_`.
    flags: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    x: i32 = 0,
    y: i32 = 0,
};

/// `RtgPixels.flags`: the picture's own coverage is not read, and every
/// pixel covers fully - a window's buffer, whose top byte is whatever was
/// drawn, laid over the display at BlendPixels' `alpha` alone. Since rtg
/// 1.8; a driver from before reads the coverage.
pub const RTGPIXF_OPAQUE: u8 = 1;

/// A picture in YUV, as a video decoder hands it out: a plane of
/// brightness (luma, Y) a sample a pixel, and the colour (chroma, Cb and
/// Cr) at half the size each way - one Cb and one Cr for each two by two
/// pixels, which is 4:2:0. WriteYUVPixelArray and ScaleYUVPixelArray read
/// it and put it down as colours; nothing else is kept of it.
///
/// What the numbers mean takes four fields, because a film says all four
/// and they do not follow from one another: the `matrix` that turns Y, Cb
/// and Cr into red, green and blue; the `transfer` - the curve from a
/// number to light, which for a high dynamic range film is nothing like a
/// television's; the `primaries`, which red, green and blue those are;
/// and the `range` the numbers use. A picture that says nothing is a
/// television's: BT.709, SDR, video's range, eight bits.
pub const RtgYuv = extern struct {
    /// The luma: rows of `y_pitch` bytes, a sample a pixel.
    y: [*]const u8,
    /// `RTGYUV_NV12`: the chroma, a Cb and a Cr sample for each two pixels
    /// across, a row for each two rows down. `RTGYUV_I420`: the Cb plane
    /// alone, a sample for each two by two pixels.
    cb: [*]const u8,
    /// `RTGYUV_I420`: the Cr plane, laid out as `cb`. Unused for NV12.
    cr: ?[*]const u8 = null,
    /// Bytes from one luma row to the next.
    y_pitch: u32,
    /// Bytes from one chroma row to the next - the Cb plane's and the Cr
    /// plane's alike for I420.
    c_pitch: u32,
    /// `RTGYUV_NV12` or `RTGYUV_I420`.
    layout: u8 = RTGYUV_NV12,
    /// Which weights make red, green and blue out of Y, Cb and Cr:
    /// `RTGYUV_BT601`, `RTGYUV_BT709` or `RTGYUV_BT2020`.
    matrix: u8 = RTGYUV_BT709,
    /// What a number stands for: `RTGYUV_SDR`, the curve a television has
    /// always had, or the high dynamic range curves `RTGYUV_PQ` and
    /// `RTGYUV_HLG`, whose light reaches far past a screen's white and is
    /// mapped into it.
    transfer: u8 = RTGYUV_SDR,
    /// Which red, green and blue they are: `RTGYUV_BT709`,
    /// `RTGYUV_BT2020` or `RTGYUV_P3`. BT.601's are taken as BT.709's,
    /// which they are within a step.
    primaries: u8 = RTGYUV_BT709,
    /// `RTGYUV_LIMITED` - video's 16 to 235 (Y) and 16 to 240 (Cb, Cr) of
    /// a byte, four times that at ten bits - or `RTGYUV_FULL`, the whole
    /// number (JPEG's).
    range: u8 = RTGYUV_LIMITED,
    /// Bits in a sample: 8, a byte each, or 10, two bytes each - little
    /// endian, the ten bits at the bottom of the word. The pitches are
    /// bytes either way.
    depth: u8 = 8,
    /// The light the film was mastered for, in candelas a square metre:
    /// the mastering display's maximum, or the brightest pixel in the film
    /// (MaxCLL) where that is all it says. 0 where it says nothing, and
    /// 1000 is taken. Read for `RTGYUV_PQ` alone.
    peak: u16 = 0,
};

/// `RtgYuv.layout`: the chroma in one plane, Cb and Cr in turn - what
/// the VisionFive 2's decoder hands out.
pub const RTGYUV_NV12: u8 = 0;
/// `RtgYuv.layout`: the chroma in two planes, Cb's and Cr's.
pub const RTGYUV_I420: u8 = 1;

/// `RtgYuv.matrix`: ITU-R BT.601's weights - a picture of standard
/// definition, and JPEG's.
pub const RTGYUV_BT601: u8 = 0;
/// `RtgYuv.matrix`, `RtgYuv.primaries`: ITU-R BT.709's - high definition
/// video, and what a screen shows.
pub const RTGYUV_BT709: u8 = 1;
/// `RtgYuv.matrix`, `RtgYuv.primaries`: ITU-R BT.2020's - ultra high
/// definition, and every film in high dynamic range.
pub const RTGYUV_BT2020: u8 = 2;
/// `RtgYuv.primaries`: DCI-P3's, the cinema's.
pub const RTGYUV_P3: u8 = 3;

/// `RtgYuv.transfer`: the curve of a television - BT.709 out of the
/// camera, BT.1886 at the screen - which is what every picture had before
/// high dynamic range.
pub const RTGYUV_SDR: u8 = 0;
/// `RtgYuv.transfer`: SMPTE ST 2084, "perceptual quantizer" - the curve
/// of HDR10, Dolby Vision and HDR10+, in which a number stands for a
/// light in candelas a square metre, up to 10000 of them.
pub const RTGYUV_PQ: u8 = 1;
/// `RtgYuv.transfer`: ITU-R BT.2100's hybrid log-gamma - broadcast's high
/// dynamic range, whose lower half is a television's own curve.
pub const RTGYUV_HLG: u8 = 2;

/// `RtgYuv.range`: video's range - 16 to 235 (Y) and 16 to 240 (Cb, Cr)
/// of a byte.
pub const RTGYUV_LIMITED: u8 = 0;
/// `RtgYuv.range`: the numbers take the whole byte, as JPEG's do.
pub const RTGYUV_FULL: u8 = 1;

/// What is taken for a film that says nothing of the light it was
/// mastered for: the peak of a mastering display, in candelas a square
/// metre.
pub const RTGYUV_PEAK_DEFAULT: u16 = 1000;

// --- what a stream or a container says, as rtg says it ----------------------
//
// A stream's parameter set and a container's own element both describe
// the colours in the numbering of ITU-T H.273 (the "code points" the
// standards share, CICP), where 2 is "unspecified" - which is what a
// file that says nothing of itself leaves. These three turn such a
// number into rtg's, and answer null where nothing was said or where it
// is something no board here shows: then what the caller had stands.

/// `RtgYuv.matrix` for H.273's matrix coefficients (Table 4).
pub fn cicpMatrix(value: u8) ?u8 {
    return switch (value) {
        1 => RTGYUV_BT709,
        // FCC, BT.470 B/G, BT.601 and SMPTE 240M are a television's.
        4, 5, 6, 7 => RTGYUV_BT601,
        // BT.2020, of either luminance.
        9, 10 => RTGYUV_BT2020,
        else => null,
    };
}

/// `RtgYuv.transfer` for H.273's transfer characteristics (Table 3).
pub fn cicpTransfer(value: u8) ?u8 {
    return switch (value) {
        // BT.709's curve, BT.601's, and BT.2020's at either depth: one
        // curve, the television's.
        1, 6, 14, 15 => RTGYUV_SDR,
        16 => RTGYUV_PQ,
        18 => RTGYUV_HLG,
        else => null,
    };
}

/// `RtgYuv.primaries` for H.273's colour primaries (Table 2).
pub fn cicpPrimaries(value: u8) ?u8 {
    return switch (value) {
        1, 5, 6, 7 => RTGYUV_BT709,
        9 => RTGYUV_BT2020,
        11, 12 => RTGYUV_P3,
        else => null,
    };
}

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

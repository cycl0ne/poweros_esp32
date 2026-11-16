// SPDX-License-Identifier: MPL-2.0
//! SetBoardPointer: the pointer's image, made once in the board's own
//! pixel format with a mask beside it.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const registry = @import("../driver/_driver.zig");
const composer = @import("../compose/_compose.zig");

/// Gives a board the image its pointer is drawn with.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, image: ?*const rtg.Surface, hot_x: u32, hot_y: u32) i32
/// ```
///
/// SINCE: 1.1. LVO -220.
///
/// INPUTS:
/// - `board` - the board.
/// - `image` - a surface (an `RtgBitMap` is one by pointer) in `rgba32`, `bgra32` or `argb1555`, at most `RTG_POINTER_MAX`
///   pixels each way; null takes the image away and shows nothing.
/// - `hot_x`, `hot_y` - the pixel of the image that is the pointer's
///   point, inside it.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_NOT_SUPPORTED` for a board without
/// `RTGBC_POINTER`; `RTGERR_BAD_FORMAT` for an image with no alpha, or a
/// board whose format a pixel is not whole bytes of; `RTGERR_BAD_ARG` for
/// an image too large, empty, or with its point outside it;
/// `RTGERR_NO_MEMORY`; or what the driver answered. On any failure the
/// board keeps the image it had.
///
/// BEHAVIOR:
/// The image is converted here and not again: every pixel into the
/// board's format, and its alpha into a mask of one bit a pixel - an
/// alpha of 128 or more is the pointer, anything less the picture showing
/// through. So laying it on the way to the glass, which a driver often
/// does from an interrupt, is a masked copy of a fixed size. The point
/// stays where MoveBoardPointer last put it, and the new image is placed
/// around it. Whether it is seen is ShowBoardPointer's business.
///
/// A board that lays its pointer itself - a cursor plane, a stream's own
/// copy - is handed the image. On a board whose picture the library
/// composes, the library lays it: the part of the picture the old image
/// covered and the part the new one covers are delivered again. A
/// display that was reading the shown buffer itself is then shown the
/// library's picture, and where its driver cannot do that the image is
/// refused with the driver's answer.
///
/// CONTEXT:
/// - Waits: for the board's compose lock while another task moves the
///   pointer or hands on what it drew, for the board's lock where the
///   library lays the pointer, and for a driver that sends rows over a
///   bus.
/// - Interrupts: no. It allocates.
/// - Locks: takes the board's compose lock while the image changes, so
///   a move cannot come between - and the board's lock before it where
///   the library lays the pointer, as the board may be shown another
///   way; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's image is read and not kept; it may be freed on return.
/// The converted one is the library's - in internal memory where a
/// driver whose interrupts read its handles lays it
/// (`RTGDF_INTERNAL_INSTANCE`) - freed by the next SetBoardPointer or by
/// DeleteBoard.
///
/// NOTES:
/// A board with no alpha in its own format still gets a mask: the mask is
/// the whole of the pointer's shape, and the pixels behind a clear bit are
/// never read.
///
/// BUGS:
/// The image is made in the pixel format the board has when it is set.
/// Where the library lays the pointer and the board is then put in a
/// mode of another format, the image is not laid until it is set again.
///
/// SEE ALSO:
/// `MoveBoardPointer`, `ShowBoardPointer`, `GetBoardInfo`
///
/// EXAMPLES:
/// ```zig
/// if (rb.SetBoardPointer(board, arrow, 0, 0) == rtg.errors.RTGERR_OK)
///     _ = rb.ShowBoardPointer(board, true);
/// ```
pub fn SetBoardPointer(rb: *RtgBase, board: *rtg.RtgBoard, image: ?*const rtg.Surface, hot_x: u32, hot_y: u32) i32 {
    if (board.info.caps & rtg.boards.RTGBC_POINTER == 0) return err.RTGERR_NOT_SUPPORTED;

    const made: ?*rtg.RtgPointerImage = if (image) |source| blk: {
        const converted = convert(rb, board, source, hot_x, hot_y, rtg.boards.RTG_POINTER_MAX, .threshold, composer.laysPointer(board));
        if (converted.code != err.RTGERR_OK) return converted.code;
        break :blk converted.image;
    } else null;

    const code = composer.setPointer(rb, board, made);
    if (code != err.RTGERR_OK) {
        if (made) |refused| rb.sys_base.FreeVec(refused);
    }
    return code;
}

pub const Converted = struct { code: i32, image: ?*rtg.RtgPointerImage = null };

/// How coverage becomes the one-bit mask: a pixel at least half covered
/// (the pointer's), or coverage dithered by a 4x4 ordered pattern, so a
/// soft edge or a see-through image keeps its look as dots (an overlay's).
pub const MaskRule = enum { threshold, dither };

/// The 4x4 ordered pattern: a pixel is shown when its coverage is above
/// its place's step, `(n * 16 + 8)` of 255.
const pattern = [4][4]u8{
    .{ 0, 8, 2, 10 },
    .{ 12, 4, 14, 6 },
    .{ 3, 11, 1, 9 },
    .{ 15, 7, 13, 5 },
};

/// One pixel of a caller's image, taken apart: its three colours and its
/// coverage, eight bits each.
pub const Colour = struct { red: u32 = 0, green: u32 = 0, blue: u32 = 0, alpha: u32 = 0 };

/// The pixel at `at` of an image in `format`. A 32-bit format's bytes are
/// its channels in the order its name gives them; `argb1555` is a word in
/// the CPU's order, its five bits a channel spread over eight and its top
/// bit the whole coverage.
///
/// INPUTS:
/// - `format` - `rgba32`, `bgra32` or `argb1555`: what an image may be.
/// - `at` - the pixel's first byte.
fn read(format: rtg.PixelFormat, at: [*]const u8) Colour {
    switch (format) {
        .rgba32 => return .{ .red = at[0], .green = at[1], .blue = at[2], .alpha = at[3] },
        .bgra32 => return .{ .blue = at[0], .green = at[1], .red = at[2], .alpha = at[3] },
        else => {
            const word: u32 = @as(*align(1) const u16, @ptrCast(at)).*;
            const red = (word >> 10) & 0x1F;
            const green = (word >> 5) & 0x1F;
            const blue = word & 0x1F;
            return .{
                .red = (red << 3) | (red >> 2),
                .green = (green << 3) | (green >> 2),
                .blue = (blue << 3) | (blue >> 2),
                .alpha = if (word & 0x8000 != 0) 255 else 0,
            };
        },
    }
}

/// A colour as one opaque pixel of `format`: the bytes to write, the
/// first in the low bits of the word - the order every drawing call
/// writes a pixel of that format in, so the image laid over a picture has
/// the picture's own colours.
///
/// INPUTS:
/// - `format` - the board's format.
/// - `colour` - the three colours, 0 to 255 each; its coverage is not
///   read.
///
/// RESULT:
/// The pixel, or 0 for a format with no colour of its own (`indexed8`,
/// `mono1`).
pub fn pack(format: rtg.PixelFormat, colour: Colour) u32 {
    const red = colour.red;
    const green = colour.green;
    const blue = colour.blue;
    return switch (format) {
        .bgra32 => 0xFF00_0000 | red << 16 | green << 8 | blue,
        .rgba32 => 0xFF00_0000 | blue << 16 | green << 8 | red,
        .bgr24 => red << 16 | green << 8 | blue,
        .rgb24 => blue << 16 | green << 8 | red,
        .rgb565 => (red >> 3) << 11 | (green >> 2) << 5 | (blue >> 3),
        .argb1555 => 0x8000 | (red >> 3) << 10 | (green >> 3) << 5 | (blue >> 3),
        // One channel: the eye's own weights for the three.
        .gray8 => (red * 77 + green * 151 + blue * 28) >> 8,
        else => 0,
    };
}

/// The caller's image in the board's format, with its mask, in one block:
/// the header, the pixels, the mask. An image the board's driver lays
/// goes where the driver's handles go - internal memory for a driver
/// whose interrupts read them; one the library lays (`composed`) is read
/// by tasks alone, and goes anywhere. Shared with SetBoardOverlay, which
/// takes a larger image and dithers.
pub fn convert(rb: *RtgBase, board: *rtg.RtgBoard, source: *const rtg.Surface, hot_x: u32, hot_y: u32, most: u32, rule: MaskRule, composed: bool) Converted {
    const sys = rb.sys_base;
    const width = source.width;
    const height = source.height;
    if (width == 0 or height == 0 or width > most or height > most) return .{ .code = err.RTGERR_BAD_ARG };
    if (hot_x >= width or hot_y >= height) return .{ .code = err.RTGERR_BAD_ARG };
    const from = source.pixels orelse return .{ .code = err.RTGERR_BAD_ARG };
    switch (source.format) {
        .rgba32, .bgra32, .argb1555 => {},
        else => return .{ .code = err.RTGERR_BAD_FORMAT },
    }
    const format = board.info.format;
    // Whole bytes a pixel: a board of one bit a pixel has no pointer.
    const bytes = rb.iface().RtgFormatBits(@intFromEnum(format)) / 8;
    if (bytes == 0) return .{ .code = err.RTGERR_BAD_FORMAT };

    const pitch = (width * bytes + 3) & ~@as(u32, 3);
    const mask_pitch = (width + 7) / 8;
    const header = (@sizeOf(rtg.RtgPointerImage) + 7) & ~@as(usize, 7);
    const size = header + @as(usize, pitch) * height + @as(usize, mask_pitch) * height;
    const where = if (composed) exec.MEMF_ANY | exec.MEMF_CLEAR else registry.memoryFor(board.driver.?.spec);
    const memory = sys.AllocVec(@intCast(size), where) orelse return .{ .code = err.RTGERR_NO_MEMORY };
    const base: [*]u8 = @ptrCast(memory);
    const pixels = base + header;
    const mask = pixels + @as(usize, pitch) * height;

    const source_bytes: u32 = if (source.format == .argb1555) 2 else 4;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row = from + @as(usize, y) * source.pitch;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const colour = read(source.format, row + x * source_bytes);
            const shown = if (source.format == .argb1555) colour.alpha != 0 else switch (rule) {
                .threshold => colour.alpha >= 0x80,
                .dither => colour.alpha > @as(u32, pattern[y % 4][x % 4]) * 16 + 8,
            };
            if (!shown) continue;
            mask[y * mask_pitch + x / 8] |= @as(u8, 0x80) >> @intCast(x % 8);
            // The word's low byte first, as the format's pixels lie in
            // memory.
            const pixel = pack(format, colour);
            const at = pixels + y * pitch + x * bytes;
            var i: u32 = 0;
            while (i < bytes) : (i += 1) at[i] = @truncate(pixel >> @intCast(8 * i));
        }
    }

    const made: *rtg.RtgPointerImage = @ptrCast(@alignCast(memory));
    made.* = .{
        .pixels = pixels,
        .mask = mask,
        .width = width,
        .height = height,
        .pitch = pitch,
        .mask_pitch = mask_pitch,
        .hot_x = hot_x,
        .hot_y = hot_y,
        .format = format,
    };
    return .{ .code = err.RTGERR_OK, .image = made };
}

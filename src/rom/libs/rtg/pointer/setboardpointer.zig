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
/// SINCE: 1.1. LVO -140.
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

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "the pointer: converted once, placed by its point, shown and hidden" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeBoard(rb);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, 0));
    var info: rtg.RtgBoardInfo = .{};
    _ = fixture.base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.caps & rtg.boards.RTGBC_POINTER != 0);

    // Three by two, rgba32: a red pixel, a clear one, a green one, and a
    // row of blue with a half-clear pixel in the middle.
    var pixels = [_]u32{ fixture.rgba(0xFF0000FF), fixture.rgba(0x12345600), fixture.rgba(0x00FF00FF), fixture.rgba(0x0000FFFF), fixture.rgba(0x0000FF7F), fixture.rgba(0x0000FFFF) };
    const image = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = 3, .height = 2, .pitch = 12, .format = .rgba32 };

    // Placed before there is an image: the image arrives there.
    fixture.base(rb).MoveBoardPointer(board, 20, 30);
    try testing.expectEqual(@as(u32, 0), fk.log.pointer_moves);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardPointer(board, &image, 1, 1));
    const made = fk.log.pointer_image.?;
    try testing.expectEqual(made, board.pointer.?);
    try testing.expectEqual(rtg.PixelFormat.rgb565, made.format);
    try testing.expect(fixture.opaqueAt(made, 0, 0) and !fixture.opaqueAt(made, 1, 0) and fixture.opaqueAt(made, 2, 0));
    try testing.expect(fixture.opaqueAt(made, 0, 1) and !fixture.opaqueAt(made, 1, 1) and fixture.opaqueAt(made, 2, 1));
    const row0: [*]const u16 = @ptrCast(@alignCast(made.pixels));
    const row1: [*]const u16 = @ptrCast(@alignCast(made.pixels + made.pitch));
    try testing.expectEqual(@as(u16, 0xF800), row0[0]);
    try testing.expectEqual(@as(u16, 0x07E0), row0[2]);
    try testing.expectEqual(@as(u16, 0x001F), row1[0]);
    // The top left, from the point.
    try testing.expectEqual(@as(i32, 19), fk.log.pointer_left);
    try testing.expectEqual(@as(i32, 29), fk.log.pointer_top);

    fixture.base(rb).MoveBoardPointer(board, -1, 5);
    try testing.expectEqual(@as(i32, -2), fk.log.pointer_left);
    try testing.expectEqual(@as(i32, 4), fk.log.pointer_top);
    // The same place again is no move.
    const moves = fk.log.pointer_moves;
    fixture.base(rb).MoveBoardPointer(board, -1, 5);
    try testing.expectEqual(moves, fk.log.pointer_moves);

    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoardPointer(board, true));
    try testing.expect(fk.log.pointer_shown);
    _ = fixture.base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.flags & rtg.boards.RTGBF_POINTER != 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoardPointer(board, false));
    try testing.expect(!fk.log.pointer_shown);

    // What will not do leaves the image it had.
    var opaque_only = [_]u16{ 0xF800, 0x001F };
    const no_alpha = rtg.Surface{ .pixels = @ptrCast(&opaque_only), .width = 2, .height = 1, .pitch = 4, .format = .rgb565 };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_FORMAT, fixture.base(rb).SetBoardPointer(board, &no_alpha, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).SetBoardPointer(board, &image, 3, 0));
    const huge = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = rtg.boards.RTG_POINTER_MAX + 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).SetBoardPointer(board, &huge, 0, 0));
    try testing.expectEqual(made, board.pointer.?);

    // A second image replaces the first; null takes it away.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardPointer(board, &image, 0, 0));
    try testing.expectEqual(@as(u32, 2), fk.log.pointer_sets);
    try testing.expectEqual(@as(i32, -1), fk.log.pointer_left);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardPointer(board, null, 0, 0));
    try testing.expect(board.pointer == null);
    try testing.expect(fk.log.pointer_image == null);

    // An image still set when the board goes is freed with it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardPointer(board, &image, 0, 0));
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "the pointer on a 32-bit board: its channels in the order the format names them" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeBoard(rb);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, 0));
    board.info.format = .bgra32;

    // A red pixel, a grey one, and one that does not cover, rgba32.
    var pixels = [_]u32{ fixture.rgba(0xFF0000FF), fixture.rgba(0x102030FF), fixture.rgba(0x40506010) };
    const image = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = 3, .height = 1, .pitch = 12, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardPointer(board, &image, 0, 0));
    const made = fk.log.pointer_image.?;
    try testing.expectEqual(rtg.PixelFormat.bgra32, made.format);
    // The pixels kept cover fully; the one left out is 0: the image is
    // ARGB as a plane takes it, without its mask.
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0xFF, 0xFF, 0x30, 0x20, 0x10, 0xFF, 0, 0, 0, 0 }, made.pixels[0..12]);
    try testing.expectEqual(@as(u8, 0b1100_0000), made.mask[0]);

    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "a board with no pointer says so" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    fixture.fakeOf(rb).without_engine = true;
    const board = try fixture.makeBoard(rb);
    var info: rtg.RtgBoardInfo = .{};
    _ = fixture.base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_POINTER);
    var pixel = [_]u32{0xFFFFFFFF};
    const image = rtg.Surface{ .pixels = @ptrCast(&pixel), .width = 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.base(rb).SetBoardPointer(board, &image, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.base(rb).ShowBoardPointer(board, true));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.base(rb).SetBoardOverlay(board, &image, 0, 0));
    fixture.base(rb).MoveBoardPointer(board, 3, 3);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

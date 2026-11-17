// SPDX-License-Identifier: MPL-2.0
//! The DSI board's engine laying pixels over an RGB565 buffer:
//! BlendPixels and BlendRect on the PPA's blend unit.
//!
//! One send channel reads what is under - the buffer's own block - the
//! other what goes over, and the receive channel writes the mix back
//! where the first read it. What goes over is the caller's picture, or
//! for a colour a block of A8 coverage whose values the fixed coverage
//! replaces - read from the buffer itself, since nothing of it is used -
//! in the unit's fixed colour. A colour that covers fully is a fill.
//!
//! The rules are the fill's (`engine.zig`): the engine gets the whole
//! cache lines inside the rectangle, and the CPU mixes the ragged ends
//! while it works. A picture the 2D-DMA cannot read, one whose rows do
//! not start on a word, a format it has no mode for and a job too small
//! to be worth it (`Engine.smallest_blend`) are answered
//! RTGERR_NOT_SUPPORTED, and the caller does them in software.
//!
//! A job the engine does not end is finished by the CPU and answered as
//! done: its ends are mixed by then, and a caller told "not supported"
//! would lay the whole rectangle over them again. Nothing says how far
//! such a job got, so rows of the middle the engine had finished are
//! mixed a second time; the ends and every row it had not reached are
//! right.
//!
//! **The mixing.** Each channel is (over x coverage + under x (255 -
//! coverage) + 127) / 255, the buffer's pixel widened to eight bits a
//! channel by repeating its high bits and the result cut back to RGB565.
//! The CPU's ends mix that way; the unit rounds its own way, which can
//! differ by one step in eight bits and rarely by one in RGB565. A
//! constant alpha below 255 is multiplied into a picture's coverage as
//! the unit does it, as alpha / 256.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const err = rtg.errors;
const ExecBase = sdk.interface.exec.ExecBase;
const dma2d = sdk.hardware.dma2d;
const ppa = @import("ppa.zig");
const engine_file = @import("engine.zig");
const Engine = engine_file.Engine;

/// A picture's format as the 2D-DMA and the unit take it: the unit's
/// colour mode, red and blue exchanged, bytes a pixel, the descriptor's
/// pbyte, and whether it carries coverage. `rgba32` is not among them:
/// the unit reads four bytes as they are, with each pair exchanged, or
/// all four reversed, and red, green, blue, alpha is none of those.
pub const Source = struct {
    cm: u32,
    swap: bool = false,
    bytes: u32,
    pbyte: u32,
    covered: bool = false,
};

pub fn sourceOf(format: rtg.PixelFormat) ?Source {
    return switch (format) {
        .bgra32 => .{ .cm = ppa.cm_argb8888, .bytes = 4, .pbyte = dma2d.pbyte_4, .covered = true },
        .bgr24 => .{ .cm = ppa.cm_rgb888, .bytes = 3, .pbyte = dma2d.pbyte_3 },
        .rgb24 => .{ .cm = ppa.cm_rgb888, .swap = true, .bytes = 3, .pbyte = dma2d.pbyte_3 },
        .rgb565 => .{ .cm = ppa.cm_rgb565, .bytes = 2, .pbyte = dma2d.pbyte_2 },
        else => null,
    };
}

/// A picture laid over a rectangle: its rows from `first_row` on, `pitch`
/// apart, `width` pixels each at most; the column that lands on the
/// rectangle's left edge; its format; the constant alpha.
pub const Picture = struct {
    first_row: usize,
    pitch: u32,
    width: u32,
    column: u32,
    source: Source,
    alpha: u32,
    /// Its coverage is not read: every pixel covers fully
    /// (`RTGPIXF_OPAQUE`).
    whole: bool = false,
};

/// The picture `pixels` describes, for a rectangle `rows` high: null for
/// one the 2D-DMA cannot read or its descriptor cannot hold, or `width`
/// columns of which run past its rows.
pub fn pictureOf(pixels: *const rtg.RtgPixels, width: u32, rows: u32, alpha: u32) ?Picture {
    const source = sourceOf(pixels.format) orelse return null;
    if (pixels.x < 0 or pixels.y < 0 or pixels.pitch % 4 != 0 or pixels.pitch % source.bytes != 0) return null;
    const picture_width = pixels.pitch / source.bytes;
    const column: u32 = @intCast(pixels.x);
    if (picture_width > dma2d.field_max or rows > dma2d.field_max) return null;
    if (width > picture_width or column > picture_width - width) return null;
    // Worked out wide: the numbers are the caller's.
    const first_row: u64 = @intFromPtr(pixels.pixels.?) + @as(u64, @intCast(pixels.y)) * pixels.pitch;
    const end = first_row + @as(u64, rows - 1) * pixels.pitch + @as(u64, column + width) * source.bytes;
    if (first_row % 4 != 0 or !engine_file.reachable(first_row, end)) return null;
    return .{ .first_row = @intCast(first_row), .pitch = pixels.pitch, .width = picture_width, .column = column, .source = source, .alpha = alpha, .whole = pixels.flags & rtg.RTGPIXF_OPAQUE != 0 };
}

/// What becomes of a picture's coverage in the unit.
fn overOf(picture: Picture) ppa.Over {
    var over = ppa.Over{ .cm = picture.source.cm, .swap = picture.source.swap };
    if (!picture.source.covered or picture.whole) {
        over.coverage = .replace;
        over.fixed = picture.alpha;
    } else if (picture.alpha < 255) {
        over.coverage = .multiply;
        over.fixed = picture.alpha;
    }
    return over;
}

/// BlendPixels: the rectangle has been clipped to the buffer and the
/// picture's corner moved with it. `watched` as for `engine.fill`.
pub fn blendPixels(engine: *Engine, sys: *ExecBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, alpha: u32, watched: bool) i32 {
    if (!engine.ready or !engine_file.lined(dest)) return err.RTGERR_NOT_SUPPORTED;
    if (alpha == 0) return err.RTGERR_OK;
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    const middle = engine_file.middleOf(@intCast(area.x), width);
    if ((middle.end - middle.start) * height < engine.smallest_blend) return err.RTGERR_NOT_SUPPORTED;
    const picture = pictureOf(pixels, width, height, alpha) orelse return err.RTGERR_NOT_SUPPORTED;
    if (overlapsDest(dest, area, picture)) return err.RTGERR_NOT_SUPPORTED;

    sys.ObtainSemaphore(&engine.lock);
    defer sys.ReleaseSemaphore(&engine.lock);
    return lay(engine, sys, dest, area, picture, watched);
}

/// Whether the memory the picture is read from and the rectangle it is
/// laid on share a byte, from the first row's first pixel to the last
/// row's last: the engine reads the one while it writes the other in an
/// order of its own, so such a blend is the CPU's, row after row.
fn overlapsDest(dest: *const rtg.RtgBitMap, area: *const rtg.RtgRect, picture: Picture) bool {
    const height: u64 = @intCast(area.height);
    const width: u64 = @intCast(area.width);
    const picture_start: u64 = picture.first_row + @as(u64, picture.column) * picture.source.bytes;
    const picture_end: u64 = picture.first_row + (height - 1) * picture.pitch + (picture.column + width) * picture.source.bytes;
    const rows: u64 = @intFromPtr(dest.pixels.?) + @as(u64, @intCast(area.y)) * dest.pitch;
    const dest_start = rows + @as(u64, @intCast(area.x)) * 2;
    const dest_end = rows + (height - 1) * dest.pitch + (@as(u64, @intCast(area.x)) + width) * 2;
    return picture_start < dest_end and dest_start < picture_end;
}

/// A picture over the rectangle, by the engine and the CPU; by the CPU
/// alone when the engine would get no whole line, and the CPU the rest
/// when the engine does not end its job. The engine's lock is held.
pub fn lay(engine: *Engine, sys: *ExecBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, picture: Picture, watched: bool) i32 {
    const x: u32 = @intCast(area.x);
    const y: u32 = @intCast(area.y);
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    const middle = engine_file.middleOf(x, width);
    const run = middle.end - middle.start;
    if (run == 0) {
        layByCpu(dest, x, x + width, y, height, picture, x);
        return err.RTGERR_OK;
    }
    const end = picture.first_row + @as(usize, height - 1) * picture.pitch + @as(usize, picture.column + width) * picture.source.bytes;
    engine_file.writeBackSpan(sys, picture.first_row + @as(usize, picture.column) * picture.source.bytes, end);
    engine_file.writeBack(sys, dest, middle.start, middle.end, y, height);

    const parts = engine_file.descriptors(engine);
    ppa.reset();
    if (!connect()) return engine_file.failed(engine, sys);
    dma2d.describe(parts.send, @intFromPtr(dest.pixels.?), dest.pitch / 2, dest.height, middle.start, y, run, height, dma2d.pbyte_2);
    dma2d.describe(parts.over, picture.first_row, picture.width, height, picture.column + (middle.start - x), 0, run, height, picture.source.pbyte);
    dma2d.describe(parts.receive, @intFromPtr(dest.pixels.?), dest.pitch / 2, dest.height, middle.start, y, run, height, dma2d.pbyte_2);
    const asleep = engine_file.prepare(engine, sys, watched);
    run3(parts);
    ppa.blend(overOf(picture), run, height);

    layByCpu(dest, x, middle.start, y, height, picture, x);
    layByCpu(dest, middle.end, x + width, y, height, picture, x);

    const done = engine_file.wait(engine, sys, asleep);
    engine_file.forget(sys, dest, middle, y, height);
    // The ends are mixed and the job is stopped: the middle is the CPU's
    // as well, over what memory holds now that its lines are out of the
    // cache.
    if (!done) layByCpu(dest, middle.start, middle.end, y, height, picture, x);
    return err.RTGERR_OK;
}

/// BlendRect: the rectangle has been clipped to the buffer. A colour
/// that covers fully is a fill, one that covers nothing no work.
pub fn blendRect(engine: *Engine, sys: *ExecBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32, watched: bool) i32 {
    const coverage = color >> 24;
    if (coverage == 0) return err.RTGERR_OK;
    if (coverage == 255) return engine_file.fill(engine, sys, dest, area, pack565(color), watched);
    if (!engine.ready or !engine_file.lined(dest) or dest.pitch > dma2d.field_max) return err.RTGERR_NOT_SUPPORTED;
    const x: u32 = @intCast(area.x);
    const y: u32 = @intCast(area.y);
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    const middle = engine_file.middleOf(x, width);
    const run = middle.end - middle.start;
    if (run * height < engine.smallest_blend) return err.RTGERR_NOT_SUPPORTED;

    sys.ObtainSemaphore(&engine.lock);
    defer sys.ReleaseSemaphore(&engine.lock);
    engine_file.writeBack(sys, dest, middle.start, middle.end, y, height);

    const parts = engine_file.descriptors(engine);
    ppa.reset();
    if (!connect()) return engine_file.failed(engine, sys);
    dma2d.describe(parts.send, @intFromPtr(dest.pixels.?), dest.pitch / 2, dest.height, middle.start, y, run, height, dma2d.pbyte_2);
    // The coverage block: any bytes of the buffer, a byte a pixel.
    dma2d.describe(parts.over, @intFromPtr(dest.pixels.?), dest.pitch, dest.height, middle.start, y, run, height, dma2d.pbyte_1);
    dma2d.describe(parts.receive, @intFromPtr(dest.pixels.?), dest.pitch / 2, dest.height, middle.start, y, run, height, dma2d.pbyte_2);
    const asleep = engine_file.prepare(engine, sys, watched);
    run3(parts);
    ppa.blend(.{ .cm = ppa.cm_a8, .coverage = .replace, .fixed = coverage, .color = color }, run, height);

    colorByCpu(dest, x, middle.start, y, height, color);
    colorByCpu(dest, middle.end, x + width, y, height, color);

    const done = engine_file.wait(engine, sys, asleep);
    engine_file.forget(sys, dest, middle, y, height);
    // As for a picture: the middle by the CPU where the engine did not
    // end it.
    if (!done) colorByCpu(dest, middle.start, middle.end, y, height, color);
    return err.RTGERR_OK;
}

/// The two send channels and the receive channel joined to the unit.
fn connect() bool {
    if (!dma2d.connectOut(engine_file.send_channel, dma2d.peri_ppa_blend)) return false;
    if (!dma2d.connectOut(engine_file.over_channel, dma2d.peri_ppa_blend_over)) return false;
    return dma2d.connectIn(engine_file.receive_channel, dma2d.peri_ppa_blend, .{});
}

fn run3(parts: engine_file.Descriptors) void {
    dma2d.runOut(engine_file.send_channel, parts.send_at);
    dma2d.runOut(engine_file.over_channel, parts.over_at);
    dma2d.runIn(engine_file.receive_channel, parts.receive_at);
}

/// 0xAARRGGBB cut to RGB565.
fn pack565(color: u32) u32 {
    return (color >> 19 & 0x1F) << 11 | (color >> 10 & 0x3F) << 5 | (color >> 3 & 0x1F);
}

/// `pen` (0xAARRGGBB) mixed into the RGB565 pixel `under` by `coverage`.
fn mix(under: u16, pen: u32, coverage: u32) u16 {
    if (coverage == 0) return under;
    if (coverage >= 255) return @intCast(pack565(pen));
    const red: u32 = under >> 11 & 0x1F;
    const green: u32 = under >> 5 & 0x3F;
    const blue: u32 = under & 0x1F;
    const was = [3]u32{ red << 3 | red >> 2, green << 2 | green >> 4, blue << 3 | blue >> 2 };
    const new = [3]u32{ pen >> 16 & 0xFF, pen >> 8 & 0xFF, pen & 0xFF };
    var mixed: u32 = 0;
    for (was, new, 0..) |before, after, index| {
        const channel = (after * coverage + before * (255 - coverage) + 127) / 255;
        mixed |= channel << @intCast(16 - index * 8);
    }
    return @intCast(pack565(mixed));
}

/// A picture's pixel as 0xAARRGGBB; one without coverage covers fully.
fn penAt(at: [*]const u8, source: Source) u32 {
    var pen: u32 = switch (source.bytes) {
        4 => @as(u32, at[0]) | @as(u32, at[1]) << 8 | @as(u32, at[2]) << 16 | @as(u32, at[3]) << 24,
        3 => 0xFF00_0000 | @as(u32, at[0]) | @as(u32, at[1]) << 8 | @as(u32, at[2]) << 16,
        else => blk: {
            const value = @as(u32, at[0]) | @as(u32, at[1]) << 8;
            const red = value >> 11 & 0x1F;
            const green = value >> 5 & 0x3F;
            const blue = value & 0x1F;
            break :blk 0xFF00_0000 | (red << 3 | red >> 2) << 16 | (green << 2 | green >> 4) << 8 | (blue << 3 | blue >> 2);
        },
    };
    if (source.swap) pen = (pen & 0xFF00_FF00) | (pen >> 16 & 0xFF) | (pen & 0xFF) << 16;
    return pen;
}

/// Columns `from` to `to` of rows `y` to `y + rows` mixed with the
/// picture, by the CPU; the picture's column `column` lands on the
/// buffer's column `left`.
fn layByCpu(dest: *const rtg.RtgBitMap, from: u32, to: u32, y: u32, rows: u32, picture: Picture, left: u32) void {
    if (to <= from) return;
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        const out: [*]u16 = @ptrFromInt(engine_file.rowAddress(dest, from, y + row));
        const in: [*]const u8 = @ptrFromInt(picture.first_row + @as(usize, row) * picture.pitch +
            @as(usize, picture.column + (from - left)) * picture.source.bytes);
        for (0..to - from) |index| {
            const pen = penAt(in + index * picture.source.bytes, picture.source);
            const coverage = if (!picture.source.covered or picture.whole) picture.alpha else if (picture.alpha < 255) (pen >> 24) * picture.alpha >> 8 else pen >> 24;
            out[index] = mix(out[index], pen, coverage);
        }
    }
}

/// Columns `from` to `to` of rows `y` to `y + rows` mixed with `color`
/// by its alpha, by the CPU.
fn colorByCpu(dest: *const rtg.RtgBitMap, from: u32, to: u32, y: u32, rows: u32, color: u32) void {
    if (to <= from) return;
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        const out: [*]u16 = @ptrFromInt(engine_file.rowAddress(dest, from, y + row));
        for (0..to - from) |index| out[index] = mix(out[index], color, color >> 24);
    }
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// The CPU's mixing, which is the ragged ends of every job and the whole
// middle of one the engine does not end. `pictureOf` and `sourceOf` are
// not among them: their limits are the 2D-DMA's fields and modes and the
// chip's memory map, which a host build does not have.

const testing = @import("std").testing;

test "a pixel mixed by its coverage: none, all, and a half rounded" {
    try testing.expectEqual(@as(u32, 0xF800), pack565(0x00FF0000));
    try testing.expectEqual(@as(u32, 0x07E0), pack565(0x0000FF00));
    try testing.expectEqual(@as(u32, 0x001F), pack565(0x000000FF));
    try testing.expectEqual(@as(u16, 0x1234), mix(0x1234, 0xFFFF_FFFF, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), mix(0x1234, 0x00FF_FFFF, 255));
    // White at 128 over black is the half; over that half again it is
    // three quarters - what a rectangle laid twice would show.
    try testing.expectEqual(@as(u16, 0x8410), mix(0x0000, 0x00FF_FFFF, 128));
    try testing.expectEqual(@as(u16, 0xC618), mix(0x8410, 0x00FF_FFFF, 128));
    // To the nearest: blue 15 at 128 is 7.53, which is 8 and cuts to 1;
    // blue 12 at 153 is 7.2, which is 7 and cuts to 0.
    try testing.expectEqual(@as(u16, 0x0001), mix(0x0000, 0x0000_000F, 128));
    try testing.expectEqual(@as(u16, 0x0000), mix(0x0000, 0x0000_000C, 153));
    // The pixel under it is widened to eight bits by repeating its high
    // bits: white stays white under a pen that all but leaves it.
    try testing.expectEqual(@as(u16, 0xFFFF), mix(0xFFFF, 0x0000_0000, 1));
}

test "a picture's pixel as the mixing takes it, from each format" {
    const covered = Source{ .cm = 0, .bytes = 4, .pbyte = 0, .covered = true };
    const three = Source{ .cm = 0, .bytes = 3, .pbyte = 0 };
    const swapped = Source{ .cm = 0, .swap = true, .bytes = 3, .pbyte = 0 };
    const two = Source{ .cm = 0, .bytes = 2, .pbyte = 0 };
    try testing.expectEqual(@as(u32, 0x80112233), penAt(&[_]u8{ 0x33, 0x22, 0x11, 0x80 }, covered));
    try testing.expectEqual(@as(u32, 0xFF112233), penAt(&[_]u8{ 0x33, 0x22, 0x11 }, three));
    try testing.expectEqual(@as(u32, 0xFF332211), penAt(&[_]u8{ 0x33, 0x22, 0x11 }, swapped));
    // RGB565's red widened to eight bits by repeating its high bits.
    try testing.expectEqual(@as(u32, 0xFFFF0000), penAt(&[_]u8{ 0x00, 0xF8 }, two));
}

test "the CPU's ends and its middle lay a rectangle once, and nothing beside it" {
    // Four rows of 96 pixels, black; a picture of white at half coverage,
    // laid on rows 1 and 2.
    var pixels: [4 * 96]u16 align(64) = @splat(0);
    var picture_pixels: [2 * 96]u32 align(4) = @splat(0x80FF_FFFF);
    const dest = rtg.RtgBitMap{ .pixels = @ptrCast(&pixels), .width = 96, .height = 4, .pitch = 192, .size_bytes = 4 * 192, .format = .rgb565 };
    const picture = Picture{
        .first_row = @intFromPtr(&picture_pixels),
        .pitch = 96 * 4,
        .width = 96,
        .column = 0,
        .source = .{ .cm = 0, .bytes = 4, .pbyte = 0, .covered = true },
        .alpha = 255,
    };
    // Columns 5 to 85: the engine's part is 32 to 64, the CPU's the two
    // ends - and, where the engine does not end its job, that part too.
    const x = 5;
    const width = 80;
    const y = 1;
    const rows = 2;
    const middle = engine_file.middleOf(x, width);
    try testing.expectEqual(engine_file.Middle{ .start = 32, .end = 64 }, middle);
    layByCpu(&dest, x, middle.start, y, rows, picture, x);
    layByCpu(&dest, middle.end, x + width, y, rows, picture, x);
    layByCpu(&dest, middle.start, middle.end, y, rows, picture, x);
    for (0..4) |row| for (0..96) |column| {
        const inside = row >= y and row < y + rows and column >= x and column < x + width;
        try testing.expectEqual(@as(u16, if (inside) 0x8410 else 0), pixels[row * 96 + column]);
    };

    // The same for a colour: 0x80 of white.
    @memset(&pixels, 0);
    colorByCpu(&dest, x, middle.start, y, rows, 0x80FF_FFFF);
    colorByCpu(&dest, middle.end, x + width, y, rows, 0x80FF_FFFF);
    colorByCpu(&dest, middle.start, middle.end, y, rows, 0x80FF_FFFF);
    for (0..4) |row| for (0..96) |column| {
        const inside = row >= y and row < y + rows and column >= x and column < x + width;
        try testing.expectEqual(@as(u16, if (inside) 0x8410 else 0), pixels[row * 96 + column]);
    };

    // Which pixel of the picture lands where: a picture whose blue rises
    // along a row and from row to row, its column 3 on the rectangle's
    // left edge. The middle starts 27 columns in, so the buffer's column
    // 32 shows the picture's column 30, of its first row and its second.
    @memset(&pixels, 0);
    for (&picture_pixels, 0..) |*pixel, index| {
        const column: u32 = @intCast(index % 96);
        const row: u32 = @intCast(index / 96);
        pixel.* = 0xFF00_0000 | ((column + 7 * row) % 32) << 3;
    }
    var moved = picture;
    moved.column = 3;
    layByCpu(&dest, middle.start, middle.end, y, rows, moved, x);
    try testing.expectEqual(@as(u16, 30), pixels[1 * 96 + 32]);
    try testing.expectEqual(@as(u16, 5), pixels[2 * 96 + 32]);
    try testing.expectEqual(@as(u16, 4), pixels[2 * 96 + 63]);
    for (0..4) |row| for (0..96) |column| {
        const inside = row >= y and row < y + rows and column >= middle.start and column < middle.end;
        if (!inside) try testing.expectEqual(@as(u16, 0), pixels[row * 96 + column]);
    };
}

test "what a picture's pixel covers: its own coverage, the constant alpha, or the two together" {
    // One pixel of white over black, from each kind of picture.
    var under: [1]u16 align(64) = .{0};
    const dest = rtg.RtgBitMap{ .pixels = @ptrCast(&under), .width = 1, .height = 1, .pitch = 2, .size_bytes = 2, .format = .rgb565 };
    const covered = Source{ .cm = 0, .bytes = 4, .pbyte = 0, .covered = true };
    const full = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    const none = [_]u8{ 0xFF, 0xFF, 0xFF, 0x00 };

    // Its own coverage under a constant alpha: 255 by 128 is 127.
    layByCpu(&dest, 0, 1, 0, 1, .{ .first_row = @intFromPtr(&full), .pitch = 4, .width = 1, .column = 0, .source = covered, .alpha = 128 }, 0);
    try testing.expectEqual(@as(u16, 0x7BEF), under[0]);
    // Its coverage not read: the constant alpha alone, whatever the
    // pixel says.
    under[0] = 0;
    layByCpu(&dest, 0, 1, 0, 1, .{ .first_row = @intFromPtr(&none), .pitch = 4, .width = 1, .column = 0, .source = covered, .alpha = 128, .whole = true }, 0);
    try testing.expectEqual(@as(u16, 0x8410), under[0]);
    // A format without coverage: the constant alpha alone.
    under[0] = 0;
    layByCpu(&dest, 0, 1, 0, 1, .{ .first_row = @intFromPtr(&full), .pitch = 3, .width = 1, .column = 0, .source = .{ .cm = 0, .bytes = 3, .pbyte = 0 }, .alpha = 128 }, 0);
    try testing.expectEqual(@as(u16, 0x8410), under[0]);
    // No constant alpha: its own coverage alone, and none leaves the
    // pixel under it.
    under[0] = 0x1234;
    layByCpu(&dest, 0, 1, 0, 1, .{ .first_row = @intFromPtr(&none), .pitch = 4, .width = 1, .column = 0, .source = covered, .alpha = 255 }, 0);
    try testing.expectEqual(@as(u16, 0x1234), under[0]);
}

test "a picture that shares memory with the rectangle it is laid on is the CPU's" {
    // A buffer of 8 rows of 64 pixels; a picture of RGB565 read from its
    // own rows.
    var pixels: [8 * 64]u16 align(64) = @splat(0);
    const dest = rtg.RtgBitMap{ .pixels = @ptrCast(&pixels), .width = 64, .height = 8, .pitch = 128, .size_bytes = 8 * 128, .format = .rgb565 };
    const from_row = struct {
        fn at(buffer: *[8 * 64]u16, row: usize) Picture {
            return .{
                .first_row = @intFromPtr(buffer) + row * 128,
                .pitch = 128,
                .width = 64,
                .column = 0,
                .source = .{ .cm = 0, .bytes = 2, .pbyte = 0 },
                .alpha = 255,
            };
        }
    };
    const area = rtg.RtgRect{ .x = 0, .y = 4, .width = 64, .height = 2 };
    // Rows 4 and 5 laid from rows 3 and 4, or from 5 and 6: shared.
    try testing.expect(overlapsDest(&dest, &area, from_row.at(&pixels, 3)));
    try testing.expect(overlapsDest(&dest, &area, from_row.at(&pixels, 5)));
    // From rows 0 and 1, or 6 and 7: apart.
    try testing.expect(!overlapsDest(&dest, &area, from_row.at(&pixels, 0)));
    try testing.expect(!overlapsDest(&dest, &area, from_row.at(&pixels, 6)));
}

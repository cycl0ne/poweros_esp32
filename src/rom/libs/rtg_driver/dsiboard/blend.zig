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
const dma2d = @import("dma2d.zig");
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
    return .{ .first_row = @intCast(first_row), .pitch = pixels.pitch, .width = picture_width, .column = column, .source = source, .alpha = alpha };
}

/// What becomes of a picture's coverage in the unit.
fn overOf(picture: Picture) ppa.Over {
    var over = ppa.Over{ .cm = picture.source.cm, .swap = picture.source.swap };
    if (!picture.source.covered) {
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

    sys.ObtainSemaphore(&engine.lock);
    defer sys.ReleaseSemaphore(&engine.lock);
    return lay(engine, sys, dest, area, picture, watched);
}

/// A picture over the rectangle, by the engine and the CPU; by the CPU
/// alone when the engine would get no whole line. The engine's lock is
/// held.
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
    if (!connect()) return engine_file.failed(engine);
    dma2d.describe(parts.send, @intFromPtr(dest.pixels.?), dest.pitch / 2, dest.height, middle.start, y, run, height, dma2d.pbyte_2);
    dma2d.describe(parts.over, picture.first_row, picture.width, height, picture.column + (middle.start - x), 0, run, height, picture.source.pbyte);
    dma2d.describe(parts.receive, @intFromPtr(dest.pixels.?), dest.pitch / 2, dest.height, middle.start, y, run, height, dma2d.pbyte_2);
    const signal = engine_file.prepare(engine, sys, watched);
    run3(parts);
    ppa.blend(overOf(picture), run, height);

    layByCpu(dest, x, middle.start, y, height, picture, x);
    layByCpu(dest, middle.end, x + width, y, height, picture, x);

    const done = engine_file.wait(engine, sys, signal);
    engine_file.forget(sys, dest, middle, y, height);
    if (!done) return engine_file.failed(engine);
    engine.blends +%= 1;
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
    if (!connect()) return engine_file.failed(engine);
    dma2d.describe(parts.send, @intFromPtr(dest.pixels.?), dest.pitch / 2, dest.height, middle.start, y, run, height, dma2d.pbyte_2);
    // The coverage block: any bytes of the buffer, a byte a pixel.
    dma2d.describe(parts.over, @intFromPtr(dest.pixels.?), dest.pitch, dest.height, middle.start, y, run, height, dma2d.pbyte_1);
    dma2d.describe(parts.receive, @intFromPtr(dest.pixels.?), dest.pitch / 2, dest.height, middle.start, y, run, height, dma2d.pbyte_2);
    const signal = engine_file.prepare(engine, sys, watched);
    run3(parts);
    ppa.blend(.{ .cm = ppa.cm_a8, .coverage = .replace, .fixed = coverage, .color = color }, run, height);

    colorByCpu(dest, x, middle.start, y, height, color);
    colorByCpu(dest, middle.end, x + width, y, height, color);

    const done = engine_file.wait(engine, sys, signal);
    engine_file.forget(sys, dest, middle, y, height);
    if (!done) return engine_file.failed(engine);
    engine.blends +%= 1;
    return err.RTGERR_OK;
}

/// The two send channels and the receive channel joined to the unit.
fn connect() bool {
    if (!dma2d.connectOut(0, dma2d.peri_ppa_blend)) return false;
    if (!dma2d.connectOut(1, dma2d.peri_ppa_blend_over)) return false;
    return dma2d.connectIn(dma2d.peri_ppa_blend, false);
}

fn run3(parts: engine_file.Descriptors) void {
    dma2d.runOut(0, parts.send_at);
    dma2d.runOut(1, parts.over_at);
    dma2d.runIn(parts.receive_at);
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
            const coverage = if (!picture.source.covered) picture.alpha else if (picture.alpha < 255) (pen >> 24) * picture.alpha >> 8 else pen >> 24;
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

// SPDX-License-Identifier: MPL-2.0
//! A copy of what is shown, which the stream reads instead of the
//! screens: for an HDMI bridge always, and for a panel while something
//! lies over its picture - a pointer, a dragged icon - which the screens
//! never hold.
//!
//! The copy is the board's own picture, and rtg.library composes it: the
//! board is told which rectangle of the display changed (`update`), and
//! `fill` fetches that rectangle's pixels from the library
//! (`ComposeLines`) - the bands of the screens' buffers, the overlay and
//! the pointer over them - and puts them into the copy.
//!
//! An HDMI bridge takes only RGB888, beside screens drawn in RGB565 - and
//! this revision of the chip converts nothing on its way to the link - so
//! its copy is three bytes a pixel; a panel's is the screens' own RGB565.
//! Either is the size of the mode.
//!
//! **An RGB565 copy** is fetched into where it lies: the library's lines
//! go straight into the copy.
//!
//! **An RGB888 copy** has the picture twice: `composed`, the library's
//! lines in RGB565, and the copy the stream reads, which they are widened
//! into. A rectangle large enough for it is widened by the engine - a
//! 2D-DMA copy, rows of `composed` into rows of the copy, its send
//! channel widening RGB565 to RGB888 as it reads - under the engine's
//! semaphore and on its channels; a small one, and any the engine does
//! not end, by the CPU (`put`).
//!
//! **The CPU writes the copy through the data cache**, and every write
//! into the copy is made holding the board's compose lock, which
//! `update` and `show` are called with. Before the CPU lets go of it,
//! the lines it wrote are written back and dropped from the cache
//! (`writeOut`), so none is left there to be written back later over
//! what the engine widened into it since. Through the cache, a rectangle
//! reaches memory a line at a time; a pixel at a time past it, every byte
//! was a transaction of its own with the stream, and dragging an icon
//! starved it.
//!
//! Both pictures are in PSRAM (`MEMF_EXTERNAL`): a frame is far more
//! than internal memory has to give, and the stream's channel and the
//! engine read PSRAM past the cache.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const err = rtg.errors;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;
const dma2d = sdk.hardware.dma2d;
const engine_file = @import("engine.zig");
const Engine = engine_file.Engine;

/// A rectangle of the copy: columns `x0` to `x1`, lines `y0` to `y1`, the
/// ends not in it.
pub const Rect = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

pub const Link = struct {
    /// The copy: `width` x `height` pixels of `format` - `bgr24` or
    /// `rgb565` - its rows `pitch` apart, on a cache line; the block it
    /// is in. No copy while `pixels` is 0.
    pixels: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0,
    format: rtg.PixelFormat = .bgr24,
    memory: ?*anyopaque = null,
    memory_size: u32 = 0,
    /// The copy as a buffer, for the stream's chain.
    whole: rtg.RtgBitMap = .{},
    /// Beside an RGB888 copy: the picture as the library composes it, in
    /// RGB565, the size of the mode, its rows whole cache lines apart -
    /// what is widened into the copy - and the block it is in. An RGB565
    /// copy is that picture itself, and has none.
    composed: rtg.RtgBitMap = .{},
    composed_memory: ?*anyopaque = null,
    composed_size: u32 = 0,
    /// Rows put into the copy by the engine and by the CPU.
    engine_rows: u32 = 0,
    cpu_rows: u32 = 0,
};

/// The copy for a mode `width` x `height`, in `format` (`bgr24` or
/// `rgb565`), and beside an RGB888 one the picture it is widened from;
/// false without memory. What is in it is whatever the memory held: the
/// show that follows fills all of it.
pub fn allocate(link: *Link, sys: *ExecBase, width: u32, height: u32, format: rtg.PixelFormat) bool {
    const line = sdk.hardware.DCACHE_LINE_SIZE;
    const pitch = width * @as(u32, if (format == .rgb565) 2 else 3);
    const size = pitch * height + line;
    const memory = sys.AllocMem(size, exec.MEMF_EXTERNAL) orelse return false;
    const pixels = (@intFromPtr(memory) + line - 1) & ~@as(usize, line - 1);
    link.* = .{ .pixels = pixels, .width = width, .height = height, .pitch = pitch, .format = format, .memory = memory, .memory_size = size };
    link.whole = .{ .width = width, .height = height, .pitch = pitch, .format = format, .pixels = @ptrFromInt(pixels) };
    if (format == .rgb565) return true;

    const composed_pitch = (width * 2 + line - 1) / line * line;
    const composed_size = composed_pitch * height + line;
    const composed_memory = sys.AllocMem(composed_size, exec.MEMF_EXTERNAL) orelse {
        free(link, sys);
        return false;
    };
    const composed_pixels = (@intFromPtr(composed_memory) + line - 1) & ~@as(usize, line - 1);
    link.composed = .{ .width = width, .height = height, .pitch = composed_pitch, .format = .rgb565, .pixels = @ptrFromInt(composed_pixels) };
    link.composed_memory = composed_memory;
    link.composed_size = composed_size;
    return true;
}

pub fn free(link: *Link, sys: *ExecBase) void {
    if (link.memory) |memory| sys.FreeMem(memory, link.memory_size);
    if (link.composed_memory) |memory| sys.FreeMem(memory, link.composed_size);
    link.* = .{};
}

/// A rectangle of the display changed: its pixels fetched from the
/// library, as they are to be seen, and put into the copy.
///
/// INPUTS:
/// - `link` - the copy.
/// - `engine` - the board's engine, which widens into an RGB888 copy.
/// - `sys` - exec.
/// - `board` - the board, whose picture the library composes; its
///   compose lock is held.
/// - `area` - the rectangle, inside the display.
/// - `watched` - the stream runs, and its frames time the engine.
///
/// RESULT:
/// RTGERR_OK, RTGERR_NO_MEMORY on a board with no copy, or what
/// `ComposeLines` answered.
pub fn fill(link: *Link, engine: *Engine, sys: *ExecBase, board: *rtg.RtgBoard, area: *const rtg.RtgRect, watched: bool) i32 {
    if (link.pixels == 0) return err.RTGERR_NO_MEMORY;
    const rb: *RtgDriverBase = @ptrCast(board.rtg_base.?);
    const x: u32 = @intCast(area.x);
    const y: u32 = @intCast(area.y);
    const width: u32 = @intCast(area.width);
    const rows: u32 = @intCast(area.height);
    const picture = if (link.format == .rgb565) &link.whole else &link.composed;
    const first: [*]u8 = picture.pixels.? + @as(usize, y) * picture.pitch + @as(usize, x) * 2;
    const code = rb.ComposeLines(board, area, first, picture.pitch);
    if (code != err.RTGERR_OK) return code;
    if (link.format == .rgb565) {
        // Where it lies: out of the cache, for the stream to read.
        writeOut(link, sys, .{ .x0 = x, .y0 = y, .x1 = x + width, .y1 = y + rows });
        link.cpu_rows +%= rows;
        return err.RTGERR_OK;
    }
    sys.ObtainSemaphore(&engine.lock);
    defer sys.ReleaseSemaphore(&engine.lock);
    widen(link, engine, sys, x, y, width, rows, watched);
    return err.RTGERR_OK;
}

/// A rectangle of `composed` widened into the copy: by the engine where
/// it is large enough to be worth setting a job up for, by the CPU where
/// it is not, or the engine does not end it. The engine's semaphore is
/// held.
fn widen(link: *Link, engine: *Engine, sys: *ExecBase, x: u32, y: u32, width: u32, rows: u32, watched: bool) void {
    if (width * rows >= engine.smallest) {
        // What the CPU composed, out of the cache for the engine to read:
        // from the rectangle's first pixel to its last.
        const first = @intFromPtr(link.composed.pixels.?) + @as(usize, y) * link.composed.pitch + @as(usize, x) * 2;
        var bytes: u32 = (rows - 1) * link.composed.pitch + width * 2;
        _ = sys.CachePreDMA(@ptrFromInt(first), &bytes, 0);
        if (byEngine(link, engine, sys, &link.composed, y, y, rows, x, width, watched)) {
            link.engine_rows +%= rows;
            return;
        }
    }
    byCpu(link, &link.composed, y, y, rows, x, width);
    writeOut(link, sys, .{ .x0 = x, .y0 = y, .x1 = x + width, .y1 = y + rows });
    link.cpu_rows +%= rows;
}

fn byEngine(link: *Link, engine: *Engine, sys: *ExecBase, source: *const rtg.RtgBitMap, row: u32, line: u32, rows: u32, x: u32, width: u32, watched: bool) bool {
    if (!engine.ready or source.format != .rgb565 or source.pixels == null) return false;
    if (source.pitch % 2 != 0 or source.pitch / 2 > dma2d.field_max) return false;
    const parts = engine_file.descriptors(engine);
    if (!dma2d.connectOut(engine_file.send_channel, dma2d.peri_memory_out)) return false;
    const wide = link.format == .bgr24;
    if (wide) dma2d.convertOut(engine_file.send_channel, .rgb565_to_rgb888);
    if (!dma2d.connectIn(engine_file.receive_channel, dma2d.peri_memory_in, .{ .sibling = true })) return false;
    dma2d.describe(parts.send, @intFromPtr(source.pixels.?), source.pitch / 2, source.height, x, row, width, rows, dma2d.pbyte_2);
    dma2d.describe(parts.receive, link.pixels, link.width, link.height, x, line, width, rows, if (wide) dma2d.pbyte_3 else dma2d.pbyte_2);
    const asleep = engine_file.prepare(engine, sys, watched);
    dma2d.runOut(engine_file.send_channel, parts.send_at);
    dma2d.runIn(engine_file.receive_channel, parts.receive_at);
    return engine_file.wait(engine, sys, asleep);
}

/// The CPU's conversion, through the data cache; `widen` writes it
/// out.
fn byCpu(link: *Link, source: *const rtg.RtgBitMap, row: u32, line: u32, rows: u32, x: u32, width: u32) void {
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        const from: [*]const u16 = @ptrFromInt(@intFromPtr(source.pixels.?) + @as(usize, row + r) * source.pitch);
        put(link, line + r, x, from + x, width);
    }
}

/// `count` RGB565 pixels from `from` into the copy at column `x` of line
/// `line`, through the data cache: as they are into an RGB565 copy,
/// widened blue first - as the engine writes them - into an RGB888 one.
/// The caller keeps them inside the copy and calls `writeOut` for them
/// before it lets go of the board's compose lock.
fn put(link: *const Link, line: u32, x: u32, from: [*]const u16, count: u32) void {
    const row = link.pixels + @as(usize, line) * link.pitch;
    if (link.format == .rgb565) {
        const to: [*]u16 = @ptrFromInt(row + @as(usize, x) * 2);
        @memcpy(to[0..count], from[0..count]);
        return;
    }
    const to: [*]u8 = @ptrFromInt(row + @as(usize, x) * 3);
    var at: u32 = 0;
    while (at < count) : (at += 1) {
        const pixel = from[at];
        const red: u8 = @truncate(pixel >> 11);
        const green: u8 = @truncate((pixel >> 5) & 0x3F);
        const blue: u8 = @truncate(pixel & 0x1F);
        to[at * 3] = blue << 3 | blue >> 2;
        to[at * 3 + 1] = green << 2 | green >> 4;
        to[at * 3 + 2] = red << 3 | red >> 2;
    }
}

/// The lines of the copy under `area`, which the CPU wrote, written back
/// to memory and dropped from the data cache: row by row, each row's
/// stretch rounded out to whole lines - only the copy's own bytes are in
/// them, and nothing else writes the copy while the board's compose lock
/// is held - but never past the copy's end.
fn writeOut(link: *const Link, sys: *ExecBase, area: Rect) void {
    const line_size = sdk.hardware.DCACHE_LINE_SIZE;
    const bytes_per_pixel: usize = if (link.format == .rgb565) 2 else 3;
    const copy_end = link.pixels + @as(usize, link.pitch) * link.height;
    var y = area.y0;
    while (y < area.y1) : (y += 1) {
        const row = link.pixels + @as(usize, y) * link.pitch;
        const start = (row + area.x0 * bytes_per_pixel) & ~@as(usize, line_size - 1);
        const end = @min((row + area.x1 * bytes_per_pixel + line_size - 1) & ~@as(usize, line_size - 1), copy_end);
        sys.CacheClearE(@ptrFromInt(start), @intCast(end - start), exec.CACRF_ClearD);
    }
}

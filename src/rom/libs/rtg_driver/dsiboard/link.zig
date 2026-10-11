// SPDX-License-Identifier: MPL-2.0
//! The picture an HDMI bridge is sent: RGB888, which is all the bridge
//! takes, beside screens drawn in RGB565 - and this revision of the chip
//! converts nothing on its way to the link.
//!
//! So the board keeps a copy of what is shown, three bytes a pixel, the
//! size of the mode, and the stream reads that copy instead of the
//! screens. What is shown is still bands of the screens' buffers; showing
//! them converts each band's rows into the copy, at the lines it covers,
//! and from then on rows a caller has drawn (RefreshBitMap) are converted
//! again wherever a band shows them. A band that repeats a buffer's first
//! row has that row converted once, at its first line, and the stream
//! sends that line again for each of its lines - its chain is built over
//! the copy as it would be over the buffers (`streamBands`).
//!
//! **The conversion** is the engine's: a 2D-DMA copy whose send channel
//! widens RGB565 to RGB888 as it reads, rows of the buffer into rows of
//! the copy, under the engine's semaphore and on its channels. Without
//! the engine the CPU converts, writing the copy through its uncached
//! view. The CPU never reads the copy, and writes it only uncached, so no
//! line of it is ever dirty in the data cache to be written over the
//! engine's work.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const ExecBase = sdk.interface.exec.ExecBase;
const dma2d = sdk.hardware.dma2d;
const engine_file = @import("engine.zig");
const Engine = engine_file.Engine;

/// From an address in PSRAM to the same bytes past the data cache.
const uncached_offset: usize = 0x4000_0000;

pub const Link = struct {
    /// The copy: `width` x `height` pixels of three bytes, its rows
    /// `pitch` apart, on a cache line; the block it is in.
    pixels: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0,
    memory: ?*anyopaque = null,
    memory_size: u32 = 0,
    /// The bands shown, as the screens' buffers give them.
    shown: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined,
    shown_count: u32 = 0,
    /// The copy as a buffer, for the stream's chain, and a buffer a row
    /// long at each repeated band's line.
    whole: rtg.RtgBitMap = .{},
    rows: [rtg.RTG_MAX_BANDS]rtg.RtgBitMap = @splat(.{}),
    /// Rows converted, by the engine and by the CPU.
    engine_rows: u32 = 0,
    cpu_rows: u32 = 0,
};

/// The copy for a mode `width` x `height`, black; false without memory.
pub fn allocate(link: *Link, sys: *ExecBase, width: u32, height: u32) bool {
    const line = sdk.hardware.DCACHE_LINE_SIZE;
    const pitch = width * 3;
    const bytes = pitch * height;
    const size = bytes + line;
    const memory = sys.AllocMem(size, exec.MEMF_EXTERNAL) orelse return false;
    const pixels = (@intFromPtr(memory) + line - 1) & ~@as(usize, line - 1);
    link.* = .{ .pixels = pixels, .width = width, .height = height, .pitch = pitch, .memory = memory, .memory_size = size };
    // Black, written past the cache, and none of it left in the cache.
    var cleared: u32 = bytes;
    _ = sys.CachePreDMA(@ptrFromInt(pixels), &cleared, 0);
    sys.CachePostDMA(@ptrFromInt(pixels), &cleared, 0);
    const words: [*]volatile u32 = @ptrFromInt(pixels + uncached_offset);
    var at: usize = 0;
    while (at < bytes / 4) : (at += 1) words[at] = 0;
    link.whole = .{ .width = width, .height = height, .pitch = pitch, .format = .bgr24, .pixels = @ptrFromInt(pixels) };
    return true;
}

pub fn free(link: *Link, sys: *ExecBase) void {
    if (link.memory) |memory| sys.FreeMem(memory, link.memory_size);
    link.* = .{};
}

/// The display lines band `index` of `bands` covers: from its line to
/// the next band's, the last to the bottom.
fn endOf(bands: []const rtg.RtgBand, index: usize, height: u32) u32 {
    return if (index + 1 < bands.len) bands[index + 1].line else height;
}

/// `bands` shown: every band's rows converted into the copy, and the
/// bands the stream is to send in their place written into `into` - the
/// copy's own lines, a repeated band's one line again. How many.
/// `watched`: the stream runs, and its frames time the engine.
pub fn show(link: *Link, engine: *Engine, sys: *ExecBase, bands: []const rtg.RtgBand, watched: bool, into: *[rtg.RTG_MAX_BANDS]rtg.RtgBand) u32 {
    sys.ObtainSemaphore(&engine.lock);
    defer sys.ReleaseSemaphore(&engine.lock);
    const count: u32 = @intCast(@min(bands.len, rtg.RTG_MAX_BANDS));
    for (bands[0..count], 0..) |band, index| link.shown[index] = band;
    link.shown_count = count;
    for (link.shown[0..count], 0..) |band, index| {
        const end = endOf(link.shown[0..count], index, link.height);
        if (band.flags & rtg.RTGBANDF_REPEAT != 0) {
            if (end > band.line) convert(link, engine, sys, band.bitmap, 0, band.line, 1, watched);
            link.rows[index] = link.whole;
            link.rows[index].pixels = @ptrFromInt(link.pixels + @as(usize, band.line) * link.pitch);
            link.rows[index].height = 1;
            into[index] = .{ .bitmap = &link.rows[index], .line = band.line, .flags = rtg.RTGBANDF_REPEAT };
        } else {
            if (end > band.line) convert(link, engine, sys, band.bitmap, band.rowAt(band.line), band.line, end - band.line, watched);
            into[index] = .{ .bitmap = &link.whole, .line = band.line, .origin = 0 };
        }
    }
    return count;
}

/// Rows `y` to `y + rows` of `bitmap` were drawn: converted again
/// wherever a band shows them.
pub fn refresh(link: *Link, engine: *Engine, sys: *ExecBase, bitmap: *const rtg.RtgBitMap, y: u32, rows: u32, watched: bool) void {
    sys.ObtainSemaphore(&engine.lock);
    defer sys.ReleaseSemaphore(&engine.lock);
    const shown = link.shown[0..link.shown_count];
    for (shown, 0..) |band, index| {
        if (band.bitmap != bitmap) continue;
        const end = endOf(shown, index, link.height);
        if (end <= band.line) continue;
        if (band.flags & rtg.RTGBANDF_REPEAT != 0) {
            if (y == 0) convert(link, engine, sys, bitmap, 0, band.line, 1, watched);
            continue;
        }
        // The band's rows, and the part of them drawn.
        const first_row = band.rowAt(band.line);
        const end_row = first_row + (end - band.line);
        const from = @max(first_row, y);
        const to = @min(end_row, y + rows);
        if (to <= from) continue;
        convert(link, engine, sys, bitmap, from, from + band.origin, to - from, watched);
    }
}

/// `rows` rows of `source` from `row` on converted into the copy from
/// display line `line` on: by the engine, or by the CPU when it cannot.
/// The engine's semaphore is held.
fn convert(link: *Link, engine: *Engine, sys: *ExecBase, source: *const rtg.RtgBitMap, row: u32, line: u32, rows: u32, watched: bool) void {
    if (rows == 0 or line >= link.height) return;
    const count = @min(rows, link.height - line, source.height - @min(row, source.height));
    if (count == 0) return;
    if (byEngine(link, engine, sys, source, row, line, count, watched)) {
        link.engine_rows +%= count;
        return;
    }
    byCpu(link, source, row, line, count);
    link.cpu_rows +%= count;
}

fn byEngine(link: *Link, engine: *Engine, sys: *ExecBase, source: *const rtg.RtgBitMap, row: u32, line: u32, rows: u32, watched: bool) bool {
    if (!engine.ready or source.format != .rgb565 or source.pixels == null) return false;
    if (source.pitch % 2 != 0 or source.pitch / 2 > dma2d.field_max) return false;
    const parts = engine_file.descriptors(engine);
    if (!dma2d.connectOut(engine_file.send_channel, dma2d.peri_memory_out)) return false;
    dma2d.convertOut(engine_file.send_channel, .rgb565_to_rgb888);
    if (!dma2d.connectIn(engine_file.receive_channel, dma2d.peri_memory_in, .{ .sibling = true })) return false;
    const width = @min(link.width, source.width);
    dma2d.describe(parts.send, @intFromPtr(source.pixels.?), source.pitch / 2, source.height, 0, row, width, rows, dma2d.pbyte_2);
    dma2d.describe(parts.receive, link.pixels, link.width, link.height, 0, line, width, rows, dma2d.pbyte_3);
    const signal = engine_file.prepare(engine, sys, watched);
    dma2d.runOut(engine_file.send_channel, parts.send_at);
    dma2d.runIn(engine_file.receive_channel, parts.receive_at);
    return engine_file.wait(engine, sys, signal);
}

/// The CPU's conversion, blue first as the engine writes it, through the
/// copy's uncached view.
fn byCpu(link: *Link, source: *const rtg.RtgBitMap, row: u32, line: u32, rows: u32) void {
    const width = @min(link.width, source.width);
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        const from: [*]const u16 = @ptrFromInt(@intFromPtr(source.pixels.?) + @as(usize, row + r) * source.pitch);
        const to: [*]volatile u8 = @ptrFromInt(link.pixels + uncached_offset + @as(usize, line + r) * link.pitch);
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const pixel = from[x];
            const red: u8 = @truncate(pixel >> 11);
            const green: u8 = @truncate((pixel >> 5) & 0x3F);
            const blue: u8 = @truncate(pixel & 0x1F);
            to[x * 3] = blue << 3 | blue >> 2;
            to[x * 3 + 1] = green << 2 | green >> 4;
            to[x * 3 + 2] = red << 3 | red >> 2;
        }
    }
}

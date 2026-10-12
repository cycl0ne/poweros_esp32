// SPDX-License-Identifier: MPL-2.0
//! A copy of what is shown, which the stream reads instead of the
//! screens: for an HDMI bridge always, and for a panel once a pointer
//! is laid over the picture (`pointer.zig`), which the screens never
//! hold.
//!
//! An HDMI bridge takes only RGB888, beside screens drawn in RGB565 - and
//! this revision of the chip converts nothing on its way to the link - so
//! its copy is three bytes a pixel; a panel's is the screens' own RGB565.
//! Either is the size of the mode. What is shown is still bands of the
//! screens' buffers; showing
//! them converts each band's rows into the copy, at the lines it covers,
//! and from then on rows a caller has drawn (RefreshBitMap) are converted
//! again wherever a band shows them.
//!
//! **A band that repeats a row** - the empty part of the display above a
//! screen pulled down - goes into the copy as lines of its own, so what
//! is laid over it shows there too: it is converted from `blank`, a
//! picture the size of the mode whose every row is that row, filled when
//! the row first comes and again only when it changes. Without memory for
//! it the row is converted once, at the band's first line, and the stream
//! sends that line again for each of the band's lines - and the pointer
//! does not show over it.
//!
//! **A rectangle kept out.** `show` and `refresh` take the pointer's
//! rectangle (`pointer.zig`) and convert around it, never into it, so
//! what is laid there stays while the rows about it change; the pointer's
//! side then fills it from the screens and lays the pointer again.
//!
//! **The conversion** is the engine's: a 2D-DMA copy, rows of the buffer
//! into rows of the copy - its send channel widening RGB565 to RGB888 as
//! it reads, for an RGB888 copy - under the engine's semaphore and on its
//! channels. Without the engine the CPU converts, writing the copy
//! through its uncached view. The CPU never reads the copy, and writes it
//! only uncached (`put`, which the pointer's pixels go through too), so
//! no line of it is ever dirty in the data cache to be written over the
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
    /// The bands shown, as the screens' buffers give them.
    shown: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined,
    shown_count: u32 = 0,
    /// The copy as a buffer, for the stream's chain, and a buffer a row
    /// long at each repeated band's line.
    whole: rtg.RtgBitMap = .{},
    rows: [rtg.RTG_MAX_BANDS]rtg.RtgBitMap = @splat(.{}),
    /// The repeated row as a whole picture, in RGB565, and the block it
    /// is in; no picture while `blank.pixels` is null. `blank_filled`:
    /// its rows hold a row yet.
    blank: rtg.RtgBitMap = .{},
    blank_memory: ?*anyopaque = null,
    blank_size: u32 = 0,
    blank_filled: bool = false,
    /// Rows converted, by the engine and by the CPU.
    engine_rows: u32 = 0,
    cpu_rows: u32 = 0,
};

/// The copy for a mode `width` x `height`, in `format` (`bgr24` or
/// `rgb565`), black; false without memory.
pub fn allocate(link: *Link, sys: *ExecBase, width: u32, height: u32, format: rtg.PixelFormat) bool {
    const line = sdk.hardware.DCACHE_LINE_SIZE;
    const pitch = width * @as(u32, if (format == .rgb565) 2 else 3);
    const bytes = pitch * height;
    const size = bytes + line;
    const memory = sys.AllocMem(size, exec.MEMF_EXTERNAL) orelse return false;
    const pixels = (@intFromPtr(memory) + line - 1) & ~@as(usize, line - 1);
    link.* = .{ .pixels = pixels, .width = width, .height = height, .pitch = pitch, .format = format, .memory = memory, .memory_size = size };
    // Black, written past the cache, and none of it left in the cache.
    var cleared: u32 = bytes;
    _ = sys.CachePreDMA(@ptrFromInt(pixels), &cleared, 0);
    sys.CachePostDMA(@ptrFromInt(pixels), &cleared, 0);
    const words: [*]volatile u32 = @ptrFromInt(pixels + uncached_offset);
    var at: usize = 0;
    while (at < bytes / 4) : (at += 1) words[at] = 0;
    link.whole = .{ .width = width, .height = height, .pitch = pitch, .format = format, .pixels = @ptrFromInt(pixels) };
    return true;
}

pub fn free(link: *Link, sys: *ExecBase) void {
    if (link.memory) |memory| sys.FreeMem(memory, link.memory_size);
    if (link.blank_memory) |memory| sys.FreeMem(memory, link.blank_size);
    link.* = .{};
}

/// `blank` holding `row`'s first row on every row: made the first time,
/// filled again when that row is not what it holds. Null without memory
/// for it.
fn blankOf(link: *Link, sys: *ExecBase, row: *const rtg.RtgBitMap) ?*const rtg.RtgBitMap {
    const source = row.pixels orelse return null;
    if (row.format != .rgb565) return null;
    if (link.blank.pixels == null) {
        const line = sdk.hardware.DCACHE_LINE_SIZE;
        const pitch = link.width * 2;
        const size = pitch * link.height + line;
        const memory = sys.AllocMem(size, exec.MEMF_EXTERNAL) orelse return null;
        const pixels = (@intFromPtr(memory) + line - 1) & ~@as(usize, line - 1);
        link.blank = .{ .width = link.width, .height = link.height, .pitch = pitch, .format = .rgb565, .pixels = @ptrFromInt(pixels) };
        link.blank_memory = memory;
        link.blank_size = size;
        link.blank_filled = false;
    }
    const blank = &link.blank;
    const bytes = @min(row.width, blank.width) * 2;
    const first: [*]u8 = @ptrCast(blank.pixels.?);
    const wanted: [*]const u8 = @ptrCast(source);
    if (link.blank_filled and sameBytes(first[0..bytes], wanted[0..bytes])) return blank;
    var at: u32 = 0;
    while (at < blank.height) : (at += 1) @memcpy(first[at * blank.pitch ..][0..bytes], wanted[0..bytes]);
    // Out of the cache, for the engine to read.
    var written: u32 = blank.pitch * blank.height;
    _ = sys.CachePreDMA(@ptrCast(first), &written, 0);
    link.blank_filled = true;
    return blank;
}

fn sameBytes(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// The display lines band `index` of `bands` covers: from its line to
/// the next band's, the last to the bottom.
fn endOf(bands: []const rtg.RtgBand, index: usize, height: u32) u32 {
    return if (index + 1 < bands.len) bands[index + 1].line else height;
}

/// `bands` shown: every band's rows converted into the copy, and the
/// bands the stream is to send in their place written into `into` - the
/// copy's own lines, a repeated band's one line again. How many.
/// `watched`: the stream runs, and its frames time the engine. `keep`
/// is left as it is.
pub fn show(link: *Link, engine: *Engine, sys: *ExecBase, bands: []const rtg.RtgBand, watched: bool, keep: ?Rect, into: *[rtg.RTG_MAX_BANDS]rtg.RtgBand) u32 {
    sys.ObtainSemaphore(&engine.lock);
    defer sys.ReleaseSemaphore(&engine.lock);
    const count: u32 = @intCast(@min(bands.len, rtg.RTG_MAX_BANDS));
    for (bands[0..count], 0..) |band, index| link.shown[index] = band;
    link.shown_count = count;
    for (link.shown[0..count], 0..) |band, index| {
        const end = endOf(link.shown[0..count], index, link.height);
        if (band.flags & rtg.RTGBANDF_REPEAT != 0) {
            if (blankOf(link, sys, band.bitmap)) |blank| {
                if (end > band.line) convertAround(link, engine, sys, blank, band.line, band.line, end - band.line, watched, keep);
                into[index] = .{ .bitmap = &link.whole, .line = band.line, .origin = 0 };
                continue;
            }
            if (end > band.line) convertAround(link, engine, sys, band.bitmap, 0, band.line, 1, watched, keep);
            link.rows[index] = link.whole;
            link.rows[index].pixels = @ptrFromInt(link.pixels + @as(usize, band.line) * link.pitch);
            link.rows[index].height = 1;
            into[index] = .{ .bitmap = &link.rows[index], .line = band.line, .flags = rtg.RTGBANDF_REPEAT };
        } else {
            if (end > band.line) convertAround(link, engine, sys, band.bitmap, band.rowAt(band.line), band.line, end - band.line, watched, keep);
            into[index] = .{ .bitmap = &link.whole, .line = band.line, .origin = 0 };
        }
    }
    return count;
}

/// Rows `y` to `y + rows` of `bitmap` were drawn: converted again
/// wherever a band shows them, around `keep`.
pub fn refresh(link: *Link, engine: *Engine, sys: *ExecBase, bitmap: *const rtg.RtgBitMap, y: u32, rows: u32, watched: bool, keep: ?Rect) void {
    sys.ObtainSemaphore(&engine.lock);
    defer sys.ReleaseSemaphore(&engine.lock);
    const shown = link.shown[0..link.shown_count];
    for (shown, 0..) |band, index| {
        if (band.bitmap != bitmap) continue;
        const end = endOf(shown, index, link.height);
        if (end <= band.line) continue;
        if (band.flags & rtg.RTGBANDF_REPEAT != 0) {
            if (y != 0) continue;
            // Shown as lines of `blank`: converted again only when the row
            // is not the one they hold.
            if (link.blank.pixels != null) {
                if (link.blank_filled and sameRow(link, bitmap)) continue;
                const blank = blankOf(link, sys, bitmap) orelse continue;
                convertAround(link, engine, sys, blank, band.line, band.line, end - band.line, watched, keep);
                continue;
            }
            convertAround(link, engine, sys, bitmap, 0, band.line, 1, watched, keep);
            continue;
        }
        // The band's rows, and the part of them drawn.
        const first_row = band.rowAt(band.line);
        const end_row = first_row + (end - band.line);
        const from = @max(first_row, y);
        const to = @min(end_row, y + rows);
        if (to <= from) continue;
        convertAround(link, engine, sys, bitmap, from, from + band.origin, to - from, watched, keep);
    }
}

/// Whether `row`'s first row is what `blank` holds.
fn sameRow(link: *const Link, row: *const rtg.RtgBitMap) bool {
    const source = row.pixels orelse return false;
    const bytes = @min(row.width, link.blank.width) * 2;
    const held: [*]const u8 = @ptrCast(link.blank.pixels.?);
    const wanted: [*]const u8 = @ptrCast(source);
    return sameBytes(held[0..bytes], wanted[0..bytes]);
}

/// `convert`, leaving `keep` alone: the lines above and below it whole,
/// and beside it the columns left and right of it.
fn convertAround(link: *Link, engine: *Engine, sys: *ExecBase, source: *const rtg.RtgBitMap, row: u32, line: u32, rows: u32, watched: bool, keep: ?Rect) void {
    const end = line + rows;
    const out = keep orelse return convert(link, engine, sys, source, row, line, rows, 0, link.width, watched);
    if (out.y1 <= line or out.y0 >= end or out.x0 >= out.x1) return convert(link, engine, sys, source, row, line, rows, 0, link.width, watched);
    if (out.y0 > line) convert(link, engine, sys, source, row, line, out.y0 - line, 0, link.width, watched);
    const top = @max(out.y0, line);
    const bottom = @min(out.y1, end);
    const beside_row = row + (top - line);
    if (out.x0 > 0) convert(link, engine, sys, source, beside_row, top, bottom - top, 0, out.x0, watched);
    if (out.x1 < link.width) convert(link, engine, sys, source, beside_row, top, bottom - top, out.x1, link.width - out.x1, watched);
    if (end > out.y1) convert(link, engine, sys, source, row + (out.y1 - line), out.y1, end - out.y1, 0, link.width, watched);
}

/// `rows` rows of `source` from `row` on converted into the copy from
/// display line `line` on, `columns` pixels of each from column `x`: by
/// the engine, or by the CPU when it cannot. The engine's semaphore is
/// held.
fn convert(link: *Link, engine: *Engine, sys: *ExecBase, source: *const rtg.RtgBitMap, row: u32, line: u32, rows: u32, x: u32, columns: u32, watched: bool) void {
    if (rows == 0 or line >= link.height) return;
    const count = @min(rows, link.height - line, source.height - @min(row, source.height));
    const width = @min(columns, link.width -| x, source.width -| x);
    if (count == 0 or width == 0) return;
    if (byEngine(link, engine, sys, source, row, line, count, x, width, watched)) {
        link.engine_rows +%= count;
        return;
    }
    byCpu(link, source, row, line, count, x, width);
    link.cpu_rows +%= count;
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
    const signal = engine_file.prepare(engine, sys, watched);
    dma2d.runOut(engine_file.send_channel, parts.send_at);
    dma2d.runIn(engine_file.receive_channel, parts.receive_at);
    return engine_file.wait(engine, sys, signal);
}

/// The CPU's conversion, through the copy's uncached view.
fn byCpu(link: *Link, source: *const rtg.RtgBitMap, row: u32, line: u32, rows: u32, x: u32, width: u32) void {
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        const from: [*]const u16 = @ptrFromInt(@intFromPtr(source.pixels.?) + @as(usize, row + r) * source.pitch);
        put(link, line + r, x, from + x, width);
    }
}

/// `count` RGB565 pixels from `from` into the copy at column `x` of line
/// `line`, through its uncached view: as they are into an RGB565 copy,
/// widened blue first - as the engine writes them - into an RGB888 one.
/// The caller keeps them inside the copy.
pub fn put(link: *const Link, line: u32, x: u32, from: [*]const u16, count: u32) void {
    const row = link.pixels + uncached_offset + @as(usize, line) * link.pitch;
    if (link.format == .rgb565) {
        const to: [*]volatile u16 = @ptrFromInt(row + @as(usize, x) * 2);
        var at: u32 = 0;
        while (at < count) : (at += 1) to[at] = from[at];
        return;
    }
    const to: [*]volatile u8 = @ptrFromInt(row + @as(usize, x) * 3);
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

/// The row of the shown buffers that display line `line` shows: its
/// band's, in RGB565; null where no band covers it.
pub fn sourceRow(link: *const Link, line: u32) ?[*]const u16 {
    var index = link.shown_count;
    while (index > 0) {
        index -= 1;
        const band = link.shown[index];
        if (line < band.line) continue;
        const pixels = band.bitmap.pixels orelse return null;
        const row = band.rowAt(line);
        if (row >= band.bitmap.height) return null;
        return @ptrFromInt(@intFromPtr(pixels) + @as(usize, row) * band.bitmap.pitch);
    }
    return null;
}

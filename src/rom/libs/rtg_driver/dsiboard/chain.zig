// SPDX-License-Identifier: MPL-2.0
//! What the DSI board streams, frame after frame: a chain of the
//! DW-GDMA's items, made from the bands the picture is shown in.
//!
//! A band shows a buffer's rows on a run of display lines; the lines of
//! one band come from consecutive rows, and a buffer's rows are its pitch
//! apart, which for a buffer of the display's mode is exactly a line. So
//! a band is one item: its first row's address and its lines' bytes. A
//! band that repeats its buffer's first row on every line is an item a
//! line, each sending that row again. One buffer shown whole is a chain
//! of one.
//!
//! A chain lives in a block of internal memory of its own, allocated when
//! it is made and freed once the stream has gone on to the next one. Its
//! items are written through the block's uncached view - the block's lines
//! are written back and dropped from the cache first, so no stale line of
//! a previous owner lands on them later - and the transfer-done interrupt
//! sets them valid again for every frame (`rearm`).

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const ExecBase = sdk.interface.exec.ExecBase;
const dwgdma = @import("dwgdma.zig");
const bridge = @import("bridge.zig");

/// An item's size and alignment.
const item_bytes = @sizeOf(dwgdma.Item);

/// A chain: its first item's cached address (0 for none), how many items,
/// and the block they are in.
pub const Chain = struct {
    first: usize = 0,
    count: u32 = 0,
    memory: ?*anyopaque = null,
    bytes: u32 = 0,
};

/// The display lines a band covers: from its line to the next band's, the
/// last to the display's bottom.
fn endOf(bands: []const rtg.RtgBand, index: usize, height: u32) u32 {
    return if (index + 1 < bands.len) bands[index + 1].line else height;
}

/// How many items `bands` take.
fn itemsFor(bands: []const rtg.RtgBand, height: u32) u32 {
    var count: u32 = 0;
    for (bands, 0..) |band, index| {
        const end = endOf(bands, index, height);
        if (end <= band.line) continue;
        count += if (band.flags & rtg.boards.RTGBANDF_REPEAT != 0) end - band.line else 1;
    }
    return count;
}

fn rowAddress(bitmap: *const rtg.RtgBitMap, row: u32) usize {
    return @intFromPtr(bitmap.pixels.?) + @as(usize, row) * bitmap.pitch;
}

/// The chain that shows `bands` on a display `height` lines of
/// `line_bytes` each; null without memory for it.
pub fn build(sys: *ExecBase, bands: []const rtg.RtgBand, height: u32, line_bytes: u32) ?Chain {
    const count = itemsFor(bands, height);
    if (count == 0) return null;
    const bytes = count * item_bytes + item_bytes - 1;
    const memory = sys.AllocMem(bytes, exec.MEMF_INTERNAL) orelse return null;
    const first = (@intFromPtr(memory) + item_bytes - 1) & ~@as(usize, item_bytes - 1);
    var lines: u32 = count * item_bytes;
    _ = sys.CachePreDMA(@ptrFromInt(first), &lines, 0);
    sys.CachePostDMA(@ptrFromInt(first), &lines, 0);

    var index: u32 = 0;
    for (bands, 0..) |band, band_index| {
        const end = endOf(bands, band_index, height);
        if (end <= band.line) continue;
        if (band.flags & rtg.boards.RTGBANDF_REPEAT != 0) {
            var line = band.line;
            while (line < end) : (line += 1) {
                put(first, count, index, rowAddress(band.bitmap, 0), line_bytes);
                index += 1;
            }
        } else {
            put(first, count, index, rowAddress(band.bitmap, band.rowAt(band.line)), (end - band.line) * line_bytes);
            index += 1;
        }
    }
    return .{ .first = first, .count = count, .memory = memory, .bytes = bytes };
}

/// Item `index` of the chain at `first`: `bytes` from `source`, then the
/// next item, or the end.
fn put(first: usize, count: u32, index: u32, source: usize, bytes: u32) void {
    const at = first + @as(usize, index) * item_bytes;
    const next: usize = if (index + 1 < count) at + item_bytes else 0;
    dwgdma.fill(@ptrFromInt(dwgdma.uncached(at)), source, bridge.fifo, bytes, next);
}

/// Every item of the chain handed back to the channel, for the next frame.
pub fn rearm(chain: Chain) void {
    var index: u32 = 0;
    while (index < chain.count) : (index += 1) {
        const at = chain.first + @as(usize, index) * item_bytes;
        dwgdma.rearm(@ptrFromInt(dwgdma.uncached(at)), index + 1 == chain.count);
    }
}

/// The chain's block given back.
pub fn free(sys: *ExecBase, chain: Chain) void {
    if (chain.memory) |memory| sys.FreeMem(memory, chain.bytes);
}

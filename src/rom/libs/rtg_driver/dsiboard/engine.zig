// SPDX-License-Identifier: MPL-2.0
//! The DSI board's engine: FillRect on the PPA's fill and CopyRect on a
//! 2D-DMA copy, for RGB565 buffers.
//!
//! **What the engine may write.** It writes memory behind the data
//! cache's back, so it is given only whole cache lines that lie inside
//! the rectangle: the part of each row between the first and the last
//! line boundary in it. The ragged ends of each row, which share a line
//! with pixels outside the rectangle - another window's, being drawn by
//! another task at the same time - are the CPU's. So nothing outside the
//! rectangle can be lost to a line the engine and the CPU both wrote. For
//! that every row has to put its line boundaries at the same columns: a
//! buffer whose start or pitch is not whole lines is not the engine's,
//! and neither is a rectangle with too few whole lines in it to be worth
//! the setting up (`smallest_at_80`). Both are answered
//! RTGERR_NOT_SUPPORTED, and the caller does them in software.
//!
//! **The cache around it.** Before the engine runs, the rows it reads and
//! writes are written back out of the cache in one go: whatever the CPU
//! wrote is in memory, and no dirty line of the rectangle is left to be
//! written over the engine's pixels later. After it, each row's lines the
//! engine wrote are dropped from the cache, so the CPU reads what the
//! engine left. The CPU fills or copies the ends while the engine works.
//!
//! **A copy within one buffer** whose two rectangles overlap is refused:
//! the 2D-DMA's order across such a copy is not one this driver can rely
//! on.
//!
//! One operation at a time, under the panel's engine semaphore; each one
//! waits until it is done before it returns, so WaitBlit has nothing left
//! to wait for.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const err = rtg.errors;
const ExecBase = sdk.interface.exec.ExecBase;
const hardware = sdk.hardware;
const system = hardware.system;
const dma2d = @import("dma2d.zig");
const ppa = @import("ppa.zig");

/// The data cache's line, and the RGB565 pixels in one.
const line_bytes = 64;
const line_pixels = line_bytes / 2;
/// The fewest pixels worth handing to the engine, with the PSRAM at
/// 80 MHz. Setting it up and keeping the cache right around it costs
/// about half a millisecond, and it fills about twice as fast as the CPU:
/// measured on the ESP32-P4-PC, the two meet near 25000 pixels. A faster
/// PSRAM speeds the CPU's fills more than the engine's - at 200 MHz they
/// meet near 50000 - so it raises this in proportion (`setUp`).
const smallest_at_80 = 32768;
/// How long one operation may take.
const timeout_us = 200_000;

/// What the engine keeps in the panel: its lock, its descriptors and how
/// often it ran.
pub const Engine = struct {
    lock: exec.SignalSemaphore = .{},
    /// Room for the two descriptors, which sit in the 64-byte line inside
    /// it (`line`, its address) and are only ever written through its
    /// uncached view.
    room: [128]u8 align(8) = @splat(0),
    line: usize = 0,
    ready: bool = false,
    /// The fewest pixels worth handing to the engine on this board.
    smallest: u32 = smallest_at_80,
    fills: u32 = 0,
    copies: u32 = 0,
    failures: u32 = 0,
};

/// The engine's clocks on and its descriptors' line out of the cache; its
/// smallest job for the PSRAM at `psram_mhz`.
pub fn setUp(engine: *Engine, sys: *ExecBase, psram_mhz: u32) void {
    sys.InitSemaphore(&engine.lock);
    engine.smallest = smallest_at_80 * @max(psram_mhz, 80) / 80;
    sys.Disable();
    system.enable(.ppa);
    system.enable(.dma2d);
    sys.Enable();
    dma2d.start();
    engine.line = (@intFromPtr(&engine.room) + line_bytes - 1) & ~@as(usize, line_bytes - 1);
    var bytes: u32 = line_bytes;
    _ = sys.CachePreDMA(@ptrFromInt(engine.line), &bytes, 0);
    sys.CachePostDMA(@ptrFromInt(engine.line), &bytes, 0);
    engine.ready = true;
}

/// The send and the receive descriptor, through the uncached view.
fn descriptors(engine: *Engine) struct { send: *volatile dma2d.Descriptor, receive: *volatile dma2d.Descriptor, send_at: usize, receive_at: usize } {
    const uncached = engine.line + 0x4000_0000;
    return .{
        .send = @ptrFromInt(uncached),
        .receive = @ptrFromInt(uncached + 32),
        .send_at = engine.line,
        .receive_at = engine.line + 32,
    };
}

/// The part of a row run the engine may have: from the first line
/// boundary at or after `x` to the last at or before `x + width`.
const Middle = struct { start: u32, end: u32 };

fn middleOf(x: u32, width: u32) Middle {
    const start = (x + line_pixels - 1) / line_pixels * line_pixels;
    const end = (x + width) / line_pixels * line_pixels;
    return .{ .start = start, .end = @max(start, end) };
}

/// Whether a buffer puts its line boundaries at the same columns in every
/// row, and its rows fit a descriptor.
fn lined(bitmap: *const rtg.RtgBitMap) bool {
    const pixels = bitmap.pixels orelse return false;
    if (bitmap.format != .rgb565) return false;
    if (@intFromPtr(pixels) % line_bytes != 0 or bitmap.pitch % line_bytes != 0) return false;
    return bitmap.pitch / 2 <= dma2d.field_max and bitmap.height <= dma2d.field_max;
}

fn rowAddress(bitmap: *const rtg.RtgBitMap, x: u32, y: u32) usize {
    return @intFromPtr(bitmap.pixels.?) + @as(usize, y) * bitmap.pitch + @as(usize, x) * 2;
}

/// Rows `y` to `y + rows` of a buffer written back out of the cache,
/// from column `x0` of the first to column `x1` of the last.
fn writeBack(sys: *ExecBase, bitmap: *const rtg.RtgBitMap, x0: u32, x1: u32, y: u32, rows: u32) void {
    const first = rowAddress(bitmap, x0, y);
    const last = rowAddress(bitmap, x1, y + rows - 1);
    var bytes: u32 = @intCast(last - first);
    if (bytes != 0) _ = sys.CachePreDMA(@ptrFromInt(first), &bytes, 0);
}

/// The engine's part of each row dropped from the cache.
fn forget(sys: *ExecBase, bitmap: *const rtg.RtgBitMap, middle: Middle, y: u32, rows: u32) void {
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var bytes: u32 = (middle.end - middle.start) * 2;
        sys.CachePostDMA(@ptrFromInt(rowAddress(bitmap, middle.start, y + row)), &bytes, 0);
    }
}

/// Columns `from` to `to` of rows `y` to `y + rows` set to `color`, by the
/// CPU.
fn fillByCpu(bitmap: *const rtg.RtgBitMap, from: u32, to: u32, y: u32, rows: u32, color: u16) void {
    if (to <= from) return;
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        const run: [*]u16 = @ptrFromInt(rowAddress(bitmap, from, y + row));
        @memset(run[0 .. to - from], color);
    }
}

/// FillRect: the rectangle has been clipped to the buffer.
pub fn fill(engine: *Engine, sys: *ExecBase, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) i32 {
    if (!engine.ready or !lined(bitmap)) return err.RTGERR_NOT_SUPPORTED;
    const x: u32 = @intCast(area.x);
    const y: u32 = @intCast(area.y);
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    const middle = middleOf(x, width);
    if ((middle.end - middle.start) * height < engine.smallest) return err.RTGERR_NOT_SUPPORTED;

    sys.ObtainSemaphore(&engine.lock);
    defer sys.ReleaseSemaphore(&engine.lock);
    writeBack(sys, bitmap, middle.start, middle.end, y, height);

    const parts = descriptors(engine);
    ppa.reset();
    if (!dma2d.connectIn(dma2d.peri_ppa_blend, false)) return failed(engine);
    dma2d.describe(parts.receive, @intFromPtr(bitmap.pixels.?), bitmap.pitch / 2, bitmap.height, middle.start, y, middle.end - middle.start, height, dma2d.pbyte_2);
    dma2d.runIn(parts.receive_at);
    ppa.fill(ppa.argbOf(color), middle.end - middle.start, height);

    const pixel: u16 = @truncate(color);
    fillByCpu(bitmap, x, middle.start, y, height, pixel);
    fillByCpu(bitmap, middle.end, x + width, y, height, pixel);

    const done = dma2d.finish(timeout_us);
    forget(sys, bitmap, middle, y, height);
    if (!done) return failed(engine);
    engine.fills +%= 1;
    return err.RTGERR_OK;
}

/// CopyRect: both rectangles have been clipped to their buffers.
pub fn copy(engine: *Engine, sys: *ExecBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, what: *const rtg.RtgCopy) i32 {
    if (!engine.ready or !lined(dest)) return err.RTGERR_NOT_SUPPORTED;
    if (src.format != .rgb565 or src.pixels == null) return err.RTGERR_NOT_SUPPORTED;
    if (src.pitch % 2 != 0 or src.pitch / 2 > dma2d.field_max or src.height > dma2d.field_max) return err.RTGERR_NOT_SUPPORTED;
    const sx: u32 = @intCast(what.src_x);
    const sy: u32 = @intCast(what.src_y);
    const dx: u32 = @intCast(what.dest_x);
    const dy: u32 = @intCast(what.dest_y);
    const width: u32 = @intCast(what.width);
    const height: u32 = @intCast(what.height);
    if (src == dest and sx < dx + width and dx < sx + width and sy < dy + height and dy < sy + height) {
        return err.RTGERR_NOT_SUPPORTED;
    }
    const middle = middleOf(dx, width);
    if ((middle.end - middle.start) * height < engine.smallest) return err.RTGERR_NOT_SUPPORTED;
    const shift = middle.start - dx;

    sys.ObtainSemaphore(&engine.lock);
    defer sys.ReleaseSemaphore(&engine.lock);
    writeBack(sys, src, sx, sx + width, sy, height);
    writeBack(sys, dest, middle.start, middle.end, dy, height);

    const parts = descriptors(engine);
    if (!dma2d.connectOut(dma2d.peri_memory_out)) return failed(engine);
    if (!dma2d.connectIn(dma2d.peri_memory_in, true)) return failed(engine);
    const run = middle.end - middle.start;
    dma2d.describe(parts.send, @intFromPtr(src.pixels.?), src.pitch / 2, src.height, sx + shift, sy, run, height, dma2d.pbyte_2);
    dma2d.describe(parts.receive, @intFromPtr(dest.pixels.?), dest.pitch / 2, dest.height, middle.start, dy, run, height, dma2d.pbyte_2);
    dma2d.runOut(parts.send_at);
    dma2d.runIn(parts.receive_at);

    copyByCpu(src, dest, sx, sy, dx, dy, shift, height);
    copyByCpu(src, dest, sx + (middle.end - dx), sy, middle.end, dy, dx + width - middle.end, height);

    const done = dma2d.finish(timeout_us);
    forget(sys, dest, middle, dy, height);
    if (!done) return failed(engine);
    engine.copies +%= 1;
    return err.RTGERR_OK;
}

/// `columns` pixels of rows `sy`.. of `src` to rows `dy`.. of `dest`, by
/// the CPU.
fn copyByCpu(src: *const rtg.RtgBitMap, dest: *const rtg.RtgBitMap, sx: u32, sy: u32, dx: u32, dy: u32, columns: u32, rows: u32) void {
    if (columns == 0) return;
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        const from: [*]const u16 = @ptrFromInt(rowAddress(src, sx, sy + row));
        const to: [*]u16 = @ptrFromInt(rowAddress(dest, dx, dy + row));
        @memcpy(to[0..columns], from[0..columns]);
    }
}

fn failed(engine: *Engine) i32 {
    engine.failures +%= 1;
    return err.RTGERR_NOT_SUPPORTED;
}

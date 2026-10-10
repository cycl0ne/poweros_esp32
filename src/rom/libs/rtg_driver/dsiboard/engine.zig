// SPDX-License-Identifier: MPL-2.0
//! The DSI board's engine: FillRect on the PPA's fill and CopyRect on a
//! 2D-DMA copy, for RGB565 buffers - and what the blend and the scale
//! (blend.zig, scale.zig) share with them.
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
//! on. The two are compared as memory, so the same pixels described by
//! two buffers are one buffer here. A source the 2D-DMA cannot read -
//! anything outside the PSRAM and the internal memory - is refused too.
//!
//! **Waiting for it.** The CPU does its part while the engine works, then
//! the calling task waits on a signal of its own, which the 2D-DMA's end
//! interrupt sends - the CPU is free for other tasks meanwhile. The
//! panel's frame interrupt (`frameTick`) keeps count: a job still running
//! after `patience_frames` frames is given up and done by the CPU. Before
//! the stream runs there are no frames to count, and the task watches
//! the engine itself, for at most `timeout_us`.
//!
//! One operation at a time, under the panel's engine semaphore; each one
//! is done before it returns, so WaitBlit has nothing left to wait for.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const err = rtg.errors;
const ExecBase = sdk.interface.exec.ExecBase;
const hardware = sdk.hardware;
const system = hardware.system;
const intbits = hardware.intbits;
const map = hardware.map;
const dma2d = @import("dma2d.zig");
const ppa = @import("ppa.zig");

/// The data cache's line, and the RGB565 pixels in one.
pub const line_bytes = 64;
const line_pixels = line_bytes / 2;
/// The fewest pixels worth handing to the engine, with the PSRAM at
/// 80 MHz. Setting it up and keeping the cache right around it costs
/// about half a millisecond, and it fills about twice as fast as the CPU:
/// measured on the ESP32-P4-PC, the two meet near 25000 pixels. A faster
/// PSRAM speeds the CPU's fills more than the engine's - at 200 MHz they
/// meet near 50000 - so it raises this in proportion (`setUp`).
const smallest_at_80 = 32768;
/// The same for a blend. Mixing is the CPU's arithmetic, not its memory,
/// so the PSRAM's speed does not move this one: measured on the
/// ESP32-P4-PC, the CPU mixes about 0.7 us a pixel, the engine takes about
/// 0.4 ms to set up and 0.06 us a pixel, and the two meet near 600
/// pixels.
const smallest_blend = 2048;
/// How long one operation may take without the stream's frames to count
/// it by, and with them, in frames.
const timeout_us = 200_000;
const patience_frames = 10;

/// What the engine keeps in the panel: its lock, its descriptors and how
/// often each kind of job ran.
pub const Engine = struct {
    sys: ?*ExecBase = null,
    lock: exec.SignalSemaphore = .{},
    /// The end interrupt's server, and whether it is hooked up.
    int: exec.Interrupt = .{},
    hooked: bool = false,
    /// The task waiting for the job and its signal; how the job ended, as
    /// the interrupt found it; the frames it has run for; whether they ran
    /// out.
    waiter: ?*exec.Task = null,
    waiter_mask: u32 = 0,
    ended: u32 = 0,
    frames_waited: u32 = 0,
    gave_up: bool = false,
    /// Room for the three descriptors, which sit in the two 64-byte lines
    /// inside it (`line`, the first's address) and are only ever written
    /// through their uncached view.
    room: [3 * line_bytes]u8 align(8) = @splat(0),
    line: usize = 0,
    ready: bool = false,
    /// The fewest pixels worth handing to the engine on this board, for a
    /// fill or a copy and for a blend.
    smallest: u32 = smallest_at_80,
    smallest_blend: u32 = smallest_blend,
    fills: u32 = 0,
    copies: u32 = 0,
    blends: u32 = 0,
    scales: u32 = 0,
    failures: u32 = 0,
};

/// The engine's clocks on and its descriptors' lines out of the cache; its
/// smallest fill or copy for the PSRAM at `psram_mhz`.
pub fn setUp(engine: *Engine, sys: *ExecBase, psram_mhz: u32) void {
    engine.sys = sys;
    sys.InitSemaphore(&engine.lock);
    engine.smallest = smallest_at_80 * @max(psram_mhz, 80) / 80;
    sys.Disable();
    system.enable(.ppa);
    system.enable(.dma2d);
    sys.Enable();
    dma2d.start();
    engine.line = (@intFromPtr(&engine.room) + line_bytes - 1) & ~@as(usize, line_bytes - 1);
    var bytes: u32 = 2 * line_bytes;
    _ = sys.CachePreDMA(@ptrFromInt(engine.line), &bytes, 0);
    sys.CachePostDMA(@ptrFromInt(engine.line), &bytes, 0);
    engine.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = "rtg-dsi engine" },
        .data = engine,
        .code = &endServer,
    };
    sys.AddIntServer(intbits.INTB_DMA2D_IN_CH0, &engine.int);
    engine.hooked = true;
    engine.ready = true;
}

/// The engine's interrupt taken away again.
pub fn takeDown(engine: *Engine) void {
    if (!engine.hooked) return;
    engine.sys.?.RemIntServer(intbits.INTB_DMA2D_IN_CH0, &engine.int);
    engine.hooked = false;
    engine.ready = false;
}

/// The 2D-DMA's receive side ended: the waiting task told.
fn endServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const engine: *Engine = @ptrCast(@alignCast(is_data.?));
    const raised = dma2d.takeEnded();
    if (raised == 0) return 0;
    engine.ended = raised;
    if (engine.waiter) |task| engine.sys.?.Signal(task, engine.waiter_mask);
    return 1;
}

/// A frame has gone by, from the panel's frame interrupt: a job that has
/// run for `patience_frames` of them is given up, and its task told.
pub fn frameTick(engine: *Engine) void {
    const task = engine.waiter orelse return;
    engine.frames_waited += 1;
    if (engine.frames_waited != patience_frames) return;
    engine.gave_up = true;
    engine.sys.?.Signal(task, engine.waiter_mask);
}

/// Before the job starts: the calling task made its waiter, with a signal
/// of its own, and the end interrupt armed; -1 when it will watch the
/// engine itself instead - no frames to count by (`watched` false), or no
/// signal free.
pub fn prepare(engine: *Engine, sys: *ExecBase, watched: bool) i8 {
    if (!watched) return -1;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return -1;
    sys.Disable();
    engine.ended = 0;
    engine.frames_waited = 0;
    engine.gave_up = false;
    engine.waiter_mask = @as(u32, 1) << @intCast(signal);
    engine.waiter = sys.FindTask(null);
    sys.Enable();
    dma2d.interruptWhenEnded();
    return signal;
}

/// After the CPU's part: until the job has ended, or been given up.
/// Whether it ended well; the channels are released either way.
pub fn wait(engine: *Engine, sys: *ExecBase, signal: i8) bool {
    if (signal < 0) return dma2d.release(dma2d.poll(timeout_us));
    var raised: u32 = 0;
    while (true) {
        sys.Disable();
        raised = engine.ended;
        const gave_up = engine.gave_up;
        if (raised != 0 or gave_up) engine.waiter = null;
        sys.Enable();
        if (raised != 0 or gave_up) break;
        _ = sys.Wait(engine.waiter_mask);
    }
    _ = sys.SetSignal(0, engine.waiter_mask);
    sys.FreeSignal(signal);
    return dma2d.release(raised);
}

/// The descriptors - two send channels' and the receive channel's -
/// through the uncached view, and where the channels find them.
pub const Descriptors = struct {
    send: *volatile dma2d.Descriptor,
    over: *volatile dma2d.Descriptor,
    receive: *volatile dma2d.Descriptor,
    send_at: usize,
    over_at: usize,
    receive_at: usize,
};

pub fn descriptors(engine: *Engine) Descriptors {
    const uncached = engine.line + 0x4000_0000;
    return .{
        .send = @ptrFromInt(uncached),
        .over = @ptrFromInt(uncached + 32),
        .receive = @ptrFromInt(uncached + 64),
        .send_at = engine.line,
        .over_at = engine.line + 32,
        .receive_at = engine.line + 64,
    };
}

/// The part of a row run the engine may have: from the first line
/// boundary at or after `x` to the last at or before `x + width`.
pub const Middle = struct { start: u32, end: u32 };

pub fn middleOf(x: u32, width: u32) Middle {
    const start = (x + line_pixels - 1) / line_pixels * line_pixels;
    const end = (x + width) / line_pixels * line_pixels;
    return .{ .start = start, .end = @max(start, end) };
}

/// Whether a buffer puts its line boundaries at the same columns in every
/// row, and its rows fit a descriptor.
pub fn lined(bitmap: *const rtg.RtgBitMap) bool {
    const pixels = bitmap.pixels orelse return false;
    if (bitmap.format != .rgb565) return false;
    if (@intFromPtr(pixels) % line_bytes != 0 or bitmap.pitch % line_bytes != 0) return false;
    return bitmap.pitch / 2 <= dma2d.field_max and bitmap.height <= dma2d.field_max;
}

pub fn rowAddress(bitmap: *const rtg.RtgBitMap, x: u32, y: u32) usize {
    return @intFromPtr(bitmap.pixels.?) + @as(usize, y) * bitmap.pitch + @as(usize, x) * 2;
}

/// Whether the 2D-DMA can read the bytes from `start` up to `end`: the
/// PSRAM and the internal memory, not the flash or the ROM. Wide, so
/// that sizes from a caller cannot wrap.
pub fn reachable(start: u64, end: u64) bool {
    if (start >= map.PSRAM_START and end <= map.PSRAM_END) return true;
    return start >= map.DRAM_START and end <= map.DRAM_END;
}

/// The bytes from `first` up to `end` written back out of the cache.
pub fn writeBackSpan(sys: *ExecBase, first: usize, end: usize) void {
    var bytes: u32 = @intCast(end - first);
    if (bytes != 0) _ = sys.CachePreDMA(@ptrFromInt(first), &bytes, 0);
}

/// Rows `y` to `y + rows` of a buffer written back out of the cache,
/// from column `x0` of the first to column `x1` of the last.
pub fn writeBack(sys: *ExecBase, bitmap: *const rtg.RtgBitMap, x0: u32, x1: u32, y: u32, rows: u32) void {
    writeBackSpan(sys, rowAddress(bitmap, x0, y), rowAddress(bitmap, x1, y + rows - 1));
}

/// The engine's part of each row dropped from the cache.
pub fn forget(sys: *ExecBase, bitmap: *const rtg.RtgBitMap, middle: Middle, y: u32, rows: u32) void {
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

/// FillRect: the rectangle has been clipped to the buffer. `watched`:
/// the stream runs, and its frames count the job's time.
pub fn fill(engine: *Engine, sys: *ExecBase, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32, watched: bool) i32 {
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
    const signal = prepare(engine, sys, watched);
    dma2d.runIn(parts.receive_at);
    ppa.fill(ppa.argbOf(color), middle.end - middle.start, height);

    const pixel: u16 = @truncate(color);
    fillByCpu(bitmap, x, middle.start, y, height, pixel);
    fillByCpu(bitmap, middle.end, x + width, y, height, pixel);

    const done = wait(engine, sys, signal);
    forget(sys, bitmap, middle, y, height);
    if (!done) return failed(engine);
    engine.fills +%= 1;
    return err.RTGERR_OK;
}

/// CopyRect: both rectangles have been clipped to their buffers;
/// `watched` as for `fill`.
pub fn copy(engine: *Engine, sys: *ExecBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, what: *const rtg.RtgCopy, watched: bool) i32 {
    if (!engine.ready or !lined(dest)) return err.RTGERR_NOT_SUPPORTED;
    if (src.format != .rgb565 or src.pixels == null) return err.RTGERR_NOT_SUPPORTED;
    if (src.pitch % 2 != 0 or src.pitch / 2 > dma2d.field_max or src.height > dma2d.field_max) return err.RTGERR_NOT_SUPPORTED;
    const sx: u32 = @intCast(what.src_x);
    const sy: u32 = @intCast(what.src_y);
    const dx: u32 = @intCast(what.dest_x);
    const dy: u32 = @intCast(what.dest_y);
    const width: u32 = @intCast(what.width);
    const height: u32 = @intCast(what.height);
    const src_start: u64 = @intFromPtr(src.pixels.?);
    if (!reachable(src_start, src_start + @as(u64, src.pitch) * src.height)) return err.RTGERR_NOT_SUPPORTED;
    const src_first = rowAddress(src, sx, sy);
    const src_end = rowAddress(src, sx + width, sy + height - 1);
    if (overlapping(src, dest, src_first, src_end, what)) return err.RTGERR_NOT_SUPPORTED;
    const middle = middleOf(dx, width);
    if ((middle.end - middle.start) * height < engine.smallest) return err.RTGERR_NOT_SUPPORTED;
    const shift = middle.start - dx;

    sys.ObtainSemaphore(&engine.lock);
    defer sys.ReleaseSemaphore(&engine.lock);
    writeBackSpan(sys, src_first, src_end);
    writeBack(sys, dest, middle.start, middle.end, dy, height);

    const parts = descriptors(engine);
    if (!dma2d.connectOut(0, dma2d.peri_memory_out)) return failed(engine);
    if (!dma2d.connectIn(dma2d.peri_memory_in, true)) return failed(engine);
    const run = middle.end - middle.start;
    dma2d.describe(parts.send, @intFromPtr(src.pixels.?), src.pitch / 2, src.height, sx + shift, sy, run, height, dma2d.pbyte_2);
    dma2d.describe(parts.receive, @intFromPtr(dest.pixels.?), dest.pitch / 2, dest.height, middle.start, dy, run, height, dma2d.pbyte_2);
    const signal = prepare(engine, sys, watched);
    dma2d.runOut(0, parts.send_at);
    dma2d.runIn(parts.receive_at);

    copyByCpu(src, dest, sx, sy, dx, dy, shift, height);
    copyByCpu(src, dest, sx + (middle.end - dx), sy, middle.end, dy, dx + width - middle.end, height);

    const done = wait(engine, sys, signal);
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

/// Whether a copy reads pixels it writes: one buffer - one memory with
/// one pitch - whose two rectangles overlap, or two descriptions of
/// memory whose spans meet any other way.
fn overlapping(src: *const rtg.RtgBitMap, dest: *const rtg.RtgBitMap, src_first: usize, src_end: usize, what: *const rtg.RtgCopy) bool {
    const dest_first = rowAddress(dest, @intCast(what.dest_x), @intCast(what.dest_y));
    const dest_end = rowAddress(dest, @intCast(what.dest_x + what.width), @intCast(what.dest_y + what.height - 1));
    if (src_end <= dest_first or dest_end <= src_first) return false;
    if (src.pixels != dest.pixels or src.pitch != dest.pitch) return true;
    return what.src_x < what.dest_x + what.width and what.dest_x < what.src_x + what.width and
        what.src_y < what.dest_y + what.height and what.dest_y < what.src_y + what.height;
}

pub fn failed(engine: *Engine) i32 {
    engine.failures +%= 1;
    return err.RTGERR_NOT_SUPPORTED;
}

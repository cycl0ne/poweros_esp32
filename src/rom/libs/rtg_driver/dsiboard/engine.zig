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
//! RTGERR_NOT_SUPPORTED, and the caller does them in software. That
//! answer says nothing was written: it comes before the first pixel, and
//! never after.
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
//! the calling task waits for the job's end, which the 2D-DMA's end
//! interrupt signals on a waitable of the engine's - the CPU is free for
//! other tasks meanwhile. The wait has the clock's bound, `timeout_us`,
//! whatever the stream does. While the stream runs, the panel's frame
//! interrupt (`frameTick`) keeps count as well: a job still running after
//! `patience_frames` frames is given up then. Before the stream runs the
//! task watches the engine itself, for at most `timeout_us`.
//!
//! **A job that does not end** - an error, or no end within its bound -
//! is stopped before its wait returns: the PPA's units back to idle, the
//! channels stopped and reset, so that nothing of it writes the rectangle
//! afterwards, or a block that is then freed. What it left of the
//! rectangle the CPU does, and the job is answered as done. The scaler's
//! own job (`scale.zig`) has written only its block, nothing of the
//! buffer: that one is answered RTGERR_NOT_SUPPORTED, and the caller
//! scales in software. The first job that does not end is said on the
//! raw port; `failures` counts them.
//!
//! One operation at a time, under the panel's engine semaphore; each one
//! is done before it returns.
//!
//! **Its channels** are dma.resource's 2D channels 1 and 2 - send
//! channels 1 and 2, receive channel 1 - claimed when the engine is set
//! up: channel 0, the only one that reorders and converts colour, is the
//! JPEG codec's. Without them the engine stays off and everything is the
//! CPU's.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const err = rtg.errors;
const ExecBase = sdk.interface.exec.ExecBase;
const hardware = sdk.hardware;
const system = hardware.system;
const intbits = hardware.intbits;
const map = hardware.map;
const dma2d = hardware.dma2d;
const dmares = sdk.resources.dma;
const ppa = @import("ppa.zig");

/// The 2D-DMA's channels the engine works with: what it reads (and what
/// lies under a blend), what goes over a blend, and what it writes.
pub const send_channel = 1;
pub const over_channel = 2;
pub const receive_channel = 1;
/// Their owner's name at dma.resource.
const owner_name = "rtg-dsi engine";

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
/// How long one operation may take, by the clock; and while the stream's
/// frames count it too, in frames - the earlier of the two ends the wait.
const timeout_us = 200_000;
const patience_frames = 10;

/// What the engine keeps in the panel: its lock, its descriptors and how
/// often each kind of job ran.
pub const Engine = struct {
    sys: ?*ExecBase = null,
    lock: exec.SignalSemaphore = .{},
    /// dma.resource, while the engine holds its two channels there.
    dma: ?*dmares.DmaBase = null,
    /// The end interrupt's server, and whether it is hooked up.
    int: exec.Interrupt = .{},
    hooked: bool = false,
    /// What the task waiting for a job waits on: signalled when the job
    /// has ended, and when its frames have run out. Whether a task waits;
    /// how the job ended, as the interrupt found it; the frames it has
    /// run for.
    done: exec.Waitable = .{},
    waiting: bool = false,
    ended: u32 = 0,
    frames_waited: u32 = 0,
    /// Whether a job that did not end has been said on the raw port.
    told: bool = false,
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

/// The engine's channels claimed, its clock on and its descriptors' lines
/// out of the cache; its smallest fill or copy for the PSRAM at
/// `psram_mhz`. Without the channels it stays off.
pub fn setUp(engine: *Engine, sys: *ExecBase, psram_mhz: u32) void {
    engine.sys = sys;
    sys.InitSemaphore(&engine.lock);
    engine.smallest = smallest_at_80 * @max(psram_mhz, 80) / 80;
    if (!claim(engine, sys)) return;
    sys.Disable();
    system.enable(.ppa);
    sys.Enable();
    engine.line = (@intFromPtr(&engine.room) + line_bytes - 1) & ~@as(usize, line_bytes - 1);
    var bytes: u32 = 2 * line_bytes;
    _ = sys.CachePreDMA(@ptrFromInt(engine.line), &bytes, 0);
    sys.CachePostDMA(@ptrFromInt(engine.line), &bytes, 0);
    engine.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = "rtg-dsi engine" },
        .data = engine,
        .code = &endServer,
    };
    sys.AddIntServer(end_interrupt, &engine.int);
    engine.hooked = true;
    engine.ready = true;
}

/// The receive channel's interrupt.
const end_interrupt = intbits.INTB_DMA2D_IN_CH0 + receive_channel;

/// The two 2D channels from dma.resource, both or neither.
fn claim(engine: *Engine, sys: *ExecBase) bool {
    const db: *dmares.DmaBase = @ptrCast(@alignCast(sys.OpenResource(dmares.DMANAME) orelse return false));
    const first = dmares.DMA2D_CHANNEL0 + send_channel;
    const second = dmares.DMA2D_CHANNEL0 + over_channel;
    if (db.AllocDMAChannel(first, owner_name) != null) return false;
    if (db.AllocDMAChannel(second, owner_name) != null) {
        db.FreeDMAChannel(first);
        return false;
    }
    engine.dma = db;
    return true;
}

/// The engine's interrupt taken away again, and its channels given back.
pub fn takeDown(engine: *Engine) void {
    if (engine.hooked) {
        engine.sys.?.RemIntServer(end_interrupt, &engine.int);
        engine.hooked = false;
    }
    engine.ready = false;
    const db = engine.dma orelse return;
    db.FreeDMAChannel(dmares.DMA2D_CHANNEL0 + send_channel);
    db.FreeDMAChannel(dmares.DMA2D_CHANNEL0 + over_channel);
    engine.dma = null;
}

/// The 2D-DMA's receive side ended: how it ended kept, and the task
/// waiting for it woken.
fn endServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const engine: *Engine = @ptrCast(@alignCast(is_data.?));
    const raised = dma2d.takeEnded(receive_channel);
    if (raised == 0) return 0;
    engine.ended = raised;
    engine.sys.?.SignalWaitable(&engine.done);
    return 1;
}

/// A frame has gone by, from the panel's frame interrupt: a job that has
/// run for `patience_frames` of them is given up, and its task woken.
///
/// INPUTS:
/// - `engine` - the engine.
pub fn frameTick(engine: *Engine) void {
    if (!engine.waiting) return;
    engine.frames_waited += 1;
    if (engine.frames_waited == patience_frames) engine.sys.?.SignalWaitable(&engine.done);
}

/// Before the job starts: the engine's waitable reset and the end
/// interrupt armed, for a task that will sleep until the job has ended.
///
/// INPUTS:
/// - `engine` - the engine, its lock held.
/// - `sys` - exec.
/// - `watched` - the stream runs, and its frames count the job's time.
///
/// RESULT:
/// Whether the task will sleep; false when it watches the engine itself
/// instead, with no frames to count by.
pub fn prepare(engine: *Engine, sys: *ExecBase, watched: bool) bool {
    if (!watched) return false;
    sys.ResetWaitable(&engine.done);
    sys.Disable();
    engine.ended = 0;
    engine.frames_waited = 0;
    engine.waiting = true;
    sys.Enable();
    dma2d.interruptWhenEnded(receive_channel);
    return true;
}

/// After the CPU's part: until the job has ended, its frames have run
/// out, or `timeout_us` has gone by - the clock's bound holds whatever
/// becomes of the stream meanwhile.
///
/// INPUTS:
/// - `engine` - the engine, its lock held.
/// - `sys` - exec.
/// - `asleep` - what `prepare` answered.
///
/// RESULT:
/// Whether the job ended well. One that did not is stopped before this
/// returns (`release`), so what it was to write is the caller's again.
pub fn wait(engine: *Engine, sys: *ExecBase, asleep: bool) bool {
    if (!asleep) return release(engine, sys, dma2d.poll(receive_channel, timeout_us));
    const ends = [_]*exec.Waitable{&engine.done};
    _ = sys.WaitForAny(&ends, ends.len, timeout_us);
    sys.Disable();
    engine.waiting = false;
    const raised = engine.ended;
    sys.Enable();
    return release(engine, sys, raised);
}

/// The channels disconnected after a job that ended as `raised` says:
/// whether it ended well. One that did not - an error, or no end at all -
/// is stopped first, and the first of them said on the raw port.
///
/// INPUTS:
/// - `engine` - the engine.
/// - `sys` - exec.
/// - `raised` - how the receive side ended, 0 for not at all.
fn release(engine: *Engine, sys: *ExecBase, raised: u32) bool {
    if (dma2d.endedWell(raised)) {
        dma2d.releaseIn(receive_channel);
        dma2d.releaseOut(send_channel);
        dma2d.releaseOut(over_channel);
        return true;
    }
    stop();
    engine.failures +%= 1;
    if (!engine.told) {
        engine.told = true;
        exec.kprintf(sys, "%s: a job did not end and was stopped; the CPU does what it left\n", .{owner_name});
    }
    return false;
}

/// A job stopped where it is: the blend unit and the scaler back to idle,
/// then each of the engine's 2D channels - a channel's number names its
/// send side and its receive side - stopped, reset and disconnected, as
/// a channel is when it goes back to dma.resource. Nothing of the job
/// writes once this returns, as far as the channels' own reset says: one
/// that does not come to rest within its bound is not noticed.
fn stop() void {
    ppa.reset();
    ppa.resetScaler();
    dma2d.stopChannel(send_channel);
    dma2d.stopChannel(over_channel);
}

comptime {
    // `stop` reaches the receive channel by the send channel's number.
    if (send_channel != receive_channel) @compileError("the engine's receive channel is not the receive side of its send channel");
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
    if (!dma2d.connectIn(receive_channel, dma2d.peri_ppa_blend, .{})) return failed(engine);
    dma2d.describe(parts.receive, @intFromPtr(bitmap.pixels.?), bitmap.pitch / 2, bitmap.height, middle.start, y, middle.end - middle.start, height, dma2d.pbyte_2);
    const asleep = prepare(engine, sys, watched);
    dma2d.runIn(receive_channel, parts.receive_at);
    ppa.fill(ppa.argbOf(color), middle.end - middle.start, height);

    const pixel: u16 = @truncate(color);
    fillByCpu(bitmap, x, middle.start, y, height, pixel);
    fillByCpu(bitmap, middle.end, x + width, y, height, pixel);

    const done = wait(engine, sys, asleep);
    forget(sys, bitmap, middle, y, height);
    // The ends are filled and the job is stopped: the middle is the
    // CPU's as well, whatever the engine got done of it.
    if (!done) fillByCpu(bitmap, middle.start, middle.end, y, height, pixel);
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
    if (!dma2d.connectOut(send_channel, dma2d.peri_memory_out)) return failed(engine);
    if (!dma2d.connectIn(receive_channel, dma2d.peri_memory_in, .{ .sibling = true })) return failed(engine);
    const run = middle.end - middle.start;
    dma2d.describe(parts.send, @intFromPtr(src.pixels.?), src.pitch / 2, src.height, sx + shift, sy, run, height, dma2d.pbyte_2);
    dma2d.describe(parts.receive, @intFromPtr(dest.pixels.?), dest.pitch / 2, dest.height, middle.start, dy, run, height, dma2d.pbyte_2);
    const asleep = prepare(engine, sys, watched);
    dma2d.runOut(send_channel, parts.send_at);
    dma2d.runIn(receive_channel, parts.receive_at);

    copyByCpu(src, dest, sx, sy, dx, dy, shift, height);
    copyByCpu(src, dest, sx + (middle.end - dx), sy, middle.end, dy, dx + width - middle.end, height);

    const done = wait(engine, sys, asleep);
    forget(sys, dest, middle, dy, height);
    // As for a fill: the middle too, from a source the copy never writes.
    if (!done) copyByCpu(src, dest, sx + shift, sy, middle.start, dy, run, height);
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

/// A job the engine did not take, counted: RTGERR_NOT_SUPPORTED, and the
/// caller does all of it itself. Only where nothing of the buffer has
/// been written - a job that wrote any of it is finished by the CPU and
/// answered RTGERR_OK.
///
/// INPUTS:
/// - `engine` - the engine, for its count.
pub fn failed(engine: *Engine) i32 {
    engine.failures +%= 1;
    return err.RTGERR_NOT_SUPPORTED;
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// What needs no engine: which part of a row is the engine's, whether a
// copy reads what it writes, and the CPU's fill and copy of a
// rectangle's ends and middle.

const testing = @import("std").testing;

test "the engine's part of a row: from the first line boundary in it to the last" {
    // Whole lines, and a run that starts and ends inside one.
    try testing.expectEqual(Middle{ .start = 0, .end = 64 }, middleOf(0, 64));
    try testing.expectEqual(Middle{ .start = 32, .end = 64 }, middleOf(1, 64));
    try testing.expectEqual(Middle{ .start = 64, .end = 128 }, middleOf(33, 100));
    // No whole line in it: the middle is empty, wherever it is put.
    for ([_][2]u32{ .{ 31, 2 }, .{ 5, 20 }, .{ 32, 31 }, .{ 0, 31 }, .{ 63, 32 } }) |run| {
        const middle = middleOf(run[0], run[1]);
        try testing.expectEqual(middle.start, middle.end);
    }
    // For every run: the middle is whole lines inside it, and the two
    // ends are less than a line each - ends and middle are the run once.
    var x: u32 = 0;
    while (x < 70) : (x += 1) {
        var width: u32 = 1;
        while (width < 140) : (width += 1) {
            const middle = middleOf(x, width);
            try testing.expect(middle.start % line_pixels == 0 and middle.end % line_pixels == 0);
            try testing.expect(middle.start >= x and middle.end >= middle.start);
            if (middle.end > middle.start) {
                try testing.expect(middle.end <= x + width);
                try testing.expect(middle.start - x < line_pixels and x + width - middle.end < line_pixels);
            }
        }
    }
}

test "a copy that reads what it writes: one buffer's rectangles that meet, or two descriptions of one memory" {
    var memory: [16 * 64]u8 align(64) = undefined;
    var other: [16 * 64]u8 align(64) = undefined;
    const one = rtg.RtgBitMap{ .pixels = &memory, .width = 32, .height = 16, .pitch = 64, .size_bytes = memory.len, .format = .rgb565 };
    const two = rtg.RtgBitMap{ .pixels = &other, .width = 32, .height = 16, .pitch = 64, .size_bytes = other.len, .format = .rgb565 };
    const first = struct {
        fn of(bitmap: *const rtg.RtgBitMap, what: rtg.RtgCopy) usize {
            return rowAddress(bitmap, @intCast(what.src_x), @intCast(what.src_y));
        }
        fn end(bitmap: *const rtg.RtgBitMap, what: rtg.RtgCopy) usize {
            return rowAddress(bitmap, @intCast(what.src_x + what.width), @intCast(what.src_y + what.height - 1));
        }
    };

    // Two buffers: never.
    const across = rtg.RtgCopy{ .src_x = 0, .src_y = 0, .width = 32, .height = 16, .dest_x = 0, .dest_y = 0 };
    try testing.expect(!overlapping(&one, &two, first.of(&one, across), first.end(&one, across), &across));
    // One buffer, rectangles apart - side by side in the same rows, whose
    // spans of memory cross - and rectangles that meet.
    const beside = rtg.RtgCopy{ .src_x = 0, .src_y = 0, .width = 8, .height = 8, .dest_x = 16, .dest_y = 0 };
    try testing.expect(!overlapping(&one, &one, first.of(&one, beside), first.end(&one, beside), &beside));
    const below = rtg.RtgCopy{ .src_x = 0, .src_y = 0, .width = 32, .height = 4, .dest_x = 0, .dest_y = 8 };
    try testing.expect(!overlapping(&one, &one, first.of(&one, below), first.end(&one, below), &below));
    const meeting = rtg.RtgCopy{ .src_x = 0, .src_y = 0, .width = 8, .height = 8, .dest_x = 4, .dest_y = 4 };
    try testing.expect(overlapping(&one, &one, first.of(&one, meeting), first.end(&one, meeting), &meeting));
    // One memory described twice, its spans crossing: taken as meeting.
    // From another first byte with the same pitch the columns count from
    // different places, and with another pitch they say nothing.
    const inside = rtg.RtgCopy{ .src_x = 0, .src_y = 0, .width = 8, .height = 8, .dest_x = 8, .dest_y = 0 };
    const shifted = rtg.RtgBitMap{ .pixels = memory[16..], .width = 24, .height = 16, .pitch = 64, .size_bytes = memory.len - 16, .format = .rgb565 };
    try testing.expect(overlapping(&shifted, &one, first.of(&shifted, inside), first.end(&shifted, inside), &inside));
    const narrow = rtg.RtgBitMap{ .pixels = &memory, .width = 16, .height = 32, .pitch = 32, .size_bytes = memory.len, .format = .rgb565 };
    try testing.expect(overlapping(&one, &narrow, first.of(&one, inside), first.end(&one, inside), &inside));
}

test "the CPU's ends and its middle fill and copy a rectangle once, and nothing beside it" {
    // Four rows of 96 pixels. The rectangle is columns 5 to 85 of rows 1
    // and 2: the engine's part of it is 32 to 64, the CPU's the two ends
    // - and, where the engine does not end its job, that part too.
    var pixels: [4 * 96]u16 align(64) = @splat(0);
    const dest = rtg.RtgBitMap{ .pixels = @ptrCast(&pixels), .width = 96, .height = 4, .pitch = 192, .size_bytes = 4 * 192, .format = .rgb565 };
    const x = 5;
    const width = 80;
    const y = 1;
    const rows = 2;
    const middle = middleOf(x, width);
    try testing.expectEqual(Middle{ .start = 32, .end = 64 }, middle);

    fillByCpu(&dest, x, middle.start, y, rows, 0x1234);
    fillByCpu(&dest, middle.end, x + width, y, rows, 0x1234);
    fillByCpu(&dest, middle.start, middle.end, y, rows, 0x1234);
    for (0..4) |row| for (0..96) |column| {
        const inside_it = row >= y and row < y + rows and column >= x and column < x + width;
        try testing.expectEqual(@as(u16, if (inside_it) 0x1234 else 0), pixels[row * 96 + column]);
    };

    // A copy from a buffer whose pixels say where they are, its rectangle
    // at another column and another row than the destination's: the two
    // ends and the middle, as `copy` hands them over.
    @memset(&pixels, 0);
    var source_pixels: [4 * 96]u16 align(64) = undefined;
    for (&source_pixels, 0..) |*pixel, index| pixel.* = @intCast(0x1000 + index);
    const src = rtg.RtgBitMap{ .pixels = @ptrCast(&source_pixels), .width = 96, .height = 4, .pitch = 192, .size_bytes = 4 * 192, .format = .rgb565 };
    const sx = 3;
    const sy = 2;
    const shift = middle.start - x;
    copyByCpu(&src, &dest, sx, sy, x, y, shift, rows);
    copyByCpu(&src, &dest, sx + (middle.end - x), sy, middle.end, y, x + width - middle.end, rows);
    copyByCpu(&src, &dest, sx + shift, sy, middle.start, y, middle.end - middle.start, rows);
    for (0..4) |row| for (0..96) |column| {
        const inside_it = row >= y and row < y + rows and column >= x and column < x + width;
        const expected: u16 = if (inside_it) @intCast(0x1000 + (row - y + sy) * 96 + (column - x + sx)) else 0;
        try testing.expectEqual(expected, pixels[row * 96 + column]);
    };
}

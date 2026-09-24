// SPDX-License-Identifier: MPL-2.0
//! Bringing an RGB panel up, feeding it, and giving it back.
//!
//! The peripheral asks for pixels continuously and a DMA chain feeds it:
//! there is no frame to kick off and no interrupt to service. Set the
//! timings, point a looping chain at memory, start it, and the panel
//! refreshes for as long as the board is on.
//!
//! What it is fed from is the awkward part. It is **not** fed from PSRAM.
//! Measured on this board with the panel fed straight out of it and
//! nothing else running, the DMA fell behind by 66 pixels a frame - about
//! two microseconds of stall, which is what the memory's own refresh costs
//! - and by half as much again with the CPU working. The pixel FIFO holds
//! about a microsecond, so every such stall is pixels the panel never
//! gets, and the picture slips sideways for good. So the panel reads two
//! small buffers in internal memory, and a second DMA channel copies the
//! picture into the one it has just finished with. The copy is the DMA's
//! and not the CPU's because the panel needs 39 MB/s of it continuously
//! and this machine's CPU copies memory at about half that.
//!
//! Everything here belongs to one panel and lives in the `Panel` the
//! library allocated for the board: nothing is kept in this module's own
//! image, so the interrupt servers are handed the panel as their data.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const rtg = sdk.rtg;
const err = rtg.errors;
const dmares = sdk.resources.dma;
const expander = sdk.resources.expander;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
const intbits = sdk.hardware.intbits;

const lcd = @import("lcd.zig");
const cpu = @import("sdk").hardware.cpu;
const systimer = sdk.hardware.systimer;
const config = @import("config.zig");
const stream = @import("stream.zig");

const MODULE_NAME = "rtg-rgb";

/// One panel: what it is, what it is running on, and how it is doing.
/// This is the board's instance, allocated and cleared by the library.
pub const Panel = struct {
    sys: *ExecBase,
    rtg_base: *RtgBase,
    board: *rtg.RtgBoard,
    config: config.Config = .{},
    /// The one mode this panel has.
    mode: rtg.RtgMode = .{},

    /// The framebuffer: what AllocMem gave, and the frame inside it that
    /// starts on a cache line.
    frame_memory: ?[*]u8 = null,
    frame_taken: usize = 0,
    frame: ?[*]u8 = null,
    frame_bytes: usize = 0,

    /// The pads the panel is on - its colour bits, its four timing
    /// signals, and those of its control lines that are pads of the chip -
    /// taken from gpio.resource while the board exists.
    gpio_base: ?*GpioBase = null,
    held_pads: [max_pads]u8 = @splat(0),
    held_count: u32 = 0,

    dma: ?*dmares.DmaBase = null,
    /// The panel's channel and the ring it runs round the two buffers.
    channel: u32 = 0,
    chain: ?*dmares.DMADescriptor = null,
    /// The channel the copy runs on.
    copy_channel: u32 = 0,
    has_channels: bool = false,

    /// The two buffers the panel is really fed from, in internal memory.
    bounce: ?[*]u8 = null,
    bounce_bytes: u32 = 0,
    /// How many bufferfuls a frame is.
    stretches: u32 = 0,
    bounce_chain: [2]?*dmares.DMADescriptor = .{ null, null },
    fill_into: [2]?*dmares.DMADescriptor = .{ null, null },
    /// The copy's chain out of each stretch of the frame, one per stretch,
    /// built when a buffer is shown: the copy's interrupt has no time to
    /// build one, and they change only when the picture does.
    fill_from: ?[*]?*dmares.DMADescriptor = null,
    /// Which buffer the panel finishes next, and which stretch goes in it.
    next_buffer: u32 = 0,
    next_stretch: u32 = 0,

    buffer_done: exec.Interrupt = .{},
    vblank: exec.Interrupt = .{},
    /// Whether the pixel stream is running at all.
    streaming: bool = false,
    /// Whether it has been put in step since it was started, and where the
    /// active area is to go at the next blanking.
    aligned: bool = false,
    want_start: ?u32 = null,

    /// What a frame and a line cost in CPU cycles, from the panel's own
    /// numbers, and what a microsecond is: the measurements below are made
    /// against these.
    frame_cycles: u32 = 0,
    line_cycles: u32 = 0,
    fill_cycles: u32 = 0,
    cycles_per_us: u32 = 1,
    last_cycles: u32 = 0,
    last_at: u32 = 0,

    /// Everything the board reports about how the stream is doing.
    stats: rtg.RtgBoardStats = .{},
};

/// The panel's own numbers turned into what the counters are measured
/// against.
fn measureAgainst(panel: *Panel) void {
    const setup = &panel.config.setup;
    const per_pixel = sdk.hardware.CPU_HZ / @max(setup.pixel_clock_hz, 1);
    const line_total = setup.hsync_pulse + setup.hsync_back_porch + setup.width + setup.hsync_front_porch;
    const frame_lines = setup.vsync_pulse + setup.vsync_back_porch + setup.height + setup.vsync_front_porch;
    panel.line_cycles = line_total * per_pixel;
    panel.frame_cycles = line_total * frame_lines * per_pixel;
    panel.cycles_per_us = @max(sdk.hardware.CPU_HZ / 1_000_000, 1);
    // Long enough for the DMA's first bytes to reach the pixel FIFO, about
    // a microsecond: the generator is started with something in it, not
    // with a line of whatever an empty FIFO answers.
    panel.fill_cycles = panel.cycles_per_us;
}

fn openExpander(panel: *Panel) ?*sdk.interface.expander.ExpanderBase {
    const base = panel.sys.OpenResource(expander.EXPANDERNAME) orelse return null;
    return @ptrCast(@alignCast(base));
}

/// A control line, wherever the board has it wired.
fn setLine(panel: *Panel, pin: sdk.expansion.BoardPin, on: bool) bool {
    const level = if (pin.active_low != 0) !on else on;
    return switch (pin.kind) {
        sdk.expansion.boardpin.BPIN_EXPANDER => blk: {
            const ex = openExpander(panel) orelse break :blk false;
            break :blk ex.SetPin(pin.number, level);
        },
        sdk.expansion.boardpin.BPIN_GPIO => blk: {
            const gpio = @import("sdk").hardware.gpio;
            gpio.outputEnable(pin.number, true);
            gpio.setLevel(pin.number, level);
            break :blk true;
        },
        // Not wired: nothing to do, and not a failure.
        else => true,
    };
}

/// The panel's display enable, for the op that offers it.
pub fn setDisplayLine(panel: *Panel, on: bool) bool {
    return setLine(panel, panel.config.display_pin, on);
}

/// A wait that does not Wait: this runs at cold start, under the display
/// module's Forbid, where giving the CPU away would break it.
fn sleep(ms: u32) void {
    systimer.spinUs(@as(u64, ms) * 1000);
}

/// Everything but the pixels: the panel out of reset, its memory, its two
/// DMA channels and the buffers it is fed from. The stream is not started
/// here - the first picture is drawn and written back while nothing is
/// reading it, and `start` is what sets it going.
pub fn bringUp(panel: *Panel) i32 {
    lcd.enable();
    const sys = panel.sys;
    const setup = &panel.config.setup;
    if (!takePads(panel)) return err.RTGERR_IN_USE;

    measureAgainst(panel);

    // Out of reset and enabled before anything clocks it.
    _ = setLine(panel, panel.config.reset_pin, false);
    sleep(panel.config.reset_ms);
    _ = setLine(panel, panel.config.reset_pin, true);
    _ = setLine(panel, panel.config.display_pin, true);
    sleep(panel.config.settle_ms);

    // The framebuffer. It starts and ends on a cache line: the DMA reaches
    // PSRAM through the cache controller and asks for whole lines, and
    // exec's allocator promises eight bytes.
    const line = sdk.hardware.DCACHE_LINE_SIZE;
    panel.frame_bytes = @as(usize, setup.width) * setup.height * (setup.bits_per_pixel / 8);
    panel.frame_taken = panel.frame_bytes + line - 1;
    const got = sys.AllocMem(panel.frame_taken, exec.MEMF_EXTERNAL | exec.MEMF_CLEAR) orelse
        return giveBack(panel, err.RTGERR_NO_MEMORY);
    panel.frame_memory = @ptrCast(got);
    panel.frame = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(got), line));

    // How the picture is cut into bufferfuls. A frame has to be a whole
    // number of them, or the two would drift apart by construction.
    panel.bounce_bytes = panel.config.bounce_lines * setup.width * (setup.bits_per_pixel / 8);
    if (panel.config.bounce_lines == 0 or setup.height % panel.config.bounce_lines != 0) {
        return giveBack(panel, err.RTGERR_BAD_TAGS);
    }
    panel.stretches = setup.height / panel.config.bounce_lines;

    const db: *dmares.DmaBase = @ptrCast(sys.OpenResource(dmares.DMANAME) orelse
        return giveBack(panel, err.RTGERR_NO_DISPLAY));
    panel.dma = db;

    var ch: u32 = 0;
    while (ch < dmares.DMA_CHANNELS) : (ch += 1) {
        if (db.AllocDMAChannel(ch, MODULE_NAME) == null) break;
    } else return giveBack(panel, err.RTGERR_IN_USE);
    panel.channel = ch;
    var copy_ch: u32 = ch + 1;
    while (copy_ch < dmares.DMA_CHANNELS) : (copy_ch += 1) {
        if (db.AllocDMAChannel(copy_ch, MODULE_NAME) == null) break;
    } else {
        db.FreeDMAChannel(ch);
        return giveBack(panel, err.RTGERR_IN_USE);
    }
    panel.copy_channel = copy_ch;
    panel.has_channels = true;

    // The panel's channel reads internal memory, so it wants no PSRAM
    // block size; the copy's channel does. The panel cannot wait - twenty
    // pixels of blanking is no time to make up a shortfall - so it
    // outranks everything else on the bus.
    if (!db.ConnectDMAChannel(ch, lcd.dma_peripheral, dmares.DMACF_LOOP | dmares.DMACF_BURST)) {
        return giveBack(panel, err.RTGERR_NO_DISPLAY);
    }
    _ = db.SetDMAPriority(ch, dmares.DMA_OUT, panel.config.dma_priority);
    // DMACF_LOOP on the copy is not about looping: it is what leaves the
    // owner bit alone, so a chain can be started again and again. Sixty
    // starts a frame would otherwise need every descriptor handed back.
    if (!db.ConnectDMAChannel(copy_ch, dmares.DMAPERI_MEMORY, dmares.DMACF_LOOP | dmares.DMACF_BURST | dmares.DMACF_WIDE)) {
        return giveBack(panel, err.RTGERR_NO_DISPLAY);
    }
    const under = if (panel.config.dma_priority == 0) 0 else panel.config.dma_priority - 1;
    _ = db.SetDMAPriority(copy_ch, dmares.DMA_OUT, under);
    _ = db.SetDMAPriority(copy_ch, dmares.DMA_IN, under);

    // The two buffers, and the ring the panel's channel runs round them
    // for ever.
    const b = sys.AllocMem(2 * panel.bounce_bytes, exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse
        return giveBack(panel, err.RTGERR_NO_MEMORY);
    panel.bounce = @ptrCast(b);
    for (0..2) |i| {
        const at: *anyopaque = @ptrFromInt(@intFromPtr(b) + i * panel.bounce_bytes);
        panel.bounce_chain[i] = db.AllocDMAChain(dmares.DMA_OUT, at, panel.bounce_bytes, 0) orelse
            return giveBack(panel, err.RTGERR_NO_MEMORY);
        panel.fill_into[i] = db.AllocDMAChain(dmares.DMA_IN, at, panel.bounce_bytes, 0) orelse
            return giveBack(panel, err.RTGERR_NO_MEMORY);
    }
    lastOf(panel.bounce_chain[0].?).next = panel.bounce_chain[1];
    lastOf(panel.bounce_chain[1].?).next = panel.bounce_chain[0];
    panel.chain = panel.bounce_chain[0];

    // Room for one chain per stretch of the picture. What they point at is
    // decided when a buffer is shown.
    // Read from the refill interrupt, so it goes where that can read it
    // without waiting on the stream.
    const chains = sys.AllocVec(panel.stretches * @sizeOf(?*dmares.DMADescriptor), exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse
        return giveBack(panel, err.RTGERR_NO_MEMORY);
    panel.fill_from = @ptrCast(@alignCast(chains));

    // The panel's channel says when a buffer is free; its own interrupt
    // says when a frame has ended.
    panel.buffer_done = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = @ptrCast(panel),
        .code = @ptrCast(&bufferServer),
    };
    sys.AddIntServer(dmares.dmaIntNumber(ch, dmares.DMA_OUT), &panel.buffer_done);
    db.EnableDMAInts(ch, dmares.DMA_OUT, dmares.DMAINTF_OUT_EOF);

    panel.vblank = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = @ptrCast(panel),
        .code = @ptrCast(&vblankServer),
    };
    lcd.intClear(lcd.INT_VSYNC);
    sys.AddIntServer(intbits.INTB_LCD_CAM, &panel.vblank);
    return err.RTGERR_OK;
}

/// The pads, the timings and the clock. Separate from bring-up because a
/// mode is set through the library and may be set again.
pub fn program(panel: *Panel) i32 {
    lcd.pins(&panel.config.setup);
    lcd.setUp(&panel.config.setup);
    return err.RTGERR_OK;
}

/// Feed the panel from `pixels` and start it. The chains over the picture
/// are built here, so showing another buffer is showing another picture.
pub fn start(panel: *Panel, pixels: [*]u8) i32 {
    const db = panel.dma orelse return err.RTGERR_NO_DISPLAY;
    const from = panel.fill_from orelse return err.RTGERR_NO_DISPLAY;

    if (panel.streaming) stream.stopStream(panel);
    for (0..panel.stretches) |i| {
        if (from[i]) |old| db.FreeDMAChain(old);
        const at: *anyopaque = @ptrFromInt(@intFromPtr(pixels) + i * panel.bounce_bytes);
        from[i] = db.AllocDMAChain(dmares.DMA_OUT, at, panel.bounce_bytes, 0) orelse
            return err.RTGERR_NO_MEMORY;
    }

    // Emptied here rather than in `program`: the FIFO must be empty at the
    // instant the DMA begins, and that is a long way from the timings.
    primeBuffers(panel);
    lcd.fifoReset();
    if (!db.StartDMA(panel.channel, dmares.DMA_OUT, panel.chain.?)) return err.RTGERR_NO_DISPLAY;
    lcd.start();
    panel.streaming = true;
    // `lcd_start` began a frame wherever the timing generator had got to,
    // so the picture and the frame are not in step yet. The first blanking
    // puts them there.
    panel.aligned = false;
    lcd.intEnable(lcd.INT_VSYNC);
    return err.RTGERR_OK;
}

/// Undo whatever was taken, and answer with `code`.
pub fn giveBack(panel: *Panel, code: i32) i32 {
    const sys = panel.sys;
    if (panel.streaming) {
        lcd.stop();
        panel.streaming = false;
    }
    if (panel.vblank.code != null) {
        sys.RemIntServer(intbits.INTB_LCD_CAM, &panel.vblank);
        panel.vblank.code = null;
    }
    if (panel.dma) |db| {
        if (panel.buffer_done.code != null) {
            db.EnableDMAInts(panel.channel, dmares.DMA_OUT, 0);
            sys.RemIntServer(dmares.dmaIntNumber(panel.channel, dmares.DMA_OUT), &panel.buffer_done);
            panel.buffer_done.code = null;
        }
        if (panel.has_channels) {
            db.StopDMA(panel.channel, dmares.DMA_OUT);
            db.StopDMA(panel.copy_channel, dmares.DMA_OUT);
            db.StopDMA(panel.copy_channel, dmares.DMA_IN);
        }
        if (panel.fill_from) |from| {
            for (0..panel.stretches) |i| {
                if (from[i]) |c| db.FreeDMAChain(c);
            }
            sys.FreeVec(@ptrCast(from));
            panel.fill_from = null;
        }
        for (&panel.bounce_chain) |*c| {
            if (c.*) |chain| db.FreeDMAChain(chain);
            c.* = null;
        }
        for (&panel.fill_into) |*c| {
            if (c.*) |chain| db.FreeDMAChain(chain);
            c.* = null;
        }
        if (panel.has_channels) {
            db.FreeDMAChannel(panel.channel);
            db.FreeDMAChannel(panel.copy_channel);
            panel.has_channels = false;
        }
    }
    panel.chain = null;
    if (panel.bounce) |b| {
        sys.FreeMem(@ptrCast(b), 2 * panel.bounce_bytes);
        panel.bounce = null;
    }
    if (panel.frame_memory) |m| {
        sys.FreeMem(@ptrCast(m), panel.frame_taken);
        panel.frame_memory = null;
        panel.frame = null;
    }
    // The panel itself goes dark and back into reset, while its lines are
    // still this driver's.
    if (panel.held_count != 0 or panel.gpio_base == null) {
        _ = setLine(panel, panel.config.display_pin, false);
        _ = setLine(panel, panel.config.reset_pin, false);
    }
    if (panel.gpio_base) |gb| gpio_resource.freePads(gb, panel.held_pads[0..panel.held_count]);
    panel.held_count = 0;
    return code;
}

/// The most pads a panel is on: 24 colour bits, 4 timing signals, 3
/// control lines.
const max_pads = 24 + 4 + 3;

/// Every pad the panel is on, taken from gpio.resource. False if another
/// driver holds one; a machine without the resource takes nothing.
fn takePads(panel: *Panel) bool {
    const sys = panel.sys;
    const gb: *GpioBase = @ptrCast(@alignCast(sys.OpenResource(gpio_resource.GPIONAME) orelse return true));
    const setup = &panel.config.setup;
    var count: u32 = 0;
    const width = @min(setup.data_width, setup.data_pins.len);
    for (setup.data_pins[0..width]) |pad| {
        panel.held_pads[count] = pad;
        count += 1;
    }
    for ([_]u8{ setup.pclk_pin, setup.hsync_pin, setup.vsync_pin, setup.de_pin }) |pad| {
        panel.held_pads[count] = pad;
        count += 1;
    }
    const lines = [_]sdk.expansion.BoardPin{ panel.config.reset_pin, panel.config.display_pin, panel.config.backlight_pin };
    for (lines) |line| {
        if (line.kind != sdk.expansion.boardpin.BPIN_GPIO) continue;
        panel.held_pads[count] = line.number;
        count += 1;
    }
    if (gpio_resource.allocPads(gb, panel.held_pads[0..count], MODULE_NAME)) |refused| {
        exec.kprintf(sys, "%s: GPIO%d is %s's\n", .{ MODULE_NAME, refused.pad, refused.holder });
        panel.gpio_base = gb;
        return false;
    }
    panel.gpio_base = gb;
    panel.held_count = count;
    return true;
}

/// The last descriptor of a chain: the one the DMA reaches before the
/// chain ends or starts again.
fn lastOf(head: *dmares.DMADescriptor) *dmares.DMADescriptor {
    var d = head;
    while (d.next) |n| : (d = n) {
        if (n == head) break;
    }
    return d;
}

// --- feeding it -------------------------------------------------------------

/// Copy one stretch of the picture into one buffer. Both sides of the copy
/// channel are started on chains built in advance, so this is four
/// register writes and nothing else - it runs from the panel's own DMA
/// interrupt, sixty times a frame.
pub fn startCopy(panel: *Panel, into: u32, from: u32) void {
    const db = panel.dma orelse return;
    const chains = panel.fill_from orelse return;
    // The one before it had a buffer's worth of time - 460 microseconds
    // for ten lines - and takes about half that. Under a CPU working PSRAM
    // hard it can still be running, and a channel must not be started
    // again while it is: the rest of it is waited for here, since the
    // buffer it is writing is the one the panel reads next either way.
    if (panel.stats.refills > 2 and
        db.DMARawIntStatus(panel.copy_channel, dmares.DMA_IN) & dmares.DMAINTF_IN_SUC_EOF == 0)
    {
        panel.stats.late_refills +%= 1;
        waitCopy(panel);
    }
    db.ClearDMAInts(panel.copy_channel, dmares.DMA_IN, dmares.DMAINTF_IN_SUC_EOF);
    _ = db.StartDMA(panel.copy_channel, dmares.DMA_IN, panel.fill_into[into].?);
    _ = db.StartDMA(panel.copy_channel, dmares.DMA_OUT, chains[from].?);
    panel.stats.refills +%= 1;
}

/// Wait for the copy in flight, which is only ever done while the panel is
/// stopped: at bring-up, and at a realignment.
pub fn waitCopy(panel: *Panel) void {
    const db = panel.dma orelse return;
    var spins: u32 = 0;
    while (db.DMARawIntStatus(panel.copy_channel, dmares.DMA_IN) & dmares.DMAINTF_IN_SUC_EOF == 0) {
        spins += 1;
        if (spins > 1_000_000) return; // something is wrong; do not hang the boot
    }
}

/// Both buffers filled with the top of the picture, and the counters set
/// to match: the panel is about to be started on the first of them.
pub fn primeBuffers(panel: *Panel) void {
    startCopy(panel, 0, 0);
    waitCopy(panel);
    startCopy(panel, 1, 1);
    waitCopy(panel);
    panel.next_buffer = 0;
    panel.next_stretch = 2 % panel.stretches;
}

/// The panel has finished with a buffer: fill it with the next stretch of
/// the picture while it reads the other one.
fn bufferServer(is_data: ?*anyopaque, _: u32) callconv(.c) i32 {
    const panel: *Panel = @ptrCast(@alignCast(is_data.?));
    const db = panel.dma orelse return 0;
    if (db.DMAIntStatus(panel.channel, dmares.DMA_OUT) & dmares.DMAINTF_OUT_EOF == 0) return 0;
    db.ClearDMAInts(panel.channel, dmares.DMA_OUT, dmares.DMAINTF_OUT_EOF);
    startCopy(panel, panel.next_buffer, panel.next_stretch);
    panel.next_buffer ^= 1;
    panel.next_stretch += 1;
    if (panel.next_stretch == panel.stretches) panel.next_stretch = 0;
    return 1;
}

/// The frame has ended: count it, see whether the stream kept up, and put
/// it back in step if it did not.
///
/// The stream can slip. If the panel asks for a pixel the DMA has not
/// fetched, every pixel after it arrives that much late: the picture is
/// offset from then on, and offset further by the next shortfall - it
/// rolls. Putting it back means starting the picture and the frame
/// **together**, which is what `stream.restart` does and why it is the
/// only code the panel's timing depends on.
///
/// It is not free, which is why it is not done every frame: the panel is
/// counting its own lines all the while. So the stream is left alone
/// unless it has something to fix, and the hardware says when - the DMA's
/// own FIFO raises `DMAINTF_OUT_FIFO_UDF` when the panel asks it for a
/// pixel it has not got, which is the shortfall itself, before its
/// consequence is visible.
fn vblankServer(is_data: ?*anyopaque, _: u32) callconv(.c) i32 {
    const panel: *Panel = @ptrCast(@alignCast(is_data.?));
    if (lcd.intStatus() & lcd.INT_VSYNC == 0) return 0; // not ours
    lcd.intClear(lcd.INT_VSYNC);
    panel.stats.frames +%= 1;

    const now = cpu.ccount();
    const took = now -% panel.last_cycles;
    panel.last_cycles = now;
    if (panel.stats.frames > 1 and took > panel.frame_cycles + panel.line_cycles) {
        panel.stats.late_frames +%= 1;
        const late_us = (took - panel.frame_cycles) / panel.cycles_per_us;
        if (late_us > panel.stats.worst_late_us) panel.stats.worst_late_us = late_us;
    }

    const db = panel.dma orelse return 1;

    // Did the panel ask for a pixel the DMA had not fetched? The bit stays
    // set until it is cleared, so one per frame is what this counts.
    const raw = db.DMARawIntStatus(panel.channel, dmares.DMA_OUT);
    if (raw & dmares.DMAINTF_OUT_FIFO_UDF != 0) {
        panel.stats.starved_frames +%= 1;
        db.ClearDMAInts(panel.channel, dmares.DMA_OUT, dmares.DMAINTF_OUT_FIFO_UDF);
    }

    // Which stretch the copy is about to fetch. In step it is the same
    // number at every blanking, since a frame is exactly `stretches`
    // bufferfuls: anything else means a buffer's worth of picture was
    // missed, and the panel is showing the frame shifted.
    const at = panel.next_stretch;
    if (panel.stats.frames > 2) {
        const walk = @as(i32, @intCast(at)) - @as(i32, @intCast(panel.last_at));
        if (walk != 0) panel.stats.total_walk +%= walk;
        panel.stats.walk_frames +%= 1;
    }
    panel.last_at = at;
    panel.stats.stream_at = at;

    if (panel.aligned) return 1;
    panel.aligned = true;
    panel.stats.realigns +%= 1;

    // Nothing may run between stopping the generator and starting it
    // again. The panel is counting its own lines through that gap, so it
    // is held as short as it can be made: interrupts off, and the sequence
    // itself in internal memory.
    stream.stopStream(panel);
    primeBuffers(panel);
    panel.sys.Disable();
    const gap = stream.restart(panel);
    panel.sys.Enable();

    const gap_us = gap / panel.cycles_per_us;
    panel.stats.last_gap_us = gap_us;
    if (gap_us > panel.stats.worst_gap_us) panel.stats.worst_gap_us = gap_us;
    if (gap_us > 5) panel.stats.slow_gaps +%= 1;
    if (gap > panel.line_cycles) panel.stats.long_gaps +%= 1;
    return 1;
}

/// Put the stream back in step at the next blanking. Nothing should need
/// this once the panel is running; it is here because a picture that has
/// been knocked sideways can be put right without a reset.
pub fn realign(panel: *Panel) void {
    panel.aligned = false;
}

/// Start the counters again, so a stretch can be measured on its own.
pub fn resetStats(panel: *Panel) void {
    panel.stats = .{};
}

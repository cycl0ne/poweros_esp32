// SPDX-License-Identifier: MPL-2.0
//! The chip's I2S controller as a line: the stream a codec or an
//! amplifier is fed over, and - for a codec that sends - the stream it is
//! read over.
//!
//! A module of its own: it opens rta.library at cold start and hands in a
//! driver of the transport kind, and from then on a sink's or a source's
//! driver that asks for an "i2s" line, with its part's tags, gets one of
//! these. The part's tags name the pads: the bit clock, the word clock and
//! the data out, the master clock for a codec that counts in it - an
//! amplifier that recovers its clock from the bit clock has no pad for it
//! - and the data in, for a part that sends; a line without it has no way
//! in.
//!
//! Nothing is touched until a way of the line is started. The first takes
//! the pads from gpio.resource, a DMA channel from dma.resource and the
//! rings' memory, clocks the controller (`esp32s3/i2s.zig`,
//! `esp32p4/i2s.zig`) - its receiver beside its transmitter, on the same
//! clocks - and starts the stream out on silence. The ring out is two
//! buffers, a descriptor apiece linked head to tail: the DMA runs round
//! them for ever and raises an interrupt at the end of each, the interrupt
//! signals the task the sink was started for, and the task fills the one
//! just played - so the stream is fed a buffer ahead of itself.
//!
//! The way in is the same ring the other way round, on the other side of
//! the same DMA channel: the controller says the end of each buffer it has
//! filled, the interrupt signals the source's task, and the task takes the
//! buffer while the next is filled. The receiver runs on the
//! transmitter's clocks, so the stream out runs - on silence, with no task
//! to fill it - for as long as the way in does, and the two run at one
//! rate: the way started second takes the rate the line runs at, or is
//! refused. The last way to stop gives everything back.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rta = sdk.rta;
const TagItem = sdk.utility.TagItem;
const UtilityBase = sdk.interface.utility.UtilityBase;
const RtaBase = sdk.interface.rta.RtaBase;
const err = rta.errors;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const BoardPin = expansion.BoardPin;
const dmares = sdk.resources.dma;
const gpio = sdk.hardware.gpio;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;

/// The chip's controller.
const controller = switch (sdk.hardware.chip) {
    .esp32s3 => @import("esp32s3/i2s.zig"),
    .esp32p4 => @import("esp32p4/i2s.zig"),
    .rv64sbi, .a64psci => @compileError("rta i2s: this chip has no I2S controller driven yet"),
};

const MODULE_NAME = "rta-i2s";
const DRIVER_NAME = "i2s";
const VERSION = 1;
const REVISION = 2;
const BUILD_DATE = "20.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// Each ring: two buffers, each of `buffer_frames` stereo frames. One
/// plays - or fills - while the task has the other, so it has a buffer's
/// worth of time for it: about five milliseconds at 48 kHz.
const buffer_frames: u32 = 256;
const buffer_samples: u32 = buffer_frames * 2;
const buffer_bytes: u32 = buffer_samples * 2;
const buffers: u32 = 2;
const ring_bytes: u32 = buffer_bytes * buffers;
/// The way in's ring starts on a boundary of the data cache's lines, and
/// its buffers are whole lines: dropping a line the DMA wrote drops
/// nothing of anyone else's.
const line_align: u32 = 128;

/// A line the part does not bring out: the master clock, for an
/// amplifier; the data in, for a part that only listens.
const no_pad: u8 = 0xFF;

/// Everything this driver has that changes, allocated once by the init: a
/// ROM image is read only, so the driver node and the libraries it calls
/// live in memory and every entry point finds them again through the
/// node, which is a field of this block.
const State = struct {
    driver: rta.RtaDriver = .{},
    sys: *ExecBase,
    utility: *UtilityBase,
};

fn stateOf(driver: *rta.RtaDriver) *State {
    return @fieldParentPtr("driver", driver);
}

/// One ring: its buffers and a descriptor apiece, its interrupt, the task
/// it signals and with what, and the buffers its interrupt has counted and
/// the count the last one was taken at - more than one between two takes
/// is a buffer the DMA went round to before the task had it.
const Ring = struct {
    frames: ?[*]i16 = null,
    chain: [buffers]?*dmares.DMADescriptor = @splat(null),
    int: exec.Interrupt = .{},
    int_added: bool = false,
    task: ?*exec.Task = null,
    signal_mask: u32 = 0,
    ended: u32 = 0,
    taken: u32 = 0,
};

/// What one line keeps. The interrupts read it, so it is in internal
/// memory (RTADF_INTERNAL_INSTANCE).
const Instance = struct {
    sys: *ExecBase,
    /// The part's pads: the clocks and the data out, the master clock and
    /// the data in `no_pad` for a part that has none.
    mclk_pin: u8 = no_pad,
    bclk_pin: u8 = 0,
    ws_pin: u8 = 0,
    data_out_pin: u8 = 0,
    data_in_pin: u8 = no_pad,
    /// The pads while they are this line's, and where they came from.
    gpio_base: ?*GpioBase = null,
    held: [5]u8 = @splat(0),
    held_count: u8 = 0,
    has_channel: bool = false,
    /// The line is up - its clocks running, the stream out going - and at
    /// what rate; and which ways a sink or a source has started.
    up: bool = false,
    out_on: bool = false,
    in_on: bool = false,
    rate: u32 = 0,
    dma: ?*dmares.DmaBase = null,
    channel: u32 = 0,
    /// The block the rings live in.
    memory: ?*anyopaque = null,
    out: Ring = .{},
    in: Ring = .{},
};

fn instanceOf(io: *rta.AudioTransport) *Instance {
    return @ptrCast(@alignCast(io.instance.?));
}

fn createTransport(made_by: *rta.RtaDriver, io: *rta.AudioTransport, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    const ub = state.utility;
    const instance = instanceOf(io);
    instance.* = .{ .sys = state.sys };
    // The clocks and the data out are pads of the chip, or there is no
    // line.
    const lines = [_]sdk.utility.Tag{ st.PART_PinBCLK, st.PART_PinWS, st.PART_PinDataOut };
    var pads: [lines.len]u8 = undefined;
    for (lines, 0..) |tag, at| {
        const line = BoardPin.of(ub.GetTagData(tag, 0, tag_list));
        if (line.kind != expansion.boardpin.BPIN_GPIO) return err.RTAERR_BAD_TAGS;
        pads[at] = line.number;
    }
    instance.bclk_pin = pads[0];
    instance.ws_pin = pads[1];
    instance.data_out_pin = pads[2];
    const mclk = BoardPin.of(ub.GetTagData(st.PART_PinMCLK, 0, tag_list));
    if (mclk.kind == expansion.boardpin.BPIN_GPIO) instance.mclk_pin = mclk.number;
    const data_in = BoardPin.of(ub.GetTagData(st.PART_PinDataIn, 0, tag_list));
    if (data_in.kind == expansion.boardpin.BPIN_GPIO) instance.data_in_pin = data_in.number;
    instance.out.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = instance,
        .code = &outServer,
    };
    instance.in.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = instance,
        .code = &inServer,
    };
    io.ops = &ops;
    io.buffer_frames = buffer_frames;
    io.buffers = buffers;
    return err.RTAERR_OK;
}

/// A ring's buffer has ended: counted, and its task told.
fn ended(instance: *Instance, ring: *Ring) void {
    _ = @atomicRmw(u32, &ring.ended, .Add, 1, .release);
    if (ring.task) |task| instance.sys.Signal(task, ring.signal_mask);
}

/// The interrupt out: a buffer has been played, so the sink has one to
/// fill.
fn outServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const instance: *Instance = @ptrCast(@alignCast(is_data.?));
    const db = instance.dma orelse return 0;
    const status = db.DMAIntStatus(instance.channel, dmares.DMA_OUT);
    if (status & dmares.DMAINTF_OUT_EOF == 0) return 0;
    db.ClearDMAInts(instance.channel, dmares.DMA_OUT, status);
    ended(instance, &instance.out);
    return 1;
}

/// The interrupt in: a buffer has been filled, so the source has one to
/// take.
fn inServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const instance: *Instance = @ptrCast(@alignCast(is_data.?));
    const db = instance.dma orelse return 0;
    const status = db.DMAIntStatus(instance.channel, dmares.DMA_IN);
    if (status & dmares.DMAINTF_IN_SUC_EOF == 0) return 0;
    db.ClearDMAInts(instance.channel, dmares.DMA_IN, status);
    ended(instance, &instance.in);
    return 1;
}

/// The pads the controller drives and reads taken from gpio.resource.
/// False if another driver holds one; a machine without the resource takes
/// nothing.
fn takePads(instance: *Instance) bool {
    const sys = instance.sys;
    const gb: *GpioBase = @ptrCast(@alignCast(sys.OpenResource(gpio_resource.GPIONAME) orelse return true));
    var wanted: [5]u8 = @splat(0);
    var count: u8 = 0;
    for ([_]u8{ instance.mclk_pin, instance.bclk_pin, instance.ws_pin, instance.data_out_pin, instance.data_in_pin }) |pad| {
        if (pad == no_pad) continue;
        wanted[count] = pad;
        count += 1;
    }
    if (gpio_resource.allocPads(gb, wanted[0..count], MODULE_NAME)) |refused| {
        exec.kprintf(sys, "%s: GPIO%d is %s's\n", .{ MODULE_NAME, @as(u32, refused.pad), refused.holder });
        return false;
    }
    instance.gpio_base = gb;
    instance.held = wanted;
    instance.held_count = count;
    return true;
}

/// The pads connected to the controller's signals: the clocks the part
/// takes and the data out driven, the data in read.
fn connectPads(instance: *Instance) void {
    const pads = [_]struct { pin: u8, signal: u32 }{
        .{ .pin = instance.mclk_pin, .signal = controller.signal_mclk },
        .{ .pin = instance.bclk_pin, .signal = controller.signal_bclk },
        .{ .pin = instance.ws_pin, .signal = controller.signal_ws },
        .{ .pin = instance.data_out_pin, .signal = controller.signal_data_out },
    };
    for (pads) |pad| {
        if (pad.pin == no_pad) continue;
        gpio.toMatrix(pad.pin);
        gpio.connectOut(pad.pin, pad.signal, false);
        gpio.outputEnable(pad.pin, true);
    }
    if (instance.data_in_pin != no_pad) {
        gpio.toMatrix(instance.data_in_pin);
        gpio.outputEnable(instance.data_in_pin, false);
        gpio.inputEnable(instance.data_in_pin, true);
        gpio.connectIn(controller.signal_data_in, instance.data_in_pin);
    }
}

/// Whether the line can run at the mode's rate: one it is clocked for
/// already, or - while it is down - one the controller takes, sixteen bits
/// a sample either way.
fn modeFits(instance: *const Instance, mode: *const rta.AudioMode) bool {
    if (mode.bits != controller.bits_per_sample) return false;
    if (instance.up) return mode.rate == instance.rate;
    return controller.takes(mode.rate);
}

/// The ring's descriptors, one a buffer, linked head to tail. The links
/// are written after AllocDMAChain wrote the chains back, so they are
/// written back again.
fn makeChain(instance: *Instance, ring: *Ring, side: u32) bool {
    const sys = instance.sys;
    const db = instance.dma.?;
    const bytes: [*]u8 = @ptrCast(ring.frames.?);
    for (0..buffers) |i| {
        ring.chain[i] = db.AllocDMAChain(side, bytes + i * buffer_bytes, buffer_bytes, 0) orelse return false;
    }
    for (0..buffers) |i| {
        const one = ring.chain[i].?;
        one.next = ring.chain[(i + 1) % buffers];
        var descriptor_bytes: u32 = @sizeOf(dmares.DMADescriptor);
        _ = sys.CachePreDMA(@ptrCast(one), &descriptor_bytes, 0);
    }
    return true;
}

/// The line brought up at `rate`, in the order the parts want it: the
/// pads, the memory, a DMA channel and the descriptors, then the
/// controller's clocks - its receiver set up beside, for a part that
/// sends - its pads, and the stream out on silence.
fn lineUp(instance: *Instance, rate: u32) i32 {
    if (!takePads(instance)) return err.RTAERR_IN_USE;
    const code = startLine(instance, rate);
    if (code != err.RTAERR_OK) lineDown(instance);
    return code;
}

fn startLine(instance: *Instance, rate: u32) i32 {
    const sys = instance.sys;
    const has_input = instance.data_in_pin != no_pad;
    // The rings' memory, where the DMA can reach it. Where the data cache
    // covers it, the silence it starts with is written back, or the DMA
    // plays whatever was there before.
    const size: u32 = ring_bytes + (if (has_input) ring_bytes + line_align else 0);
    const memory = sys.AllocVec(size, exec.MEMF_INTERNAL | exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return err.RTAERR_NO_MEMORY;
    instance.memory = memory;
    var all: u32 = size;
    _ = sys.CachePreDMA(memory, &all, 0);
    instance.out.frames = @ptrCast(@alignCast(memory));
    if (has_input) {
        const after = @intFromPtr(memory) + ring_bytes;
        instance.in.frames = @ptrFromInt((after + line_align - 1) & ~@as(usize, line_align - 1));
    }

    // A channel of the engine that serves the controller: one the
    // controller cannot be connected to is given back, and the next tried.
    const db: *dmares.DmaBase = @ptrCast(sys.OpenResource(dmares.DMANAME) orelse return err.RTAERR_NO_OUTPUT);
    instance.dma = db;
    const channel = for (0..dmares.DMA_CHANNELS) |n| {
        const candidate: u32 = @intCast(n);
        if (db.AllocDMAChannel(candidate, MODULE_NAME) != null) continue;
        // Rings that never stop: the streams are endless, and a buffer
        // handed back would be a buffer the DMA stopped at.
        if (db.ConnectDMAChannel(candidate, controller.dma_peripheral, dmares.DMACF_LOOP)) break candidate;
        db.FreeDMAChannel(candidate);
    } else {
        exec.kprintf(sys, "%s: no DMA channel free\n", .{MODULE_NAME});
        return err.RTAERR_NO_OUTPUT;
    };
    instance.channel = channel;
    instance.has_channel = true;
    if (!makeChain(instance, &instance.out, dmares.DMA_OUT)) return err.RTAERR_NO_MEMORY;
    if (has_input and !makeChain(instance, &instance.in, dmares.DMA_IN)) return err.RTAERR_NO_MEMORY;

    // The controller, its pads, and the stream out running, with no task
    // to fill it until a sink starts.
    instance.out.task = null;
    instance.out.ended = 0;
    instance.out.taken = 0;
    controller.init(rate);
    if (has_input) controller.initInput(rate, buffer_bytes);
    connectPads(instance);
    controller.reset();
    _ = db.StartDMA(channel, dmares.DMA_OUT, instance.out.chain[0].?);
    db.EnableDMAInts(channel, dmares.DMA_OUT, dmares.DMAINTF_OUT_EOF);
    sys.AddIntServer(dmares.dmaIntNumber(channel, dmares.DMA_OUT), &instance.out.int);
    instance.out.int_added = true;
    controller.start();
    instance.up = true;
    instance.rate = rate;
    return err.RTAERR_OK;
}

/// The way in started on a line that is up: its ring from the first
/// buffer, its interrupt in, and the receiver on.
fn inputUp(instance: *Instance, task: *exec.Task, signal_mask: u32) void {
    const sys = instance.sys;
    const db = instance.dma.?;
    const ring = &instance.in;
    ring.ended = 0;
    ring.taken = 0;
    ring.signal_mask = signal_mask;
    ring.task = task;
    db.ResetDMA(instance.channel, dmares.DMA_IN);
    controller.resetInput();
    _ = db.StartDMA(instance.channel, dmares.DMA_IN, ring.chain[0].?);
    db.EnableDMAInts(instance.channel, dmares.DMA_IN, dmares.DMAINTF_IN_SUC_EOF);
    sys.AddIntServer(dmares.dmaIntNumber(instance.channel, dmares.DMA_IN), &ring.int);
    ring.int_added = true;
    controller.startInput();
}

/// The way in stopped: the receiver off, its interrupt out, its side of
/// the channel stopped. The line stays up.
fn inputDown(instance: *Instance) void {
    const sys = instance.sys;
    const ring = &instance.in;
    controller.stopInput();
    if (ring.int_added) sys.RemIntServer(dmares.dmaIntNumber(instance.channel, dmares.DMA_IN), &ring.int);
    ring.int_added = false;
    if (instance.dma) |db| {
        db.EnableDMAInts(instance.channel, dmares.DMA_IN, 0);
        db.StopDMA(instance.channel, dmares.DMA_IN);
    }
    ring.task = null;
}

/// Everything the line took given back: the controller stopped, its
/// interrupts out, the DMA channel and the memory freed, the pads free.
fn lineDown(instance: *Instance) void {
    const sys = instance.sys;
    if (instance.in.int_added) inputDown(instance);
    if (instance.up) controller.stop();
    instance.up = false;
    if (instance.out.int_added) sys.RemIntServer(dmares.dmaIntNumber(instance.channel, dmares.DMA_OUT), &instance.out.int);
    instance.out.int_added = false;
    if (instance.has_channel) {
        const db = instance.dma.?;
        db.StopDMA(instance.channel, dmares.DMA_OUT);
        db.EnableDMAInts(instance.channel, dmares.DMA_OUT, 0);
        db.StopDMA(instance.channel, dmares.DMA_IN);
        db.FreeDMAChannel(instance.channel);
        instance.has_channel = false;
    }
    if (instance.dma) |db| {
        for ([_]*Ring{ &instance.out, &instance.in }) |ring| {
            for (&ring.chain) |*chain| {
                if (chain.*) |one| db.FreeDMAChain(one);
                chain.* = null;
            }
        }
    }
    if (instance.memory) |memory| sys.FreeVec(memory);
    instance.memory = null;
    instance.out.frames = null;
    instance.in.frames = null;
    instance.out.task = null;
    instance.in.task = null;
    if (instance.gpio_base) |gb| gpio_resource.freePads(gb, instance.held[0..instance.held_count]);
    instance.gpio_base = null;
    instance.held_count = 0;
}

/// The way out started for a sink: the line brought up at its rate, or -
/// up already for the way in - joined at the rate it runs at.
fn start(io: *rta.AudioTransport, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = instanceOf(io);
    if (!modeFits(instance, mode)) return err.RTAERR_BAD_MODE;
    if (!instance.up) {
        const code = lineUp(instance, mode.rate);
        if (code != err.RTAERR_OK) return code;
    }
    const ring = &instance.out;
    ring.signal_mask = signal_mask;
    ring.taken = @atomicLoad(u32, &ring.ended, .acquire);
    ring.task = task;
    instance.out_on = true;
    return err.RTAERR_OK;
}

/// The way out stopped: the line goes down if the way in is not running,
/// and otherwise plays silence for the receiver's clocks.
fn stop(io: *rta.AudioTransport) callconv(.c) void {
    const instance = instanceOf(io);
    instance.out_on = false;
    instance.out.task = null;
    if (!instance.in_on) {
        lineDown(instance);
        return;
    }
    const frames = instance.out.frames orelse return;
    @memset(frames[0 .. buffer_samples * buffers], 0);
    var bytes: u32 = ring_bytes;
    _ = instance.sys.CachePreDMA(@ptrCast(frames), &bytes, 0);
}

fn destroy(io: *rta.AudioTransport) callconv(.c) void {
    lineDown(instanceOf(io));
}

/// The buffer a ring's DMA finished last, by the descriptor it says it
/// ended at; null if none has ended since the last ask, and more than one
/// counted in `missed`.
fn finished(instance: *Instance, ring: *Ring, side: u32, missed: *u32) ?[*]i16 {
    const count = @atomicLoad(u32, &ring.ended, .acquire);
    const behind = count -% ring.taken;
    if (behind == 0) return null;
    if (behind > 1) missed.* +%= behind - 1;
    ring.taken = count;
    const last = instance.dma.?.DMAEOFDescriptor(instance.channel, side);
    var which: usize = 0;
    for (ring.chain, 0..) |one, i| {
        if (one == last) which = i;
    }
    return ring.frames.? + which * buffer_samples;
}

/// The buffer that has just been played, which is the one to fill: the
/// DMA is in the other one now.
fn buffer(io: *rta.AudioTransport) callconv(.c) ?[*]i16 {
    const instance = instanceOf(io);
    if (!instance.out_on) return null;
    return finished(instance, &instance.out, dmares.DMA_OUT, &io.underruns);
}

/// A filled buffer written back out of the cache, where the DMA reads it.
fn play(io: *rta.AudioTransport, frames: [*]i16) callconv(.c) i32 {
    var bytes: u32 = buffer_bytes;
    _ = instanceOf(io).sys.CachePreDMA(@ptrCast(frames), &bytes, 0);
    return err.RTAERR_OK;
}

/// The way in started for a source: the line brought up at its rate, or
/// joined at the rate it runs at, and the receiver on.
fn startInput(io: *rta.AudioTransport, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = instanceOf(io);
    if (instance.data_in_pin == no_pad) return err.RTAERR_NO_INPUT;
    if (!modeFits(instance, mode)) return err.RTAERR_BAD_MODE;
    if (!instance.up) {
        const code = lineUp(instance, mode.rate);
        if (code != err.RTAERR_OK) return code;
    }
    inputUp(instance, task, signal_mask);
    instance.in_on = true;
    return err.RTAERR_OK;
}

/// The way in stopped; the line goes down with it if nothing plays.
fn stopInput(io: *rta.AudioTransport) callconv(.c) void {
    const instance = instanceOf(io);
    inputDown(instance);
    instance.in_on = false;
    if (!instance.out_on) lineDown(instance);
}

/// The buffer the receiver filled last, read from memory, not from what
/// the data cache held of it.
fn inputBuffer(io: *rta.AudioTransport) callconv(.c) ?[*]const i16 {
    const instance = instanceOf(io);
    if (!instance.in_on) return null;
    const frames = finished(instance, &instance.in, dmares.DMA_IN, &io.overruns) orelse return null;
    var bytes: u32 = buffer_bytes;
    instance.sys.CachePostDMA(@ptrCast(frames), &bytes, 0);
    return frames;
}

const ops = rta.AudioTransportOps{
    .destroy = &destroy,
    .start = &start,
    .stop = &stop,
    .buffer = &buffer,
    .play = &play,
    .start_input = &startInput,
    .stop_input = &stopInput,
    .input_buffer = &inputBuffer,
};

const driver_ops = rta.RtaDriverOps{ .create_transport = &createTransport };

/// Cold start at 32: after rta.library (33), which it joins, and before
/// the parts' drivers (31), which make their lines from it at their own
/// init.
fn init(seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*anyopaque {
    _ = seg_list;
    const library = sys.OpenLibrary(rta.RTANAME, rta.RTA_VERSION) orelse return @ptrCast(sys);
    const rb: *RtaBase = @ptrCast(library);
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse {
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    };
    const memory = sys.AllocVec(@sizeOf(State), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.CloseLibrary(utility_lib);
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    };
    const state: *State = @ptrCast(@alignCast(memory));
    state.* = .{ .sys = sys, .utility = @ptrCast(utility_lib) };
    state.driver = .{
        .node = .{ .name = DRIVER_NAME, .pri = 0 },
        .version = VERSION,
        .revision = REVISION,
        .id_string = VERSION_STRING[1..],
        .type = rta.sinks.RTADT_TRANSPORT,
        .flags = rta.sinks.RTADF_INTERNAL_INSTANCE,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Instance),
    };
    if (!rb.AddRtaDriver(&state.driver)) {
        sys.FreeVec(memory);
        sys.CloseLibrary(utility_lib);
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    }
    // The libraries stay open and the state stays allocated: the driver
    // is on the list for good, and the list is how anything finds it.
    return @ptrCast(sys);
}

/// No library and no vectors: the tag's init is the whole of it.
export const rta_i2s_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rta_i2s_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 32,
    .type = .rta_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};

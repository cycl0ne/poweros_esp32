// SPDX-License-Identifier: MPL-2.0
//! The chip's I2S controller as a line: the stream a codec or an
//! amplifier is fed over.
//!
//! A module of its own: it opens rta.library at cold start and hands in a
//! driver of the transport kind, and from then on a sink's driver that
//! asks for an "i2s" line, with its part's tags, gets one of these. The
//! part's tags name the pads: the bit clock, the word clock and the data
//! out, and the master clock for a codec that counts in it - an amplifier
//! that recovers its clock from the bit clock has no pad for it.
//!
//! Nothing is touched until the line is started. That takes the pads from
//! gpio.resource, a DMA channel from dma.resource and the ring's memory,
//! clocks the controller (`esp32s3/i2s.zig`, `esp32p4/i2s.zig`), and
//! starts the stream on silence. The ring is two buffers, a descriptor
//! apiece linked head to tail: the DMA runs round them for ever and raises
//! an interrupt at the end of each, the interrupt signals the task the
//! sink was started for, and the task fills the one just played - so the
//! stream is fed a buffer ahead of itself.

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
    .rv64sbi => @compileError("rta i2s: this chip has no I2S controller driven yet"),
};

const MODULE_NAME = "rta-i2s";
const DRIVER_NAME = "i2s";
const VERSION = 1;
const REVISION = 0;
const BUILD_DATE = "19.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The ring: two buffers, each of `buffer_frames` stereo frames. One
/// plays while the other is filled, so the task has a buffer's worth of
/// time to do it in - about five milliseconds at 48 kHz.
const buffer_frames: u32 = 256;
const buffer_samples: u32 = buffer_frames * 2;
const buffer_bytes: u32 = buffer_samples * 2;
const buffers: u32 = 2;

/// A line the part does not bring out: the master clock, for an
/// amplifier.
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

/// What one line keeps. The interrupt reads it, so it is in internal
/// memory (RTADF_INTERNAL_INSTANCE).
const Instance = struct {
    sys: *ExecBase,
    /// The part's pads: the clocks and the data out, the master clock
    /// `no_pad` for a part that takes none.
    mclk_pin: u8 = no_pad,
    bclk_pin: u8 = 0,
    ws_pin: u8 = 0,
    data_out_pin: u8 = 0,
    /// The pads while they are this line's, and where they came from.
    gpio_base: ?*GpioBase = null,
    held: [4]u8 = .{ 0, 0, 0, 0 },
    held_count: u8 = 0,
    has_channel: bool = false,
    int_added: bool = false,
    streaming: bool = false,
    dma: ?*dmares.DmaBase = null,
    channel: u32 = 0,
    /// The ring's buffers, and a descriptor apiece.
    ring: ?[*]i16 = null,
    chain: [buffers]?*dmares.DMADescriptor = @splat(null),
    int: exec.Interrupt = .{},
    /// The task the interrupt signals, and with what.
    task: ?*exec.Task = null,
    signal_mask: u32 = 0,
    /// The buffers the DMA has finished, counted by its interrupt, and
    /// the count the last buffer was asked at: more than one between two
    /// asks is a buffer the DMA went round to before it had been filled,
    /// played again - an underrun.
    ended: u32 = 0,
    taken: u32 = 0,
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
    instance.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = instance,
        .code = &intServer,
    };
    io.ops = &ops;
    io.buffer_frames = buffer_frames;
    io.buffers = buffers;
    return err.RTAERR_OK;
}

/// The interrupt: a buffer has been played, so the task has one to fill.
fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const instance: *Instance = @ptrCast(@alignCast(is_data.?));
    const db = instance.dma orelse return 0;
    const status = db.DMAIntStatus(instance.channel, dmares.DMA_OUT);
    if (status & dmares.DMAINTF_OUT_EOF == 0) return 0;
    db.ClearDMAInts(instance.channel, dmares.DMA_OUT, status);
    _ = @atomicRmw(u32, &instance.ended, .Add, 1, .release);
    if (instance.task) |task| instance.sys.Signal(task, instance.signal_mask);
    return 1;
}

/// The pads the controller drives taken from gpio.resource. False if
/// another driver holds one; a machine without the resource takes
/// nothing.
fn takePads(instance: *Instance) bool {
    const sys = instance.sys;
    const gb: *GpioBase = @ptrCast(@alignCast(sys.OpenResource(gpio_resource.GPIONAME) orelse return true));
    var wanted: [4]u8 = @splat(0);
    var count: u8 = 0;
    for ([_]u8{ instance.mclk_pin, instance.bclk_pin, instance.ws_pin, instance.data_out_pin }) |pad| {
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
/// takes and the data out.
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
}

/// The ring started, in the order the parts want it: the memory, a DMA
/// channel and the descriptors, then the controller's clocks, its pads
/// and the stream.
fn start(io: *rta.AudioTransport, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = instanceOf(io);
    // The controller is clocked for one rate, at sixteen bits.
    if (mode.rate != controller.sample_rate or mode.bits != controller.bits_per_sample) return err.RTAERR_BAD_MODE;
    if (!takePads(instance)) return err.RTAERR_IN_USE;
    const code = startRing(instance, task, signal_mask);
    if (code != err.RTAERR_OK) giveBack(instance);
    return code;
}

fn startRing(instance: *Instance, task: *exec.Task, signal_mask: u32) i32 {
    const sys = instance.sys;
    // The ring's memory: the buffers the DMA reads and the descriptors
    // that ring them, both where the DMA can reach them. Where the data
    // cache covers that memory, the silence it starts with is written
    // back, or the DMA plays whatever was there before.
    const memory = sys.AllocVec(buffer_bytes * buffers, exec.MEMF_INTERNAL | exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return err.RTAERR_NO_MEMORY;
    instance.ring = @ptrCast(@alignCast(memory));
    var ring_bytes: u32 = buffer_bytes * buffers;
    _ = sys.CachePreDMA(memory, &ring_bytes, 0);

    // A channel of the engine that serves the controller: one the
    // controller cannot be connected to is given back, and the next tried.
    const db: *dmares.DmaBase = @ptrCast(sys.OpenResource(dmares.DMANAME) orelse return err.RTAERR_NO_OUTPUT);
    instance.dma = db;
    const channel = for (0..dmares.DMA_CHANNELS) |n| {
        const candidate: u32 = @intCast(n);
        if (db.AllocDMAChannel(candidate, MODULE_NAME) != null) continue;
        // A ring that never stops: the stream is endless, and a buffer
        // handed back would be a buffer the DMA stopped at.
        if (db.ConnectDMAChannel(candidate, controller.dma_peripheral, dmares.DMACF_LOOP)) break candidate;
        db.FreeDMAChannel(candidate);
    } else {
        exec.kprintf(sys, "%s: no DMA channel free\n", .{MODULE_NAME});
        return err.RTAERR_NO_OUTPUT;
    };
    instance.channel = channel;
    instance.has_channel = true;
    // A descriptor a buffer, linked head to tail: the DMA runs round them
    // for ever and says at the end of each which one has been played. The
    // links are written after AllocDMAChain wrote the chains back, so
    // they are written back again.
    const bytes: [*]u8 = @ptrCast(memory);
    for (0..buffers) |i| {
        instance.chain[i] = db.AllocDMAChain(dmares.DMA_OUT, bytes + i * buffer_bytes, buffer_bytes, 0) orelse return err.RTAERR_NO_MEMORY;
    }
    for (0..buffers) |i| {
        const one = instance.chain[i].?;
        one.next = instance.chain[(i + 1) % buffers];
        var descriptor_bytes: u32 = @sizeOf(dmares.DMADescriptor);
        _ = sys.CachePreDMA(@ptrCast(one), &descriptor_bytes, 0);
    }

    // The controller, its pads, and the stream running.
    instance.task = task;
    instance.signal_mask = signal_mask;
    instance.ended = 0;
    instance.taken = 0;
    controller.init();
    connectPads(instance);
    controller.reset();
    _ = db.StartDMA(channel, dmares.DMA_OUT, instance.chain[0].?);
    db.EnableDMAInts(channel, dmares.DMA_OUT, dmares.DMAINTF_OUT_EOF);
    sys.AddIntServer(dmares.dmaIntNumber(channel, dmares.DMA_OUT), &instance.int);
    instance.int_added = true;
    controller.start();
    instance.streaming = true;
    return err.RTAERR_OK;
}

/// Everything the ring took given back: the controller stopped, its
/// interrupt out, the DMA channel and the memory freed, the pads free.
fn giveBack(instance: *Instance) void {
    const sys = instance.sys;
    if (instance.streaming) controller.stop();
    instance.streaming = false;
    if (instance.int_added) sys.RemIntServer(dmares.dmaIntNumber(instance.channel, dmares.DMA_OUT), &instance.int);
    instance.int_added = false;
    if (instance.has_channel) {
        const db = instance.dma.?;
        db.StopDMA(instance.channel, dmares.DMA_OUT);
        db.EnableDMAInts(instance.channel, dmares.DMA_OUT, 0);
        db.FreeDMAChannel(instance.channel);
        instance.has_channel = false;
    }
    if (instance.dma) |db| {
        for (&instance.chain) |*chain| {
            if (chain.*) |one| db.FreeDMAChain(one);
            chain.* = null;
        }
    }
    if (instance.ring) |ring| sys.FreeVec(ring);
    instance.ring = null;
    if (instance.gpio_base) |gb| gpio_resource.freePads(gb, instance.held[0..instance.held_count]);
    instance.gpio_base = null;
    instance.held_count = 0;
    instance.task = null;
}

fn stop(io: *rta.AudioTransport) callconv(.c) void {
    giveBack(instanceOf(io));
}

fn destroy(io: *rta.AudioTransport) callconv(.c) void {
    giveBack(instanceOf(io));
}

/// The buffer that has just been played, which is the one to fill: the
/// DMA is in the other one now. Null if none has ended since the last
/// ask; more than one is a gap, counted.
fn buffer(io: *rta.AudioTransport) callconv(.c) ?[*]i16 {
    const instance = instanceOf(io);
    const ended = @atomicLoad(u32, &instance.ended, .acquire);
    const behind = ended -% instance.taken;
    if (behind == 0) return null;
    if (behind > 1) io.underruns +%= behind - 1;
    instance.taken = ended;
    const db = instance.dma.?;
    const finished = db.DMAEOFDescriptor(instance.channel, dmares.DMA_OUT);
    var which: usize = 0;
    for (instance.chain, 0..) |one, i| {
        if (one == finished) which = i;
    }
    return instance.ring.? + which * buffer_samples;
}

/// A filled buffer written back out of the cache, where the DMA reads it.
fn play(io: *rta.AudioTransport, frames: [*]i16) callconv(.c) i32 {
    var bytes: u32 = buffer_bytes;
    _ = instanceOf(io).sys.CachePreDMA(@ptrCast(frames), &bytes, 0);
    return err.RTAERR_OK;
}

const ops = rta.AudioTransportOps{
    .destroy = &destroy,
    .start = &start,
    .stop = &stop,
    .buffer = &buffer,
    .play = &play,
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

// SPDX-License-Identifier: MPL-2.0
//! audio.device: four channels of sound, mixed into the board's codec.
//!
//! The channels are the ones the API is named for - allocated with a
//! precedence, stolen by anything that outranks them, written to with a
//! period, a volume and a count of cycles. This machine has no four-voice
//! hardware, so the device is the hardware: a task mixes the four into
//! one stereo stream (`mixer.zig`) and a DMA channel hands that stream to
//! the I2S controller, which clocks it into an ES8311 codec
//! (`es8311.zig`) and out to the speaker.
//!
//! Nothing is touched until the first OpenDevice. That starts the task,
//! which brings the codec up over i2c.device, turns the amplifier on,
//! takes a DMA channel from dma.resource and starts the stream. From
//! then on the DMA raises an interrupt every time it finishes a buffer,
//! the interrupt signals the task, and the task mixes the next one - so
//! the stream is fed ahead of itself and nothing waits on a bus at the
//! moment a sample is due.
//!
//! A board with no codec has no audio.device: `src/main.zig` links it
//! only where the board's description has `audio`.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const audio = sdk.devices.audio;
const i2c = sdk.devices.i2c;
const timer = sdk.devices.timer;
const dmares = sdk.resources.dma;
const intbits = sdk.hardware.intbits;
const ExecBase = sdk.interface.exec.ExecBase;
const IOAudio = audio.IOAudio;

const mixer = @import("mixer.zig");
const es8311 = @import("es8311.zig");
const expansion = sdk.expansion;
const st = expansion.systemtags;
const BoardPin = expansion.BoardPin;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
const i2s = @import("i2s.zig");
const gpio = @import("sdk").hardware.gpio;

pub const DEVICE_NAME = audio.AUDIONAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "23.9.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Above ordinary tasks: a buffer that is not mixed in time is a gap
/// everyone hears.
const task_pri = 15;
const stack_size = 4096;

/// The stream: two buffers the DMA runs round, each of `buffer_frames`
/// stereo frames. One plays while the other is mixed, so the task has a
/// buffer's worth of time to do it in - about five milliseconds.
const buffer_frames: u32 = 256;
const buffer_samples: u32 = buffer_frames * 2;
const buffer_bytes: u32 = buffer_samples * 2;
const buffers: u32 = 2;

/// How loud the codec is driven. The amplifier does the rest, and half
/// of what the part can do is as much as this speaker wants.
const codec_volume: u32 = 50;

/// One channel's requests: what is playing and what is queued behind it,
/// as the hardware's double-buffered registers allowed.
const ChannelRequests = extern struct {
    playing: ?*IOAudio = null,
    next: ?*IOAudio = null,
    /// Whose allocation this channel belongs to, and how hard it is to
    /// take away.
    key: i16 = 0,
    precedence: i8 = 0,
    taken: u8 = 0,
    /// The request that locked it, if any.
    lock: ?*IOAudio = null,
    /// A request waiting for this channel's cycle to end.
    wait_cycle: ?*IOAudio = null,
};

const AudioBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    /// One unit a channel combination: `io_Unit` is the unit of the mask
    /// the allocation got, and `ioa.channels` says which channels those
    /// are.
    units: [16]exec.Unit = @splat(.{}),
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    int: exec.Interrupt = .{},
    /// The task is running and the codec answered.
    ready: u8 = 0,
    started: u8 = 0,
    start_signal: i8 = -1,
    pad: u8 = 0,
    starter: ?*exec.Task = null,
    /// The task's signal the DMA's interrupt raises.
    int_mask: u32 = 0,
    /// Owned by the task.
    port: ?*exec.MsgPort = null,
    i2c_io: i2c.IOExtI2C = .{},
    timer_io: timer.TimeRequest = .{},
    dma: ?*dmares.DmaBase = null,
    channel: u32 = 0,
    has_channel: u8 = 0,
    pad2: [3]u8 = .{ 0, 0, 0 },
    /// The stream: the buffers, and a descriptor apiece linked into a
    /// ring, so the end of each one is an interrupt and the other is the
    /// one to mix into.
    stream: ?[*]i16 = null,
    chain: [buffers]?*dmares.DMADescriptor = @splat(null),
    /// What the four channels are playing, and who owns them.
    voices: [mixer.channels]mixer.Channel = @splat(.{}),
    owners: [mixer.channels]ChannelRequests = @splat(.{}),
    /// The last key handed out.
    last_key: i16 = 0,
    /// Allocations waiting for channels to come free.
    waiting: exec.List = .{},
    /// What the board's codec and amplifier parts say, read at init: the
    /// codec's I2C unit and address, the pads of its I2S lines, and the
    /// amplifier's enable line. `has_codec` clear: the board has none this
    /// device can drive.
    has_codec: u8 = 0,
    pad3: u8 = 0,
    codec_address: u16 = 0,
    bus_unit: u32 = 0,
    mclk_pin: u8 = 0,
    bclk_pin: u8 = 0,
    ws_pin: u8 = 0,
    data_out_pin: u8 = 0,
    amplifier: BoardPin = .{},
    /// The pads taken from gpio.resource while the stream runs: the I2S
    /// lines, and the amplifier's enable when it is a pad of the chip.
    gpio_base: ?*GpioBase = null,
    held_pads: [5]u8 = .{ 0, 0, 0, 0, 0 },
    held_count: u8 = 0,
    /// The pads are this device's: taken, or no resource to take them from.
    pads_held: u8 = 0,
    pad7: u8 = 0,
};

fn audioBase(dev: *exec.Device) *AudioBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

fn baseOf(io: *exec.IORequest) *AudioBase {
    return audioBase(io.device.?);
}

fn ioAudio(io: *exec.IORequest) *IOAudio {
    return @alignCast(@fieldParentPtr("req", io));
}

// --- the hardware ---------------------------------------------------------

fn wait(ab: *AudioBase, us: u32) void {
    const sys = ab.sys_base;
    ab.timer_io.node.command = timer.TR_ADDREQUEST;
    ab.timer_io.time = timer.TimeVal.fromMicros(us);
    _ = sys.DoIO(&ab.timer_io.node);
}

/// One register of the codec.
fn writeCodec(ab: *AudioBase, register: u8, value: u8) bool {
    var bytes = [2]u8{ register, value };
    const io = &ab.i2c_io;
    io.req.req.command = exec.CMD_WRITE;
    io.req.req.flags = exec.IOF_QUICK;
    io.address = ab.codec_address;
    io.req.data = &bytes;
    io.req.length = bytes.len;
    _ = ab.sys_base.DoIO(&io.req.req);
    return io.req.req.err == 0;
}

/// The amplifier in front of the speaker, switched by its enable line - a
/// pad, asserted as the board says. A board without one has nothing to
/// switch.
fn amplifier(ab: *AudioBase, on: bool) void {
    const line = ab.amplifier;
    if (line.kind != expansion.boardpin.BPIN_GPIO) return;
    gpio.toMatrix(line.number);
    gpio.connectOut(line.number, gpio.out_of_gpio, true);
    gpio.outputEnable(line.number, true);
    gpio.setLevel(line.number, if (line.active_low != 0) !on else on);
}

/// The pads the controller drives: the three clocks and the data out.
fn connectPads(ab: *AudioBase) void {
    const pads = [_]struct { pin: u8, signal: u32 }{
        .{ .pin = ab.mclk_pin, .signal = i2s.signal_mclk },
        .{ .pin = ab.bclk_pin, .signal = i2s.signal_bclk },
        .{ .pin = ab.ws_pin, .signal = i2s.signal_ws },
        .{ .pin = ab.data_out_pin, .signal = i2s.signal_data_out },
    };
    for (pads) |pad| {
        gpio.toMatrix(pad.pin);
        gpio.connectOut(pad.pin, pad.signal, false);
        gpio.outputEnable(pad.pin, true);
    }
}

/// The interrupt: a buffer has been played, so the task has one to mix.
fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const ab: *AudioBase = @ptrCast(@alignCast(is_data.?));
    const db = ab.dma orelse return 0;
    const status = db.DMAIntStatus(ab.channel, dmares.DMA_OUT);
    if (status & dmares.DMAINTF_OUT_EOF == 0) return 0;
    db.ClearDMAInts(ab.channel, dmares.DMA_OUT, status);
    ab.sys_base.Signal(&ab.task, ab.int_mask);
    return 1;
}

fn step(ab: *AudioBase, what: [*:0]const u8) void {
    sdk.exec.kprintf(ab.sys_base, "%s: %s\n", .{ DEVICE_NAME, what });
}

/// The codec brought up, the stream started: the device's hardware, in
/// the order the parts want it.
fn bringUp(ab: *AudioBase) bool {
    const sys = ab.sys_base;
    if (ab.has_codec == 0) {
        sdk.exec.kprintf(sys, "%s: the board has no codec\n", .{DEVICE_NAME});
        return false;
    }
    if (!takePads(ab)) return false;

    ab.port = sys.CreateMsgPort() orelse return false;
    ab.i2c_io = .{};
    ab.i2c_io.req.req.message.reply_port = ab.port;
    ab.i2c_io.req.req.message.length = @sizeOf(i2c.IOExtI2C);
    if (sys.OpenDevice(i2c.DEVICE_NAME, ab.bus_unit, &ab.i2c_io.req.req, 0) != 0) {
        sdk.exec.kprintf(sys, "%s: no %s unit %d\n", .{ DEVICE_NAME, i2c.DEVICE_NAME, ab.bus_unit });
        return false;
    }
    ab.timer_io = .{};
    ab.timer_io.node.message.reply_port = ab.port;
    ab.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &ab.timer_io.node, 0) != 0) return false;
    step(ab, "i2c.device and timer.device open");

    // The stream's memory: the buffers the DMA reads and the descriptors
    // that ring them, both where the DMA can reach them.
    const memory = sys.AllocVec(buffer_bytes * buffers, exec.MEMF_INTERNAL | exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return false;
    ab.stream = @ptrCast(@alignCast(memory));

    const db: *dmares.DmaBase = @ptrCast(sys.OpenResource(dmares.DMANAME) orelse return false);
    ab.dma = db;
    var ch: u32 = 0;
    while (ch < dmares.DMA_CHANNELS) : (ch += 1) {
        if (db.AllocDMAChannel(ch, DEVICE_NAME) == null) break;
    } else {
        sdk.exec.kprintf(sys, "%s: no DMA channel free\n", .{DEVICE_NAME});
        return false;
    }
    ab.channel = ch;
    ab.has_channel = 1;
    // A ring that never stops: the stream is endless, and a buffer handed
    // back would be a buffer the DMA stopped at.
    if (!db.ConnectDMAChannel(ch, i2s.dma_peripheral, dmares.DMACF_LOOP)) return false;
    // A descriptor a buffer, linked head to tail: the DMA runs round them
    // for ever and says at the end of each which one has been played.
    const stream: [*]u8 = @ptrCast(memory);
    for (0..buffers) |i| {
        ab.chain[i] = db.AllocDMAChain(dmares.DMA_OUT, stream + i * buffer_bytes, buffer_bytes, 0) orelse return false;
    }
    for (0..buffers) |i| {
        ab.chain[i].?.next = ab.chain[(i + 1) % buffers];
    }
    step(ab, "DMA channel and buffers");

    // The codec, over the bus it shares with the touch controller.
    for (es8311.bring_up) |one| {
        if (!writeCodec(ab, one.reg, one.value)) {
            sdk.exec.kprintf(sys, "%s: the codec does not answer at 0x%02x\n", .{ DEVICE_NAME, @as(u32, ab.codec_address) });
            return false;
        }
        if (one.delay_ms != 0) wait(ab, @as(u32, one.delay_ms) * 1000);
    }
    step(ab, "codec up");

    // The controller, its pads, and the stream running. The codec counts
    // everything in the master clock, so the clocks come before its
    // volume goes up.
    i2s.init();
    connectPads(ab);
    i2s.reset();
    _ = db.StartDMA(ch, dmares.DMA_OUT, ab.chain[0].?);
    db.EnableDMAInts(ch, dmares.DMA_OUT, dmares.DMAINTF_OUT_EOF);
    sys.AddIntServer(dmares.dmaIntNumber(ch, dmares.DMA_OUT), &ab.int);
    i2s.start();

    _ = writeCodec(ab, es8311.reg_volume, es8311.volumeFor(codec_volume));
    amplifier(ab, true);
    sdk.exec.kprintf(sys, "%s: ES8311 at 0x%02x, %d Hz stereo, %d channels mixed\n", .{
        DEVICE_NAME,
        @as(u32, ab.codec_address),
        i2s.sample_rate,
        @as(u32, mixer.channels),
    });
    return true;
}

/// The codec's I2S pads and the amplifier's enable, taken from
/// gpio.resource. False if another driver holds one; a machine without the
/// resource takes nothing.
fn takePads(ab: *AudioBase) bool {
    const sys = ab.sys_base;
    const gb: *GpioBase = @ptrCast(@alignCast(sys.OpenResource(gpio_resource.GPIONAME) orelse {
        ab.pads_held = 1;
        return true;
    }));
    var wanted: [5]u8 = .{ ab.mclk_pin, ab.bclk_pin, ab.ws_pin, ab.data_out_pin, 0 };
    var count: u8 = 4;
    if (ab.amplifier.kind == expansion.boardpin.BPIN_GPIO) {
        wanted[4] = ab.amplifier.number;
        count = 5;
    }
    if (gpio_resource.allocPads(gb, wanted[0..count], DEVICE_NAME)) |refused| {
        sdk.exec.kprintf(sys, "%s: GPIO%d is %s's\n", .{ DEVICE_NAME, refused.pad, refused.holder });
        return false;
    }
    ab.gpio_base = gb;
    ab.held_pads = wanted;
    ab.held_count = count;
    ab.pads_held = 1;
    return true;
}

fn giveBack(ab: *AudioBase) void {
    const sys = ab.sys_base;
    // The amplifier's line is driven only while it is this device's.
    if (ab.pads_held != 0) amplifier(ab, false);
    if (ab.has_channel != 0) {
        const db = ab.dma.?;
        db.StopDMA(ab.channel, dmares.DMA_OUT);
        db.EnableDMAInts(ab.channel, dmares.DMA_OUT, 0);
        for (&ab.chain) |*chain| {
            if (chain.*) |one| db.FreeDMAChain(one);
            chain.* = null;
        }
        db.FreeDMAChannel(ab.channel);
        ab.has_channel = 0;
    }
    if (ab.stream) |stream| sys.FreeVec(stream);
    ab.stream = null;
    if (ab.timer_io.node.device != null) sys.CloseDevice(&ab.timer_io.node);
    if (ab.i2c_io.req.req.device != null) sys.CloseDevice(&ab.i2c_io.req.req);
    if (ab.port) |port| sys.DeleteMsgPort(port);
    ab.port = null;
    if (ab.gpio_base) |gb| gpio_resource.freePads(gb, ab.held_pads[0..ab.held_count]);
    ab.gpio_base = null;
    ab.held_count = 0;
    ab.pads_held = 0;
}

// --- the stream -----------------------------------------------------------

/// The buffer that has just been played, which is the one to mix into:
/// the DMA is in the other one now.
fn freeBuffer(ab: *AudioBase) []i16 {
    const stream = ab.stream.?;
    const db = ab.dma.?;
    const ended = db.DMAEOFDescriptor(ab.channel, dmares.DMA_OUT);
    var which: usize = 0;
    for (ab.chain, 0..) |one, i| {
        if (one == ended) which = i;
    }
    return stream[which * buffer_samples ..][0..buffer_samples];
}

/// One buffer's worth of sound, and whatever that finished replied.
fn mixBuffer(ab: *AudioBase) void {
    const out = freeBuffer(ab);
    const done = mixer.fill(&ab.voices, out);
    var bytes: u32 = @intCast(out.len * 2);
    _ = ab.sys_base.CachePreDMA(@ptrCast(out.ptr), &bytes, 0);
    if (done.finished == 0) return;
    for (0..mixer.channels) |i| {
        if (done.finished & (@as(u32, 1) << @intCast(i)) == 0) continue;
        finishChannel(ab, i);
    }
}

/// A channel that has played its write out: the request replied, the one
/// queued behind it started, and anything waiting for the cycle told.
fn finishChannel(ab: *AudioBase, channel: usize) void {
    const sys = ab.sys_base;
    const owner = &ab.owners[channel];
    if (owner.wait_cycle) |waiter| {
        owner.wait_cycle = null;
        sys.ReplyIO(&waiter.req);
    }
    const played = owner.playing;
    owner.playing = null;
    if (owner.next) |next| {
        owner.next = null;
        startWrite(ab, channel, next);
    }
    if (played) |io| {
        // A write that asked for a message got it when the samples went;
        // the request itself waits for the next write to start, which is
        // what the hardware's own double buffering meant.
        if (io.req.flags & audio.ADIOF_WRITEMESSAGE != 0) {
            sys.ReplyMsg(&io.write_msg);
        }
        sys.ReplyIO(&io.req);
    }
}

/// A write onto a channel: its samples, its rate and its loudness.
fn startWrite(ab: *AudioBase, channel: usize, io: *IOAudio) void {
    const owner = &ab.owners[channel];
    owner.playing = io;
    const voice = &ab.voices[channel];
    if (io.req.flags & audio.ADIOF_PERVOL != 0 or voice.step == 0) {
        voice.step = mixer.stepFor(audio.AUDIO_CLOCK, io.period, i2s.sample_rate);
        voice.volume = @min(io.volume, audio.ADVOLUME_MAX);
    }
    voice.data = io.data;
    voice.length = io.length;
    voice.position = 0;
    voice.cycles = io.cycles;
    voice.endless = if (io.cycles == 0) 1 else 0;
}

fn audioTask(sys: *ExecBase) callconv(.c) void {
    const ab: *AudioBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const signal = sys.AllocSignal(-1);
    const ok = signal >= 0 and bringUp(ab);
    if (ok) {
        ab.int_mask = @as(u32, 1) << @intCast(signal);
        ab.ready = 1;
    } else {
        giveBack(ab);
    }
    if (ab.starter) |starter| {
        ab.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(ab.start_signal));
    }
    if (!ok) return;

    while (true) {
        _ = sys.Wait(ab.int_mask);
        sys.Forbid();
        mixBuffer(ab);
        sys.Permit();
    }
}

/// The task started and waited for, so an open knows whether there is a
/// codec. Under the opener's own signal.
fn start(ab: *AudioBase) bool {
    const sys = ab.sys_base;
    if (ab.started != 0) return ab.ready != 0;
    // A task cannot free the stack it is ending on, so a failed bring-up
    // keeps it for the next attempt.
    const stack = ab.stack orelse blk: {
        const s = sys.AllocMem(stack_size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
        ab.stack = s;
        break :blk s;
    };
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    defer sys.FreeSignal(signal);
    ab.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    ab.starter = sys.FindTask(null);
    ab.start_signal = @intCast(signal);
    ab.ready = 0;
    _ = sys.AddTask(&ab.task, &audioTask, null);
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (ab.ready != 0) ab.started = 1;
    return ab.ready != 0;
}

// --- the channels ---------------------------------------------------------

/// Whether every channel of `mask` can be had at `precedence`: free, or
/// held by something that does not outrank it.
fn canTake(ab: *AudioBase, mask: u32, precedence: i8) bool {
    for (0..mixer.channels) |i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const owner = &ab.owners[i];
        if (owner.taken == 0) continue;
        if (owner.lock != null) return false;
        if (owner.precedence >= precedence) return false;
    }
    return true;
}

/// What it costs to take `mask`: the highest precedence it would steal.
/// Null when it cannot be taken at all.
fn costOf(ab: *AudioBase, mask: u32, precedence: i8) ?i32 {
    if (!canTake(ab, mask, precedence)) return null;
    var worst: i32 = std.math.minInt(i32);
    for (0..mixer.channels) |i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const owner = &ab.owners[i];
        if (owner.taken == 0) continue;
        worst = @max(worst, @as(i32, owner.precedence));
    }
    return worst;
}

/// A channel taken from whoever had it: what it was playing is stopped
/// and replied, and its owner hears ADIOERR_CHANNELSTOLEN the next time
/// it asks for anything.
fn steal(ab: *AudioBase, channel: usize) void {
    const sys = ab.sys_base;
    const owner = &ab.owners[channel];
    ab.voices[channel] = .{};
    for ([_]?*IOAudio{ owner.playing, owner.next, owner.wait_cycle, owner.lock }) |maybe| {
        if (maybe) |io| {
            io.req.err = audio.ADIOERR_CHANNELSTOLEN;
            sys.ReplyIO(&io.req);
        }
    }
    owner.* = .{};
}

/// A key that is not in use.
fn newKey(ab: *AudioBase) i16 {
    ab.last_key +%= 1;
    if (ab.last_key == 0) ab.last_key = 1;
    return ab.last_key;
}

/// Whether the channels this request names are still the caller's.
fn owns(ab: *AudioBase, io: *IOAudio) bool {
    const mask = io.channels;
    if (mask == 0) return false;
    for (0..mixer.channels) |i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const owner = &ab.owners[i];
        if (owner.taken == 0 or owner.key != io.alloc_key) return false;
    }
    return true;
}

/// The first channel of a request's mask, which is the one a write plays
/// on. A write to several channels plays on each.
fn eachChannel(io: *IOAudio, at: *usize) ?usize {
    while (at.* < mixer.channels) {
        const i = at.*;
        at.* += 1;
        if (io.channels & (@as(u32, 1) << @intCast(i)) != 0) return i;
    }
    return null;
}

/// Try the combinations this request offers, in the order it gave them.
/// Answers the mask it got, or null.
fn allocate(ab: *AudioBase, io: *IOAudio) ?u32 {
    const precedence: i8 = @intCast(io.req.message.node.pri);
    // No combinations named: any free channel will do, which is what a
    // zero-length array means.
    if (io.data == null or io.length == 0) {
        var best: ?u32 = null;
        var cheapest: i32 = std.math.maxInt(i32);
        for (0..mixer.channels) |i| {
            const mask = @as(u32, 1) << @intCast(i);
            const cost = costOf(ab, mask, precedence) orelse continue;
            if (cost < cheapest) {
                cheapest = cost;
                best = mask;
            }
        }
        return best;
    }
    var best: ?u32 = null;
    var cheapest: i32 = std.math.maxInt(i32);
    const list = io.data.?;
    for (0..io.length) |i| {
        const mask: u32 = @as(u8, @bitCast(list[i]));
        if (mask == 0 or mask > 0x0F) continue;
        const cost = costOf(ab, mask, precedence) orelse continue;
        // A combination that steals nothing is taken at once, in the
        // order the caller asked for; otherwise the cheapest theft wins.
        if (cost == std.math.minInt(i32)) return mask;
        if (cost < cheapest) {
            cheapest = cost;
            best = mask;
        }
    }
    return best;
}

/// The channels handed over: stolen from whoever had them, reset, and
/// marked with this allocation's key and precedence.
fn take(ab: *AudioBase, io: *IOAudio, mask: u32) void {
    const key = if (io.alloc_key != 0) io.alloc_key else newKey(ab);
    for (0..mixer.channels) |i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
        if (ab.owners[i].taken != 0) steal(ab, i);
        ab.owners[i] = .{
            .key = key,
            .precedence = @intCast(io.req.message.node.pri),
            .taken = 1,
        };
        ab.voices[i] = .{};
    }
    io.alloc_key = key;
    io.channels = mask;
    io.req.unit = &ab.units[mask];
}

/// Channels given back, and whatever was waiting for channels tried
/// again.
fn free(ab: *AudioBase, io: *IOAudio) void {
    const mask = io.channels;
    for (0..mixer.channels) |i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const owner = &ab.owners[i];
        if (owner.taken == 0 or owner.key != io.alloc_key) continue;
        ab.voices[i] = .{};
        const sys = ab.sys_base;
        for ([_]?*IOAudio{ owner.playing, owner.next, owner.wait_cycle }) |maybe| {
            if (maybe) |waiting| {
                waiting.req.err = exec.IOERR_ABORTED;
                sys.ReplyIO(&waiting.req);
            }
        }
        owner.* = .{};
    }
    retryWaiting(ab);
}

/// The allocations that could not be made before, tried again now that
/// something has come free.
fn retryWaiting(ab: *AudioBase) void {
    const sys = ab.sys_base;
    var node = ab.waiting.first();
    while (node) |n| {
        const next = n.next();
        const message: *exec.Message = @fieldParentPtr("node", n);
        const io: *IOAudio = @alignCast(@fieldParentPtr("req", @as(*exec.IORequest, @fieldParentPtr("message", message))));
        if (allocate(ab, io)) |mask| {
            sys.Remove(n);
            take(ab, io, mask);
            io.req.err = 0;
            sys.ReplyIO(&io.req);
        }
        node = next;
    }
}

// --- the commands ---------------------------------------------------------

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const ab = audioBase(dev);
    const ioa = ioAudio(io);
    const sys = ab.sys_base;
    io.err = 0;
    io.flags &= ~exec.IOF_DONE;

    sys.Forbid();
    defer sys.Permit();

    switch (io.command) {
        audio.ADCMD_ALLOCATE => {
            if (allocate(ab, ioa)) |mask| {
                take(ab, ioa, mask);
            } else if (io.flags & audio.ADIOF_NOWAIT != 0) {
                io.err = audio.ADIOERR_ALLOCFAILED;
                ioa.channels = 0;
                io.unit = null;
            } else {
                // It waits for channels: the reply comes when it gets
                // them, so this one is never quick.
                io.flags &= ~exec.IOF_QUICK;
                io.message.node.type = .message;
                sys.AddTail(&ab.waiting, &io.message.node);
                return;
            }
        },
        audio.ADCMD_FREE => {
            if (!owns(ab, ioa)) {
                io.err = audio.ADIOERR_NOALLOCATION;
            } else {
                free(ab, ioa);
            }
        },
        audio.ADCMD_SETPREC => {
            if (!owns(ab, ioa)) {
                io.err = audio.ADIOERR_NOALLOCATION;
            } else {
                var at: usize = 0;
                while (eachChannel(ioa, &at)) |i| {
                    ab.owners[i].precedence = @intCast(io.message.node.pri);
                }
                retryWaiting(ab);
            }
        },
        exec.CMD_WRITE => return write(ab, ioa),
        audio.ADCMD_PERVOL => {
            if (!owns(ab, ioa)) {
                io.err = audio.ADIOERR_NOALLOCATION;
            } else {
                var at: usize = 0;
                while (eachChannel(ioa, &at)) |i| {
                    const voice = &ab.voices[i];
                    voice.step = mixer.stepFor(audio.AUDIO_CLOCK, ioa.period, i2s.sample_rate);
                    voice.volume = @min(ioa.volume, audio.ADVOLUME_MAX);
                }
            }
        },
        audio.ADCMD_FINISH => {
            if (!owns(ab, ioa)) {
                io.err = audio.ADIOERR_NOALLOCATION;
            } else {
                var at: usize = 0;
                while (eachChannel(ioa, &at)) |i| stopChannel(ab, i, exec.IOERR_ABORTED);
            }
        },
        audio.ADCMD_WAITCYCLE => {
            var at: usize = 0;
            const first = if (owns(ab, ioa)) eachChannel(ioa, &at) else null;
            if (first) |channel| {
                const owner = &ab.owners[channel];
                // Nothing playing is a cycle already over.
                if (owner.playing != null) {
                    io.flags &= ~exec.IOF_QUICK;
                    io.message.node.type = .message;
                    owner.wait_cycle = ioa;
                    return;
                }
            } else {
                io.err = audio.ADIOERR_NOALLOCATION;
            }
        },
        audio.ADCMD_LOCK => {
            if (!owns(ab, ioa)) {
                io.err = audio.ADIOERR_NOALLOCATION;
            } else {
                var at: usize = 0;
                while (eachChannel(ioa, &at)) |i| ab.owners[i].lock = ioa;
                io.flags &= ~exec.IOF_QUICK;
                io.message.node.type = .message;
                return; // replied when the channels are stolen
            }
        },
        exec.CMD_STOP, exec.CMD_START => {
            if (!owns(ab, ioa)) {
                io.err = audio.ADIOERR_NOALLOCATION;
            } else {
                var at: usize = 0;
                while (eachChannel(ioa, &at)) |i| {
                    const voice = &ab.voices[i];
                    if (io.command == exec.CMD_STOP) {
                        voice.step = 0;
                    } else if (ab.owners[i].playing) |playing| {
                        voice.step = mixer.stepFor(audio.AUDIO_CLOCK, playing.period, i2s.sample_rate);
                    }
                }
            }
        },
        exec.CMD_FLUSH, exec.CMD_RESET, exec.CMD_CLEAR => {
            if (!owns(ab, ioa)) {
                io.err = audio.ADIOERR_NOALLOCATION;
            } else {
                var at: usize = 0;
                while (eachChannel(ioa, &at)) |i| stopChannel(ab, i, exec.IOERR_ABORTED);
            }
        },
        exec.CMD_UPDATE => {}, // nothing is buffered anywhere else
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyIO(io);
}

/// A channel silenced, and whatever it was playing given back.
fn stopChannel(ab: *AudioBase, channel: usize, err: i8) void {
    const sys = ab.sys_base;
    const owner = &ab.owners[channel];
    ab.voices[channel] = .{};
    for ([_]?*IOAudio{ owner.playing, owner.next }) |maybe| {
        if (maybe) |io| {
            io.req.err = err;
            sys.ReplyIO(&io.req);
        }
    }
    owner.playing = null;
    owner.next = null;
}

/// CMD_WRITE: the samples onto every channel the request names, or
/// queued behind what is playing there.
fn write(ab: *AudioBase, ioa: *IOAudio) void {
    const sys = ab.sys_base;
    const io = &ioa.req;
    if (!owns(ab, ioa)) {
        io.err = audio.ADIOERR_NOALLOCATION;
        sys.ReplyIO(io);
        return;
    }
    if (ioa.data == null or ioa.length == 0) {
        io.err = exec.IOERR_BADADDRESS;
        sys.ReplyIO(io);
        return;
    }
    // It is replied when its samples have been played, not now.
    io.flags &= ~exec.IOF_QUICK;
    io.message.node.type = .message;
    var at: usize = 0;
    var started = false;
    while (eachChannel(ioa, &at)) |i| {
        const owner = &ab.owners[i];
        if (owner.playing == null) {
            startWrite(ab, i, ioa);
            started = true;
        } else if (owner.next == null) {
            owner.next = ioa;
            started = true;
        }
    }
    if (!started) {
        // Both the playing and the queued write are taken: the caller
        // waits for one of them rather than losing this one.
        io.err = exec.IOERR_UNITBUSY;
        sys.ReplyIO(io);
    }
}

fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const ab = audioBase(dev);
    const ioa = ioAudio(io);
    const sys = ab.sys_base;
    sys.Forbid();
    defer sys.Permit();
    var found = false;
    for (&ab.owners, 0..) |*owner, i| {
        if (owner.playing == ioa) {
            ab.voices[i] = .{};
            owner.playing = null;
            found = true;
        }
        if (owner.next == ioa) {
            owner.next = null;
            found = true;
        }
        if (owner.wait_cycle == ioa) {
            owner.wait_cycle = null;
            found = true;
        }
        if (owner.lock == ioa) {
            owner.lock = null;
            found = true;
        }
    }
    if (!found and io.message.node.type == .message) {
        sys.Remove(&io.message.node);
        found = true;
    }
    if (!found) return -1;
    io.err = exec.IOERR_ABORTED;
    sys.ReplyIO(io);
    return 0;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    _ = unit_number;
    const ab = audioBase(dev);
    if (io.message.length < @sizeOf(IOAudio)) return exec.IOERR_OPENFAIL;
    if (!start(ab)) return exec.IOERR_OPENFAIL;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    io.unit = null;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const ab = audioBase(dev);
    const ioa = ioAudio(io);
    // Channels a program forgot are given back when it closes: a silent
    // channel nobody owns is worse than a noisy one.
    if (ioa.channels != 0 and owns(ab, ioa)) {
        ab.sys_base.Forbid();
        free(ab, ioa);
        ab.sys_base.Permit();
    }
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: its task holds the codec and the stream, and the
/// stream is what the machine's sound is.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    _ = seg_list;
    dev.revision = DEVICE_REVISION;
    const ab = audioBase(dev);
    ab.sys_base = sys_base;
    ab.waiting.init(.message);
    for (&ab.units) |*unit| unit.msg_port.msg_list.init(.message);
    ab.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = DEVICE_NAME },
        .data = ab,
        .code = &intServer,
    };
    findCodec(ab);
    return dev;
}

/// The board's codec - an ES8311, the chip this device drives - and its
/// amplifier, read into the base. A board without the codec, or whose I2S
/// lines are not pads of the chip, leaves `has_codec` clear, and every
/// open fails.
fn findCodec(ab: *AudioBase) void {
    const sys = ab.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const codec = eb.FindBoardPart(null, st.PARTKIND_CODEC, st.CHIP_ES8311) orelse return;
    const tags = codec.tags;
    const lines = [_]sdk.utility.Tag{ st.PART_PinMCLK, st.PART_PinBCLK, st.PART_PinWS, st.PART_PinDataOut };
    var pads: [lines.len]u8 = undefined;
    for (lines, 0..) |tag, at| {
        const line = BoardPin.of(ub.GetTagData(tag, 0, tags));
        if (line.kind != expansion.boardpin.BPIN_GPIO) return;
        pads[at] = line.number;
    }
    ab.mclk_pin = pads[0];
    ab.bclk_pin = pads[1];
    ab.ws_pin = pads[2];
    ab.data_out_pin = pads[3];
    ab.codec_address = @truncate(ub.GetTagData(st.PART_Address, es8311.address, tags));
    ab.bus_unit = @truncate(ub.GetTagData(st.PART_BusUnit, 0, tags));
    if (eb.FindBoardPart(null, st.PARTKIND_AMPLIFIER, st.CHIP_ANY)) |amp| {
        ab.amplifier = BoardPin.of(ub.GetTagData(st.PART_PinEnable, 0, amp.tags));
    }
    ab.has_codec = 1;
}

const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(AudioBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// Cold start at 26: after i2c.device (35), dma.resource (70) and
/// timer.device, which its first open needs, and before the shell.
export const audio_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &audio_device_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .pri = 26,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};

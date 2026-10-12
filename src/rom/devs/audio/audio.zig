// SPDX-License-Identifier: MPL-2.0
//! audio.device: four channels of sound, mixed into the board's codec.
//!
//! The channels are the ones the API is named for - allocated with a
//! precedence, stolen by anything that outranks them, written to with a
//! period, a volume and a count of cycles. This machine has no four-voice
//! hardware, so the device is the hardware: a task mixes the four into
//! one stereo stream (`mixer.zig`) and a DMA channel hands that stream to
//! the chip's I2S controller (`esp32s3/i2s.zig`, `esp32p4/i2s.zig`).
//!
//! Where the stream goes is the board's: an ES8311 codec (`es8311.zig`)
//! set up over I2C, with an amplifier in front of the speaker, or an
//! amplifier that takes I2S itself and needs nothing set up - the
//! CrowPanel's pair, one a speaker. Either has an enable line the device
//! drives while the stream runs.
//!
//! Nothing is touched until the first OpenDevice. That starts the task,
//! which brings the codec up over i2c.device if there is one, turns the
//! amplifier on, takes a DMA channel from dma.resource and starts the
//! stream. From then on the DMA raises an interrupt every time it
//! finishes a buffer, the interrupt signals the task, and the task mixes
//! the next one - so the stream is fed ahead of itself and nothing waits
//! on a bus at the moment a sample is due.
//!
//! A board with neither has no audio.device: only the ROM tags of a board
//! that has one link it.

const std = @import("std");
const builtin = @import("builtin");
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
const alloc = @import("alloc.zig");
const es8311 = @import("es8311.zig");
const expansion = sdk.expansion;
const st = expansion.systemtags;
const BoardPin = expansion.BoardPin;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
/// The chip's I2S controller; in the host tests a stand-in with its
/// numbers and nothing behind its calls.
const i2s = if (builtin.is_test) no_i2s else switch (sdk.hardware.chip) {
    .esp32s3 => @import("esp32s3/i2s.zig"),
    .esp32p4 => @import("esp32p4/i2s.zig"),
};

const no_i2s = struct {
    pub const sample_rate: u32 = 48_000;
    pub const signal_bclk: u32 = 0;
    pub const signal_mclk: u32 = 0;
    pub const signal_ws: u32 = 0;
    pub const signal_data_out: u32 = 0;
    pub const dma_peripheral: u32 = 0;
    pub fn init() void {}
    pub fn reset() void {}
    pub fn start() void {}
    pub fn stop() void {}
};
const gpio = sdk.hardware.gpio;

pub const DEVICE_NAME = audio.AUDIONAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 2;
const BUILD_DATE = "11.10.2026";
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

/// One channel: who has it, the writes on it, and who waits for the end of
/// its cycle.
const ChannelState = extern struct {
    /// Every write on the channel, in the order they play. The first is
    /// the one playing - or the one a stopped channel holds. `handed`
    /// says how many from the front the mixer has been given: none, the
    /// one it plays, or that one and the one it holds behind it (and, for
    /// a moment inside a mix, those it went on to).
    writes: exec.List = .{},
    handed: u32 = 0,
    /// The first write's message has gone: it has started to play.
    announced: u8 = 0,
    /// The channel is someone's: their key, and how hard it is to take
    /// away.
    taken: u8 = 0,
    key: i16 = 0,
    precedence: i8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// ADCMD_WAITCYCLE requests, replied when the cycle playing ends.
    waiters: exec.List = .{},
};

const AudioBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    /// The voices, the channels' owners and the requests waiting, shared by
    /// the task's mixer and every caller's BeginIO: a semaphore, since the
    /// mixer holds it for a whole buffer.
    lock: exec.SignalSemaphore = .{},
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
    states: [mixer.channels]ChannelState = @splat(.{}),
    /// The last key handed out.
    last_key: i16 = 0,
    /// Allocations waiting for channels to come free, highest precedence
    /// first.
    waiting: exec.List = .{},
    /// ADCMD_LOCK requests, each with the channels it still locks in
    /// `channels`, and those channels together: a lock is given up only
    /// when its channels are freed.
    locks: exec.List = .{},
    lock_map: u8 = 0,
    /// The stream runs (the controller started), and the DMA's interrupt
    /// server is in.
    streaming: u8 = 0,
    int_added: u8 = 0,
    pad4: u8 = 0,
    /// The task's signal to end, for an expunge.
    quit_mask: u32 = 0,
    /// What the board's parts say, read at init: where the stream goes
    /// (`has_output`), whether that is a codec to set up (`has_codec`) and
    /// its I2C unit and address, the pads of the I2S lines - MCLK only for
    /// a codec, `no_pad` otherwise - the amplifier's enable line, and the
    /// output's chip name.
    has_codec: u8 = 0,
    has_output: u8 = 0,
    codec_address: u16 = 0,
    bus_unit: u32 = 0,
    output_name: [*:0]const u8 = "",
    mclk_pin: u8 = no_pad,
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
    /// What the output's halves of a frame get: an ES8311 is mono, an I2S
    /// amplifier pair takes the sides as the board wires them
    /// (PART_SidesSwapped).
    sides: mixer.Sides = .left_first,
};

/// An I2S line the board does not bring out: MCLK, for an amplifier.
const no_pad: u8 = 0xFF;

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

/// The pads the controller drives: the clocks the output takes and the
/// data out.
fn connectPads(ab: *AudioBase) void {
    const pads = [_]struct { pin: u8, signal: u32 }{
        .{ .pin = ab.mclk_pin, .signal = i2s.signal_mclk },
        .{ .pin = ab.bclk_pin, .signal = i2s.signal_bclk },
        .{ .pin = ab.ws_pin, .signal = i2s.signal_ws },
        .{ .pin = ab.data_out_pin, .signal = i2s.signal_data_out },
    };
    for (pads) |pad| {
        if (pad.pin == no_pad) continue;
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
    if (ab.has_output == 0) {
        sdk.exec.kprintf(sys, "%s: the board has no codec or I2S amplifier\n", .{DEVICE_NAME});
        return false;
    }
    if (!takePads(ab)) return false;

    if (ab.has_codec != 0) {
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
    }

    // The stream's memory: the buffers the DMA reads and the descriptors
    // that ring them, both where the DMA can reach them. Where the data
    // cache covers that memory, the silence it starts with is written
    // back, or the DMA plays whatever was there before.
    const memory = sys.AllocVec(buffer_bytes * buffers, exec.MEMF_INTERNAL | exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return false;
    ab.stream = @ptrCast(@alignCast(memory));
    var stream_bytes: u32 = buffer_bytes * buffers;
    _ = sys.CachePreDMA(memory, &stream_bytes, 0);

    // A channel of the engine that serves the controller: one the
    // controller cannot be connected to is given back, and the next tried.
    const db: *dmares.DmaBase = @ptrCast(sys.OpenResource(dmares.DMANAME) orelse return false);
    ab.dma = db;
    const ch = for (0..dmares.DMA_CHANNELS) |n| {
        const candidate: u32 = @intCast(n);
        if (db.AllocDMAChannel(candidate, DEVICE_NAME) != null) continue;
        // A ring that never stops: the stream is endless, and a buffer
        // handed back would be a buffer the DMA stopped at.
        if (db.ConnectDMAChannel(candidate, i2s.dma_peripheral, dmares.DMACF_LOOP)) break candidate;
        db.FreeDMAChannel(candidate);
    } else {
        sdk.exec.kprintf(sys, "%s: no DMA channel free\n", .{DEVICE_NAME});
        return false;
    };
    ab.channel = ch;
    ab.has_channel = 1;
    // A descriptor a buffer, linked head to tail: the DMA runs round them
    // for ever and says at the end of each which one has been played. The
    // links are written after AllocDMAChain wrote the chains back, so
    // they are written back again.
    const stream: [*]u8 = @ptrCast(memory);
    for (0..buffers) |i| {
        ab.chain[i] = db.AllocDMAChain(dmares.DMA_OUT, stream + i * buffer_bytes, buffer_bytes, 0) orelse return false;
    }
    for (0..buffers) |i| {
        const one = ab.chain[i].?;
        one.next = ab.chain[(i + 1) % buffers];
        var descriptor_bytes: u32 = @sizeOf(dmares.DMADescriptor);
        _ = sys.CachePreDMA(@ptrCast(one), &descriptor_bytes, 0);
    }
    step(ab, "DMA channel and buffers");

    // The codec, over the bus it shares with the touch controller.
    if (ab.has_codec != 0) {
        for (es8311.bring_up) |one| {
            if (!writeCodec(ab, one.reg, one.value)) {
                sdk.exec.kprintf(sys, "%s: the codec does not answer at 0x%02x\n", .{ DEVICE_NAME, @as(u32, ab.codec_address) });
                return false;
            }
            if (one.delay_ms != 0) wait(ab, @as(u32, one.delay_ms) * 1000);
        }
        step(ab, "codec up");
    }

    // The controller, its pads, and the stream running. The codec counts
    // everything in the master clock, so the clocks come before its
    // volume goes up.
    i2s.init();
    connectPads(ab);
    i2s.reset();
    _ = db.StartDMA(ch, dmares.DMA_OUT, ab.chain[0].?);
    db.EnableDMAInts(ch, dmares.DMA_OUT, dmares.DMAINTF_OUT_EOF);
    sys.AddIntServer(dmares.dmaIntNumber(ch, dmares.DMA_OUT), &ab.int);
    ab.int_added = 1;
    i2s.start();
    ab.streaming = 1;

    if (ab.has_codec != 0) _ = writeCodec(ab, es8311.reg_volume, es8311.volumeFor(codec_volume));
    amplifier(ab, true);
    sdk.exec.kprintf(sys, "%s: %s, %d Hz stereo, %d channels mixed\n", .{
        DEVICE_NAME,
        ab.output_name,
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
    var wanted: [5]u8 = @splat(0);
    var count: u8 = 0;
    for ([_]u8{ ab.mclk_pin, ab.bclk_pin, ab.ws_pin, ab.data_out_pin }) |pad| {
        if (pad == no_pad) continue;
        wanted[count] = pad;
        count += 1;
    }
    if (ab.amplifier.kind == expansion.boardpin.BPIN_GPIO) {
        wanted[count] = ab.amplifier.number;
        count += 1;
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
    if (ab.streaming != 0) i2s.stop();
    ab.streaming = 0;
    if (ab.int_added != 0) sys.RemIntServer(dmares.dmaIntNumber(ab.channel, dmares.DMA_OUT), &ab.int);
    ab.int_added = 0;
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
    mixInto(ab, out);
    var bytes: u32 = @intCast(out.len * 2);
    _ = ab.sys_base.CachePreDMA(@ptrCast(out.ptr), &bytes, 0);
}

/// `out` mixed from the channels, and what the mix came to answered: the
/// writes played out replied, the ones that began announced, the cycles'
/// waiters told. Under the device's lock.
fn mixInto(ab: *AudioBase, out: []i16) void {
    const done = mixer.fill(&ab.voices, out, ab.sides, .{ .context = ab, .next = handNext });
    for (0..mixer.channels) |channel| {
        for (0..done.ended[channel]) |_| playedOut(ab, channel);
        if (done.cycles[channel] != 0) replyWaiters(ab, channel, 0);
    }
}

/// The mixer has taken over the write it held and asks for the one after
/// it: the first write it has not been given yet.
fn handNext(context: *anyopaque, channel: usize) ?mixer.Queued {
    const ab: *AudioBase = @ptrCast(@alignCast(context));
    const state = &ab.states[channel];
    const io = writeAt(state, state.handed) orelse return null;
    state.handed += 1;
    return queuedOf(io);
}

/// The write at the front played out by the mixer: its message, if it
/// started and ended within one mix, the request replied, and the write
/// after it - which the mixer went on with - the front, begun.
fn playedOut(ab: *AudioBase, channel: usize) void {
    const sys = ab.sys_base;
    const state = &ab.states[channel];
    const front = firstWrite(state) orelse return;
    if (state.announced == 0) sendWriteMessage(ab, front);
    _ = sys.RemHead(&state.writes);
    state.handed -|= 1;
    state.announced = 0;
    sys.ReplyIO(&front.req);
    if (state.handed != 0) {
        if (firstWrite(state)) |next| {
            sendWriteMessage(ab, next);
            state.announced = 1;
        }
    }
}

/// A write's message, for one that asked for it: replied when the write
/// starts to play.
fn sendWriteMessage(ab: *AudioBase, io: *IOAudio) void {
    if (io.req.flags & audio.ADIOF_WRITEMESSAGE == 0) return;
    ab.sys_base.ReplyMsg(&io.write_msg);
}

/// The front write announced, if the mixer plays it now and it has not
/// been: on a channel that has just been started.
fn announceFront(ab: *AudioBase, channel: usize) void {
    const state = &ab.states[channel];
    if (state.announced != 0 or state.handed == 0 or ab.voices[channel].stopped != 0) return;
    const front = firstWrite(state) orelse return;
    sendWriteMessage(ab, front);
    state.announced = 1;
}

/// What the mixer is handed of a write: its samples, how often, and its
/// period and volume when it brings them (ADIOF_PERVOL).
fn queuedOf(io: *IOAudio) mixer.Queued {
    const pervol = io.req.flags & audio.ADIOF_PERVOL != 0;
    return .{
        .data = io.data,
        .length = io.length,
        .cycles = io.cycles,
        .step = if (pervol) mixer.stepFor(audio.AUDIO_CLOCK, io.period, i2s.sample_rate) else 0,
        .volume = if (pervol) @min(io.volume, audio.ADVOLUME_MAX) else 0,
    };
}

/// The channel's voice given the front write anew, and the one after it to
/// hold - after the front has changed outside a mix. The period and volume
/// stay, as the hardware's registers kept theirs; a channel that has none
/// takes the write's. A stopped channel stays stopped, and announces its
/// write when it is started.
fn startFront(ab: *AudioBase, channel: usize) void {
    const state = &ab.states[channel];
    const voice = &ab.voices[channel];
    silence(ab, channel);
    state.handed = 0;
    state.announced = 0;
    const front = firstWrite(state) orelse return;
    if (front.req.flags & audio.ADIOF_PERVOL != 0 or voice.step == 0) {
        voice.step = mixer.stepFor(audio.AUDIO_CLOCK, front.period, i2s.sample_rate);
        voice.volume = @min(front.volume, audio.ADVOLUME_MAX);
    }
    voice.data = front.data;
    voice.length = front.length;
    voice.cycles = front.cycles;
    voice.endless = if (front.cycles == 0) 1 else 0;
    state.handed = 1;
    if (writeAt(state, 1)) |second| {
        voice.queued = queuedOf(second);
        state.handed = 2;
    }
    announceFront(ab, channel);
}

/// A channel's voice with nothing to play. Its period and volume stay, and
/// a stopped channel stays stopped.
fn silence(ab: *AudioBase, channel: usize) void {
    const voice = &ab.voices[channel];
    voice.* = .{ .step = voice.step, .volume = voice.volume, .stopped = voice.stopped };
}

/// The write at the front taken off: `err` its answer, and the next one
/// started in its place.
fn endFront(ab: *AudioBase, channel: usize, err: i8) void {
    const sys = ab.sys_base;
    const state = &ab.states[channel];
    const front = firstWrite(state) orelse return;
    _ = sys.RemHead(&state.writes);
    front.req.err = err;
    sys.ReplyIO(&front.req);
    startFront(ab, channel);
}

/// Every write on a channel and every wait for its cycle answered with
/// `err`, and the voice silent - CMD_FLUSH.
fn flushChannel(ab: *AudioBase, channel: usize, err: i8) void {
    const sys = ab.sys_base;
    const state = &ab.states[channel];
    while (sys.RemHead(&state.writes)) |node| {
        const io = ioOf(node);
        io.req.err = err;
        sys.ReplyIO(&io.req);
    }
    replyWaiters(ab, channel, err);
    silence(ab, channel);
    state.handed = 0;
    state.announced = 0;
}

/// A channel back to where it started - CMD_RESET: flushed, its period
/// and volume cleared, and started if it was stopped.
fn resetChannel(ab: *AudioBase, channel: usize) void {
    flushChannel(ab, channel, exec.IOERR_ABORTED);
    ab.voices[channel] = .{};
}

/// Everything waiting for the channel's cycle to end told, with `err`.
fn replyWaiters(ab: *AudioBase, channel: usize, err: i8) void {
    const sys = ab.sys_base;
    while (sys.RemHead(&ab.states[channel].waiters)) |node| {
        const io = ioOf(node);
        io.req.err = err;
        sys.ReplyIO(&io.req);
    }
}

fn firstWrite(state: *ChannelState) ?*IOAudio {
    return ioOf(state.writes.first() orelse return null);
}

/// The write `n` places from the front.
fn writeAt(state: *ChannelState, n: u32) ?*IOAudio {
    var node = state.writes.first() orelse return null;
    var left = n;
    while (left > 0) : (left -= 1) node = node.next() orelse return null;
    return ioOf(node);
}

/// The request a node of one of the device's lists belongs to.
fn ioOf(node: *exec.Node) *IOAudio {
    const message: *exec.Message = @fieldParentPtr("node", node);
    const req: *exec.IORequest = @fieldParentPtr("message", message);
    return @alignCast(@fieldParentPtr("req", req));
}

/// Whether `io` is on `list`, by address.
fn onList(list: *exec.List, io: *IOAudio) bool {
    var it = list.iterator();
    while (it.next()) |node| {
        if (node == &io.req.message.node) return true;
    }
    return false;
}

fn audioTask(sys: *ExecBase) callconv(.c) void {
    const ab: *AudioBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const signal = sys.AllocSignal(-1);
    const quit = sys.AllocSignal(-1);
    const ok = signal >= 0 and quit >= 0 and bringUp(ab);
    if (ok) {
        ab.int_mask = @as(u32, 1) << @intCast(signal);
        ab.quit_mask = @as(u32, 1) << @intCast(quit);
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
        const got = sys.Wait(ab.int_mask | ab.quit_mask);
        if (got & ab.quit_mask != 0) break;
        sys.ObtainSemaphore(&ab.lock);
        mixBuffer(ab);
        sys.ReleaseSemaphore(&ab.lock);
    }
    // Expunged: everything the stream held given back.
    giveBack(ab);
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

/// A key that is not in use: counted up from 1, and round to 1 again
/// before it would turn negative.
fn newKey(ab: *AudioBase) i16 {
    ab.last_key +%= 1;
    if (ab.last_key <= 0) ab.last_key = 1;
    return ab.last_key;
}

fn bit(channel: usize) u32 {
    return @as(u32, 1) << @intCast(channel);
}

/// Whether the channel is the caller's: allocated, with the request's key.
fn ownsChannel(ab: *AudioBase, io: *IOAudio, channel: usize) bool {
    const state = &ab.states[channel];
    return state.taken != 0 and state.key == io.alloc_key;
}

/// The channels a command for several of them acts on: those it names
/// that are the caller's. One that is not drops out of `channels` and the
/// request comes back ADIOERR_NOALLOCATION; the rest are served.
fn ownedChannels(ab: *AudioBase, io: *IOAudio) u32 {
    var owned: u32 = 0;
    for (0..mixer.channels) |i| {
        if (io.channels & bit(i) == 0) continue;
        if (ownsChannel(ab, io, i)) owned |= bit(i) else io.req.err = audio.ADIOERR_NOALLOCATION;
    }
    io.channels = owned;
    return owned;
}

/// The channel a command for one channel acts on: the lowest it names,
/// and `channels` narrowed to it. Null - and `channels` 0 - when that one
/// is not the caller's or none is named.
fn ownedChannel(ab: *AudioBase, io: *IOAudio) ?usize {
    for (0..mixer.channels) |i| {
        if (io.channels & bit(i) == 0) continue;
        if (!ownsChannel(ab, io, i)) break;
        io.channels = bit(i);
        return i;
    }
    io.channels = 0;
    io.req.err = audio.ADIOERR_NOALLOCATION;
    return null;
}

const Allocation = enum { made, refused, locked };

/// ADCMD_ALLOCATE's work: the combination chosen (alloc.zig), its channels
/// taken from whoever had them - their writes and waits answered
/// IOERR_ABORTED, the channels reset - and given this request's key and
/// precedence. A combination with a locked channel is not taken: the
/// locks on it are told ADIOERR_CHANNELSTOLEN, and the allocation waits
/// until those channels are freed.
fn allocate(ab: *AudioBase, io: *IOAudio) Allocation {
    const count = @min(io.length, 16);
    if (count == 0 or io.data == null) {
        // No combinations: nothing to allocate, and nothing refused - only
        // a key.
        if (io.alloc_key == 0) io.alloc_key = newKey(ab);
        io.channels = 0;
        io.req.unit = null;
        return .made;
    }
    const combinations: [*]const u8 = @ptrCast(io.data.?);
    var precedences: [mixer.channels]i16 = undefined;
    for (&ab.states, 0..) |*state, i| {
        precedences[i] = if (state.taken != 0) state.precedence else alloc.free_precedence;
    }
    const precedence: i8 = io.req.message.node.pri;
    const mask = alloc.choose(combinations[0..count], precedences, precedence) orelse return .refused;
    if (mask & ab.lock_map != 0) {
        stealLocks(ab, mask);
        return .locked;
    }
    if (io.alloc_key == 0) io.alloc_key = newKey(ab);
    for (0..mixer.channels) |i| {
        if (mask & bit(i) == 0) continue;
        resetChannel(ab, i);
        const state = &ab.states[i];
        state.taken = 1;
        state.key = io.alloc_key;
        state.precedence = precedence;
    }
    io.channels = mask;
    io.req.unit = &ab.units[mask];
    return .made;
}

/// The locks on any of `mask`'s channels told that something of higher
/// precedence wants them. The channels stay locked until they are freed.
fn stealLocks(ab: *AudioBase, mask: u32) void {
    const sys = ab.sys_base;
    var it = ab.locks.iterator();
    while (it.next()) |node| {
        const lock = ioOf(node);
        if (lock.channels & mask == 0) continue;
        sys.Remove(node);
        lock.req.err = audio.ADIOERR_CHANNELSTOLEN;
        sys.ReplyIO(&lock.req);
    }
}

/// An allocation that waits: replied when it gets its channels, in the
/// order of its precedence among those waiting.
fn waitForChannels(ab: *AudioBase, io: *IOAudio) void {
    io.req.flags &= ~exec.IOF_QUICK;
    io.req.message.node.type = .message;
    ab.sys_base.Enqueue(&ab.waiting, &io.req.message.node);
}

/// The allocations waiting, tried again now that channels have come free
/// or their precedence has dropped. One that may not wait (ADIOF_NOWAIT -
/// it waited only for a lock) and still cannot be made is refused.
fn retryWaiting(ab: *AudioBase) void {
    const sys = ab.sys_base;
    var it = ab.waiting.iterator();
    while (it.next()) |node| {
        const io = ioOf(node);
        switch (allocate(ab, io)) {
            .made => io.req.err = 0,
            .refused => {
                if (io.req.flags & audio.ADIOF_NOWAIT == 0) continue;
                io.req.err = audio.ADIOERR_ALLOCFAILED;
                io.channels = 0;
                io.req.unit = null;
            },
            .locked => continue,
        }
        sys.Remove(node);
        sys.ReplyIO(&io.req);
    }
}

/// ADCMD_FREE's work on the channels in `mask`: each reset and nobody's,
/// and the locks on them given up - a lock request with no channel left
/// is replied.
fn freeChannels(ab: *AudioBase, mask: u32) void {
    const sys = ab.sys_base;
    for (0..mixer.channels) |i| {
        if (mask & bit(i) == 0) continue;
        resetChannel(ab, i);
        const state = &ab.states[i];
        state.taken = 0;
        state.key = 0;
        state.precedence = 0;
    }
    const unlocked: u8 = @intCast(mask & ab.lock_map);
    if (unlocked == 0) return;
    ab.lock_map &= ~unlocked;
    var it = ab.locks.iterator();
    while (it.next()) |node| {
        const lock = ioOf(node);
        lock.channels &= ~@as(u32, unlocked);
        if (lock.channels != 0) continue;
        sys.Remove(node);
        sys.ReplyIO(&lock.req);
    }
}

// --- the commands ---------------------------------------------------------

/// BeginIO: every command under the device's lock, which the mixer holds
/// for each buffer, so a command lands between two buffers and acts on
/// all the channels it names at once. A command for several channels
/// serves those that are the caller's and leaves the rest out of
/// `channels`; a command for one channel takes the lowest it names.
fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const ab = audioBase(dev);
    const ioa = ioAudio(io);
    const sys = ab.sys_base;
    io.err = 0;
    io.message.node.type = .message;

    sys.ObtainSemaphore(&ab.lock);
    defer sys.ReleaseSemaphore(&ab.lock);

    switch (io.command) {
        audio.ADCMD_ALLOCATE => switch (allocate(ab, ioa)) {
            .made => {},
            .refused => {
                if (io.flags & audio.ADIOF_NOWAIT == 0) return waitForChannels(ab, ioa);
                io.err = audio.ADIOERR_ALLOCFAILED;
                ioa.channels = 0;
                io.unit = null;
            },
            // Even a request that may not wait waits for a lock to go.
            .locked => return waitForChannels(ab, ioa),
        },
        audio.ADCMD_FREE => {
            freeChannels(ab, ownedChannels(ab, ioa));
            retryWaiting(ab);
        },
        audio.ADCMD_SETPREC => {
            const mask = ownedChannels(ab, ioa);
            for (0..mixer.channels) |i| {
                if (mask & bit(i) != 0) ab.states[i].precedence = io.message.node.pri;
            }
            retryWaiting(ab);
        },
        audio.ADCMD_LOCK => {
            // Every channel named must be the caller's, or none is locked.
            for (0..mixer.channels) |i| {
                if (ioa.channels & bit(i) != 0 and !ownsChannel(ab, ioa, i)) {
                    ioa.channels = 0;
                    io.err = audio.ADIOERR_NOALLOCATION;
                    break;
                }
            } else {
                ab.lock_map |= @intCast(ioa.channels & 0xF);
                io.flags &= ~exec.IOF_QUICK;
                sys.AddTail(&ab.locks, &io.message.node);
                return; // replied when its channels are freed or stolen
            }
        },
        exec.CMD_WRITE => if (ownedChannel(ab, ioa)) |channel| {
            if (ioa.data == null or ioa.length == 0) {
                io.err = exec.IOERR_BADADDRESS;
            } else {
                // Replied when its samples have been played, not now.
                io.flags &= ~exec.IOF_QUICK;
                const state = &ab.states[channel];
                sys.AddTail(&state.writes, &io.message.node);
                if (state.handed == 0) {
                    startFront(ab, channel);
                } else if (state.handed == 1) {
                    ab.voices[channel].queued = queuedOf(ioa);
                    state.handed = 2;
                }
                return;
            }
        },
        exec.CMD_READ => if (ownedChannel(ab, ioa)) |channel| {
            const state = &ab.states[channel];
            const playing: ?*IOAudio = if (state.announced != 0) firstWrite(state) else null;
            ioa.data = @ptrCast(playing);
        },
        audio.ADCMD_WAITCYCLE => if (ownedChannel(ab, ioa)) |channel| {
            // Nothing playing is a cycle already over.
            const state = &ab.states[channel];
            if (state.announced != 0) {
                io.flags &= ~exec.IOF_QUICK;
                sys.AddTail(&state.waiters, &io.message.node);
                return;
            }
        },
        audio.ADCMD_PERVOL => {
            const mask = ownedChannels(ab, ioa);
            const new_step = mixer.stepFor(audio.AUDIO_CLOCK, ioa.period, i2s.sample_rate);
            const new_volume = @min(ioa.volume, audio.ADVOLUME_MAX);
            for (0..mixer.channels) |i| {
                if (mask & bit(i) == 0) continue;
                const voice = &ab.voices[i];
                if (io.flags & audio.ADIOF_SYNCCYCLE != 0 and ab.states[i].announced != 0) {
                    // At the end of the cycle playing now.
                    voice.sync_step = new_step;
                    voice.sync_volume = new_volume;
                    voice.has_sync = 1;
                } else {
                    voice.step = new_step;
                    voice.volume = new_volume;
                    voice.has_sync = 0;
                }
            }
        },
        audio.ADCMD_FINISH => {
            const mask = ownedChannels(ab, ioa);
            for (0..mixer.channels) |i| {
                if (mask & bit(i) == 0) continue;
                const state = &ab.states[i];
                if (firstWrite(state) == null) continue;
                if (state.announced == 0) {
                    // Never begun: it is aborted rather than finished.
                    endFront(ab, i, exec.IOERR_ABORTED);
                } else if (io.flags & audio.ADIOF_SYNCCYCLE != 0) {
                    // The cycle playing now is its last.
                    const voice = &ab.voices[i];
                    voice.cycles = 1;
                    voice.endless = 0;
                } else {
                    endFront(ab, i, 0);
                }
            }
        },
        exec.CMD_STOP, exec.CMD_START => {
            // A stopped channel holds its write, and those sent to it,
            // until it is started. The channels named change together,
            // between two buffers, so channels started together start in
            // the same frame - a sound on a left and a right channel
            // stays in step.
            const mask = ownedChannels(ab, ioa);
            const stopped: u16 = @intFromBool(io.command == exec.CMD_STOP);
            for (0..mixer.channels) |i| {
                if (mask & bit(i) == 0) continue;
                ab.voices[i].stopped = stopped;
                if (stopped == 0) announceFront(ab, i);
            }
        },
        exec.CMD_FLUSH => {
            const mask = ownedChannels(ab, ioa);
            for (0..mixer.channels) |i| {
                if (mask & bit(i) != 0) flushChannel(ab, i, exec.IOERR_ABORTED);
            }
        },
        exec.CMD_RESET => {
            const mask = ownedChannels(ab, ioa);
            for (0..mixer.channels) |i| {
                if (mask & bit(i) != 0) resetChannel(ab, i);
            }
        },
        // Nothing is cached and nothing is buffered anywhere else.
        exec.CMD_CLEAR, exec.CMD_UPDATE => _ = ownedChannels(ab, ioa),
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyIO(io);
}

/// AbortIO: a write, a wait for a cycle, a lock or an allocation that
/// waits, answered IOERR_ABORTED. A write that plays stops, and the one
/// after it starts; a lock's channels stay locked until they are freed.
/// -1 for a request the device does not hold.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const ab = audioBase(dev);
    const ioa = ioAudio(io);
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.lock);
    defer sys.ReleaseSemaphore(&ab.lock);
    switch (io.command) {
        exec.CMD_WRITE => for (&ab.states, 0..) |*state, channel| {
            if (!onList(&state.writes, ioa)) continue;
            if (firstWrite(state) == ioa) {
                endFront(ab, channel, exec.IOERR_ABORTED);
                return 0;
            }
            const was_held = state.handed >= 2 and writeAt(state, 1) == ioa;
            sys.Remove(&io.message.node);
            if (was_held) {
                // The mixer held it behind the playing one: the next
                // write takes its place there.
                const voice = &ab.voices[channel];
                if (writeAt(state, 1)) |next| {
                    voice.queued = queuedOf(next);
                } else {
                    voice.queued = .{};
                    state.handed = 1;
                }
            }
            break;
        } else return -1,
        audio.ADCMD_WAITCYCLE => for (&ab.states) |*state| {
            if (!onList(&state.waiters, ioa)) continue;
            sys.Remove(&io.message.node);
            break;
        } else return -1,
        audio.ADCMD_LOCK => {
            if (!onList(&ab.locks, ioa)) return -1;
            sys.Remove(&io.message.node);
        },
        audio.ADCMD_ALLOCATE => {
            if (!onList(&ab.waiting, ioa)) return -1;
            sys.Remove(&io.message.node);
        },
        else => return -1,
    }
    io.err = exec.IOERR_ABORTED;
    sys.ReplyIO(io);
    return 0;
}

/// OpenDevice: the device's task and hardware the first time, and an
/// allocation as ADCMD_ALLOCATE makes it - from `data` and `length`, at
/// the request's precedence, without waiting. With a length of 0 the open
/// only gets a key. An allocation that fails fails the open
/// (ADIOERR_ALLOCFAILED).
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    _ = unit_number;
    const ab = audioBase(dev);
    if (io.message.length < @sizeOf(IOAudio)) return exec.IOERR_OPENFAIL;
    if (!start(ab)) return exec.IOERR_OPENFAIL;
    return openAllocating(ab, ioAudio(io));
}

/// The open's allocation, through the device's own BeginIO, as the
/// request would go. It waits only for a locked channel, which needs the
/// request's reply port.
fn openAllocating(ab: *AudioBase, io: *IOAudio) i32 {
    const sys = ab.sys_base;
    ab.dev.open_cnt += 1;
    ab.dev.flags &= ~exec.LIBF_DELEXP;
    io.req.command = audio.ADCMD_ALLOCATE;
    io.req.flags = audio.ADIOF_NOWAIT;
    const err = sys.DoIO(&io.req);
    io.req.flags = 0;
    if (err != 0) {
        freeKey(ab, io);
        ab.dev.open_cnt -= 1;
    }
    return err;
}

/// CloseDevice: every channel the request's key still holds freed, as
/// ADCMD_FREE does - a program that forgot its channels gives them back -
/// and the request left as it was.
fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const ab = audioBase(dev);
    freeKey(ab, ioAudio(io));
    dev.open_cnt -= 1;
    return null;
}

/// ADCMD_FREE on all four channels with the request's key, through the
/// device's BeginIO; the request's command, flags and error kept.
fn freeKey(ab: *AudioBase, io: *IOAudio) void {
    const command_was = io.req.command;
    const flags_was = io.req.flags;
    const err_was = io.req.err;
    io.req.command = audio.ADCMD_FREE;
    io.req.flags = 0;
    io.channels = (1 << mixer.channels) - 1;
    _ = ab.sys_base.DoIO(&io.req);
    io.req.command = command_was;
    io.req.flags = flags_was;
    io.req.err = err_was;
    io.channels = 0;
}

/// Expunge: while it is open only marked, to go at the last close. Then
/// the task is told to end - it gives the stream, the DMA, the codec and
/// the pads back - and once it has left its stack, the device goes.
/// exec makes it again from its ROM tag when it is next opened.
fn expunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
    const ab = audioBase(dev);
    const sys = ab.sys_base;
    if (dev.open_cnt != 0) {
        dev.flags |= exec.LIBF_DELEXP;
        return null;
    }
    if (ab.started != 0) {
        // Without a port to hear the task end on, the device stays.
        const port = sys.CreateMsgPort() orelse {
            dev.flags |= exec.LIBF_DELEXP;
            return null;
        };
        defer sys.DeleteMsgPort(port);
        var ended: exec.Message = .{ .reply_port = port };
        sys.SetTaskEndMsg(&ab.task, &ended);
        sys.Signal(&ab.task, ab.quit_mask);
        while (sys.GetMsg(port) == null) _ = sys.Wait(port.sigMask());
    }
    if (ab.stack) |stack| sys.FreeMem(stack, stack_size);
    sys.DetachLibrary(dev);
    const start_of: *anyopaque = @ptrFromInt(@intFromPtr(dev) - dev.neg_size);
    sys.FreeMem(start_of, @as(usize, dev.neg_size) + dev.pos_size);
    return null;
}

fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    _ = seg_list;
    dev.revision = DEVICE_REVISION;
    const ab = audioBase(dev);
    ab.sys_base = sys_base;
    sys_base.InitSemaphore(&ab.lock);
    ab.waiting.init(.message);
    ab.locks.init(.message);
    for (&ab.states) |*state| {
        state.writes.init(.message);
        state.waiters.init(.message);
    }
    for (&ab.units) |*unit| unit.msg_port.msg_list.init(.message);
    ab.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = DEVICE_NAME },
        .data = ab,
        .code = &intServer,
    };
    findOutput(ab);
    return dev;
}

/// Where the stream goes, read into the base: the board's codec - an
/// ES8311, the codec this device drives - and its amplifier, or on a board
/// without one an amplifier that takes I2S itself. One whose I2S lines are
/// not pads of the chip is no output; with none, `has_output` stays clear
/// and every open fails.
fn findOutput(ab: *AudioBase) void {
    const sys = ab.sys_base;
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    if (eb.FindBoardPart(null, st.PARTKIND_CODEC, st.CHIP_ES8311)) |codec| {
        const tags = codec.tags;
        if (!readLines(ab, ub, tags)) return;
        const mclk = BoardPin.of(ub.GetTagData(st.PART_PinMCLK, 0, tags));
        if (mclk.kind != expansion.boardpin.BPIN_GPIO) return;
        ab.mclk_pin = mclk.number;
        ab.codec_address = @truncate(ub.GetTagData(st.PART_Address, es8311.address, tags));
        ab.bus_unit = @truncate(ub.GetTagData(st.PART_BusUnit, 0, tags));
        if (eb.FindBoardPart(null, st.PARTKIND_AMPLIFIER, st.CHIP_ANY)) |amp| {
            ab.amplifier = BoardPin.of(ub.GetTagData(st.PART_PinEnable, 0, amp.tags));
        }
        ab.output_name = codec.node.name orelse "es8311";
        ab.sides = es8311.sides;
        ab.has_codec = 1;
        ab.has_output = 1;
        return;
    }
    // No codec: an amplifier on I2S, which is its own enable line's.
    var found = eb.FindBoardPart(null, st.PARTKIND_AMPLIFIER, st.CHIP_ANY);
    while (found) |amp| : (found = eb.FindBoardPart(amp, st.PARTKIND_AMPLIFIER, st.CHIP_ANY)) {
        if (ub.GetTagData(st.PART_Bus, st.BUS_NONE, amp.tags) != st.BUS_I2S) continue;
        if (!readLines(ab, ub, amp.tags)) return;
        ab.amplifier = BoardPin.of(ub.GetTagData(st.PART_PinEnable, 0, amp.tags));
        ab.output_name = amp.node.name orelse "amplifier";
        ab.sides = sidesOf(ub, amp.tags);
        ab.has_output = 1;
        return;
    }
}

/// Which side the part's speakers take first in a frame.
fn sidesOf(ub: *sdk.interface.utility.UtilityBase, tags: ?[*]const sdk.utility.TagItem) mixer.Sides {
    return if (ub.GetTagData(st.PART_SidesSwapped, 0, tags) != 0) .right_first else .left_first;
}

/// The bit clock, the word clock and the data out of a part's tags, into
/// the base. False if one is not a pad of the chip.
fn readLines(ab: *AudioBase, ub: *sdk.interface.utility.UtilityBase, tags: ?[*]const sdk.utility.TagItem) bool {
    const lines = [_]sdk.utility.Tag{ st.PART_PinBCLK, st.PART_PinWS, st.PART_PinDataOut };
    var pads: [lines.len]u8 = undefined;
    for (lines, 0..) |tag, at| {
        const line = BoardPin.of(ub.GetTagData(tag, 0, tags));
        if (line.kind != expansion.boardpin.BPIN_GPIO) return false;
        pads[at] = line.number;
    }
    ab.bclk_pin = pads[0];
    ab.ws_pin = pads[1];
    ab.data_out_pin = pads[2];
    return true;
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

/// What the device speaks, for ObtainDeviceUnits (expansion.library),
/// and where its units come from: its one unit; it is in the ROM of a board with a codec or an amplifier.
const device_speaks = [_]u32{ sdk.expansion.devices.DEVIF_AUDIO, 0 };

/// Cold start at 26: after i2c.device (35), dma.resource (70) and
/// timer.device, which its first open needs, and before the shell.
export const audio_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&audio_device_tag),
        .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
        .version = DEVICE_VERSION,
        .pri = 26,
        .type = .device,
        .name = DEVICE_NAME,
        .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
        .init = &init_table,
    },
    .speaks = &device_speaks,
    .units = 1,
};

// --- tests (host: ./zig build test) -----------------------------------------
//
// The device made from its ROM tag without the hardware: no board to read,
// no task. Opens go straight to the allocation an open makes, and the mix
// is driven by hand (`mixInto` stands in for the stream). A period of 75
// is a little under a sample a frame.

const testing = std.testing;
const kexec = @import("../../libs/exec/exec.zig");

const test_period: u16 = 75;
const wave = [_]i8{ 10, 20, 30, 40, 50, 60, 70, 80 };

fn testDevice() !*AudioBase {
    try kexec.setUp();
    const made = kexec.InitResident(kexec.SysBase, &audio_device_tag.resident, null) orelse return error.NoDevice;
    return audioBase(@ptrCast(@alignCast(made)));
}

/// The test's ports deleted, the device expunged - which frees it - and
/// nothing left over.
fn testDeviceGone(ab: *AudioBase, ports: []const *exec.MsgPort) !void {
    for (ports) |port| kexec.SysBase.iface().DeleteMsgPort(port);
    _ = kexec.RemDevice(kexec.SysBase, &ab.dev);
    try kexec.expectNoLeaks();
}

fn requestFor(ab: *AudioBase, port: *exec.MsgPort, precedence: i8) IOAudio {
    var io: IOAudio = .{};
    io.req.message.reply_port = port;
    io.req.message.length = @sizeOf(IOAudio);
    io.req.message.node.pri = precedence;
    io.req.device = &ab.dev;
    return io;
}

/// An open asking for one of `combinations`.
fn openWith(ab: *AudioBase, io: *IOAudio, combinations: []const u8) i32 {
    io.data = @ptrCast(combinations.ptr);
    io.length = @intCast(combinations.len);
    return openAllocating(ab, io);
}

/// A write of `wave` sent on `channels`, asked to play `cycles` times.
fn sendWrite(io: *IOAudio, from: *const IOAudio, channels: u32, cycles: u16, flags: u8) void {
    io.alloc_key = from.alloc_key;
    io.channels = channels;
    io.req.command = exec.CMD_WRITE;
    io.req.flags = audio.ADIOF_PERVOL | flags;
    io.data = &wave;
    io.length = wave.len;
    io.period = test_period;
    io.volume = 64;
    io.cycles = cycles;
    kexec.SysBase.iface().SendIO(&io.req);
}

/// A command on the channels `from` holds, with its flags, waited for.
fn command(io: *IOAudio, from: *const IOAudio, which: u16, channels: u32, flags: u8) i32 {
    io.alloc_key = from.alloc_key;
    io.channels = channels;
    io.req.command = which;
    io.req.flags = flags;
    return kexec.SysBase.iface().DoIO(&io.req);
}

/// An allocation of one of `combinations` sent, with its flags.
fn sendAllocate(io: *IOAudio, combinations: []const u8, flags: u8) void {
    io.data = @ptrCast(combinations.ptr);
    io.length = @intCast(combinations.len);
    io.req.command = audio.ADCMD_ALLOCATE;
    io.req.flags = flags;
    kexec.SysBase.iface().SendIO(&io.req);
}

fn mix(ab: *AudioBase, comptime frames: usize) [frames * 2]i16 {
    var out: [frames * 2]i16 = undefined;
    mixInto(ab, &out);
    return out;
}

fn replied(port: *exec.MsgPort) ?*exec.Message {
    return kexec.SysBase.iface().GetMsg(port);
}

test "an open allocates or fails, and a close frees what its key holds" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;

    const pairs = [_]u8{ 0x03, 0x0C };
    var first = requestFor(ab, port, 10);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &first, &pairs));
    try testing.expectEqual(@as(u32, 0x03), first.channels);
    try testing.expect(first.alloc_key > 0);
    var second = requestFor(ab, port, 10);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &second, &pairs));
    try testing.expectEqual(@as(u32, 0x0C), second.channels);
    try testing.expect(second.alloc_key != first.alloc_key);
    // Nothing left that the same precedence may take.
    var third = requestFor(ab, port, 10);
    try testing.expectEqual(@as(i32, audio.ADIOERR_ALLOCFAILED), openWith(ab, &third, &pairs));
    // Without combinations an open only gets a key.
    var bare = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &bare, &.{}));
    try testing.expectEqual(@as(u32, 0), bare.channels);
    try testing.expect(bare.alloc_key > 0);
    try testing.expectEqual(@as(u16, 3), ab.dev.open_cnt);

    _ = close(&ab.dev, &first.req);
    try testing.expectEqual(@as(u8, 0), ab.states[0].taken);
    try testing.expectEqual(@as(u8, 1), ab.states[2].taken);
    _ = close(&ab.dev, &second.req);
    _ = close(&ab.dev, &bare.req);
    try testing.expectEqual(@as(u16, 0), ab.dev.open_cnt);
    try testDeviceGone(ab, &.{port});
}

test "a higher precedence steals: the writes there are aborted, and the old key refused" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;

    var low = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &low, &.{0x01}));
    var playing = requestFor(ab, port, 0);
    sendWrite(&playing, &low, 0x01, 0, 0);
    try testing.expect(replied(port) == null);

    var high = requestFor(ab, port, 20);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &high, &.{0x01}));
    try testing.expectEqual(@as(u32, 0x01), high.channels);
    try testing.expectEqual(&playing.req.message, replied(port).?);
    try testing.expectEqual(@as(i8, exec.IOERR_ABORTED), playing.req.err);

    var late = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, audio.ADIOERR_NOALLOCATION), command(&late, &low, exec.CMD_FLUSH, 0x01, 0));
    try testing.expectEqual(@as(u32, 0), late.channels);
    _ = close(&ab.dev, &low.req);
    _ = close(&ab.dev, &high.req);
    try testDeviceGone(ab, &.{port});
}

test "an allocation that may wait gets its channels when they are freed" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;

    var holder = requestFor(ab, port, 10);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &holder, &.{0x0F}));
    var waiter = requestFor(ab, port, 10);
    sendAllocate(&waiter, &.{0x01}, 0);
    try testing.expect(replied(port) == null);

    var free_one = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), command(&free_one, &holder, audio.ADCMD_FREE, 0x01, 0));
    try testing.expectEqual(@as(u32, 0x01), free_one.channels);
    try testing.expectEqual(&waiter.req.message, replied(port).?);
    try testing.expectEqual(@as(i8, 0), waiter.req.err);
    try testing.expectEqual(@as(u32, 0x01), waiter.channels);

    _ = close(&ab.dev, &holder.req);
    waiter.channels = 0x01;
    _ = command(&waiter, &waiter, audio.ADCMD_FREE, 0x01, 0);
    try testDeviceGone(ab, &.{port});
}

test "a lock is told of a steal, the allocation waits for the free, even without waiting" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;

    var owner = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &owner, &.{0x01}));
    var lock = requestFor(ab, port, 0);
    lock.alloc_key = owner.alloc_key;
    lock.channels = 0x01;
    lock.req.command = audio.ADCMD_LOCK;
    sys.SendIO(&lock.req);
    try testing.expect(replied(port) == null);

    var thief = requestFor(ab, port, 20);
    sendAllocate(&thief, &.{0x01}, audio.ADIOF_NOWAIT);
    try testing.expectEqual(&lock.req.message, replied(port).?);
    try testing.expectEqual(@as(i8, audio.ADIOERR_CHANNELSTOLEN), lock.req.err);
    try testing.expect(replied(port) == null);

    _ = close(&ab.dev, &owner.req);
    try testing.expectEqual(&thief.req.message, replied(port).?);
    try testing.expectEqual(@as(u32, 0x01), thief.channels);
    _ = command(&thief, &thief, audio.ADCMD_FREE, 0x01, 0);
    try testDeviceGone(ab, &.{port});
}

test "writes queue without a limit, play in order, and each says when it starts" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    const starts = sys.CreateMsgPort().?;

    var owner = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &owner, &.{0x01}));
    var writes: [3]IOAudio = undefined;
    for (&writes) |*io| {
        io.* = requestFor(ab, port, 0);
        io.write_msg.reply_port = starts;
        sendWrite(io, &owner, 0x03, 1, audio.ADIOF_WRITEMESSAGE);
        // A write is one channel's: the lowest it names.
        try testing.expectEqual(@as(u32, 0x01), io.channels);
    }
    // The first starts at once, the others when their turn comes.
    try testing.expectEqual(&writes[0].write_msg, replied(starts).?);
    try testing.expect(replied(starts) == null);

    _ = mix(ab, 12);
    try testing.expectEqual(&writes[0].req.message, replied(port).?);
    try testing.expectEqual(&writes[1].write_msg, replied(starts).?);
    _ = mix(ab, 20);
    try testing.expectEqual(&writes[1].req.message, replied(port).?);
    try testing.expectEqual(&writes[2].write_msg, replied(starts).?);
    try testing.expectEqual(&writes[2].req.message, replied(port).?);
    try testing.expect(replied(port) == null);
    _ = close(&ab.dev, &owner.req);
    try testDeviceGone(ab, &.{ port, starts });
}

test "a wait for the cycle is told when the cycle playing ends" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;

    var owner = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &owner, &.{0x01}));
    // Nothing playing: a cycle already over.
    var early = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), command(&early, &owner, audio.ADCMD_WAITCYCLE, 0x01, 0));

    var looping = requestFor(ab, port, 0);
    sendWrite(&looping, &owner, 0x01, 0, 0);
    var waits: [2]IOAudio = undefined;
    for (&waits) |*io| {
        io.* = requestFor(ab, port, 0);
        io.alloc_key = owner.alloc_key;
        io.channels = 0x01;
        io.req.command = audio.ADCMD_WAITCYCLE;
        sys.SendIO(&io.req);
    }
    _ = mix(ab, 4);
    try testing.expect(replied(port) == null);
    _ = mix(ab, 6);
    try testing.expectEqual(&waits[0].req.message, replied(port).?);
    try testing.expectEqual(&waits[1].req.message, replied(port).?);

    var flush = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), command(&flush, &owner, exec.CMD_FLUSH, 0x01, 0));
    try testing.expectEqual(&looping.req.message, replied(port).?);
    try testing.expectEqual(@as(i8, exec.IOERR_ABORTED), looping.req.err);
    _ = close(&ab.dev, &owner.req);
    try testDeviceGone(ab, &.{port});
}

test "a finish ends the write now or at the end of its cycle, and the next goes on" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;

    var owner = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &owner, &.{0x01}));
    var first = requestFor(ab, port, 0);
    sendWrite(&first, &owner, 0x01, 0, 0);
    var second = requestFor(ab, port, 0);
    sendWrite(&second, &owner, 0x01, 0, 0);

    var finish = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), command(&finish, &owner, audio.ADCMD_FINISH, 0x01, 0));
    try testing.expectEqual(&first.req.message, replied(port).?);
    try testing.expectEqual(@as(i8, 0), first.req.err);
    try testing.expectEqual(@as(?*IOAudio, &second), firstWrite(&ab.states[0]));

    // At the end of the cycle: not yet, then once it has gone round.
    try testing.expectEqual(@as(i32, 0), command(&finish, &owner, audio.ADCMD_FINISH, 0x01, audio.ADIOF_SYNCCYCLE));
    try testing.expect(replied(port) == null);
    _ = mix(ab, 12);
    try testing.expectEqual(&second.req.message, replied(port).?);
    try testing.expectEqual(@as(i8, 0), second.req.err);
    _ = close(&ab.dev, &owner.req);
    try testDeviceGone(ab, &.{port});
}

test "stopped channels hold their writes and start together" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    const starts = sys.CreateMsgPort().?;

    var owner = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &owner, &.{0x03}));
    var stop = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), command(&stop, &owner, exec.CMD_STOP, 0x03, 0));
    var left = requestFor(ab, port, 0);
    left.write_msg.reply_port = starts;
    sendWrite(&left, &owner, 0x01, 0, audio.ADIOF_WRITEMESSAGE);
    // Between the two writes the mixer runs, and plays nothing.
    const quiet = mix(ab, 4);
    for (quiet) |sample| try testing.expectEqual(@as(i16, 0), sample);
    var right = requestFor(ab, port, 0);
    right.write_msg.reply_port = starts;
    sendWrite(&right, &owner, 0x02, 0, audio.ADIOF_WRITEMESSAGE);
    try testing.expect(replied(starts) == null);

    try testing.expectEqual(@as(i32, 0), command(&stop, &owner, exec.CMD_START, 0x03, 0));
    try testing.expectEqual(&left.write_msg, replied(starts).?);
    try testing.expectEqual(&right.write_msg, replied(starts).?);
    // In step: every frame the same on both sides.
    const heard = mix(ab, 8);
    for (0..8) |frame| try testing.expectEqual(heard[frame * 2], heard[frame * 2 + 1]);
    try testing.expect(heard[0] != 0);
    _ = close(&ab.dev, &owner.req);
    try testDeviceGone(ab, &.{ port, starts });
}

test "read answers the write playing; an abort takes a queued write out or ends the playing one" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;

    var owner = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &owner, &.{0x01}));
    var writes: [3]IOAudio = undefined;
    for (&writes) |*io| {
        io.* = requestFor(ab, port, 0);
        sendWrite(io, &owner, 0x01, 0, 0);
    }
    var read = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), command(&read, &owner, exec.CMD_READ, 0x01, 0));
    try testing.expectEqual(@as(usize, @intFromPtr(&writes[0])), @intFromPtr(read.data));

    // The one held behind the playing write: the third takes its place.
    try testing.expectEqual(@as(i32, 0), sys.AbortIO(&writes[1].req));
    try testing.expectEqual(&writes[1].req.message, replied(port).?);
    try testing.expectEqual(@as(i8, exec.IOERR_ABORTED), writes[1].req.err);
    try testing.expectEqual(@as(?[*]const i8, &wave), ab.voices[0].queued.data);
    // The playing one: the third plays.
    try testing.expectEqual(@as(i32, 0), sys.AbortIO(&writes[0].req));
    try testing.expectEqual(&writes[0].req.message, replied(port).?);
    try testing.expectEqual(@as(?*IOAudio, &writes[2]), firstWrite(&ab.states[0]));
    _ = close(&ab.dev, &owner.req);
    try testing.expectEqual(&writes[2].req.message, replied(port).?);
    try testDeviceGone(ab, &.{port});
}

test "a command for several channels serves the caller's and names the rest" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;

    var mine = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &mine, &.{0x01}));
    var theirs = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &theirs, &.{0x02}));

    var pervol = requestFor(ab, port, 0);
    pervol.period = 150;
    pervol.volume = 32;
    try testing.expectEqual(@as(i32, audio.ADIOERR_NOALLOCATION), command(&pervol, &mine, audio.ADCMD_PERVOL, 0x03, 0));
    try testing.expectEqual(@as(u32, 0x01), pervol.channels);
    try testing.expectEqual(@as(u16, 32), ab.voices[0].volume);
    try testing.expectEqual(@as(u16, 0), ab.voices[1].volume);
    _ = close(&ab.dev, &mine.req);
    _ = close(&ab.dev, &theirs.req);
    try testDeviceGone(ab, &.{port});
}

test "a period and volume for the end of the cycle wait for it" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;

    var owner = requestFor(ab, port, 0);
    try testing.expectEqual(@as(i32, 0), openWith(ab, &owner, &.{0x01}));
    var looping = requestFor(ab, port, 0);
    sendWrite(&looping, &owner, 0x01, 0, 0);
    var pervol = requestFor(ab, port, 0);
    pervol.period = test_period;
    pervol.volume = 16;
    try testing.expectEqual(@as(i32, 0), command(&pervol, &owner, audio.ADCMD_PERVOL, 0x01, audio.ADIOF_SYNCCYCLE));
    try testing.expectEqual(@as(u16, 64), ab.voices[0].volume);
    _ = mix(ab, 10);
    try testing.expectEqual(@as(u16, 16), ab.voices[0].volume);
    _ = close(&ab.dev, &owner.req);
    _ = replied(port);
    try testDeviceGone(ab, &.{port});
}

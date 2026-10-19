// SPDX-License-Identifier: MPL-2.0
//! audio.device: streams of sound, mixed into the board's codec or
//! amplifiers.
//!
//! Each open is a stream (`sdk/devices/audio.zig`): its own sample form,
//! rate, volume and pan, and a queue of writes. Up to sixteen play at
//! once; a task mixes them into one stereo stream (`mixer.zig`) at the rate
//! the output runs at, and a DMA channel hands that stream to the chip's
//! I2S controller (`esp32s3/i2s.zig`, `esp32p4/i2s.zig`,
//! `jh7110/i2s.zig`).
//!
//! Where the stream goes is the board's: an ES8311 codec (`es8311.zig`)
//! set up over I2C, with an amplifier in front of the speaker, or an
//! amplifier that takes I2S itself and needs nothing set up - the
//! CrowPanel's pair, one a speaker. Either has an enable line the device
//! drives while the stream runs. On the VisionFive 2 it is the HDMI port
//! (`jh7110/hdmi.zig`), and the JH7110's own DMA controller feeds the I2S
//! controller (`jh7110/dma.zig`) in place of dma.resource.
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
    .rv64sbi => @import("jh7110/i2s.zig"),
};

/// The JH7110's way out: the HDMI port, from I2STX0, which the chip's own
/// DMA controller feeds. No pads to take, no codec, no amplifier.
const jh7110 = !builtin.is_test and sdk.hardware.chip == .rv64sbi;
const ring_dma = if (jh7110) @import("jh7110/dma.zig") else struct {
    pub const Ring = extern struct {};
};
const hdmi = if (jh7110) @import("jh7110/hdmi.zig") else struct {};

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
const DEVICE_VERSION = 2;
const DEVICE_REVISION = 1;
const BUILD_DATE = "19.10.2026";
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

/// How many streams there are: a voice of the mixer each.
const max_streams = mixer.max_voices;

/// One stream: what an open made, and what every request on it points at
/// (`io_Unit`).
const Stream = extern struct {
    unit: exec.Unit = .{},
    /// Every write on the stream, in the order they play. The first is the
    /// one playing - or the one a stopped stream holds. `handed` says how
    /// many from the front the mixer has been given: none, the one it
    /// plays, or that one and the one it holds behind it (and, for a
    /// moment inside a mix, those it went on to).
    writes: exec.List = .{},
    handed: u32 = 0,
    /// The stream is someone's.
    in_use: u8 = 0,
    /// The form the next write is in.
    format: u8 = audio.AUDIO_S16,
    channels: u8 = 2,
    pad: u8 = 0,
    rate: u32 = 0,
    volume: u32 = audio.AUDIO_VOLUME_UNITY,
    pan: i32 = 0,
};

const AudioBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    /// The streams and their voices, shared by the task's mixer and every
    /// caller's BeginIO: a semaphore, since the mixer holds it for a whole
    /// buffer.
    lock: exec.SignalSemaphore = .{},
    streams: [max_streams]Stream = @splat(.{}),
    voices: [max_streams]mixer.Voice = @splat(.{}),
    /// The device's volume, over every stream (AUDIOCMD_MASTER).
    master: u32 = audio.AUDIO_VOLUME_UNITY,
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
    /// The stream runs (the controller started), and the DMA's interrupt
    /// server is in.
    streaming: u8 = 0,
    int_added: u8 = 0,
    pad4: [2]u8 = .{ 0, 0 },
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
    /// On the JH7110: the DMA controller's ring round the buffers. MCLK's
    /// pad is `mclk_pin`, which there is an input.
    ring: ring_dma.Ring = .{},
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
    const std_req: *exec.IOStdReq = @alignCast(@fieldParentPtr("req", io));
    return @alignCast(@fieldParentPtr("std", std_req));
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
    if (comptime jh7110) {
        if (!ring_dma.serve(ab.sys_base, &ab.ring)) return 0;
        ab.sys_base.Signal(&ab.task, ab.int_mask);
        return 1;
    }
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
    if (comptime jh7110) return bringUpHdmi(ab);
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
    sdk.exec.kprintf(sys, "%s: %s, %d Hz %s, up to %d streams mixed\n", .{
        DEVICE_NAME,
        ab.output_name,
        i2s.sample_rate,
        @as([*:0]const u8, if (ab.sides == .mono) "mono" else "stereo"),
        @as(u32, max_streams),
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
    if (comptime jh7110) return giveBackHdmi(ab);
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

// --- the JH7110's HDMI port ---------------------------------------------

/// The stream started out of the HDMI port: the buffers, the DMA
/// controller's ring round them, I2STX0 on the board's oscillator, and
/// the transmitter's sound on. Only once the display driver has the
/// transmitter up.
fn bringUpHdmi(ab: *AudioBase) bool {
    const sys = ab.sys_base;
    if (!hdmi.present()) {
        sdk.exec.kprintf(sys, "%s: the HDMI port is not up\n", .{DEVICE_NAME});
        return false;
    }
    // The buffers, written back with the silence they start with, and the
    // list items, each on 64 bytes of its own: one more for the rounding.
    const memory = sys.AllocVec(buffer_bytes * buffers, exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return false;
    ab.stream = @ptrCast(@alignCast(memory));
    var stream_bytes: u32 = buffer_bytes * buffers;
    _ = sys.CachePreDMA(memory, &stream_bytes, 0);
    const item_bytes = @sizeOf(ring_dma.Item);
    const block = sys.AllocVec(item_bytes * (buffers + 1), exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return false;
    ab.ring.block = block;
    ab.ring.items = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(block), item_bytes));
    ab.ring.buffers = @intFromPtr(memory);
    ab.ring.target = i2s.TXDMA;
    ab.ring.count = buffers;
    ab.ring.bytes = buffer_bytes;

    ring_dma.init();
    i2s.init(ab.mclk_pin);
    i2s.reset();
    sys.AddIntServer(ab.ring.irq, &ab.int);
    ab.int_added = 1;
    ring_dma.start(sys, &ab.ring, i2s.dma_handshake);
    i2s.start();
    hdmi.start(i2s.sample_rate);
    ab.streaming = 1;
    sdk.exec.kprintf(sys, "%s: %s, %d Hz stereo, up to %d streams mixed\n", .{
        DEVICE_NAME,
        ab.output_name,
        i2s.sample_rate,
        @as(u32, max_streams),
    });
    return true;
}

fn giveBackHdmi(ab: *AudioBase) void {
    const sys = ab.sys_base;
    if (ab.streaming != 0) {
        hdmi.stop();
        ring_dma.stop();
        i2s.stop();
    }
    ab.streaming = 0;
    if (ab.int_added != 0) sys.RemIntServer(ab.ring.irq, &ab.int);
    ab.int_added = 0;
    ab.ring.items = null;
    if (ab.ring.block) |block| sys.FreeVec(block);
    ab.ring.block = null;
    if (ab.stream) |stream| sys.FreeVec(stream);
    ab.stream = null;
}

/// The HDMI port's part: the pad the master clock comes in on, and the
/// DMA controller's interrupt.
fn findHdmi(ab: *AudioBase, eb: *sdk.interface.expansion.ExpansionBase, ub: *sdk.interface.utility.UtilityBase) void {
    const part = eb.FindBoardPart(null, st.PARTKIND_CODEC, st.CHIP_JH7110_HDMI) orelse return;
    const mclk = BoardPin.of(ub.GetTagData(st.PART_PinMCLK, 0, part.tags));
    if (mclk.kind != expansion.boardpin.BPIN_GPIO) return;
    ab.mclk_pin = mclk.number;
    ab.ring.irq = @intCast(ub.GetTagData(st.PART_Irq, 0, part.tags));
    ab.output_name = part.node.name orelse "hdmi";
    ab.has_output = 1;
}

// --- the mix --------------------------------------------------------------

/// The buffer that has just been played, which is the one to mix into:
/// the DMA is in the other one now.
fn freeBuffer(ab: *AudioBase) []i16 {
    const stream = ab.stream.?;
    if (comptime jh7110) return stream[ab.ring.ended * buffer_samples ..][0..buffer_samples];
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

/// `out` mixed from the streams, and the writes that played out replied.
/// Under the device's lock.
fn mixInto(ab: *AudioBase, out: []i16) void {
    const done = mixer.fill(&ab.voices, out, ab.sides, mixer.masterGain(ab.master), .{ .context = ab, .next = handNext });
    for (0..max_streams) |n| {
        for (0..done.ended[n]) |_| playedOut(ab, n);
    }
}

/// The mixer has taken over the write it held and asks for the one after
/// it: the first write it has not been given yet.
fn handNext(context: *anyopaque, n: usize) ?mixer.Queued {
    const ab: *AudioBase = @ptrCast(@alignCast(context));
    const stream = &ab.streams[n];
    const io = writeAt(stream, stream.handed) orelse return null;
    stream.handed += 1;
    return queuedOf(io);
}

/// The write at the front played out by the mixer: replied, with the
/// bytes it played, and the one after it - which the mixer went on with -
/// the front.
fn playedOut(ab: *AudioBase, n: usize) void {
    const stream = &ab.streams[n];
    const front = firstWrite(stream) orelse return;
    _ = ab.sys_base.RemHead(&stream.writes);
    stream.handed -|= 1;
    front.std.actual = front.std.length * @max(front.loops, 1);
    ab.sys_base.ReplyIO(&front.std.req);
}

/// What the mixer is handed of a write: its frames, how often, and the
/// form the stream had when it was sent.
fn queuedOf(io: *IOAudio) mixer.Queued {
    const frame = audio.frameBytes(io.format, io.channels);
    return .{
        .data = @ptrCast(io.std.data),
        .frames = @intCast(io.std.length / frame),
        .loops = io.loops,
        .format = io.format,
        .channels = io.channels,
    };
}

/// The stream's voice given the front write anew, and the one after it to
/// hold - after the front has changed outside a mix. The rate, the gains
/// and whether it is stopped stay the stream's.
fn startFront(ab: *AudioBase, n: usize) void {
    const stream = &ab.streams[n];
    const voice = &ab.voices[n];
    silence(ab, n);
    stream.handed = 0;
    const front = firstWrite(stream) orelse return;
    const first = queuedOf(front);
    voice.data = first.data;
    voice.frames = first.frames;
    voice.format = first.format;
    voice.channels = first.channels;
    voice.loops = first.loops;
    voice.endless = if (first.loops == 0) 1 else 0;
    stream.handed = 1;
    if (writeAt(stream, 1)) |second| {
        voice.queued = queuedOf(second);
        stream.handed = 2;
    }
}

/// A stream's voice with nothing to play. Its step, gains, count of frames
/// played and whether it is stopped stay.
fn silence(ab: *AudioBase, n: usize) void {
    const voice = &ab.voices[n];
    voice.* = .{
        .step = voice.step,
        .gain_left = voice.gain_left,
        .gain_right = voice.gain_right,
        .played = voice.played,
        .stopped = voice.stopped,
    };
}

/// The write at the front taken off: `err` its answer, and the next one
/// started in its place.
fn endFront(ab: *AudioBase, n: usize, err: i8) void {
    const stream = &ab.streams[n];
    const front = firstWrite(stream) orelse return;
    _ = ab.sys_base.RemHead(&stream.writes);
    front.std.req.err = err;
    front.std.actual = 0;
    ab.sys_base.ReplyIO(&front.std.req);
    startFront(ab, n);
}

/// Every write on a stream answered with `err`, and its voice silent -
/// CMD_FLUSH.
fn flushStream(ab: *AudioBase, n: usize, err: i8) void {
    const stream = &ab.streams[n];
    while (ab.sys_base.RemHead(&stream.writes)) |node| {
        const io = ioOf(node);
        io.std.req.err = err;
        io.std.actual = 0;
        ab.sys_base.ReplyIO(&io.std.req);
    }
    silence(ab, n);
    stream.handed = 0;
}

fn firstWrite(stream: *Stream) ?*IOAudio {
    return ioOf(stream.writes.first() orelse return null);
}

/// The write `n` places from the front.
fn writeAt(stream: *Stream, n: u32) ?*IOAudio {
    var node = stream.writes.first() orelse return null;
    var left = n;
    while (left > 0) : (left -= 1) node = node.next() orelse return null;
    return ioOf(node);
}

/// The request a node of a stream's writes belongs to.
fn ioOf(node: *exec.Node) *IOAudio {
    const message: *exec.Message = @fieldParentPtr("node", node);
    return ioAudio(@fieldParentPtr("message", message));
}

/// Whether `io` is on `list`, by address.
fn onList(list: *exec.List, io: *IOAudio) bool {
    var it = list.iterator();
    while (it.next()) |node| {
        if (node == &io.std.req.message.node) return true;
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

// --- the streams ----------------------------------------------------------

/// The number of the stream a request was opened on, or null for one that
/// was not opened here.
fn streamOf(ab: *AudioBase, io: *IOAudio) ?usize {
    const unit = io.std.req.unit orelse return null;
    for (&ab.streams, 0..) |*stream, n| {
        if (&stream.unit == unit and stream.in_use != 0) return n;
    }
    return null;
}

/// Whether the request's form, rate, volume and pan are ones the device
/// takes.
fn paramsValid(io: *const IOAudio) bool {
    if (audio.frameBytes(io.format, io.channels) == 0) return false;
    if (io.rate == 0 or io.rate > audio.AUDIO_MAX_RATE) return false;
    if (io.volume > audio.AUDIO_VOLUME_MAX) return false;
    return io.pan >= -audio.AUDIO_PAN_FULL and io.pan <= audio.AUDIO_PAN_FULL;
}

/// The request's form, rate, volume and pan made the stream's: the rate
/// and the gains at once, the form for the writes that follow.
fn takeParams(ab: *AudioBase, n: usize, io: *const IOAudio) void {
    const stream = &ab.streams[n];
    stream.format = io.format;
    stream.channels = io.channels;
    stream.rate = io.rate;
    stream.volume = io.volume;
    stream.pan = io.pan;
    const voice = &ab.voices[n];
    voice.step = mixer.stepFor(io.rate, i2s.sample_rate);
    const g = mixer.gains(io.volume, io.pan);
    voice.gain_left = g.left;
    voice.gain_right = g.right;
}

/// How many streams are open.
fn openStreams(ab: *AudioBase) u32 {
    var count: u32 = 0;
    for (&ab.streams) |*stream| count += stream.in_use;
    return count;
}

/// What the device and the board are, for AUDIOCMD_QUERY.
fn infoOf(ab: *AudioBase) audio.AudioInfo {
    return .{
        .rate = i2s.sample_rate,
        .channels = if (ab.sides == .mono) 1 else 2,
        .bits = 16,
        .latency = buffer_frames * buffers,
        .streams = openStreams(ab),
        .master = ab.master,
        .has_input = 0,
        .output = ab.output_name,
    };
}

// --- the commands ---------------------------------------------------------

/// BeginIO: every command under the device's lock, which the mixer holds
/// for each buffer, so a command lands between two buffers. A command acts
/// on the stream the request was opened on.
fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const ab = audioBase(dev);
    const ioa = ioAudio(io);
    const sys = ab.sys_base;
    io.err = 0;
    io.message.node.type = .message;

    sys.ObtainSemaphore(&ab.lock);
    defer sys.ReleaseSemaphore(&ab.lock);

    const n = streamOf(ab, ioa) orelse {
        io.err = exec.IOERR_OPENFAIL;
        sys.ReplyIO(io);
        return;
    };
    const stream = &ab.streams[n];
    switch (io.command) {
        exec.CMD_WRITE => {
            const frame = audio.frameBytes(stream.format, stream.channels);
            if (ioa.std.data == null or ioa.std.length == 0 or ioa.std.length % frame != 0 or ioa.std.length / frame > std.math.maxInt(u32)) {
                io.err = exec.IOERR_BADLENGTH;
            } else {
                // The write keeps the form the stream has now; replied when
                // its frames have been played, not now.
                ioa.format = stream.format;
                ioa.channels = stream.channels;
                ioa.std.actual = 0;
                io.flags &= ~exec.IOF_QUICK;
                sys.AddTail(&stream.writes, &io.message.node);
                if (stream.handed == 0) {
                    startFront(ab, n);
                } else if (stream.handed == 1) {
                    ab.voices[n].queued = queuedOf(ioa);
                    stream.handed = 2;
                }
                return;
            }
        },
        // A stopped stream holds its write, and those sent to it, until it
        // is started.
        exec.CMD_STOP => ab.voices[n].stopped = 1,
        exec.CMD_START => ab.voices[n].stopped = 0,
        exec.CMD_FLUSH => flushStream(ab, n, exec.IOERR_ABORTED),
        exec.CMD_RESET => {
            flushStream(ab, n, exec.IOERR_ABORTED);
            ab.voices[n].stopped = 0;
        },
        audio.AUDIOCMD_SETPARAMS => {
            if (paramsValid(ioa)) takeParams(ab, n, ioa) else io.err = audio.AUDIOERR_BADFORMAT;
        },
        audio.AUDIOCMD_QUERY => {
            ioa.position = ab.voices[n].played;
            if (ioa.std.data) |into| {
                if (ioa.std.length >= @sizeOf(audio.AudioInfo)) {
                    const info: *audio.AudioInfo = @ptrCast(@alignCast(into));
                    info.* = infoOf(ab);
                    ioa.std.actual = @sizeOf(audio.AudioInfo);
                } else {
                    io.err = exec.IOERR_BADLENGTH;
                }
            }
        },
        audio.AUDIOCMD_MASTER => {
            if (ioa.volume <= audio.AUDIO_VOLUME_MAX) ab.master = ioa.volume else io.err = audio.AUDIOERR_BADFORMAT;
        },
        // Nothing is cached and nothing is buffered anywhere else.
        exec.CMD_CLEAR, exec.CMD_UPDATE => {},
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyIO(io);
}

/// AbortIO: a write answered IOERR_ABORTED - one waiting taken out, the
/// one playing stopped and the one after it begun. -1 for a request the
/// device does not hold.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const ab = audioBase(dev);
    const ioa = ioAudio(io);
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.lock);
    defer sys.ReleaseSemaphore(&ab.lock);
    if (io.command != exec.CMD_WRITE) return -1;
    const n = streamOf(ab, ioa) orelse return -1;
    const stream = &ab.streams[n];
    if (!onList(&stream.writes, ioa)) return -1;
    if (firstWrite(stream) == ioa) {
        endFront(ab, n, exec.IOERR_ABORTED);
        return 0;
    }
    const was_held = stream.handed >= 2 and writeAt(stream, 1) == ioa;
    sys.Remove(&io.message.node);
    if (was_held) {
        // The mixer held it behind the playing one: the next write takes
        // its place there.
        const voice = &ab.voices[n];
        if (writeAt(stream, 1)) |next| {
            voice.queued = queuedOf(next);
        } else {
            voice.queued = .{};
            stream.handed = 1;
        }
    }
    io.err = exec.IOERR_ABORTED;
    ioa.std.actual = 0;
    sys.ReplyIO(io);
    return 0;
}

/// OpenDevice: the device's task and hardware the first time, then a
/// stream of the request's form, rate, volume and pan. Unit 1, the way
/// in, is not driven yet (AUDIOERR_NOINPUT).
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const ab = audioBase(dev);
    if (unit_number == audio.AUDIO_UNIT_RECORD) return audio.AUDIOERR_NOINPUT;
    if (unit_number != audio.AUDIO_UNIT_PLAY) return exec.IOERR_OPENFAIL;
    if (io.message.length < @sizeOf(IOAudio)) return exec.IOERR_OPENFAIL;
    if (!start(ab)) return exec.IOERR_OPENFAIL;
    return openStream(ab, ioAudio(io));
}

/// A stream for the request, if its parameters are good and one is free.
fn openStream(ab: *AudioBase, io: *IOAudio) i32 {
    const sys = ab.sys_base;
    if (!paramsValid(io)) return audio.AUDIOERR_BADFORMAT;
    sys.ObtainSemaphore(&ab.lock);
    defer sys.ReleaseSemaphore(&ab.lock);
    const n = for (&ab.streams, 0..) |*stream, n| {
        if (stream.in_use == 0) break n;
    } else return audio.AUDIOERR_NOSTREAM;
    const stream = &ab.streams[n];
    stream.in_use = 1;
    stream.handed = 0;
    ab.voices[n] = .{};
    takeParams(ab, n, io);
    io.std.req.unit = &stream.unit;
    ab.dev.open_cnt += 1;
    ab.dev.flags &= ~exec.LIBF_DELEXP;
    return 0;
}

/// CloseDevice: the stream's writes that are left answered IOERR_ABORTED -
/// a program that forgot them gets them back - and the stream free again.
fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const ab = audioBase(dev);
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.lock);
    if (streamOf(ab, ioAudio(io))) |n| {
        flushStream(ab, n, exec.IOERR_ABORTED);
        ab.voices[n] = .{};
        ab.streams[n].in_use = 0;
    }
    sys.ReleaseSemaphore(&ab.lock);
    io.unit = null;
    dev.open_cnt -= 1;
    return null;
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
    // The base comes zeroed; what it starts as is its fields' defaults -
    // the master at as recorded, no MCLK pad - the node exec made kept.
    const made = ab.dev;
    ab.* = .{ .dev = made, .sys_base = sys_base };
    sys_base.InitSemaphore(&ab.lock);
    for (&ab.streams) |*stream| {
        stream.writes.init(.message);
        stream.unit.msg_port.msg_list.init(.message);
    }
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
    if (comptime jh7110) return findHdmi(ab, eb, ub);
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
// no task. Opens go straight to the stream an open makes, and the mix is
// driven by hand (`mixInto` stands in for the output). The output runs at
// 48 kHz with the sides in order, so a stream at 48 kHz moves a frame an
// output frame and a one-channel stream is heard on both sides.

const testing = std.testing;
const kexec = @import("../../libs/exec/exec.zig");

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

/// A request for a 16-bit stream of one channel at the output's rate.
fn requestFor(ab: *AudioBase, port: *exec.MsgPort) IOAudio {
    var io: IOAudio = .{ .channels = 1, .rate = 48_000 };
    io.std.req.message.reply_port = port;
    io.std.req.message.length = @sizeOf(IOAudio);
    io.std.req.device = &ab.dev;
    return io;
}

/// A write of `data` on the stream `from` was opened on, `loops` times.
fn sendWrite(io: *IOAudio, from: *const IOAudio, data: []const u8, loops: u32) void {
    io.std.req.unit = from.std.req.unit;
    io.std.req.command = exec.CMD_WRITE;
    io.std.req.flags = 0;
    io.std.data = @ptrCast(@constCast(data.ptr));
    io.std.length = data.len;
    io.loops = loops;
    kexec.SysBase.iface().SendIO(&io.std.req);
}

/// A command on the stream `from` was opened on, waited for.
fn command(io: *IOAudio, from: *const IOAudio, which: u16) i32 {
    io.std.req.unit = from.std.req.unit;
    io.std.req.command = which;
    io.std.req.flags = 0;
    return kexec.SysBase.iface().DoIO(&io.std.req);
}

fn mix(ab: *AudioBase, comptime frames: usize) [frames * 2]i16 {
    var out: [frames * 2]i16 = undefined;
    mixInto(ab, &out);
    return out;
}

fn replied(port: *exec.MsgPort) ?*exec.Message {
    return kexec.SysBase.iface().GetMsg(port);
}

/// Bytes of 16-bit samples, in the machine's order.
fn pcm16(comptime samples: []const i16) [samples.len * 2]u8 {
    var bytes: [samples.len * 2]u8 = undefined;
    for (samples, 0..) |sample, i| {
        const word: u16 = @bitCast(sample);
        bytes[i * 2] = @truncate(word);
        bytes[i * 2 + 1] = @truncate(word >> 8);
    }
    return bytes;
}

test "an open is a stream of its own, sixteen at most; what it cannot take is refused; a close frees it" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;

    var requests: [max_streams + 1]IOAudio = undefined;
    for (requests[0..max_streams]) |*io| {
        io.* = requestFor(ab, port);
        try testing.expectEqual(@as(i32, 0), openStream(ab, io));
    }
    try testing.expect(requests[0].std.req.unit != requests[1].std.req.unit);
    try testing.expectEqual(@as(u32, max_streams), openStreams(ab));
    requests[max_streams] = requestFor(ab, port);
    try testing.expectEqual(@as(i32, audio.AUDIOERR_NOSTREAM), openStream(ab, &requests[max_streams]));

    // A form, a channel count, a rate or a pan the device does not take.
    var bad = requestFor(ab, port);
    bad.format = 9;
    try testing.expectEqual(@as(i32, audio.AUDIOERR_BADFORMAT), openStream(ab, &bad));
    bad.format = audio.AUDIO_S16;
    bad.channels = 3;
    try testing.expectEqual(@as(i32, audio.AUDIOERR_BADFORMAT), openStream(ab, &bad));
    bad.channels = 2;
    bad.rate = 0;
    try testing.expectEqual(@as(i32, audio.AUDIOERR_BADFORMAT), openStream(ab, &bad));
    bad.rate = 48_000;
    bad.pan = 2 * audio.AUDIO_PAN_FULL;
    try testing.expectEqual(@as(i32, audio.AUDIOERR_BADFORMAT), openStream(ab, &bad));
    // Unit 1 is the way in, which is not driven yet.
    try testing.expectEqual(@as(i32, audio.AUDIOERR_NOINPUT), open(&ab.dev, &bad.std.req, audio.AUDIO_UNIT_RECORD, 0));

    for (requests[0..max_streams]) |*io| _ = close(&ab.dev, &io.std.req);
    try testing.expectEqual(@as(u16, 0), ab.dev.open_cnt);
    try testing.expectEqual(@as(u32, 0), openStreams(ab));
    try testDeviceGone(ab, &.{port});
}

test "writes play one after the other without a gap, and come back with the bytes played" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));

    const a = pcm16(&.{ 100, 200 });
    const b = pcm16(&.{300});
    var first = requestFor(ab, port);
    var second = requestFor(ab, port);
    sendWrite(&first, &io, &a, 1);
    sendWrite(&second, &io, &b, 2);
    try testing.expect(replied(port) == null);
    const out = mix(ab, 6);
    // The one channel on both sides: 100, 200, then 300 twice, then quiet.
    try testing.expectEqualSlices(i16, &.{ 100, 100, 200, 200, 300, 300, 300, 300, 0, 0, 0, 0 }, &out);
    try testing.expect(replied(port) == &first.std.req.message);
    try testing.expect(replied(port) == &second.std.req.message);
    try testing.expectEqual(@as(u64, 4), first.std.actual);
    try testing.expectEqual(@as(u64, 4), second.std.actual);
    try testing.expectEqual(@as(i8, 0), second.std.req.err);

    _ = close(&ab.dev, &io.std.req);
    try testDeviceGone(ab, &.{port});
}

test "each write keeps the form it was sent in; new parameters change the rate and gains at once" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));

    const words = pcm16(&.{1000});
    const bytes = [_]u8{100};
    var first = requestFor(ab, port);
    sendWrite(&first, &io, &words, 1);
    // From here on 8-bit samples, at half the volume.
    var params = requestFor(ab, port);
    params.format = audio.AUDIO_S8;
    params.volume = audio.AUDIO_VOLUME_UNITY / 2;
    try testing.expectEqual(@as(i32, 0), command(&params, &io, audio.AUDIOCMD_SETPARAMS));
    var second = requestFor(ab, port);
    sendWrite(&second, &io, &bytes, 1);
    try testing.expectEqual(audio.AUDIO_S16, first.format);
    try testing.expectEqual(audio.AUDIO_S8, second.format);
    const out = mix(ab, 2);
    try testing.expectEqual(@as(i16, 500), out[0]);
    try testing.expectEqual(@as(i16, 100 * 256 / 2), out[2]);
    _ = replied(port);
    _ = replied(port);

    // Parameters it does not take change nothing.
    params.rate = audio.AUDIO_MAX_RATE + 1;
    try testing.expectEqual(@as(i32, audio.AUDIOERR_BADFORMAT), command(&params, &io, audio.AUDIOCMD_SETPARAMS));
    try testing.expectEqual(audio.AUDIO_S8, ab.streams[0].format);

    _ = close(&ab.dev, &io.std.req);
    try testDeviceGone(ab, &.{port});
}

test "stop holds a stream, start goes on, flush answers its writes aborted" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));

    const note = pcm16(&.{1000});
    var forever = requestFor(ab, port);
    sendWrite(&forever, &io, &note, 0);
    try testing.expectEqual(@as(i16, 1000), mix(ab, 1)[0]);
    var control = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), command(&control, &io, exec.CMD_STOP));
    try testing.expectEqual(@as(i16, 0), mix(ab, 1)[0]);
    try testing.expectEqual(@as(i32, 0), command(&control, &io, exec.CMD_START));
    try testing.expectEqual(@as(i16, 1000), mix(ab, 1)[0]);
    try testing.expect(replied(port) == null);
    try testing.expectEqual(@as(i32, 0), command(&control, &io, exec.CMD_FLUSH));
    try testing.expect(replied(port) == &forever.std.req.message);
    try testing.expectEqual(exec.IOERR_ABORTED, forever.std.req.err);
    try testing.expectEqual(@as(i16, 0), mix(ab, 1)[0]);

    _ = close(&ab.dev, &io.std.req);
    try testDeviceGone(ab, &.{port});
}

test "an abort takes a waiting write out, or ends the one playing and the next goes on" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));

    const a = pcm16(&.{111});
    const b = pcm16(&.{222});
    const c = pcm16(&.{333});
    var first = requestFor(ab, port);
    var held = requestFor(ab, port);
    var third = requestFor(ab, port);
    sendWrite(&first, &io, &a, 0);
    sendWrite(&held, &io, &b, 1);
    sendWrite(&third, &io, &c, 1);
    try testing.expectEqual(@as(i16, 111), mix(ab, 1)[0]);
    // The one the mixer holds behind the playing one, then the playing one.
    try testing.expectEqual(@as(i32, 0), abortIO(&ab.dev, &held.std.req));
    try testing.expectEqual(@as(i32, 0), abortIO(&ab.dev, &first.std.req));
    try testing.expect(replied(port) == &held.std.req.message);
    try testing.expect(replied(port) == &first.std.req.message);
    try testing.expectEqual(exec.IOERR_ABORTED, first.std.req.err);
    try testing.expectEqual(@as(i16, 333), mix(ab, 1)[0]);
    try testing.expectEqual(@as(i16, 0), mix(ab, 1)[0]);
    try testing.expect(replied(port) == &third.std.req.message);
    // A write that is not there any more.
    try testing.expectEqual(@as(i32, -1), abortIO(&ab.dev, &third.std.req));

    _ = close(&ab.dev, &io.std.req);
    try testDeviceGone(ab, &.{port});
}

test "the query says what the output is and how far the stream has got; the master turns everything down" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));

    var info: audio.AudioInfo = .{};
    var ask = requestFor(ab, port);
    ask.std.data = &info;
    ask.std.length = @sizeOf(audio.AudioInfo);
    try testing.expectEqual(@as(i32, 0), command(&ask, &io, audio.AUDIOCMD_QUERY));
    try testing.expectEqual(@as(u32, 48_000), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u32, 16), info.bits);
    try testing.expectEqual(buffer_frames * buffers, info.latency);
    try testing.expectEqual(@as(u32, 1), info.streams);
    try testing.expectEqual(@as(u32, max_streams), info.max_streams);
    try testing.expectEqual(@as(u32, 0), ask.position);

    const note = pcm16(&.{ 1000, 1000, 1000 });
    var write = requestFor(ab, port);
    sendWrite(&write, &io, &note, 0);
    _ = mix(ab, 3);
    ask.std.data = null;
    try testing.expectEqual(@as(i32, 0), command(&ask, &io, audio.AUDIOCMD_QUERY));
    try testing.expectEqual(@as(u32, 3), ask.position);

    var master = requestFor(ab, port);
    master.volume = audio.AUDIO_VOLUME_UNITY / 2;
    try testing.expectEqual(@as(i32, 0), command(&master, &io, audio.AUDIOCMD_MASTER));
    try testing.expectEqual(@as(i16, 500), mix(ab, 1)[0]);
    master.volume = audio.AUDIO_VOLUME_MAX + 1;
    try testing.expectEqual(@as(i32, audio.AUDIOERR_BADFORMAT), command(&master, &io, audio.AUDIOCMD_MASTER));

    _ = close(&ab.dev, &io.std.req);
    try testing.expect(replied(port) == &write.std.req.message);
    try testDeviceGone(ab, &.{port});
}

test "a write is whole frames, or it is refused" {
    const ab = try testDevice();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort().?;
    var io = requestFor(ab, port);
    io.channels = 2;
    try testing.expectEqual(@as(i32, 0), openStream(ab, &io));
    const three = [_]u8{ 1, 2, 3 };
    var write = requestFor(ab, port);
    write.std.data = @ptrCast(@constCast(&three));
    write.std.length = three.len;
    try testing.expectEqual(@as(i32, exec.IOERR_BADLENGTH), command(&write, &io, exec.CMD_WRITE));
    write.std.data = null;
    write.std.length = 4;
    try testing.expectEqual(@as(i32, exec.IOERR_BADLENGTH), command(&write, &io, exec.CMD_WRITE));
    _ = close(&ab.dev, &io.std.req);
    try testDeviceGone(ab, &.{port});
}

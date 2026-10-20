// SPDX-License-Identifier: MPL-2.0
//! The ES8311 codec as a sink and a source: set up over I2C, fed and read
//! over an I2S line, with the amplifier in front of its speaker switched
//! by its enable line.
//!
//! A module of its own. At cold start it opens rta.library, hands in a
//! driver of the sink and the source kind, and makes a sink for every
//! ES8311 the board lists (expansion.library): an "i2s" line from the
//! codec's tags first, then the sink over it, named as the board names the
//! part - and, where the board brings the codec's data out to a pad of the
//! chip (`PART_PinDataIn`), a source on the same line, for its microphone.
//! The board's amplifier - a part of its own, not on I2S - is the codec's:
//! its enable line comes along with the codec's tags.
//!
//! The sink and the source are two handles on one codec. The codec itself
//! - where it answers, and how many of the two have it up - is the sink's,
//! and the source is told its sink when it is made. Nothing is touched
//! until one of them is started, on the task that is to fill or take its
//! buffers. That opens i2c.device and timer.device for it, and - when the
//! other is not running already - resets the codec and sets it up for a
//! master clock 256 times the rate (`codec.zig`), both ways at once. Then
//! the sink starts its line's way out - the clocks run from here, which
//! the codec counts in - turns the volume up and the amplifier on; the
//! source starts the line's way in and turns the ADC's volume up. The
//! codec plays one side and hears one, so its modes are mono: both sides
//! together in each half of the frame out, the one side in the first half
//! of the frame in.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rta = sdk.rta;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const UtilityBase = sdk.interface.utility.UtilityBase;
const RtaBase = sdk.interface.rta.RtaBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const err = rta.errors;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const BoardPin = expansion.BoardPin;
const i2c = sdk.devices.i2c;
const timer = sdk.devices.timer;

const codec = @import("codec.zig");
const Enable = @import("../enable.zig").Enable;

const MODULE_NAME = "rta-es8311";
const DRIVER_NAME = "es8311";
const VERSION = 1;
const REVISION = 2;
const BUILD_DATE = "20.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// How loud the codec is driven. The amplifier does the rest, and half
/// of what the part can do is as much as these speakers want.
const codec_volume: u32 = 50;

/// The rates it runs at - 48 kHz, the default, and a CD's 44.1 kHz -
/// and their modes' names. Its master clock is 256 times the rate, which
/// is what the bring-up's dividers are for at either.
const rates = [_]u32{ 48_000, 44_100 };
const mode_names = [_][*:0]const u8{ "48000 Hz mono", "44100 Hz mono" };

/// A source's tag, this driver's own: the sink whose codec it records
/// from.
const ES8311_Sink = utility.TAG_USER | 0x8311;

/// Everything this driver has that changes, allocated once by the init.
const State = struct {
    driver: rta.RtaDriver = .{},
    sys: *ExecBase,
    utility: *UtilityBase,
    rta: *RtaBase,
};

fn stateOf(driver: *rta.RtaDriver) *State {
    return @fieldParentPtr("driver", driver);
}

/// The codec, which its sink and its source share: where it answers on
/// its bus, and how many of the two have it up.
const Codec = struct {
    address: u16 = codec.address,
    bus_unit: u32 = 0,
    users: u32 = 0,
};

/// What one handle - the sink or the source - keeps: the codec (its own,
/// in the sink; the sink's, for the source), the amplifier's line (the
/// sink's), its modes, and while it runs the requests it talks through.
const Instance = struct {
    state: *State,
    own: Codec = .{},
    part: *Codec = undefined,
    amplifier: Enable = .{},
    modes: [rates.len]rta.AudioMode = @splat(.{}),
    port: ?*exec.MsgPort = null,
    i2c_io: i2c.IOExtI2C = .{},
    timer_io: timer.TimeRequest = .{},
};

fn instanceOf(sink: *rta.AudioSink) *Instance {
    return @ptrCast(@alignCast(sink.instance.?));
}

fn sourceInstanceOf(source: *rta.AudioSource) *Instance {
    return @ptrCast(@alignCast(source.instance.?));
}

/// A handle's modes, one a rate, the first the default.
fn addModes(instance: *Instance, modes: *exec.List, sides: u8) void {
    for (&instance.modes, rates, mode_names, 0..) |*mode, mode_rate, name, n| {
        mode.* = .{
            .node = .{ .name = name },
            .id = @intCast(n),
            .rate = mode_rate,
            .bits = 16,
            .channels = 1,
            .sides = sides,
            .flags = if (n == 0) rta.sinks.AUDIOMF_DEFAULT else 0,
        };
        instance.state.sys.AddTail(modes, &mode.node);
    }
}

fn createSink(made_by: *rta.RtaDriver, sink: *rta.AudioSink, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    const ub = state.utility;
    const io = sink.transport orelse return err.RTAERR_BAD_TAGS;
    // A codec counts in its master clock, so its pad has to be there.
    const mclk = BoardPin.of(ub.GetTagData(st.PART_PinMCLK, 0, tag_list));
    if (mclk.kind != expansion.boardpin.BPIN_GPIO) return err.RTAERR_BAD_TAGS;
    const instance = instanceOf(sink);
    instance.* = .{
        .state = state,
        .own = .{
            .address = @truncate(ub.GetTagData(st.PART_Address, codec.address, tag_list)),
            .bus_unit = @truncate(ub.GetTagData(st.PART_BusUnit, 0, tag_list)),
        },
        .amplifier = Enable.of(ub.GetTagData(st.PART_PinEnable, 0, tag_list)),
    };
    instance.part = &instance.own;
    addModes(instance, &sink.modes, codec.sides);
    sink.ops = &ops;
    sink.buffer_frames = io.buffer_frames;
    sink.buffers = io.buffers;
    return err.RTAERR_OK;
}

/// A source on the codec of the sink its tags name, read over the same
/// line.
fn createSource(made_by: *rta.RtaDriver, source: *rta.AudioSource, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    const io = source.transport orelse return err.RTAERR_BAD_TAGS;
    const sink: *rta.AudioSink = @ptrFromInt(state.utility.GetTagData(ES8311_Sink, 0, tag_list));
    if (@intFromPtr(sink) == 0 or sink.driver != made_by) return err.RTAERR_BAD_TAGS;
    const instance = sourceInstanceOf(source);
    instance.* = .{ .state = state };
    instance.part = instanceOf(sink).part;
    addModes(instance, &source.modes, rta.AUDIOSIDES_MONO);
    source.ops = &source_ops;
    source.buffer_frames = io.buffer_frames;
    source.buffers = io.buffers;
    return err.RTAERR_OK;
}

fn wait(instance: *Instance, us: u32) void {
    instance.timer_io.node.command = timer.TR_ADDREQUEST;
    instance.timer_io.time = timer.TimeVal.fromMicros(us);
    _ = instance.state.sys.DoIO(&instance.timer_io.node);
}

/// One register of the codec.
fn writeCodec(instance: *Instance, register: u8, value: u8) bool {
    var bytes = [2]u8{ register, value };
    const io = &instance.i2c_io;
    io.req.req.command = exec.CMD_WRITE;
    io.req.req.flags = exec.IOF_QUICK;
    io.address = instance.part.address;
    io.req.data = &bytes;
    io.req.length = bytes.len;
    _ = instance.state.sys.DoIO(&io.req.req);
    return io.req.req.err == 0;
}

/// The handle's own requests opened, on the task that starts it, and the
/// codec set up if the other handle has not set it up already. `absent`
/// is the answer for a bus or a timer that is not there.
fn partUp(instance: *Instance, absent: i32) i32 {
    const sys = instance.state.sys;
    instance.port = sys.CreateMsgPort() orelse return err.RTAERR_NO_MEMORY;
    instance.i2c_io = .{};
    instance.i2c_io.req.req.message.reply_port = instance.port;
    instance.i2c_io.req.req.message.length = @sizeOf(i2c.IOExtI2C);
    if (sys.OpenDevice(i2c.DEVICE_NAME, instance.part.bus_unit, &instance.i2c_io.req.req, 0) != 0) {
        exec.kprintf(sys, "%s: no %s unit %d\n", .{ MODULE_NAME, i2c.DEVICE_NAME, instance.part.bus_unit });
        return absent;
    }
    instance.timer_io = .{};
    instance.timer_io.node.message.reply_port = instance.port;
    instance.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &instance.timer_io.node, 0) != 0) return absent;

    if (instance.part.users == 0) {
        for (codec.bring_up) |one| {
            if (!writeCodec(instance, one.reg, one.value)) {
                exec.kprintf(sys, "%s: the codec does not answer at 0x%02x\n", .{ MODULE_NAME, @as(u32, instance.part.address) });
                return err.RTAERR_IO;
            }
            if (one.delay_ms != 0) wait(instance, @as(u32, one.delay_ms) * 1000);
        }
    }
    instance.part.users += 1;
    return err.RTAERR_OK;
}

/// The handle's requests closed; the codec is one user less. `counted`
/// says whether `partUp` got as far as counting it.
fn partDown(instance: *Instance, counted: bool) void {
    const sys = instance.state.sys;
    if (counted and instance.part.users != 0) instance.part.users -= 1;
    if (instance.timer_io.node.device != null) sys.CloseDevice(&instance.timer_io.node);
    instance.timer_io = .{};
    if (instance.i2c_io.req.req.device != null) sys.CloseDevice(&instance.i2c_io.req.req);
    instance.i2c_io = .{};
    if (instance.port) |port| sys.DeleteMsgPort(port);
    instance.port = null;
}

/// The codec brought up and the line started, in the order the parts want
/// it: the bus and the reset, the codec's set-up, the clocks, then the
/// volume and the amplifier - a speaker that comes up mid-note is a bang.
fn start(sink: *rta.AudioSink, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = instanceOf(sink);
    const state = instance.state;
    if (!instance.amplifier.take(state.sys, MODULE_NAME)) return err.RTAERR_IN_USE;
    var code = partUp(instance, err.RTAERR_NO_OUTPUT);
    if (code == err.RTAERR_OK) {
        code = state.rta.StartAudioTransport(sink.transport.?, mode, task, signal_mask);
        if (code == err.RTAERR_OK) {
            _ = writeCodec(instance, codec.reg_volume, codec.volumeFor(codec_volume));
            instance.amplifier.set(true);
            return err.RTAERR_OK;
        }
        partDown(instance, true);
    } else {
        partDown(instance, false);
    }
    instance.amplifier.giveBack();
    return code;
}

/// The amplifier off first, so the speaker does not hear the clocks stop,
/// then the DAC silent, the line's way out stopped, and the codec's bus
/// given up.
fn stop(sink: *rta.AudioSink) callconv(.c) void {
    const instance = instanceOf(sink);
    instance.amplifier.giveBack();
    _ = writeCodec(instance, codec.reg_volume, 0);
    instance.state.rta.StopAudioTransport(sink.transport.?);
    partDown(instance, true);
}

/// The line's next buffer, and the gaps it counted.
fn buffer(sink: *rta.AudioSink) callconv(.c) ?[*]i16 {
    const io = sink.transport.?;
    const frames = instanceOf(sink).state.rta.AudioTransportBuffer(io);
    sink.underruns = io.underruns;
    return frames;
}

fn play(sink: *rta.AudioSink, frames: [*]i16) callconv(.c) i32 {
    return instanceOf(sink).state.rta.PlayAudioTransportBuffer(sink.transport.?, frames);
}

const ops = rta.AudioSinkOps{
    .start = &start,
    .stop = &stop,
    .buffer = &buffer,
    .play = &play,
};

/// The microphone: the codec up, the line's way in started, and the ADC's
/// volume up once the data comes.
fn startSource(source: *rta.AudioSource, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = sourceInstanceOf(source);
    const state = instance.state;
    var code = partUp(instance, err.RTAERR_NO_INPUT);
    if (code != err.RTAERR_OK) {
        partDown(instance, false);
        return code;
    }
    code = state.rta.StartAudioTransportInput(source.transport.?, mode, task, signal_mask);
    if (code != err.RTAERR_OK) {
        partDown(instance, true);
        return code;
    }
    _ = writeCodec(instance, codec.reg_adc_volume, codec.adc_unity);
    return err.RTAERR_OK;
}

/// The ADC silent, the line's way in stopped, the bus given up.
fn stopSource(source: *rta.AudioSource) callconv(.c) void {
    const instance = sourceInstanceOf(source);
    _ = writeCodec(instance, codec.reg_adc_volume, 0);
    instance.state.rta.StopAudioTransportInput(source.transport.?);
    partDown(instance, true);
}

/// The line's last buffer in, and the ones it lost.
fn sourceBuffer(source: *rta.AudioSource) callconv(.c) ?[*]const i16 {
    const io = source.transport.?;
    const frames = sourceInstanceOf(source).state.rta.AudioTransportInput(io);
    source.overruns = io.overruns;
    return frames;
}

const source_ops = rta.AudioSourceOps{
    .start = &startSource,
    .stop = &stopSource,
    .buffer = &sourceBuffer,
};

const driver_ops = rta.RtaDriverOps{ .create_sink = &createSink, .create_source = &createSource };

/// A sink for every ES8311 the board lists, each over a line of its own,
/// and a source beside it where the codec's data comes back to the chip.
fn makeSinks(state: *State, eb: *ExpansionBase) void {
    const sys = state.sys;
    const ub = state.utility;
    const rb = state.rta;
    // The amplifier in front of the speaker: the one the board lists that
    // takes no I2S of its own.
    var enable: usize = 0;
    var amp = eb.FindBoardPart(null, st.PARTKIND_AMPLIFIER, st.CHIP_ANY);
    while (amp) |part| : (amp = eb.FindBoardPart(part, st.PARTKIND_AMPLIFIER, st.CHIP_ANY)) {
        if (ub.GetTagData(st.PART_Bus, st.BUS_NONE, part.tags) == st.BUS_I2S) continue;
        enable = ub.GetTagData(st.PART_PinEnable, 0, part.tags);
        break;
    }
    var found = eb.FindBoardPart(null, st.PARTKIND_CODEC, st.CHIP_ES8311);
    while (found) |part| : (found = eb.FindBoardPart(part, st.PARTKIND_CODEC, st.CHIP_ES8311)) {
        const io = rb.CreateAudioTransportTagList("i2s", part.tags) orelse {
            exec.kprintf(sys, "%s: no I2S line: %s\n", .{ MODULE_NAME, rb.RtaErrorText(rb.RtaLastError()) });
            continue;
        };
        const name: usize = @intFromPtr(part.node.name orelse DRIVER_NAME);
        const sink_tags = [_]TagItem{
            .{ .tag = rta.tags.RTAA_Name, .data = name },
            .{ .tag = rta.tags.RTAA_Transport, .data = @intFromPtr(io) },
            .{ .tag = if (enable != 0) st.PART_PinEnable else utility.TAG_IGNORE, .data = enable },
            .{ .tag = utility.TAG_MORE, .data = @intFromPtr(part.tags) },
        };
        const sink = rb.CreateSinkTagList(DRIVER_NAME, &sink_tags) orelse {
            exec.kprintf(sys, "%s: no sink: %s\n", .{ MODULE_NAME, rb.RtaErrorText(rb.RtaLastError()) });
            rb.DeleteAudioTransport(io);
            continue;
        };
        if (BoardPin.of(ub.GetTagData(st.PART_PinDataIn, 0, part.tags)).kind != expansion.boardpin.BPIN_GPIO) continue;
        const source_tags = [_]TagItem{
            .{ .tag = rta.tags.RTAA_Name, .data = name },
            .{ .tag = rta.tags.RTAA_Transport, .data = @intFromPtr(io) },
            .{ .tag = ES8311_Sink, .data = @intFromPtr(sink) },
            .{ .tag = utility.TAG_MORE, .data = @intFromPtr(part.tags) },
        };
        if (rb.CreateSourceTagList(DRIVER_NAME, &source_tags) == null) {
            exec.kprintf(sys, "%s: no source: %s\n", .{ MODULE_NAME, rb.RtaErrorText(rb.RtaLastError()) });
        }
    }
}

/// Cold start at 31: after rta.library (33) and the I2S line's driver
/// (32), whose lines it makes.
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
    state.* = .{ .sys = sys, .utility = @ptrCast(utility_lib), .rta = rb };
    state.driver = .{
        .node = .{ .name = DRIVER_NAME, .pri = 0 },
        .version = VERSION,
        .revision = REVISION,
        .id_string = VERSION_STRING[1..],
        .type = rta.sinks.RTADT_SINK | rta.sinks.RTADT_SOURCE,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Instance),
    };
    if (!rb.AddRtaDriver(&state.driver)) {
        sys.FreeVec(memory);
        sys.CloseLibrary(utility_lib);
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    }
    if (sys.OpenLibrary(expansion.EXPANSIONNAME, 1)) |expansion_lib| {
        makeSinks(state, @ptrCast(expansion_lib));
        sys.CloseLibrary(expansion_lib);
    }
    // The libraries stay open and the state stays allocated: the driver
    // is on the list for good, and its sinks and sources with it.
    return @ptrCast(sys);
}

/// No library and no vectors: the tag's init is the whole of it.
export const rta_es8311_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rta_es8311_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 31,
    .type = .rta_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};

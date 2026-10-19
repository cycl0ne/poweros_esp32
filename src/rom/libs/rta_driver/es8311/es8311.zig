// SPDX-License-Identifier: MPL-2.0
//! The ES8311 codec as a sink: set up over I2C, fed over an I2S line,
//! with the amplifier in front of its speaker switched by its enable line.
//!
//! A module of its own. At cold start it opens rta.library, hands in a
//! driver of the sink kind, and makes a sink for every ES8311 the board
//! lists (expansion.library): an "i2s" line from the codec's tags first,
//! then the sink over it, named as the board names the part. The board's
//! amplifier - a part of its own, not on I2S - is the codec's: its enable
//! line comes along with the codec's tags.
//!
//! Nothing is touched until the sink is started, on the task that is to
//! fill it. That opens i2c.device and timer.device, resets the codec and
//! sets it up for a master clock 256 times the rate (`codec.zig`), starts
//! the line - the clocks run from here, which the codec counts in - turns
//! the volume up and the amplifier on. The codec plays one side, so its
//! mode is mono: both sides together in each half of the frame.

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
const REVISION = 0;
const BUILD_DATE = "19.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// How loud the codec is driven. The amplifier does the rest, and half
/// of what the part can do is as much as these speakers want.
const codec_volume: u32 = 50;

/// The rate it runs at: its master clock is 256 times it, which is what
/// the bring-up's dividers are for.
const rate: u32 = 48_000;

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

/// What one sink keeps: the codec's address on its bus, the amplifier's
/// line, its mode, and while it plays the requests it talks through.
const Instance = struct {
    state: *State,
    address: u16 = codec.address,
    bus_unit: u32 = 0,
    amplifier: Enable = .{},
    mode: rta.AudioMode = .{},
    port: ?*exec.MsgPort = null,
    i2c_io: i2c.IOExtI2C = .{},
    timer_io: timer.TimeRequest = .{},
};

fn instanceOf(sink: *rta.AudioSink) *Instance {
    return @ptrCast(@alignCast(sink.instance.?));
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
        .address = @truncate(ub.GetTagData(st.PART_Address, codec.address, tag_list)),
        .bus_unit = @truncate(ub.GetTagData(st.PART_BusUnit, 0, tag_list)),
        .amplifier = Enable.of(ub.GetTagData(st.PART_PinEnable, 0, tag_list)),
    };
    instance.mode = .{
        .node = .{ .name = "48000 Hz mono" },
        .rate = rate,
        .bits = 16,
        .channels = 1,
        .sides = codec.sides,
        .flags = rta.sinks.AUDIOMF_DEFAULT,
    };
    state.sys.AddTail(&sink.modes, &instance.mode.node);
    sink.ops = &ops;
    sink.buffer_frames = io.buffer_frames;
    sink.buffers = io.buffers;
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
    io.address = instance.address;
    io.req.data = &bytes;
    io.req.length = bytes.len;
    _ = instance.state.sys.DoIO(&io.req.req);
    return io.req.req.err == 0;
}

/// The codec brought up and the line started, in the order the parts want
/// it: the bus and the reset, the codec's set-up, the clocks, then the
/// volume and the amplifier - a speaker that comes up mid-note is a bang.
fn start(sink: *rta.AudioSink, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = instanceOf(sink);
    const code = bringUp(instance, sink, mode, task, signal_mask);
    if (code != err.RTAERR_OK) giveBack(instance, sink);
    return code;
}

fn bringUp(instance: *Instance, sink: *rta.AudioSink, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) i32 {
    const state = instance.state;
    const sys = state.sys;
    if (!instance.amplifier.take(sys, MODULE_NAME)) return err.RTAERR_IN_USE;
    instance.port = sys.CreateMsgPort() orelse return err.RTAERR_NO_MEMORY;
    instance.i2c_io = .{};
    instance.i2c_io.req.req.message.reply_port = instance.port;
    instance.i2c_io.req.req.message.length = @sizeOf(i2c.IOExtI2C);
    if (sys.OpenDevice(i2c.DEVICE_NAME, instance.bus_unit, &instance.i2c_io.req.req, 0) != 0) {
        exec.kprintf(sys, "%s: no %s unit %d\n", .{ MODULE_NAME, i2c.DEVICE_NAME, instance.bus_unit });
        return err.RTAERR_NO_OUTPUT;
    }
    instance.timer_io = .{};
    instance.timer_io.node.message.reply_port = instance.port;
    instance.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &instance.timer_io.node, 0) != 0) return err.RTAERR_NO_OUTPUT;

    for (codec.bring_up) |one| {
        if (!writeCodec(instance, one.reg, one.value)) {
            exec.kprintf(sys, "%s: the codec does not answer at 0x%02x\n", .{ MODULE_NAME, @as(u32, instance.address) });
            return err.RTAERR_IO;
        }
        if (one.delay_ms != 0) wait(instance, @as(u32, one.delay_ms) * 1000);
    }

    const code = state.rta.StartAudioTransport(sink.transport.?, mode, task, signal_mask);
    if (code != err.RTAERR_OK) return code;
    _ = writeCodec(instance, codec.reg_volume, codec.volumeFor(codec_volume));
    instance.amplifier.set(true);
    return err.RTAERR_OK;
}

/// The amplifier off first, so the speaker does not hear the clocks stop,
/// then the line, and the codec's bus given up.
fn giveBack(instance: *Instance, sink: *rta.AudioSink) void {
    const sys = instance.state.sys;
    instance.amplifier.giveBack();
    instance.state.rta.StopAudioTransport(sink.transport.?);
    if (instance.timer_io.node.device != null) sys.CloseDevice(&instance.timer_io.node);
    instance.timer_io = .{};
    if (instance.i2c_io.req.req.device != null) sys.CloseDevice(&instance.i2c_io.req.req);
    instance.i2c_io = .{};
    if (instance.port) |port| sys.DeleteMsgPort(port);
    instance.port = null;
}

fn stop(sink: *rta.AudioSink) callconv(.c) void {
    giveBack(instanceOf(sink), sink);
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

const driver_ops = rta.RtaDriverOps{ .create_sink = &createSink };

/// A sink for every ES8311 the board lists, each over a line of its own.
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
        const sink_tags = [_]TagItem{
            .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr(part.node.name orelse DRIVER_NAME) },
            .{ .tag = rta.tags.RTAA_Transport, .data = @intFromPtr(io) },
            .{ .tag = if (enable != 0) st.PART_PinEnable else utility.TAG_IGNORE, .data = enable },
            .{ .tag = utility.TAG_MORE, .data = @intFromPtr(part.tags) },
        };
        if (rb.CreateSinkTagList(DRIVER_NAME, &sink_tags) == null) {
            exec.kprintf(sys, "%s: no sink: %s\n", .{ MODULE_NAME, rb.RtaErrorText(rb.RtaLastError()) });
            rb.DeleteAudioTransport(io);
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
        .type = rta.sinks.RTADT_SINK,
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
    // is on the list for good, and its sinks with it.
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

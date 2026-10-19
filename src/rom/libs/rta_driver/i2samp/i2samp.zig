// SPDX-License-Identifier: MPL-2.0
//! An amplifier that takes I2S itself as a sink: nothing to set up, only
//! an enable line, fed over an I2S line of its own.
//!
//! A module of its own. At cold start it opens rta.library, hands in a
//! driver of the sink kind, and makes a sink for every amplifier the
//! board lists on I2S (`PART_Bus` BUS_I2S): an "i2s" line from the part's
//! tags first, then the sink over it, named as the board names the part.
//! A pair of them on one line - the CrowPanel's, one a speaker each - is
//! one part, which plays both sides: its mode is stereo, the sides the way
//! round the board wires them (`PART_SidesSwapped`).
//!
//! Starting it takes its enable pad, starts the line and switches the
//! amplifier on; it recovers its clock from the bit clock, so the line
//! drives no master clock for it.

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

const Enable = @import("../enable.zig").Enable;

const MODULE_NAME = "rta-i2samp";
const DRIVER_NAME = "i2samp";
const VERSION = 1;
const REVISION = 0;
const BUILD_DATE = "19.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The rate the line is clocked for.
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

/// What one sink keeps: its enable line and its mode.
const Instance = struct {
    state: *State,
    amplifier: Enable = .{},
    mode: rta.AudioMode = .{},
};

fn instanceOf(sink: *rta.AudioSink) *Instance {
    return @ptrCast(@alignCast(sink.instance.?));
}

fn createSink(made_by: *rta.RtaDriver, sink: *rta.AudioSink, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    const ub = state.utility;
    const io = sink.transport orelse return err.RTAERR_BAD_TAGS;
    const instance = instanceOf(sink);
    instance.* = .{
        .state = state,
        .amplifier = Enable.of(ub.GetTagData(st.PART_PinEnable, 0, tag_list)),
    };
    const swapped = ub.GetTagData(st.PART_SidesSwapped, 0, tag_list) != 0;
    instance.mode = .{
        .node = .{ .name = "48000 Hz stereo" },
        .rate = rate,
        .bits = 16,
        .channels = 2,
        .sides = if (swapped) rta.AUDIOSIDES_RIGHT_FIRST else rta.AUDIOSIDES_LEFT_FIRST,
        .flags = rta.sinks.AUDIOMF_DEFAULT,
    };
    state.sys.AddTail(&sink.modes, &instance.mode.node);
    sink.ops = &ops;
    sink.buffer_frames = io.buffer_frames;
    sink.buffers = io.buffers;
    return err.RTAERR_OK;
}

fn start(sink: *rta.AudioSink, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = instanceOf(sink);
    const state = instance.state;
    if (!instance.amplifier.take(state.sys, MODULE_NAME)) return err.RTAERR_IN_USE;
    const code = state.rta.StartAudioTransport(sink.transport.?, mode, task, signal_mask);
    if (code != err.RTAERR_OK) {
        instance.amplifier.giveBack();
        return code;
    }
    instance.amplifier.set(true);
    return err.RTAERR_OK;
}

/// The amplifier off first, so the speaker does not hear the clocks stop.
fn stop(sink: *rta.AudioSink) callconv(.c) void {
    const instance = instanceOf(sink);
    instance.amplifier.giveBack();
    instance.state.rta.StopAudioTransport(sink.transport.?);
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

/// A sink for every amplifier on I2S the board lists, each over a line of
/// its own.
fn makeSinks(state: *State, eb: *ExpansionBase) void {
    const sys = state.sys;
    const ub = state.utility;
    const rb = state.rta;
    var found = eb.FindBoardPart(null, st.PARTKIND_AMPLIFIER, st.CHIP_ANY);
    while (found) |part| : (found = eb.FindBoardPart(part, st.PARTKIND_AMPLIFIER, st.CHIP_ANY)) {
        if (ub.GetTagData(st.PART_Bus, st.BUS_NONE, part.tags) != st.BUS_I2S) continue;
        const io = rb.CreateAudioTransportTagList("i2s", part.tags) orelse {
            exec.kprintf(sys, "%s: no I2S line: %s\n", .{ MODULE_NAME, rb.RtaErrorText(rb.RtaLastError()) });
            continue;
        };
        const sink_tags = [_]TagItem{
            .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr(part.node.name orelse DRIVER_NAME) },
            .{ .tag = rta.tags.RTAA_Transport, .data = @intFromPtr(io) },
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
export const rta_i2samp_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rta_i2samp_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 31,
    .type = .rta_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};

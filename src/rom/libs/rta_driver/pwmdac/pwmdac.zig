// SPDX-License-Identifier: MPL-2.0
//! The VisionFive 2's audio jack as a sink: stereo, at the rate the
//! chip's PWM-DAC comes nearest 48000 Hz at - 48340 Hz from the audio
//! root the firmware leaves.
//!
//! A module of its own. At cold start it opens rta.library, hands in a
//! driver of the sink kind, and makes a sink for the PWM-DAC the board
//! lists (CHIP_JH7110_PWMDAC), named as the board names the part, on the
//! pads its PART_PinLeft and PART_PinRight name. The DAC is inside the
//! chip, so the sink drives it itself rather than over a line of rta's.
//! The sink goes on the list below the HDMI port's (RTAA_Priority -10):
//! nothing says whether anything is plugged into the jack, so the monitor
//! stays the output most wanted, and the jack is the one a program or
//! `Audio OUTPUT` picks.
//!
//! Nothing is touched until the sink is started. That takes a channel of
//! the chip's DesignWare DMA controller from dma.resource - the last free
//! one, at the highest priority, as the HDMI port's sink does - and the
//! ring's memory, clocks the DAC and puts its lines on the pads
//! (`dac.zig`), and starts the stream on silence. The ring is two
//! buffers, an item apiece, which the channel runs round
//! (`sdk.hardware.dwdma`), a frame a word: each item is the last of its
//! transfer, so the channel raises its interrupt at the end of each, the
//! interrupt starts it on the other and signals the task the sink was
//! started for, and the task fills the one just played. Stopping it gives
//! everything back.

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
const dmares = sdk.resources.dma;
const dwdma = sdk.hardware.dwdma;
const dac = @import("dac.zig");

const MODULE_NAME = "rta-pwmdac";
const DRIVER_NAME = "pwmdac";
const VERSION = 1;
const REVISION = 0;
const BUILD_DATE = "25.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The rate the DAC is asked to come nearest.
const wanted_rate: u32 = 48_000;

/// Where the sink goes on the list: below the HDMI port's, at 0.
const sink_priority: isize = -10;

/// The ring: two buffers, each of `buffer_frames` stereo frames. One
/// plays while the task fills the other, so it has a buffer's worth of
/// time for it: about five milliseconds.
const buffer_frames: u32 = 256;
const buffer_samples: u32 = buffer_frames * 2;
const buffer_bytes: u32 = buffer_samples * 2;
const buffers: u32 = 2;
const ring_bytes: u32 = buffer_bytes * buffers;

/// Everything this driver has that changes, allocated once by the init.
const State = struct {
    driver: rta.RtaDriver = .{},
    sys: *ExecBase,
    utility: *UtilityBase,
};

fn stateOf(driver: *rta.RtaDriver) *State {
    return @fieldParentPtr("driver", driver);
}

/// What the sink keeps. The interrupt reads it, so it is in internal
/// memory (RTADF_INTERNAL_INSTANCE).
const Instance = struct {
    sys: *ExecBase,
    /// The pads the two sides go out on.
    left_pin: u8,
    right_pin: u8,
    /// The core clock's divider, and the rate it gives.
    rate: dac.Rate,
    /// The mode, and its name, which has the rate in it.
    modes: [1]rta.AudioMode = @splat(.{}),
    mode_name: [24]u8 = @splat(0),
    dma: ?*dmares.DmaBase = null,
    channel: u32 = 0,
    has_channel: bool = false,
    /// The buffers, and the block the ring's items are in.
    memory: ?*anyopaque = null,
    ring: dwdma.Ring = .{},
    int: exec.Interrupt = .{},
    int_added: bool = false,
    /// The stream is going out.
    up: bool = false,
    /// The task the interrupt signals and with what; the buffers it has
    /// counted and the count the last one was taken at - more than one
    /// between two takes is a buffer the channel went round to before the
    /// task had it.
    task: ?*exec.Task = null,
    signal_mask: u32 = 0,
    ended: u32 = 0,
    taken: u32 = 0,
};

fn instanceOf(sink: *rta.AudioSink) *Instance {
    return @ptrCast(@alignCast(sink.instance.?));
}

fn createSink(made_by: *rta.RtaDriver, sink: *rta.AudioSink, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    const left = BoardPin.of(state.utility.GetTagData(st.PART_PinLeft, 0, tag_list));
    const right = BoardPin.of(state.utility.GetTagData(st.PART_PinRight, 0, tag_list));
    if (left.kind != expansion.boardpin.BPIN_GPIO or right.kind != expansion.boardpin.BPIN_GPIO) return err.RTAERR_BAD_TAGS;
    const instance = instanceOf(sink);
    instance.* = .{
        .sys = state.sys,
        .left_pin = left.number,
        .right_pin = right.number,
        .rate = dac.rate(wanted_rate),
    };
    instance.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = instance,
        .code = &server,
    };
    const name = std.fmt.bufPrint(instance.mode_name[0 .. instance.mode_name.len - 1], "{d} Hz stereo", .{instance.rate.hz}) catch unreachable;
    instance.mode_name[name.len] = 0;
    instance.modes[0] = .{
        .node = .{ .name = @ptrCast(&instance.mode_name) },
        .id = 0,
        .rate = instance.rate.hz,
        .bits = 16,
        .channels = 2,
        .sides = rta.AUDIOSIDES_LEFT_FIRST,
        .flags = rta.sinks.AUDIOMF_DEFAULT,
    };
    state.sys.AddTail(&sink.modes, &instance.modes[0].node);
    sink.ops = &ops;
    sink.buffer_frames = buffer_frames;
    sink.buffers = buffers;
    return err.RTAERR_OK;
}

/// The channel's interrupt, which it shares with the controller's other
/// channels: a buffer has been played, so the task has one to fill.
fn server(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const instance: *Instance = @ptrCast(@alignCast(is_data.?));
    if (!dwdma.serve(instance.sys, &instance.ring)) return 0;
    _ = @atomicRmw(u32, &instance.ended, .Add, 1, .release);
    if (instance.task) |task| instance.sys.Signal(task, instance.signal_mask);
    return 1;
}

/// The stream started, in the order the parts want it: the memory, a DMA
/// channel and its ring, then the DAC's clocks and pads, and the channel
/// and the DAC on silence.
fn streamUp(instance: *Instance) i32 {
    const sys = instance.sys;
    // The buffers, written back with the silence they start with, then
    // the items, each on 64 bytes of its own: one more for the rounding.
    // Both below 4 GiB, where the controller reaches.
    const item_bytes = @sizeOf(dwdma.Item);
    const size = ring_bytes + item_bytes * (buffers + 1);
    const memory = sys.AllocVec(size, exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return err.RTAERR_NO_MEMORY;
    instance.memory = memory;
    var all: u32 = size;
    _ = sys.CachePreDMA(memory, &all, 0);

    const db: *dmares.DmaBase = @ptrCast(sys.OpenResource(dmares.DMANAME) orelse return err.RTAERR_NO_OUTPUT);
    instance.dma = db;
    var n: u32 = dmares.DWDMA_CHANNELS;
    const channel = while (n > 0) {
        n -= 1;
        const candidate = dmares.DWDMA_CHANNEL0 + n;
        if (db.AllocDMAChannel(candidate, MODULE_NAME) == null) break candidate;
    } else {
        exec.kprintf(sys, "%s: no DMA channel free\n", .{MODULE_NAME});
        return err.RTAERR_NO_OUTPUT;
    };
    instance.channel = channel;
    instance.has_channel = true;
    const controller = dwdma.find() orelse return err.RTAERR_NO_OUTPUT;
    const items = std.mem.alignForward(usize, @intFromPtr(memory) + ring_bytes, item_bytes);
    instance.ring = .{
        .base = controller.base,
        .channel = channel - dmares.DWDMA_CHANNEL0,
        .priority = dwdma.max_priority,
        .items = @ptrFromInt(items),
        .buffers = @intFromPtr(memory),
        .target = dac.WDATA,
        .count = buffers,
        .bytes = buffer_bytes,
        .dst_width = dwdma.WIDTH_32,
    };
    instance.ended = 0;
    instance.taken = 0;

    dac.init(sys, instance.left_pin, instance.right_pin, instance.rate.divider);
    sys.AddIntServer(dmares.dmaIntNumber(channel, dmares.DMA_OUT), &instance.int);
    instance.int_added = true;
    dwdma.start(sys, &instance.ring, dac.dma_handshake);
    dac.start();
    instance.up = true;
    return err.RTAERR_OK;
}

/// Everything the stream took given back: the channel and the DAC
/// stopped, the interrupt out, the channel and the memory freed.
fn streamDown(instance: *Instance) void {
    const sys = instance.sys;
    if (instance.up) {
        dwdma.stop(instance.ring.base, instance.ring.channel);
        dac.stop();
    }
    instance.up = false;
    if (instance.int_added) sys.RemIntServer(dmares.dmaIntNumber(instance.channel, dmares.DMA_OUT), &instance.int);
    instance.int_added = false;
    if (instance.has_channel) instance.dma.?.FreeDMAChannel(instance.channel);
    instance.has_channel = false;
    instance.ring.items = null;
    if (instance.memory) |memory| sys.FreeVec(memory);
    instance.memory = null;
    instance.task = null;
}

fn start(sink: *rta.AudioSink, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = instanceOf(sink);
    if (mode.rate != instance.rate.hz or mode.bits != 16) return err.RTAERR_BAD_MODE;
    if (instance.up) return err.RTAERR_IN_USE;
    instance.signal_mask = signal_mask;
    instance.task = task;
    const code = streamUp(instance);
    if (code != err.RTAERR_OK) streamDown(instance);
    return code;
}

fn stop(sink: *rta.AudioSink) callconv(.c) void {
    streamDown(instanceOf(sink));
}

/// The buffer the channel finished last, which is the one to fill: null
/// if none has ended since the last ask, and more than one counted in
/// `underruns`.
fn buffer(sink: *rta.AudioSink) callconv(.c) ?[*]i16 {
    const instance = instanceOf(sink);
    if (!instance.up) return null;
    const count = @atomicLoad(u32, &instance.ended, .acquire);
    const behind = count -% instance.taken;
    if (behind == 0) return null;
    if (behind > 1) sink.underruns +%= behind - 1;
    instance.taken = count;
    const frames: [*]i16 = @ptrCast(@alignCast(instance.memory.?));
    return frames + @atomicLoad(u32, &instance.ring.ended, .acquire) * buffer_samples;
}

/// A filled buffer written back out of the cache, where the DMA reads it.
fn play(sink: *rta.AudioSink, frames: [*]i16) callconv(.c) i32 {
    var bytes: u32 = buffer_bytes;
    _ = instanceOf(sink).sys.CachePreDMA(@ptrCast(frames), &bytes, 0);
    return err.RTAERR_OK;
}

const ops = rta.AudioSinkOps{
    .start = &start,
    .stop = &stop,
    .buffer = &buffer,
    .play = &play,
};

const driver_ops = rta.RtaDriverOps{ .create_sink = &createSink };

/// A sink for the PWM-DAC the board lists.
fn makeSinks(state: *State, rb: *RtaBase, eb: *ExpansionBase) void {
    const sys = state.sys;
    var found = eb.FindBoardPart(null, st.PARTKIND_CODEC, st.CHIP_JH7110_PWMDAC);
    while (found) |part| : (found = eb.FindBoardPart(part, st.PARTKIND_CODEC, st.CHIP_JH7110_PWMDAC)) {
        const sink_tags = [_]TagItem{
            .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr(part.node.name orelse DRIVER_NAME) },
            .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(sink_priority) },
            .{ .tag = utility.TAG_MORE, .data = @intFromPtr(part.tags) },
        };
        if (rb.CreateSinkTagList(DRIVER_NAME, &sink_tags) == null) {
            exec.kprintf(sys, "%s: no sink: %s\n", .{ MODULE_NAME, rb.RtaErrorText(rb.RtaLastError()) });
        }
    }
}

/// Cold start at 30: after rta.library (33), which it joins and makes its
/// sink in, and after the HDMI port's sink (31).
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
        .type = rta.sinks.RTADT_SINK,
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
    if (sys.OpenLibrary(expansion.EXPANSIONNAME, 1)) |expansion_lib| {
        makeSinks(state, rb, @ptrCast(expansion_lib));
        sys.CloseLibrary(expansion_lib);
    }
    // The libraries stay open and the state stays allocated: the driver
    // is on the list for good, and its sink with it.
    return @ptrCast(sys);
}

/// No library and no vectors: the tag's init is the whole of it.
export const rta_pwmdac_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rta_pwmdac_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 30,
    .type = .rta_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};

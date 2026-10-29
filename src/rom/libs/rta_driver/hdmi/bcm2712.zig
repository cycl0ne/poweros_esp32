// SPDX-License-Identifier: MPL-2.0
//! The Compute Module 5's first HDMI port as a sink: the monitor's
//! speakers, in stereo at 48000 Hz while the picture goes out as HDMI.
//!
//! A module of its own, rta-hdmi as the VisionFive 2's: at cold start it
//! opens rta.library, hands in a driver of the sink kind, and makes a
//! sink for the HDMI sound the board lists (CHIP_BCM2712_HDMI_AUDIO),
//! named as the board names the part. The part is the DMA channel that
//! feeds the HDMI controller (PART_Address its registers, PART_Irq its
//! interrupt); the controller is the display's (`rtg_driver/fbboard/
//! bcm2712.zig`), which the sound shares with it.
//!
//! The controller takes the sound as IEC 958 subframes, a 32-bit word a
//! sample: the sample in bits 12 to 27 - the top of the 24 a subframe
//! has - a bit of the channel status in bit 30, the parity in 31, and
//! the preamble in the low four, which marks the left channel and, every
//! 192 frames, the start of a block (`subframe`). rta.library's buffers
//! are 16-bit, so each is turned into them as it is handed back. A
//! buffer is two blocks of 192 frames, so a buffer played again, as one
//! is when the next is late, keeps the blocks where they belong.
//!
//! Nothing is touched until the sink is started. That takes the ring's
//! memory, sets up the controller's MAI for the stream (`audioStart`),
//! and starts the channel on silence: two buffers, a control block
//! apiece, which the channel runs round (`dma40.zig`), raising its
//! interrupt at the end of each; the interrupt signals the task the sink
//! was started for, and the task fills the one just played. Stopping it
//! stops the channel and the MAI and gives the memory back. A sink
//! started while the display is down, or goes out as DVI, says there is
//! no output.

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
const display = @import("../../rtg_driver/fbboard/bcm2712.zig");
const dma40 = @import("dma40.zig");

const MODULE_NAME = "rta-hdmi";
const DRIVER_NAME = "hdmi";
const VERSION = 1;
const REVISION = 0;
const BUILD_DATE = "29.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const sample_rate: u32 = 48_000;
const channels: u32 = 2;

/// The ring: two buffers, each two IEC 958 blocks of 192 stereo frames.
/// One plays while the task fills the other, so it has a buffer's worth
/// of time for it: 8 milliseconds.
const block_frames: u32 = 192;
const buffer_frames: u32 = 2 * block_frames;
const buffer_samples: u32 = buffer_frames * channels;
const buffers: u32 = 2;
/// A buffer as the task fills it, 16 bits a sample, and as the channel
/// reads it, 32.
const filled_bytes: u32 = buffer_samples * 2;
const subframe_bytes: u32 = buffer_samples * 4;

/// The channel's bus priorities, as the device tree's dmas cell for the
/// HDMI's sound gives them: QoS 10, 15 in a panic.
const dma_flags: u32 = 0x00FA_0000;

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
    /// The DMA channel's registers and its interrupt.
    channel: usize,
    irq: u32,
    modes: [1]rta.AudioMode = @splat(.{}),
    /// The ring's memory as AllocVec gave it; in it, each buffer as the
    /// channel reads it and as the task fills it, and the control blocks.
    memory: ?*anyopaque = null,
    subframes: [buffers][*]u32 = undefined,
    filled: [buffers][*]i16 = undefined,
    blocks: [buffers]*dma40.Block = undefined,
    int: exec.Interrupt = .{},
    int_added: bool = false,
    /// The MAI set up for the stream, and the channel running.
    mai: bool = false,
    up: bool = false,
    /// The task the interrupt signals and with what; the buffers it has
    /// counted, the one that ended last, and the count the last one was
    /// taken at - more than one between two takes is a buffer the channel
    /// went round to before the task had it.
    task: ?*exec.Task = null,
    signal_mask: u32 = 0,
    ended: u32 = 0,
    last: u32 = 0,
    taken: u32 = 0,
};

fn instanceOf(sink: *rta.AudioSink) *Instance {
    return @ptrCast(@alignCast(sink.instance.?));
}

/// What the display's calls wait with: the task given away meanwhile.
const Waiter = struct {
    sys: *ExecBase,

    pub fn wait(waiter: Waiter, micros: u32) void {
        var never: exec.Waitable = .{};
        _ = waiter.sys.WaitForAny(&[_]*exec.Waitable{&never}, 1, micros);
    }
};

// --- IEC 958 -----------------------------------------------------------------

/// The channel status a stream carries, a bit a frame, the first of a
/// block's 192 first: a consumer's PCM, not copyrighted, an original from
/// a PCM coder, at 48 kHz (IEC 60958-3, as alsa-lib's vc4-hdmi.conf has
/// it); the rest of the block 0.
const channel_status = [4]u8{ 0x04, 0x82, 0x00, 0x02 };

/// The preambles' codes in a subframe's low four bits: a block's first
/// frame's left channel (Z), any other left channel (X), a right one (Y).
const PREAMBLE_Z: u32 = 0x08;
const PREAMBLE_X: u32 = 0x02;
const PREAMBLE_Y: u32 = 0x04;
const STATUS_BIT: u32 = 1 << 30;
const PARITY_BIT: u32 = 1 << 31;

/// The subframe for `sample` of channel `channel` (0 left, 1 right) in
/// frame `frame` of its block (alsa-lib's iec958_subframe).
pub fn subframe(sample: i16, frame: u32, channel: u1) u32 {
    var word = @as(u32, @as(u16, @bitCast(sample))) << 12;
    if (frame / 8 < channel_status.len and channel_status[frame / 8] >> @intCast(frame % 8) & 1 != 0) word |= STATUS_BIT;
    // Even parity over bits 4 to 31.
    if (@popCount(word >> 4) & 1 != 0) word |= PARITY_BIT;
    return word | if (channel == 1) PREAMBLE_Y else if (frame == 0) PREAMBLE_Z else PREAMBLE_X;
}

/// A buffer of 16-bit frames turned into the subframes the channel reads.
fn encode(from: [*]const i16, into: [*]u32) void {
    for (0..buffer_frames) |frame| {
        const in_block: u32 = @intCast(frame % block_frames);
        into[frame * 2] = subframe(from[frame * 2], in_block, 0);
        into[frame * 2 + 1] = subframe(from[frame * 2 + 1], in_block, 1);
    }
}

// --- the sink ----------------------------------------------------------------

fn createSink(made_by: *rta.RtaDriver, sink: *rta.AudioSink, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    const channel: usize = @intCast(state.utility.GetTagData(st.PART_Address, 0, tag_list));
    const irq: u32 = @truncate(state.utility.GetTagData(st.PART_Irq, 0, tag_list));
    if (channel == 0 or irq == 0) return err.RTAERR_BAD_TAGS;
    const instance = instanceOf(sink);
    instance.* = .{ .sys = state.sys, .channel = channel, .irq = irq };
    instance.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = instance,
        .code = &server,
    };
    instance.modes[0] = .{
        .node = .{ .name = "48000 Hz stereo" },
        .id = 0,
        .rate = sample_rate,
        .bits = 16,
        .channels = channels,
        .sides = rta.AUDIOSIDES_LEFT_FIRST,
        .flags = rta.sinks.AUDIOMF_DEFAULT,
    };
    state.sys.AddTail(&sink.modes, &instance.modes[0].node);
    sink.ops = &ops;
    sink.buffer_frames = buffer_frames;
    sink.buffers = buffers;
    return err.RTAERR_OK;
}

/// The channel's interrupt: a buffer has been played - the one before
/// the block the channel is on now - so the task has one to fill.
fn server(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const instance: *Instance = @ptrCast(@alignCast(is_data.?));
    if (!dma40.acknowledge(instance.channel, dma_flags)) return 0;
    const on = dma40.current(instance.channel);
    const ended: u32 = if (on == @intFromPtr(instance.blocks[1])) 0 else 1;
    @atomicStore(u32, &instance.last, ended, .release);
    _ = @atomicRmw(u32, &instance.ended, .Add, 1, .release);
    if (instance.task) |task| instance.sys.Signal(task, instance.signal_mask);
    return 1;
}

/// The stream started: the memory - both buffers silence - and the
/// control blocks, the MAI set up for it, then the channel.
fn streamUp(instance: *Instance) i32 {
    const sys = instance.sys;
    // Each piece on a cache line of its own, below the DMA limit, where
    // the channel reaches; one more line for the rounding.
    const line = 64;
    const block_bytes = std.mem.alignForward(usize, @sizeOf(dma40.Block), line);
    const size = buffers * (subframe_bytes + filled_bytes + block_bytes) + line;
    const memory = sys.AllocVec(size, exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return err.RTAERR_NO_MEMORY;
    instance.memory = memory;
    var at = std.mem.alignForward(usize, @intFromPtr(memory), line);
    for (0..buffers) |i| {
        instance.subframes[i] = @ptrFromInt(at);
        at += subframe_bytes;
    }
    for (0..buffers) |i| {
        instance.blocks[i] = @ptrFromInt(at);
        at += block_bytes;
    }
    for (0..buffers) |i| {
        instance.filled[i] = @ptrFromInt(at);
        at += filled_bytes;
    }
    for (0..buffers) |i| {
        encode(instance.filled[i], instance.subframes[i]);
        const next = instance.blocks[(i + 1) % buffers];
        instance.blocks[i].* = dma40.toDevice(@intFromPtr(instance.subframes[i]), display.mai_data, subframe_bytes, display.audio_dreq, @intFromPtr(next));
    }
    var all: u32 = @intCast(size);
    _ = sys.CachePreDMA(memory, &all, 0);
    instance.ended = 0;
    instance.taken = 0;
    instance.last = 0;

    if (!display.audioStart(sys, sample_rate, channels, Waiter{ .sys = sys })) return err.RTAERR_NO_OUTPUT;
    instance.mai = true;
    dma40.stop(instance.channel);
    sys.AddIntServer(instance.irq, &instance.int);
    instance.int_added = true;
    dma40.start(instance.channel, @intFromPtr(instance.blocks[0]), dma_flags);
    instance.up = true;
    return err.RTAERR_OK;
}

/// Everything the stream took given back: the channel stopped, then the
/// MAI, the interrupt out, the memory freed.
fn streamDown(instance: *Instance) void {
    const sys = instance.sys;
    if (instance.up) dma40.stop(instance.channel);
    instance.up = false;
    if (instance.mai) display.audioStop(sys, Waiter{ .sys = sys });
    instance.mai = false;
    if (instance.int_added) sys.RemIntServer(instance.irq, &instance.int);
    instance.int_added = false;
    if (instance.memory) |memory| sys.FreeVec(memory);
    instance.memory = null;
    instance.task = null;
}

fn start(sink: *rta.AudioSink, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    const instance = instanceOf(sink);
    if (mode.rate != sample_rate or mode.bits != 16 or mode.channels != channels) return err.RTAERR_BAD_MODE;
    if (instance.up) return err.RTAERR_IN_USE;
    if (!display.audible(instance.sys)) return err.RTAERR_NO_OUTPUT;
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
    return instance.filled[@atomicLoad(u32, &instance.last, .acquire)];
}

/// A filled buffer turned into subframes, written back out of the cache,
/// where the channel reads it.
fn play(sink: *rta.AudioSink, frames: [*]i16) callconv(.c) i32 {
    const instance = instanceOf(sink);
    if (!instance.up) return err.RTAERR_OK;
    const which: usize = if (frames == instance.filled[1]) 1 else 0;
    encode(frames, instance.subframes[which]);
    var bytes: u32 = subframe_bytes;
    _ = instance.sys.CachePreDMA(@ptrCast(instance.subframes[which]), &bytes, 0);
    return err.RTAERR_OK;
}

const ops = rta.AudioSinkOps{
    .start = &start,
    .stop = &stop,
    .buffer = &buffer,
    .play = &play,
};

const driver_ops = rta.RtaDriverOps{ .create_sink = &createSink };

/// A sink for the HDMI sound the board lists.
fn makeSinks(state: *State, rb: *RtaBase, eb: *ExpansionBase) void {
    const sys = state.sys;
    var found = eb.FindBoardPart(null, st.PARTKIND_CODEC, st.CHIP_BCM2712_HDMI_AUDIO);
    while (found) |part| : (found = eb.FindBoardPart(part, st.PARTKIND_CODEC, st.CHIP_BCM2712_HDMI_AUDIO)) {
        const sink_tags = [_]TagItem{
            .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr(part.node.name orelse DRIVER_NAME) },
            .{ .tag = utility.TAG_MORE, .data = @intFromPtr(part.tags) },
        };
        if (rb.CreateSinkTagList(DRIVER_NAME, &sink_tags) == null) {
            exec.kprintf(sys, "%s: no sink: %s\n", .{ MODULE_NAME, rb.RtaErrorText(rb.RtaLastError()) });
        }
    }
}

/// Cold start at 31: after rta.library (33), which it joins and makes its
/// sink in.
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
export const rta_hdmi_bcm2712_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rta_hdmi_bcm2712_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 31,
    .type = .rta_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "IEC 958 subframes: the sample, the channel status, the parity and the preambles" {
    // Silence: a block's first frame starts with Z, the right channel is
    // Y; frame 2 carries the status's third bit (0x04), set, so its
    // parity is set too.
    try testing.expectEqual(@as(u32, 0x08), subframe(0, 0, 0));
    try testing.expectEqual(@as(u32, 0x04), subframe(0, 0, 1));
    try testing.expectEqual(@as(u32, STATUS_BIT | PARITY_BIT | 0x02), subframe(0, 2, 0));
    // A full-scale negative sample in bits 12 to 27: one bit, so odd.
    try testing.expectEqual(@as(u32, 0x0800_0000 | PARITY_BIT | 0x02), subframe(-32768, 1, 0));
    try testing.expectEqual(@as(u32, 0x0FFF_F000 | 0x04), subframe(-1, 1, 1));
    // The status's last set bit is frame 25 (0x02 of the fourth byte);
    // past the four bytes nothing.
    try testing.expectEqual(STATUS_BIT, subframe(0, 25, 1) & STATUS_BIT);
    try testing.expectEqual(@as(u32, 0), subframe(0, 191, 0) & STATUS_BIT);
    // Even parity over bits 4 to 31, whatever the sample.
    for ([_]i16{ 1, -2, 12345, -12345, 32767 }) |sample| {
        for ([_]u32{ 0, 2, 15, 25, 100 }) |frame| {
            try testing.expectEqual(@as(u32, 0), @popCount(subframe(sample, frame, 0) >> 4) & 1);
        }
    }
}

test "a buffer is two blocks: Z at its first frame and at its 193rd" {
    var from: [buffer_samples]i16 = @splat(0);
    var into: [buffer_samples]u32 = undefined;
    encode(&from, &into);
    for (0..buffer_frames) |frame| {
        const want: u32 = if (frame % block_frames == 0) PREAMBLE_Z else PREAMBLE_X;
        try testing.expectEqual(want, into[frame * 2] & 0xF);
        try testing.expectEqual(PREAMBLE_Y, into[frame * 2 + 1] & 0xF);
    }
}

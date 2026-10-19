// SPDX-License-Identifier: MIT
//! Sinks: what a driver registers, and what audio.device plays through.
//!
//! A sink is one output - a codec behind a jack, an amplifier on a
//! speaker, a stream that goes nowhere - and the modes it can run in. Once
//! started it runs for ever on a ring of buffers: each time one has been
//! played the task that started it is signalled, takes the next one to
//! fill with SinkBuffer, and hands it back with PlaySinkBuffer. A buffer
//! that is not handed back in time is played again; the sink counts those
//! in `underruns`.
//!
//! A driver fills in `AudioSinkOps`. A slot left null is an operation the
//! sink has not got, and the call answers RTAERR_NOT_SUPPORTED: the
//! library does not do the work instead.

const nodes = @import("../exec/nodes.zig");
const lists = @import("../exec/lists.zig");
const tasks = @import("../exec/tasks.zig");
const tagitem = @import("../utility/tagitem.zig");
const transport = @import("transport.zig");

const Node = nodes.Node;
const List = lists.List;
const Task = tasks.Task;
const RtaBase = @import("../../interface/rta.zig").RtaBase;

/// One way a sink can run.
pub const AudioMode = extern struct {
    /// ln_Name is the mode as a caller would name it ("48000 Hz stereo");
    /// ln_Pri orders the list, highest first.
    node: Node = .{},
    /// The driver's own number for it.
    id: u32 = 0,
    /// Frames a second.
    rate: u32 = 0,
    /// Bits a sample the part is given.
    bits: u32 = 16,
    /// How many sides are heard: 1 for one speaker, a jack with one
    /// output, a codec that plays one half of the frame; 2 for two.
    channels: u32 = 2,
    /// What the two halves of a buffer's frames carry (AUDIOSIDES_*).
    sides: u8 = AUDIOSIDES_LEFT_FIRST,
    pad: [3]u8 = .{ 0, 0, 0 },
    flags: u32 = 0,
};

/// AudioMode.sides. The left side in the first half, the right in the
/// second, as I2S sends them.
pub const AUDIOSIDES_LEFT_FIRST: u8 = 0;
/// The right side first: a board whose right speaker plays the first
/// half.
pub const AUDIOSIDES_RIGHT_FIRST: u8 = 1;
/// Both sides together in each half: an output that plays one of them.
pub const AUDIOSIDES_MONO: u8 = 2;

/// AudioMode.flags
/// What the sink runs in when no mode is asked for.
pub const AUDIOMF_DEFAULT: u32 = 1 << 0;
/// The mode the sink is in now.
pub const AUDIOMF_CURRENT: u32 = 1 << 1;

/// An output.
pub const AudioSink = extern struct {
    /// ln_Name is the output's name, as the board names its part
    /// ("es8311", "ns4168"); ln_Pri orders the list, highest first.
    node: Node = .{},
    /// The output's number, the library's: the same for the same output
    /// from one boot to the next, as it is worked out from its driver's
    /// name and its own, and never 0. What a program or a preference names
    /// an output by.
    id: u32 = 0,
    rta_base: ?*RtaBase = null,
    driver: ?*RtaDriver = null,
    /// The line its part is fed over, for a sink that has one.
    transport: ?*transport.AudioTransport = null,
    ops: ?*const AudioSinkOps = null,
    /// The modes, AudioMode nodes. The driver fills the list before it
    /// returns from create; the library makes its default the current
    /// one.
    modes: List = .{},
    mode: ?*AudioMode = null,
    /// The ring a started sink runs on: frames a buffer, and how many
    /// buffers it goes round. The driver sets both at create.
    buffer_frames: u32 = 0,
    buffers: u32 = 0,
    /// Buffers played again because the next had not been handed back in
    /// time, since the sink was made. The driver counts them.
    underruns: u32 = 0,
    /// AUDIOSF_*
    flags: u32 = 0,
    /// The caller's, untouched by the library and the driver.
    user_data: ?*anyopaque = null,
    /// The driver's own data: `instance_size` bytes the library allocated
    /// and cleared when the sink was made, and frees with it.
    instance: ?*anyopaque = null,
    instance_size: u32 = 0,
};

/// AudioSink.flags
/// The sink has been started and not stopped. The library's.
pub const AUDIOSF_RUNNING: u32 = 1 << 0;

/// What a driver fills in. Every slot may be null; a null slot is an
/// operation the sink has not got.
pub const AudioSinkOps = extern struct {
    /// Undo what create did. DeleteSink calls it last.
    destroy: ?*const fn (*AudioSink) callconv(.c) void = null,
    /// Bring the output up in that mode and start the ring on silence:
    /// from now on `signal_mask` is raised on the task every time a
    /// buffer has been played. RTAERR_OK, or why not, with nothing left
    /// taken.
    start: ?*const fn (*AudioSink, *const AudioMode, *Task, u32) callconv(.c) i32 = null,
    /// Stop the ring and give back what start took.
    stop: ?*const fn (*AudioSink) callconv(.c) void = null,
    /// The next buffer to fill - `buffer_frames` stereo frames of 16-bit
    /// samples - or null when none has been played since the last.
    buffer: ?*const fn (*AudioSink) callconv(.c) ?[*]i16 = null,
    /// The buffer `buffer` gave, filled: on to the part.
    play: ?*const fn (*AudioSink, [*]i16) callconv(.c) i32 = null,
    /// Something only this driver knows about (AUDIOCTRL_DRIVER and up).
    control: ?*const fn (*AudioSink, u32, isize) callconv(.c) isize = null,
};

/// SinkControl's `what`. Everything below AUDIOCTRL_DRIVER means the same
/// on every sink; a driver's own start at AUDIOCTRL_DRIVER.
pub const AUDIOCTRL_DRIVER: u32 = 0x1000;

/// RtaDriver.type: what a driver makes.
pub const RTADT_SINK: u32 = 1 << 0;
pub const RTADT_TRANSPORT: u32 = 1 << 1;

/// RtaDriver.flags
/// The driver's instance is read from its interrupts: the library puts it
/// in internal memory.
pub const RTADF_INTERNAL_INSTANCE: u32 = 1 << 0;

/// A driver on the library's list. One of these is what a module hands to
/// AddRtaDriver; the module keeps it for as long as it is registered.
pub const RtaDriver = extern struct {
    /// ln_Name is the name a caller creates by ("es8311", "i2s"); ln_Pri
    /// orders the list, highest first.
    node: Node = .{},
    version: u16 = 0,
    revision: u16 = 0,
    id_string: ?[*:0]const u8 = null,
    /// RTADT_*
    type: u32 = 0,
    /// RTADF_*
    flags: u32 = 0,
    ops: ?*const RtaDriverOps = null,
    /// Bytes of private data the library puts behind each handle it makes
    /// for this driver.
    instance_size: u32 = 0,
    /// Handles alive. RemRtaDriver refuses while it is not zero.
    open_cnt: u16 = 0,
    pad: u16 = 0,
    /// The segments of a driver that was loaded, or null for one in ROM.
    seg_list: ?*anyopaque = null,
    user_data: ?*anyopaque = null,
};

pub const RtaDriverOps = extern struct {
    /// Fill the sink in from the tags: its ops, its modes, its ring's
    /// geometry, its instance. The library has allocated and cleared it
    /// and has already read the tags every driver shares. RTAERR_OK or
    /// why not.
    create_sink: ?*const fn (*RtaDriver, *AudioSink, ?[*]const tagitem.TagItem) callconv(.c) i32 = null,
    /// The same for a line.
    create_transport: ?*const fn (*RtaDriver, *transport.AudioTransport, ?[*]const tagitem.TagItem) callconv(.c) i32 = null,
};

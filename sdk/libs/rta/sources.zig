// SPDX-License-Identifier: MIT
//! Sources: what a driver registers for sound coming in, and what
//! audio.device records from.
//!
//! A source is one way in - a codec's microphone input, a stream that
//! hears what the machine plays - and the modes it can run in. Once
//! started it runs for ever on a ring of buffers: each time one has been
//! filled the task that started it is signalled and takes it with
//! SourceBuffer. The buffer is the caller's to read until the ring comes
//! round to it again, `buffers - 1` buffers' time later; a buffer that is
//! filled while the one before it has not been taken is lost, and the
//! source counts those in `overruns`.
//!
//! The buffers are a sink's: `buffer_frames` stereo frames of 16-bit
//! samples, the two halves of each as the mode's `sides` says - for a part
//! that records one side, AUDIOSIDES_MONO, that side in the first half.
//!
//! A source and a sink of one part - a codec's way in and its way out -
//! are two handles, often on one line. A line that carries both runs at
//! one rate: the side started second is started at the rate the line runs
//! at, or not at all.
//!
//! A driver fills in `AudioSourceOps`. A slot left null is an operation
//! the source has not got, and the call answers RTAERR_NOT_SUPPORTED.

const nodes = @import("../exec/nodes.zig");
const lists = @import("../exec/lists.zig");
const tasks = @import("../exec/tasks.zig");
const sinks = @import("sinks.zig");
const transport = @import("transport.zig");

const Node = nodes.Node;
const List = lists.List;
const Task = tasks.Task;
const RtaBase = @import("../../interface/rta.zig").RtaBase;

/// A way in.
pub const AudioSource = extern struct {
    /// ln_Name is the way in's name, as the board names its part
    /// ("es8311"); ln_Pri orders the list, highest first.
    node: Node = .{},
    /// Its number, the library's: worked out as a sink's, from its
    /// driver's name and its own, so the same from one boot to the next;
    /// never 0.
    id: u32 = 0,
    rta_base: ?*RtaBase = null,
    driver: ?*sinks.RtaDriver = null,
    /// The line its part is read over, for a source that has one.
    transport: ?*transport.AudioTransport = null,
    ops: ?*const AudioSourceOps = null,
    /// The modes, AudioMode nodes, filled by the driver at create.
    modes: List = .{},
    /// The mode it runs in once started, and starts in by default before:
    /// the library's.
    mode: ?*sinks.AudioMode = null,
    /// The ring a started source runs on: frames a buffer, and how many
    /// buffers it goes round. The driver sets both at create.
    buffer_frames: u32 = 0,
    buffers: u32 = 0,
    /// Buffers filled while the one before was still not taken - each
    /// one lost - since the source was made. The driver counts them.
    overruns: u32 = 0,
    /// AUDIOSRCF_*
    flags: u32 = 0,
    /// The caller's, untouched by the library and the driver.
    user_data: ?*anyopaque = null,
    /// The driver's own data: `instance_size` bytes the library allocated
    /// and cleared when the source was made, and frees with it.
    instance: ?*anyopaque = null,
    instance_size: u32 = 0,
};

/// AudioSource.flags
/// The source has been started and not stopped. The library's.
pub const AUDIOSRCF_RUNNING: u32 = 1 << 0;

/// What a driver fills in. Every slot may be null; a null slot is an
/// operation the source has not got.
pub const AudioSourceOps = extern struct {
    /// Undo what create did. DeleteSource calls it last.
    destroy: ?*const fn (*AudioSource) callconv(.c) void = null,
    /// Bring the way in up in that mode and start the ring: from now on
    /// `signal_mask` is raised on the task every time a buffer has been
    /// filled. RTAERR_OK, or why not, with nothing left taken.
    start: ?*const fn (*AudioSource, *const sinks.AudioMode, *Task, u32) callconv(.c) i32 = null,
    /// Stop the ring and give back what start took.
    stop: ?*const fn (*AudioSource) callconv(.c) void = null,
    /// The buffer filled last - `buffer_frames` stereo frames of 16-bit
    /// samples - or null when none has been filled since the last.
    buffer: ?*const fn (*AudioSource) callconv(.c) ?[*]const i16 = null,
};

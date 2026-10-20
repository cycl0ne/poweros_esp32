// SPDX-License-Identifier: MIT
//! Lines: what a part that takes I2S is fed over.
//!
//! The part and the line are two different things - the same codec turns
//! up on more than one chip's controller, and the same controller feeds
//! codecs and amplifiers alike - so a line is a handle of its own, made by
//! its own driver, and a sink is given one to play through. The line is
//! the stream: its clocks, its pads, the DMA ring and the interrupt at the
//! end of each buffer. The sink is what turns that into sound: the codec
//! set up over its bus, the amplifier's enable.
//!
//! A line may also have a way in, for a source: a second ring, which the
//! line fills from the part as the first is played to it. The two run on
//! the line's one set of clocks, so at one rate: whichever is started
//! first sets it, and the other is started at that rate or refused, until
//! both have stopped. Either may run alone.

const nodes = @import("../exec/nodes.zig");
const tasks = @import("../exec/tasks.zig");
const sinks = @import("sinks.zig");

const Node = nodes.Node;
const Task = tasks.Task;
const RtaBase = @import("../../interface/rta.zig").RtaBase;

/// A line a sink plays through.
pub const AudioTransport = extern struct {
    /// ln_Name is the instance's name ("i2s0").
    node: Node = .{},
    rta_base: ?*RtaBase = null,
    /// A driver of type RTADT_TRANSPORT.
    driver: ?*sinks.RtaDriver = null,
    ops: ?*const AudioTransportOps = null,
    /// The ring it runs on, as a sink's: frames a buffer, how many
    /// buffers, and the buffers played again for want of the next. The
    /// driver sets the first two at create and counts the third.
    buffer_frames: u32 = 0,
    buffers: u32 = 0,
    underruns: u32 = 0,
    /// AUDIOTF_*
    flags: u32 = 0,
    /// How many sinks and sources were given this line.
    /// DeleteAudioTransport refuses while it is not zero.
    open_cnt: u16 = 0,
    pad: u16 = 0,
    user_data: ?*anyopaque = null,
    /// The driver's own data: `instance_size` bytes the library allocated
    /// and cleared when the line was made, and frees with it.
    instance: ?*anyopaque = null,
    instance_size: u32 = 0,
    /// The way in's buffers filled while the one before was still not
    /// taken, each one lost. The driver counts them. Since 1.3.
    overruns: u32 = 0,
};

/// AudioTransport.flags
/// The line's way out has been started and not stopped. The library's.
pub const AUDIOTF_RUNNING: u32 = 1 << 0;
/// The line's way in has been started and not stopped. The library's.
/// Since 1.3.
pub const AUDIOTF_INPUT: u32 = 1 << 1;

pub const AudioTransportOps = extern struct {
    destroy: ?*const fn (*AudioTransport) callconv(.c) void = null,
    /// Clock the line for that mode, take its pads and start the ring on
    /// silence, raising `signal_mask` on the task each time a buffer has
    /// been played. RTAERR_OK, or why not, with nothing left taken.
    start: ?*const fn (*AudioTransport, *const sinks.AudioMode, *Task, u32) callconv(.c) i32 = null,
    stop: ?*const fn (*AudioTransport) callconv(.c) void = null,
    /// The next buffer to fill, or null when none has been played since
    /// the last.
    buffer: ?*const fn (*AudioTransport) callconv(.c) ?[*]i16 = null,
    /// The buffer `buffer` gave, filled: where the line reads it from.
    play: ?*const fn (*AudioTransport, [*]i16) callconv(.c) i32 = null,
    /// The way in started for that mode - alone, or beside the way out at
    /// the rate it runs at - its ring filled from the part, raising
    /// `signal_mask` on the task each time a buffer has been. RTAERR_OK,
    /// or why not, with nothing left taken. Since 1.3.
    start_input: ?*const fn (*AudioTransport, *const sinks.AudioMode, *Task, u32) callconv(.c) i32 = null,
    stop_input: ?*const fn (*AudioTransport) callconv(.c) void = null,
    /// The way in's buffer filled last, or null when none has been since
    /// the last.
    input_buffer: ?*const fn (*AudioTransport) callconv(.c) ?[*]const i16 = null,
};

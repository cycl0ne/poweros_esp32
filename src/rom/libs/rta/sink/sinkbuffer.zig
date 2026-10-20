// SPDX-License-Identifier: MPL-2.0
//! SinkBuffer: The next buffer to fill.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const _sink = @import("_sink.zig");

/// The next buffer of a running sink to fill.
///
/// SYNOPSIS:
/// ```zig
/// fn SinkBuffer(rb: *RtaBase, sink: *rta.AudioSink) ?[*]i16
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `sink` - a started sink.
///
/// RESULT:
/// The buffer: `buffer_frames` stereo frames of 16-bit samples, the two
/// halves of each as the mode's `sides` says. Null when no buffer has
/// been played since the last one was asked for, or the sink is not
/// started.
///
/// BEHAVIOR:
/// What comes back is the buffer that has just been played, which is the
/// one the output is furthest from. A caller woken late - more than one
/// buffer played since it was last here - gets the latest; the ones it
/// missed were played again, and the sink counts them in `underruns`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do: the one that started the sink.
///
/// OWNERSHIP:
/// The buffer is the caller's to write until `PlaySinkBuffer`; it stays
/// the sink's memory.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PlaySinkBuffer`, `StartSink`
///
/// EXAMPLES:
/// ```zig
/// const frames = rb.SinkBuffer(sink) orelse return;
/// mix(frames[0 .. sink.buffer_frames * 2]);
/// _ = rb.PlaySinkBuffer(sink, frames);
/// ```
pub fn SinkBuffer(_: *RtaBase, sink: *rta.AudioSink) ?[*]i16 {
    if (!_sink.running(sink)) return null;
    const ops = sink.ops orelse return null;
    const buffer = ops.buffer orelse return null;
    return buffer(sink);
}

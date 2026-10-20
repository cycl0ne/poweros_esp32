// SPDX-License-Identifier: MPL-2.0
//! AudioTransportBuffer: The line's next buffer to fill.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const _transport = @import("_transport.zig");

/// The next buffer of a running line to fill.
///
/// SYNOPSIS:
/// ```zig
/// fn AudioTransportBuffer(rb: *RtaBase, io: *rta.AudioTransport) ?[*]i16
/// ```
///
/// SINCE: 1.0. LVO -100.
///
/// INPUTS:
/// - `io` - a started line.
///
/// RESULT:
/// The buffer just played, `buffer_frames` stereo frames of 16-bit
/// samples, or null when none has been played since the last one was
/// asked for, or the line is not started.
///
/// BEHAVIOR:
/// As `SinkBuffer`, for a sink's driver: the buffers played again because
/// the caller came late are counted in the line's `underruns`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer is the caller's to write until `PlayAudioTransportBuffer`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PlayAudioTransportBuffer`, `SinkBuffer`
///
/// EXAMPLES:
/// ```zig
/// const frames = rb.AudioTransportBuffer(io) orelse return null;
/// ```
pub fn AudioTransportBuffer(_: *RtaBase, io: *rta.AudioTransport) ?[*]i16 {
    if (!_transport.running(io)) return null;
    const ops = io.ops orelse return null;
    const buffer = ops.buffer orelse return null;
    return buffer(io);
}

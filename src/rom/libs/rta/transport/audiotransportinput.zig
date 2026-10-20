// SPDX-License-Identifier: MPL-2.0
//! AudioTransportInput: The buffer a line's way in filled last.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const _transport = @import("_transport.zig");

/// The buffer a running way in has just filled.
///
/// SYNOPSIS:
/// ```zig
/// fn AudioTransportInput(rb: *RtaBase, io: *rta.AudioTransport) ?[*]const i16
/// ```
///
/// SINCE: 1.3. LVO -164.
///
/// INPUTS:
/// - `io` - a line whose way in is started.
///
/// RESULT:
/// The buffer filled last, `buffer_frames` stereo frames of 16-bit
/// samples, or null when none has been filled since the last one was
/// taken, or the way in is not started.
///
/// BEHAVIOR:
/// As `SourceBuffer`, for a source's driver: the buffers lost because the
/// caller came late are counted in the line's `overruns`. Where the data
/// cache covers the ring, the buffer comes back read from memory.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer is the line's memory, the caller's to read until the ring
/// comes round to it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartAudioTransportInput`, `SourceBuffer`
///
/// EXAMPLES:
/// ```zig
/// const frames = rb.AudioTransportInput(io) orelse return null;
/// ```
pub fn AudioTransportInput(_: *RtaBase, io: *rta.AudioTransport) ?[*]const i16 {
    if (!_transport.inputRunning(io)) return null;
    const ops = io.ops orelse return null;
    const buffer = ops.input_buffer orelse return null;
    return buffer(io);
}

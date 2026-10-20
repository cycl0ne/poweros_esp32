// SPDX-License-Identifier: MPL-2.0
//! PlayAudioTransportBuffer: A filled buffer, where the line reads it.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;
const _transport = @import("_transport.zig");

/// Hands a filled buffer to the line.
///
/// SYNOPSIS:
/// ```zig
/// fn PlayAudioTransportBuffer(rb: *RtaBase, io: *rta.AudioTransport, buffer: [*]i16) i32
/// ```
///
/// SINCE: 1.0. LVO -104.
///
/// INPUTS:
/// - `io` - a started line.
/// - `buffer` - what `AudioTransportBuffer` gave, filled.
///
/// RESULT:
/// `RTAERR_OK`, or `RTAERR_NOT_RUNNING` for a line that is not started.
///
/// BEHAVIOR:
/// The buffer is written back out of the cache, where the DMA reads it
/// from, and played when the ring comes round to it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer is the line's again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AudioTransportBuffer`, `PlaySinkBuffer`
///
/// EXAMPLES:
/// ```zig
/// return rb.PlayAudioTransportBuffer(io, frames);
/// ```
pub fn PlayAudioTransportBuffer(_: *RtaBase, io: *rta.AudioTransport, buffer: [*]i16) i32 {
    if (!_transport.running(io)) return err.RTAERR_NOT_RUNNING;
    const ops = io.ops orelse return err.RTAERR_NOT_SUPPORTED;
    const play = ops.play orelse return err.RTAERR_NOT_SUPPORTED;
    return play(io, buffer);
}

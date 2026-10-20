// SPDX-License-Identifier: MPL-2.0
//! StopAudioTransportInput: Stop a line's way in.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const _transport = @import("_transport.zig");

/// Stops a line's way in.
///
/// SYNOPSIS:
/// ```zig
/// fn StopAudioTransportInput(rb: *RtaBase, io: *rta.AudioTransport) void
/// ```
///
/// SINCE: 1.3. LVO -160.
///
/// INPUTS:
/// - `io` - the line.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The way in's ring stops and its interrupt is taken out. A line whose
/// way out still plays goes on playing; one that ran only for the way in
/// stops, and its DMA channel, memory and pads are given back. A way in
/// that is not started is left alone.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// What `StartAudioTransportInput` took is given back once nothing else
/// runs on it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartAudioTransportInput`, `StopSource`
///
/// EXAMPLES:
/// ```zig
/// rb.StopAudioTransportInput(io);
/// ```
pub fn StopAudioTransportInput(_: *RtaBase, io: *rta.AudioTransport) void {
    if (!_transport.inputRunning(io)) return;
    if (io.ops) |ops| {
        if (ops.stop_input) |stop| stop(io);
    }
    io.flags &= ~rta.transport.AUDIOTF_INPUT;
}

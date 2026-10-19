// SPDX-License-Identifier: MPL-2.0
//! StopAudioTransport: Stop a line and give its pads back.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const _transport = @import("_transport.zig");

/// Stops a line.
///
/// SYNOPSIS:
/// ```zig
/// fn StopAudioTransport(rb: *RtaBase, io: *rta.AudioTransport) void
/// ```
///
/// SINCE: 1.0. LVO -96.
///
/// INPUTS:
/// - `io` - the line.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The ring stops, its interrupt is taken out, and the DMA channel, the
/// memory and the pads are given back. A line that is not started is left
/// alone.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Everything `StartAudioTransport` took is given back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartAudioTransport`, `StopSink`
///
/// EXAMPLES:
/// ```zig
/// rb.StopAudioTransport(io);
/// ```
pub fn StopAudioTransport(_: *RtaBase, io: *rta.AudioTransport) void {
    if (!_transport.running(io)) return;
    if (io.ops) |ops| {
        if (ops.stop) |stop| stop(io);
    }
    io.flags &= ~rta.transport.AUDIOTF_RUNNING;
}

// SPDX-License-Identifier: MPL-2.0
//! StopSink: Stop an output and give back what it took.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const _sink = @import("_sink.zig");

/// Stops an output.
///
/// SYNOPSIS:
/// ```zig
/// fn StopSink(rb: *RtaBase, sink: *rta.AudioSink) void
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `sink` - the sink.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The driver switches its part off - the amplifier first, so the speaker
/// does not hear the clocks stop - stops the ring and gives back what
/// `StartSink` took. A sink that is not started is left alone.
///
/// CONTEXT:
/// - Waits: yes, if the driver does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do. Call it on the task that started the sink.
///
/// OWNERSHIP:
/// The pads, the DMA channel and the memory are given back; the sink may
/// be started again, or deleted.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartSink`, `DeleteSink`
///
/// EXAMPLES:
/// ```zig
/// rb.StopSink(sink);
/// ```
pub fn StopSink(_: *RtaBase, sink: *rta.AudioSink) void {
    if (!_sink.running(sink)) return;
    if (sink.ops) |ops| {
        if (ops.stop) |stop| stop(sink);
    }
    sink.flags &= ~rta.sinks.AUDIOSF_RUNNING;
}

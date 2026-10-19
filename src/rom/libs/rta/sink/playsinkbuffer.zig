// SPDX-License-Identifier: MPL-2.0
//! PlaySinkBuffer: A filled buffer, on to the output.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;
const _sink = @import("_sink.zig");

/// Hands a filled buffer on to the output.
///
/// SYNOPSIS:
/// ```zig
/// fn PlaySinkBuffer(rb: *RtaBase, sink: *rta.AudioSink, buffer: [*]i16) i32
/// ```
///
/// SINCE: 1.0. LVO -76.
///
/// INPUTS:
/// - `sink` - a started sink.
/// - `buffer` - what `SinkBuffer` gave, filled.
///
/// RESULT:
/// `RTAERR_OK`; `RTAERR_NOT_RUNNING` for a sink that is not started;
/// `RTAERR_NOT_SUPPORTED` for one whose driver takes no buffers.
///
/// BEHAVIOR:
/// The driver makes the buffer the part's to read: written back out of
/// the cache where the DMA reads round it, converted where the part
/// wants another width, sent where the output is somewhere else. It is
/// heard once the ring comes round to it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do: the one that started the sink.
///
/// OWNERSHIP:
/// The buffer is the sink's again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SinkBuffer`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.PlaySinkBuffer(sink, frames);
/// ```
pub fn PlaySinkBuffer(_: *RtaBase, sink: *rta.AudioSink, buffer: [*]i16) i32 {
    if (!_sink.running(sink)) return err.RTAERR_NOT_RUNNING;
    const ops = sink.ops orelse return err.RTAERR_NOT_SUPPORTED;
    const play = ops.play orelse return err.RTAERR_NOT_SUPPORTED;
    return play(sink, buffer);
}

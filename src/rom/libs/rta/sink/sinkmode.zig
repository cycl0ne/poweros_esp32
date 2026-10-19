// SPDX-License-Identifier: MPL-2.0
//! SinkMode: The mode the sink is in.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;

/// The mode a sink is in.
///
/// SYNOPSIS:
/// ```zig
/// fn SinkMode(rb: *RtaBase, sink: *rta.AudioSink) ?*rta.AudioMode
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `sink` - the sink.
///
/// RESULT:
/// Its mode: the rate it runs at, the bits a sample its part takes, how
/// many sides are heard and what the halves of a frame carry.
///
/// BEHAVIOR:
/// A sink is made in the mode its driver marked the default, so every
/// sink is in one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The mode is the sink's, alive as long as the sink is.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartSink`, `CreateSinkTagList`
///
/// EXAMPLES:
/// ```zig
/// const mode = rb.SinkMode(sink).?;
/// const step = mixer.stepFor(stream_rate, mode.rate);
/// ```
pub fn SinkMode(_: *RtaBase, sink: *rta.AudioSink) ?*rta.AudioMode {
    return sink.mode;
}

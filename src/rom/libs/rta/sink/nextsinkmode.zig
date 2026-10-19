// SPDX-License-Identifier: MPL-2.0
//! NextSinkMode: The next mode of a sink, or its first for null.

const sdk = @import("sdk");
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;

/// Walks a sink's modes.
///
/// SYNOPSIS:
/// ```zig
/// fn NextSinkMode(_: *RtaBase, sink: *rta.AudioSink, after: ?*rta.AudioMode) ?*rta.AudioMode
/// ```
///
/// SINCE: 1.2. LVO -116.
///
/// INPUTS:
/// - `sink` - the sink.
/// - `after` - the mode to go on from, or null for the first.
///
/// RESULT:
/// The next mode, or null at the end.
///
/// BEHAVIOR:
/// The modes are the driver's, fixed when the sink was made, in the order
/// it gave them.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe: the modes do not change after the sink is made.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The modes are the sink's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindSinkMode`, `SetSinkMode`, `SinkMode`
///
/// EXAMPLES:
/// ```zig
/// var mode = rb.NextSinkMode(sink, null);
/// while (mode) |m| : (mode = rb.NextSinkMode(sink, m)) list(m);
/// ```
pub fn NextSinkMode(_: *RtaBase, sink: *rta.AudioSink, after: ?*rta.AudioMode) ?*rta.AudioMode {
    const node = if (after) |mode| mode.node.next() else sink.modes.first();
    return @fieldParentPtr("node", node orelse return null);
}

// SPDX-License-Identifier: MPL-2.0
//! NextSink: The next sink after `after`, or the first for null.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;

/// Walks the list of sinks.
///
/// SYNOPSIS:
/// ```zig
/// fn NextSink(rb: *RtaBase, after: ?*rta.AudioSink) ?*rta.AudioSink
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `after` - the sink to go on from, or null for the first.
///
/// RESULT:
/// The next sink, or null at the end.
///
/// BEHAVIOR:
/// The sinks alive by their priority, highest first: the first is the
/// output most wanted, the one audio.device plays through.
///
/// CONTEXT:
/// - Waits: yes, while another task is changing the sink list.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The list is held for each step, not between
/// them: `after` must still be a sink, which the caller agrees on with
/// any task that may delete one.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindSink`, `CreateSinkTagList`
///
/// EXAMPLES:
/// ```zig
/// var sink = rb.NextSink(null);
/// while (sink) |s| : (sink = rb.NextSink(s)) list(s);
/// ```
pub fn NextSink(rb: *RtaBase, after: ?*rta.AudioSink) ?*rta.AudioSink {
    const sys = rb.sys_base;
    // Held for the step, so the sink after `after` is not taken out from
    // between them.
    sys.ObtainSemaphoreShared(&rb.sink_lock);
    defer sys.ReleaseSemaphore(&rb.sink_lock);
    const node = if (after) |sink| sink.node.next() else rb.sinks.first();
    return @fieldParentPtr("node", node orelse return null);
}

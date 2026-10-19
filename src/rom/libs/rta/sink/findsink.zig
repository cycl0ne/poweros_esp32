// SPDX-License-Identifier: MPL-2.0
//! FindSink: The sink of that name, or null.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;

/// Finds a sink by its name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindSink(rb: *RtaBase, sink_name: [*:0]const u8) ?*rta.AudioSink
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `sink_name` - its name ("es8311", "null").
///
/// RESULT:
/// The sink, or null if none of that name is alive.
///
/// BEHAVIOR:
/// The names are compared exactly; the first of the name on the list is
/// the answer.
///
/// CONTEXT:
/// - Waits: yes, while another task is changing the sink list.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The sink is whoever made it's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NextSink`
///
/// EXAMPLES:
/// ```zig
/// const sink = rb.FindSink("null") orelse return null;
/// ```
pub fn FindSink(rb: *RtaBase, sink_name: [*:0]const u8) ?*rta.AudioSink {
    const sys = rb.sys_base;
    sys.ObtainSemaphoreShared(&rb.sink_lock);
    defer sys.ReleaseSemaphore(&rb.sink_lock);
    const node = sys.FindName(&rb.sinks, sink_name) orelse return null;
    return @fieldParentPtr("node", node);
}

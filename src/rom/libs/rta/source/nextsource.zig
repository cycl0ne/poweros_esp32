// SPDX-License-Identifier: MPL-2.0
//! NextSource: The next source after `after`, or the first for null.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;

/// Walks the list of sources.
///
/// SYNOPSIS:
/// ```zig
/// fn NextSource(rb: *RtaBase, after: ?*rta.AudioSource) ?*rta.AudioSource
/// ```
///
/// SINCE: 1.3. LVO -136.
///
/// INPUTS:
/// - `after` - the source to go on from, or null for the first.
///
/// RESULT:
/// The next source, or null at the end.
///
/// BEHAVIOR:
/// The sources alive by their priority, highest first: the first is the
/// way in most wanted, the one audio.device records from.
///
/// CONTEXT:
/// - Waits: yes, while another task is changing the list.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The list is held for each step, not between
/// them: `after` must still be a source, which the caller agrees on with
/// any task that may delete one.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateSourceTagList`, `NextSink`
///
/// EXAMPLES:
/// ```zig
/// var source = rb.NextSource(null);
/// while (source) |s| : (source = rb.NextSource(s)) list(s);
/// ```
pub fn NextSource(rb: *RtaBase, after: ?*rta.AudioSource) ?*rta.AudioSource {
    const sys = rb.sys_base;
    // Held for the step, so the source after `after` is not taken out
    // from between them.
    sys.ObtainSemaphoreShared(&rb.sink_lock);
    defer sys.ReleaseSemaphore(&rb.sink_lock);
    const node = if (after) |source| source.node.next() else rb.sources.first();
    return @fieldParentPtr("node", node orelse return null);
}

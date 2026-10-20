// SPDX-License-Identifier: MPL-2.0
//! NextSourceMode: The next mode of a source, or its first for null.

const sdk = @import("sdk");
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;

/// Walks a source's modes.
///
/// SYNOPSIS:
/// ```zig
/// fn NextSourceMode(_: *RtaBase, source: *rta.AudioSource, after: ?*rta.AudioMode) ?*rta.AudioMode
/// ```
///
/// SINCE: 1.3. LVO -140.
///
/// INPUTS:
/// - `source` - the source.
/// - `after` - the mode to go on from, or null for the first.
///
/// RESULT:
/// The next mode, or null at the end.
///
/// BEHAVIOR:
/// The modes are the driver's, fixed when the source was made, in the
/// order it gave them.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe: the modes do not change after the source is made.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The modes are the source's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartSource`, `NextSinkMode`
///
/// EXAMPLES:
/// ```zig
/// var mode = rb.NextSourceMode(source, null);
/// while (mode) |m| : (mode = rb.NextSourceMode(source, m)) {
///     if (m.rate == wanted) break;
/// }
/// ```
pub fn NextSourceMode(_: *RtaBase, source: *rta.AudioSource, after: ?*rta.AudioMode) ?*rta.AudioMode {
    const node = if (after) |mode| mode.node.next() else source.modes.first();
    return @fieldParentPtr("node", node orelse return null);
}

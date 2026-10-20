// SPDX-License-Identifier: MPL-2.0
//! FindSinkMode: The sink's mode at that rate and with that many sides, or
//! null.

const sdk = @import("sdk");
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;

/// Finds a sink's mode by its rate and sides.
///
/// SYNOPSIS:
/// ```zig
/// fn FindSinkMode(rb: *RtaBase, sink: *rta.AudioSink, rate: u32, channels: u32) ?*rta.AudioMode
/// ```
///
/// SINCE: 1.2. LVO -120.
///
/// INPUTS:
/// - `sink` - the sink.
/// - `rate` - the frames a second wanted, or 0 for any.
/// - `channels` - the sides wanted, 1 or 2, or 0 for any.
///
/// RESULT:
/// The first mode that matches, or null. With both 0, the sink's default
/// mode - the one marked `AUDIOMF_DEFAULT`, or else its first.
///
/// BEHAVIOR:
/// Each 0 matches anything, so a caller can ask whether a sink runs at
/// 44100 Hz at all, or for its default.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It calls through the jump table.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NextSinkMode`, `SetSinkMode`
///
/// EXAMPLES:
/// ```zig
/// const cd = rb.FindSinkMode(sink, 44_100, 0) orelse rb.FindSinkMode(sink, 0, 0).?;
/// ```
pub fn FindSinkMode(rb: *RtaBase, sink: *rta.AudioSink, rate: u32, channels: u32) ?*rta.AudioMode {
    const rta_lib = rb.iface();
    var best: ?*rta.AudioMode = null;
    var mode = rta_lib.NextSinkMode(sink, null);
    while (mode) |m| : (mode = rta_lib.NextSinkMode(sink, m)) {
        if (rate != 0 and m.rate != rate) continue;
        if (channels != 0 and m.channels != channels) continue;
        // With nothing asked for, the sink's default is the answer.
        if (rate == 0 and channels == 0) {
            if (m.flags & rta.sinks.AUDIOMF_DEFAULT != 0) return m;
            if (best == null) best = m;
            continue;
        }
        return m;
    }
    return best;
}

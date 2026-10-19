// SPDX-License-Identifier: MPL-2.0
//! SetSinkMode: Put a stopped sink in that mode, or in its default for
//! null.

const sdk = @import("sdk");
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;
const _sink = @import("_sink.zig");

/// Puts a sink in a mode.
///
/// SYNOPSIS:
/// ```zig
/// fn SetSinkMode(rb: *RtaBase, sink: *rta.AudioSink, mode: ?*rta.AudioMode) i32
/// ```
///
/// SINCE: 1.2. LVO -124.
///
/// INPUTS:
/// - `sink` - the sink.
/// - `mode` - one of its modes, or null for its default.
///
/// RESULT:
/// `RTAERR_OK`, or: `RTAERR_IN_USE` while the sink is started,
/// `RTAERR_BAD_MODE` for a mode that is not the sink's.
///
/// BEHAVIOR:
/// The mode is the one the sink starts in from now on: `StartSink` hands
/// it to the driver, which clocks its part for it, and `SinkMode` answers
/// it. A started sink keeps the mode it runs in; a caller that wants
/// another stops it, sets the mode and starts it again.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It calls through the jump table.
/// - Locks: none needed: one task plays through a sink.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindSinkMode`, `SinkMode`, `StartSink`
///
/// EXAMPLES:
/// ```zig
/// rb.StopSink(sink);
/// _ = rb.SetSinkMode(sink, rb.FindSinkMode(sink, 44_100, 0));
/// _ = rb.StartSink(sink, task, mask);
/// ```
pub fn SetSinkMode(rb: *RtaBase, sink: *rta.AudioSink, mode: ?*rta.AudioMode) i32 {
    const rta_lib = rb.iface();
    if (_sink.running(sink)) return err.RTAERR_IN_USE;
    const wanted = mode orelse rta_lib.FindSinkMode(sink, 0, 0) orelse return err.RTAERR_BAD_MODE;
    var found = false;
    var walk = rta_lib.NextSinkMode(sink, null);
    while (walk) |m| : (walk = rta_lib.NextSinkMode(sink, m)) {
        if (m == wanted) found = true;
    }
    if (!found) return err.RTAERR_BAD_MODE;
    walk = rta_lib.NextSinkMode(sink, null);
    while (walk) |m| : (walk = rta_lib.NextSinkMode(sink, m)) {
        m.flags &= ~rta.sinks.AUDIOMF_CURRENT;
    }
    wanted.flags |= rta.sinks.AUDIOMF_CURRENT;
    sink.mode = wanted;
    return err.RTAERR_OK;
}

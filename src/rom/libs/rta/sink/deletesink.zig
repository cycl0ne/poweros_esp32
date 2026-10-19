// SPDX-License-Identifier: MPL-2.0
//! DeleteSink: Give a sink back.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;
const _sink = @import("_sink.zig");

/// Gives a sink back.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteSink(rb: *RtaBase, sink: ?*rta.AudioSink) void
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `sink` - the sink. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A sink that is started is refused, with `RTAERR_IN_USE` in
/// `RtaLastError`: something is playing through it. Otherwise the
/// driver's `destroy` is called and the sink leaves the list.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the sink list, and if the
///   driver does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: it waits for a lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The sink is gone; its driver, and the line it named, are one handle
/// less.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateSinkTagList`, `StopSink`
///
/// EXAMPLES:
/// ```zig
/// rb.DeleteSink(sink);
/// ```
pub fn DeleteSink(rb: *RtaBase, sink: ?*rta.AudioSink) void {
    const gone = sink orelse return;
    const sys = rb.sys_base;
    if (_sink.running(gone)) {
        rb.last_error = err.RTAERR_IN_USE;
        return;
    }
    if (gone.ops) |ops| {
        if (ops.destroy) |destroy| destroy(gone);
    }
    sys.ObtainSemaphore(&rb.sink_lock);
    sys.Remove(&gone.node);
    sys.ReleaseSemaphore(&rb.sink_lock);

    if (gone.transport) |io| {
        if (io.open_cnt != 0) io.open_cnt -= 1;
    }
    if (gone.driver) |driver| {
        if (driver.open_cnt != 0) driver.open_cnt -= 1;
    }
    if (gone.instance) |instance| sys.FreeVec(instance);
    sys.FreeVec(_sink.privateOf(gone));
}

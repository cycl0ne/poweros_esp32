// SPDX-License-Identifier: MPL-2.0
//! DeleteAudioTransport: Give a line back.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;
const _transport = @import("_transport.zig");

/// Gives a line back.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteAudioTransport(rb: *RtaBase, io: ?*rta.AudioTransport) void
/// ```
///
/// SINCE: 1.0. LVO -88.
///
/// INPUTS:
/// - `io` - the line. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A line a sink or a source is still given, or one that is started either
/// way, is refused, with
/// `RTAERR_IN_USE` in `RtaLastError`. Otherwise the driver's `destroy` is
/// called and the line leaves the list.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the sink list, and if the
///   driver does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: it waits for a lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The line is gone; its driver is one handle less.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateAudioTransportTagList`, `DeleteSink`
///
/// EXAMPLES:
/// ```zig
/// rb.DeleteSink(sink);
/// rb.DeleteAudioTransport(io);
/// ```
pub fn DeleteAudioTransport(rb: *RtaBase, io: ?*rta.AudioTransport) void {
    const gone = io orelse return;
    const sys = rb.sys_base;
    if (gone.open_cnt != 0 or _transport.running(gone) or _transport.inputRunning(gone)) {
        rb.last_error = err.RTAERR_IN_USE;
        return;
    }
    if (gone.ops) |ops| {
        if (ops.destroy) |destroy| destroy(gone);
    }
    sys.ObtainSemaphore(&rb.sink_lock);
    sys.Remove(&gone.node);
    sys.ReleaseSemaphore(&rb.sink_lock);

    if (gone.driver) |driver| {
        if (driver.open_cnt != 0) driver.open_cnt -= 1;
    }
    if (gone.instance) |instance| sys.FreeVec(instance);
    sys.FreeVec(_transport.privateOf(gone));
}

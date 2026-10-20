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
/// The sink leaves the list, the driver's `destroy` is called, and the
/// sink is freed. Since 1.4, one that is started - something plays
/// through it - leaves the list at once and is marked `AUDIOSF_GONE`, and
/// the task that started it is signalled with the signal it gave
/// `StartSink`; the rest happens when that task stops it (`StopSink`).
/// Until then the driver's operations are still called.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the sink list, and if the
///   driver does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: it waits for a lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The sink is the caller's no more: it may not be used after, though
/// one that was started stays allocated until it is stopped. Its driver,
/// and the line it named, are one handle less once it is freed.
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
    if (gone.flags & rta.sinks.AUDIOSF_GONE == 0) {
        sys.ObtainSemaphore(&rb.sink_lock);
        sys.Remove(&gone.node);
        sys.ReleaseSemaphore(&rb.sink_lock);
    }
    if (_sink.running(gone)) {
        // Played through: it goes once its player stops it, and the
        // player is told.
        gone.flags |= rta.sinks.AUDIOSF_GONE;
        const private = _sink.privateOf(gone);
        if (private.task) |task| sys.Signal(task, private.signal_mask);
        return;
    }
    if (gone.ops) |ops| {
        if (ops.destroy) |destroy| destroy(gone);
    }

    if (gone.transport) |io| {
        if (io.open_cnt != 0) io.open_cnt -= 1;
    }
    if (gone.driver) |driver| {
        if (driver.open_cnt != 0) driver.open_cnt -= 1;
    }
    if (gone.instance) |instance| sys.FreeVec(instance);
    sys.FreeVec(_sink.privateOf(gone));
}

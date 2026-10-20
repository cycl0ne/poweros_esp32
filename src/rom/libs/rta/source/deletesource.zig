// SPDX-License-Identifier: MPL-2.0
//! DeleteSource: Give a source back.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;
const _source = @import("_source.zig");

/// Gives a source back.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteSource(rb: *RtaBase, source: ?*rta.AudioSource) void
/// ```
///
/// SINCE: 1.3. LVO -132.
///
/// INPUTS:
/// - `source` - the source. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A source that is started is refused, with `RTAERR_IN_USE` in
/// `RtaLastError`: something is recording from it. Otherwise the driver's
/// `destroy` is called and the source leaves the list.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the list, and if the driver
///   does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: it waits for a lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The source is gone; its driver, and the line it named, are one handle
/// less.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateSourceTagList`, `StopSource`
///
/// EXAMPLES:
/// ```zig
/// rb.DeleteSource(source);
/// ```
pub fn DeleteSource(rb: *RtaBase, source: ?*rta.AudioSource) void {
    const gone = source orelse return;
    const sys = rb.sys_base;
    if (_source.running(gone)) {
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
    sys.FreeVec(_source.privateOf(gone));
}

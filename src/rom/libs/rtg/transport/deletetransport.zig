// SPDX-License-Identifier: MPL-2.0
//! DeleteTransport: Give a bus back.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const privateOf = _transport.privateOf;
const err = rtg.errors;
const _transport = @import("_transport.zig");

/// Gives a bus back.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteTransport(rb: *RtgBase, io: ?*rtg.RtgTransport) void
/// ```
///
/// SINCE: 1.0. LVO -176.
///
/// INPUTS:
/// - `io` - the transport. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A transport a board still talks through is refused, with `RTGERR_IN_USE`
/// in `RtgLastError`. Otherwise the driver's `destroy` is called and the
/// transport leaves the list.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the board list, and if the
///   driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Forbid: must not be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The transport is gone; its driver is one open less.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateTransportTagList`, `DeleteBoard`
///
/// EXAMPLES:
/// ```zig
/// rb.DeleteTransport(io);
/// ```
pub fn DeleteTransport(rb: *RtgBase, io: ?*rtg.RtgTransport) void {
    const gone = io orelse return;
    const sys = rb.sys_base;
    // A board still talking through it keeps it alive.
    if (gone.open_cnt != 0) {
        rb.last_error = err.RTGERR_IN_USE;
        return;
    }
    if (gone.ops) |ops| {
        if (ops.destroy) |destroy| destroy(gone);
    }
    sys.ObtainSemaphore(&rb.board_lock);
    sys.Remove(&gone.node);
    sys.ReleaseSemaphore(&rb.board_lock);

    if (gone.driver) |driver_ptr| {
        const driver: *rtg.RtgDriver = @ptrCast(@alignCast(driver_ptr));
        if (driver.open_cnt != 0) driver.open_cnt -= 1;
    }
    if (gone.instance) |instance| sys.FreeVec(instance);
    sys.FreeVec(privateOf(gone));
}

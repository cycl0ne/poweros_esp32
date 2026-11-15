// SPDX-License-Identifier: MPL-2.0
//! CloseTransport: Give a bus back.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const privateOf = _transport.privateOf;
const _transport = @import("_transport.zig");

/// Gives a bus back.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseTransport(rb: *RtgBase, io: ?*rtg.RtgTransport) void
/// ```
///
/// SINCE: 1.18. LVO -352.
///
/// INPUTS:
/// - `io` - the bus, as `OpenTransport` answered it. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The bus's driver's `destroy` is called, the bus leaves the library's
/// list, and its handle and instance are freed. Whoever opened it sends
/// nothing over it any more: a board's driver closes its bus when its
/// bring-up fails, and from its board's `destroy`.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the board list, and if the
///   bus's driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board list's lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bus is gone; its driver is one bus less.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenTransport`
///
/// EXAMPLES:
/// ```zig
/// rb.CloseTransport(io);
/// ```
pub fn CloseTransport(rb: *RtgBase, io: ?*rtg.RtgTransport) void {
    const gone = io orelse return;
    const sys = rb.sys_base;

    if (gone.ops) |ops| {
        if (ops.destroy) |destroy| destroy(gone);
    }
    sys.ObtainSemaphore(&rb.board_lock);
    sys.Remove(&gone.node);
    sys.ReleaseSemaphore(&rb.board_lock);

    if (gone.driver) |made_by| {
        const driver: *rtg.RtgDriver = @ptrCast(@alignCast(made_by));
        if (driver.buses != 0) driver.buses -= 1;
    }
    if (gone.instance) |instance| sys.FreeVec(instance);
    sys.FreeVec(privateOf(gone));
}

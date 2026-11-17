// SPDX-License-Identifier: MPL-2.0
//! CloseService: a service closed with the firmware.

const sdk = @import("sdk");
const vchiq = sdk.resources.vchiq;
const base = @import("../vchiq_base.zig");
const VchiqBase = base.VchiqBase;
const Service = base.Service;
const queue = @import("../link/_queue.zig");

/// Closes a service.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseService(vb: *VchiqBase, service: ?*VchiqService) void
/// ```
///
/// SINCE: 1.0. LVO -8.
///
/// INPUTS:
/// - `service` - as OpenService gave it; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A CLOSE goes to the firmware, unless it closed the service itself,
/// and its answer is waited for, a second at most. Bulks still out are
/// given up (VCHIQERR_ABORTED, their `done` signalled) and the messages
/// not received are dropped.
///
/// CONTEXT:
/// - Waits: yes, for the firmware's answer.
/// - Interrupts: no.
/// - Locks: the resource's start lock, for the call.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The service is gone. The bulks that were out are the caller's again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenService`
///
/// EXAMPLES:
/// ```zig
/// vb.CloseService(mmal);
/// ```
pub fn CloseService(vb: *VchiqBase, service: ?*vchiq.VchiqService) void {
    const handle = service orelse return;
    const s = Service.of(handle);
    const sys = vb.sys_base;
    sys.ObtainSemaphore(&vb.start_lock);
    defer sys.ReleaseSemaphore(&vb.start_lock);
    queue.close(vb, s);
    queue.forget(vb, s);
    sys.FreeMem(s, @sizeOf(Service));
}

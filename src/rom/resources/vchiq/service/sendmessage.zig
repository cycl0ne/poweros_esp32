// SPDX-License-Identifier: MPL-2.0
//! SendMessage: one message to a service.

const sdk = @import("sdk");
const vchiq = sdk.resources.vchiq;
const base = @import("../vchiq_base.zig");
const VchiqBase = base.VchiqBase;
const Service = base.Service;
const queue = @import("../link/_queue.zig");
const layout = @import("../link/_layout.zig");

/// Sends a message to the service on the firmware's side.
///
/// SYNOPSIS:
/// ```zig
/// fn SendMessage(vb: *VchiqBase, service: *VchiqService,
///     data: [*]const u8, size: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -12.
///
/// INPUTS:
/// - `service` - as OpenService gave it.
/// - `data` - the message: `size` bytes, 1 to VCHIQ_MAX_MESSAGE.
///
/// RESULT:
/// VCHIQERR_OK; VCHIQERR_SIZE for an empty message or one too large,
/// VCHIQERR_CLOSED when the service is closed, VCHIQERR_TIMEOUT when the
/// firmware gave no room for it in two seconds - and then nothing went.
///
/// BEHAVIOR:
/// The message goes after everything sent before it on the queue - by
/// any task, on any service, bulks' messages too - and the firmware is
/// told at once. When the ARM's slots are full the call waits for the
/// firmware to give one back.
///
/// CONTEXT:
/// - Waits: only while the queue is full, or the firmware paused it.
/// - Interrupts: no.
/// - Locks: the queue's send lock, for the call.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bytes are copied: `data` is the caller's again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReceiveMessage`, `QueueBulk`
///
/// EXAMPLES:
/// ```zig
/// if (vb.SendMessage(mmal, &request, request.len) != vchiq.VCHIQERR_OK) return error.Failed;
/// ```
pub fn SendMessage(vb: *VchiqBase, service: *vchiq.VchiqService, data: [*]const u8, size: u32) u32 {
    if (size == 0 or size > vchiq.VCHIQ_MAX_MESSAGE) return vchiq.VCHIQERR_SIZE;
    const s = Service.of(service);
    const sys = vb.sys_base;
    sys.ObtainSemaphore(&vb.tx_lock);
    defer sys.ReleaseSemaphore(&vb.tx_lock);
    if (s.state != base.SERVICE_OPEN) return vchiq.VCHIQERR_CLOSED;
    return queue.sendLocked(vb, layout.msgid(layout.MSG_DATA, s.localport, s.remoteport), data[0..size]);
}

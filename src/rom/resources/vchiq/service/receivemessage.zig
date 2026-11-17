// SPDX-License-Identifier: MPL-2.0
//! ReceiveMessage: the next message from a service.

const sdk = @import("sdk");
const exec = sdk.exec;
const vchiq = sdk.resources.vchiq;
const base = @import("../vchiq_base.zig");
const VchiqBase = base.VchiqBase;
const Service = base.Service;
const Message = base.Message;
const queue = @import("../link/_queue.zig");

/// Takes the next message the service on the firmware's side sent.
///
/// SYNOPSIS:
/// ```zig
/// fn ReceiveMessage(vb: *VchiqBase, service: *VchiqService,
///     buffer: [*]u8, size: u32, length: *u32, timeout_us: u64) u32
/// ```
///
/// SINCE: 1.0. LVO -16.
///
/// INPUTS:
/// - `service` - as OpenService gave it.
/// - `buffer` - `size` bytes of room for it; VCHIQ_MAX_MESSAGE always
///   has room.
/// - `length` - the message's length, of which no more than `size`
///   bytes were copied; 0 when there was none.
/// - `timeout_us` - how long to wait for one: 0 only looks,
///   exec.WAIT_FOREVER has no limit.
///
/// RESULT:
/// VCHIQERR_OK; VCHIQERR_TIMEOUT when none came in the time;
/// VCHIQERR_CLOSED when the service is closed and every message it got
/// was taken.
///
/// BEHAVIOR:
/// The messages come in the order the firmware sent them. The
/// resource's task copies each out of the firmware's slot as soon as it
/// arrives, so they wait here however long the caller takes.
///
/// CONTEXT:
/// - Waits: yes, up to `timeout_us`.
/// - Interrupts: no.
/// - Locks: the queue's list lock, briefly.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bytes are the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SendMessage`, `OpenService`
///
/// EXAMPLES:
/// ```zig
/// var reply: [vchiq.VCHIQ_MAX_MESSAGE]u8 = undefined;
/// var length: u32 = 0;
/// if (vb.ReceiveMessage(mmal, &reply, reply.len, &length, 3_000_000) == vchiq.VCHIQERR_OK) use(reply[0..length]);
/// ```
pub fn ReceiveMessage(vb: *VchiqBase, service: *vchiq.VchiqService, buffer: [*]u8, size: u32, length: *u32, timeout_us: u64) u32 {
    const s = Service.of(service);
    const sys = vb.sys_base;
    const waits = [_]*exec.Waitable{&s.arrived};
    const forever = timeout_us == exec.WAIT_FOREVER;
    const until = if (forever) 0 else sys.UptimeUs() +| timeout_us;
    length.* = 0;
    while (true) {
        if (queue.nextMessage(vb, s)) |m| {
            const n = @min(m.size, size);
            @memcpy(buffer[0..n], m.bytes()[0..n]);
            length.* = m.size;
            sys.FreeMem(m, @sizeOf(Message) + m.size);
            return vchiq.VCHIQERR_OK;
        }
        if (s.state != base.SERVICE_OPEN) return vchiq.VCHIQERR_CLOSED;
        var wait: u64 = exec.WAIT_FOREVER;
        if (!forever) {
            const now = sys.UptimeUs();
            if (now >= until) return vchiq.VCHIQERR_TIMEOUT;
            wait = until - now;
        }
        _ = sys.WaitForAny(&waits, waits.len, wait);
    }
}

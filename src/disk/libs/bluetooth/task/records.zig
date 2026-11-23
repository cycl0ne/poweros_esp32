// SPDX-License-Identifier: MIT
//! The task's side of the SDP server's records (sdp/server.zig): the
//! programs' records (AddBTService) read for the server one at a time,
//! each copied out under their lock, so that one given back while the
//! server answers is never read.
//!
//! Runs in the task, called by the layer under the base's lock - the
//! records' lock taken after it, never before.

const _controller = @import("../controller/_controller.zig");
const Controller = _controller.Controller;
const _hci = @import("../hci/_hci.zig");
const _service = @import("../service/_service.zig");

/// The port's upcall for the SDP server: the record at `index` among the
/// programs', in the order they were added, copied into `into` - its
/// handle, and its bytes there; null past the last.
pub fn record(context: *anyopaque, index: usize, into: []u8) ?_hci.Served {
    const controller: *Controller = @ptrCast(@alignCast(context));
    const base = controller.base;
    const sys = base.sys_base;
    sys.ObtainSemaphoreShared(&base.records_lock);
    defer sys.ReleaseSemaphore(&base.records_lock);
    var it = base.records.iterator();
    var at: usize = 0;
    while (it.next()) |node| : (at += 1) {
        if (at != index) continue;
        const kept: *_service.Record = @alignCast(@fieldParentPtr("node", node));
        const bytes = kept.bytes();
        // AddBTService took none longer.
        if (bytes.len > into.len) return null;
        @memcpy(into[0..bytes.len], bytes);
        return .{ .handle = kept.handle, .bytes = into[0..bytes.len] };
    }
    return null;
}

// SPDX-License-Identifier: MPL-2.0
//! Delay: waits a number of ticks.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const timer = sdk.devices.timer;

/// Waits a number of fiftieths of a second.
///
/// SYNOPSIS:
/// ```zig
/// fn Delay(db: *DosBase, ticks: u32) void
/// ```
///
/// SINCE: 1.0. LVO -512.
///
/// INPUTS:
/// - `ticks` - how long, in 1/50 s.
///
/// RESULT:
/// Nothing; IoErr says whether it waited: 0 when it did,
/// ERROR_OBJECT_NOT_FOUND without timer.device, ERROR_NO_FREE_STORE when
/// no message port could be made (then it returns at once).
///
/// BEHAVIOR:
/// A copy of dos's timer request, with a reply port of the caller's own,
/// is sent with TR_ADDREQUEST and waited for, so several tasks can wait at
/// once. 0 returns at once.
///
/// CONTEXT:
/// - Waits: yes.
/// - Interrupts: no.
/// - Forbid: never under Forbid.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A message port is made and freed within the call.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DateStamp`, `WaitForChar`
///
/// EXAMPLES:
/// ```zig
/// dos_lib.Delay(50); // a second
/// ```
pub fn Delay(db: *DosBase, ticks: u32) void {
    if (ticks == 0) return;
    const dos_lib = db.iface();
    const opened = db.timer_io orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_OBJECT_NOT_FOUND);
        return;
    };
    const port = db.sys_base.CreateMsgPort() orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return;
    };
    defer db.sys_base.DeleteMsgPort(port);
    var req: timer.TimeRequest = @as(*timer.TimeRequest, @ptrCast(@alignCast(opened))).*;
    req.node.message.reply_port = port;
    req.node.command = timer.TR_ADDREQUEST;
    req.time = .{ .secs = ticks / 50, .micro = ticks % 50 * 20_000 };
    _ = db.sys_base.DoIO(&req.node);
    _ = dos_lib.SetIoErr(0);
}

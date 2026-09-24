// SPDX-License-Identifier: MPL-2.0
//! systime [secs]: the system time set (TR_SETSYSTIME) and read back, by
//! request (TR_GETSYSTIME) and by the device's GetSysTime.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const timer = sdk.devices.timer;

pub const name = "systime";
pub const usage = "systime [secs]";
pub const help =
    \\  systime [secs]       set and read the system time (TR_SETSYSTIME, TR_GETSYSTIME, GetSysTime)
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const sys = shell.base.iface();
    const req = try _shell.openTimer(shell, timer.UNIT_MICROHZ);
    defer _shell.closeTimer(shell, req);
    if (args.peek() != null) {
        req.node.command = timer.TR_SETSYSTIME;
        req.time = .{ .secs = try args.number(), .micro = 0 };
        _ = sys.DoIO(&req.node);
    }
    req.node.command = timer.TR_GETSYSTIME;
    const err = sys.DoIO(&req.node);
    const device: *timer.TimerBase = @ptrCast(req.node.device.?);
    var now: timer.TimeVal = .{};
    device.GetSysTime(&now);
    shell.print("TR_GETSYSTIME: %d.%06d s (error %d); GetSysTime: %d.%06d s\n", .{
        req.time.secs, req.time.micro, err, now.secs, now.micro,
    });
}

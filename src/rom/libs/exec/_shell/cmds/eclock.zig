// SPDX-License-Identifier: MPL-2.0
//! eclock: timer.device's ReadEClock, the count and its rate.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const timer = sdk.devices.timer;

pub const name = "eclock";
pub const usage = "eclock";
pub const help =
    \\  eclock               timer.device ReadEClock
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const req = try _shell.openTimer(shell, timer.UNIT_ECLOCK);
    defer _shell.closeTimer(shell, req);
    const device: *timer.TimerBase = @ptrCast(req.node.device.?);
    var count: timer.EClockVal = .{};
    const hz = device.ReadEClock(&count);
    shell.print("ReadEClock: hi 0x%08x lo 0x%08x: %ld ticks at %d Hz, %ld ms\n", .{
        count.hi, count.lo, count.toTicks(), hz, count.toTicks() / (hz / 1000),
    });
}

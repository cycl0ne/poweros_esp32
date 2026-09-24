// SPDX-License-Identifier: MPL-2.0
//! tdelay <ms> [micro|vblank|eclock|until|waiteclock]: a TR_ADDREQUEST on
//! that timer.device unit, each given its time the way the unit reads it,
//! and how long it really took.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const uptime = @import("../../../../../arch/esp32s3/timer.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const timer = sdk.devices.timer;

pub const name = "tdelay";
pub const usage = "tdelay <ms> [micro|vblank|eclock|until|waiteclock]";
pub const help =
    \\  tdelay <ms> [micro|vblank|eclock|until|waiteclock]  timer.device TR_ADDREQUEST on that unit
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const ms = try args.number();
    const which = args.next() orelse "micro";
    const unit_names = [_]struct { []const u8, u32 }{
        .{ "micro", timer.UNIT_MICROHZ },
        .{ "vblank", timer.UNIT_VBLANK },
        .{ "eclock", timer.UNIT_ECLOCK },
        .{ "until", timer.UNIT_WAITUNTIL },
        .{ "waiteclock", timer.UNIT_WAITECLOCK },
    };
    const unit = for (unit_names) |entry| {
        if (_shell.same(entry[0], which)) break entry[1];
    } else return error.Usage;

    const req = try _shell.openTimer(shell, unit);
    defer _shell.closeTimer(shell, req);
    const device: *timer.TimerBase = @ptrCast(req.node.device.?);
    const us = @as(u64, ms) * 1000;
    var now: timer.EClockVal = .{};
    const eclock_hz = device.ReadEClock(&now);
    const ticks = us * (eclock_hz / 1_000_000);
    const eclock: *timer.EClockVal = @ptrCast(&req.time);
    switch (unit) {
        timer.UNIT_ECLOCK => eclock.* = timer.EClockVal.fromTicks(ticks),
        timer.UNIT_WAITUNTIL => {
            // Until now + ms, with the device's own GetSysTime and AddTime.
            device.GetSysTime(&req.time);
            const delta = timer.TimeVal.fromMicros(us);
            device.AddTime(&req.time, &delta);
        },
        timer.UNIT_WAITECLOCK => eclock.* = timer.EClockVal.fromTicks(now.toTicks() + ticks),
        else => req.time = timer.TimeVal.fromMicros(us),
    }
    req.node.command = timer.TR_ADDREQUEST;
    const start = uptime.uptimeUs();
    const err = shell.base.iface().DoIO(&req.node);
    shell.print("TR_ADDREQUEST %d ms, unit %s: error %d, after %ld us\n", .{ ms, which, err, uptime.uptimeUs() - start });
}

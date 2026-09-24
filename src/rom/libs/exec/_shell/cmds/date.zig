// SPDX-License-Identifier: MPL-2.0
//! date [secs]: the system time, or `secs` since 1978, as a date through
//! utility.library's Amiga2Date, and what CheckDate makes of it.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const timer = sdk.devices.timer;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const name = "date";
pub const usage = "date [secs]";
pub const help =
    \\  date [secs]          the system time (or secs since 1978) as a date: utility.library
    \\                       Amiga2Date and CheckDate
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const sys = shell.base.iface();
    const lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse {
        shell.print("can't open %s\n", .{sdk.interface.utility.NAME});
        return;
    };
    defer sys.CloseLibrary(lib);
    const ub: *UtilityBase = @ptrCast(lib);
    const secs = if (args.peek() != null) try args.number() else now: {
        const req = try _shell.openTimer(shell, timer.UNIT_MICROHZ);
        defer _shell.closeTimer(shell, req);
        const device: *timer.TimerBase = @ptrCast(req.node.device.?);
        var now: timer.TimeVal = .{};
        device.GetSysTime(&now);
        break :now now.secs;
    };
    var clock: sdk.utility.ClockData = .{};
    ub.Amiga2Date(secs, &clock);
    const checked = ub.CheckDate(&clock);
    const days = [_][*:0]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    shell.print("%d s since 1978: %s %04d-%02d-%02d %02d:%02d:%02d (CheckDate %d)\n", .{
        secs, days[clock.wday], clock.year, clock.month, clock.mday, clock.hour, clock.min, clock.sec, checked,
    });
}

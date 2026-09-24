// SPDX-License-Identifier: MPL-2.0
//! wdt [arm <ms> [cpu]|feed|off]: watchdog.resource's functions, through
//! OpenResource; alone, its state.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const watchdog = sdk.resources.watchdog;

pub const name = "wdt";
pub const usage = "wdt [arm <ms> [cpu]|feed|off]";
pub const help =
    \\  wdt [arm <ms> [cpu]|feed|off]  watchdog.resource: arm (a system reset, or with cpu
    \\                       a CPU reset, after <ms> without a feed), feed, stop; alone: the state
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const wb: *watchdog.WatchdogBase = @ptrCast(shell.base.iface().OpenResource(watchdog.WATCHDOGNAME) orelse {
        shell.print("no %s\n", .{watchdog.WATCHDOGNAME});
        return;
    });
    if (args.next()) |word| {
        if (_shell.same(word, "arm")) {
            const ms = try args.number();
            const cpu_reset = if (args.next()) |how| _shell.same(how, "cpu") else false;
            if (!wb.ArmWatchdog(ms, if (cpu_reset) watchdog.WATCHDOG_RESET_CPU else watchdog.WATCHDOG_RESET_SYSTEM)) {
                shell.print("ArmWatchdog %d ms: refused\n", .{ms});
                return;
            }
        } else if (_shell.same(word, "feed")) {
            wb.FeedWatchdog();
        } else if (_shell.same(word, "off")) {
            wb.DisarmWatchdog();
        } else return error.Usage;
    }
    const armed = wb.ReadWatchdog();
    if (armed == 0) {
        shell.print("watchdog off\n", .{});
    } else {
        shell.print("watchdog armed: a reset after %d ms without a feed\n", .{armed});
    }
}

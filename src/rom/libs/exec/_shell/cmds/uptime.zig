// SPDX-License-Identifier: MPL-2.0
//! uptime: the time since boot, from the system timer, and the ticks.

const _shell = @import("../shell.zig");
const timer = @import("../../../../../arch/esp32s3/timer.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "uptime";
pub const usage = "uptime";
pub const help =
    \\  uptime               time since boot and tick count
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const us = timer.uptimeUs();
    shell.print("up %ld.%03ld s, %d ticks\n", .{ us / 1_000_000, us / 1000 % 1000, timer.tickCount() });
}

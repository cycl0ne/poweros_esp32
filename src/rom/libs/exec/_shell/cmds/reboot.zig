// SPDX-License-Identifier: MPL-2.0
//! reboot: exec's ColdReboot, which resets the chip.

const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "reboot";
pub const usage = "reboot";
pub const help =
    \\  reboot               ColdReboot: reset the chip
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    shell.print("rebooting...\n", .{});
    shell.base.iface().ColdReboot();
}

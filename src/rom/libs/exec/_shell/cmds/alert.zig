// SPDX-License-Identifier: MPL-2.0
//! alert <code>: exec's Alert; a code with AT_DeadEnd set halts.

const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "alert";
pub const usage = "alert <code>";
pub const help =
    \\  alert <code>         exec Alert(); 0x8....... is a dead end (halts)
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    shell.base.iface().Alert(try args.number());
}

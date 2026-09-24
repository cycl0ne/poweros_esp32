// SPDX-License-Identifier: MPL-2.0
//! clis: the CLI processes by number, through dos.library's MaxCli and
//! FindCliProc.

const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "clis";
pub const usage = "clis";
pub const help =
    \\  clis                 dos.library MaxCli and FindCliProc: the CLIs and their processes
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const dl = _shell.openDos(shell) orelse return;
    defer shell.base.iface().CloseLibrary(dl.lib());
    const max = dl.MaxCli();
    if (max == 0) shell.print("no CLIs\n", .{});
    var n: u32 = 1;
    while (n <= max) : (n += 1) {
        if (dl.FindCliProc(n)) |process| shell.print("%u  %s\n", .{ n, _shell.nodeName(&process.task.node) });
    }
}

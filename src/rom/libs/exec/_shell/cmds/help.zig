// SPDX-License-Identifier: MPL-2.0
//! help: every command with its words, and what it does - each command's
//! own lines, gathered at compile time (shell.zig's `help_text`).

const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "help";
pub const usage = "help";
pub const help =
    \\  help                 this list
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    shell.print("%s", .{_shell.help_text.ptr});
}

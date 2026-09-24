// SPDX-License-Identifier: MPL-2.0
//! panic: a Zig panic on purpose, which ends in exec's kernel panic.

const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "panic";
pub const usage = "panic";
pub const help =
    \\  panic                raise a Zig panic
    \\
;

pub fn run(_: *Shell, _: *Args) anyerror!void {
    @panic("requested from the shell");
}

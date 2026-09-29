// SPDX-License-Identifier: MPL-2.0
//! debug: the ROM debugger, from a machine that is still working.
//!
//! The other ways in are a dead-end Guru, which offers it, and `Debug()`
//! from code. This one is for looking at a running system with
//! everything else stopped - and for trying the debugger before the day
//! it is needed.

const _shell = @import("../shell.zig");
const _debug = @import("../../debug/_debug.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "debug";
pub const usage = "debug";
pub const help =
    \\  debug                stop the machine and enter the ROM debugger
    \\
;

pub fn run(_: *Shell, _: *Args) anyerror!void {
    _debug.enter(.asked, null, 0);
}

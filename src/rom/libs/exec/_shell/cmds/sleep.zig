// SPDX-License-Identifier: MPL-2.0
//! sleep <ms>: a timer.device wait, and how long it really took.

const _shell = @import("../shell.zig");
const timer = @import("../../../../../arch/esp32s3/timer.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "sleep";
pub const usage = "sleep <ms>";
pub const help =
    \\  sleep <ms>           a timer.device wait, timed
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const ms = try args.number();
    const start = timer.uptimeUs();
    _shell.sleepMs(shell, ms);
    shell.print("slept %ld us\n", .{timer.uptimeUs() - start});
}

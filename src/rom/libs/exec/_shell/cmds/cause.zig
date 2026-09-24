// SPDX-License-Identifier: MPL-2.0
//! cause: the shell's software interrupt Caused twice under Disable - the
//! second is ignored, since it is queued already - and when it ran.

const _shell = @import("../shell.zig");
const uptime = @import("../../../../../arch/esp32s3/timer.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "cause";
pub const usage = "cause";
pub const help =
    \\  cause                Cause() the demo software interrupt
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    const runs: *volatile u32 = &shell.softint_runs;
    const before = runs.*;
    sys.Disable();
    sys.Cause(&shell.softint);
    sys.Cause(&shell.softint); // already queued: ignored
    const while_disabled = runs.* - before;
    sys.Enable(); // it runs now
    const deadline = uptime.uptimeUs() + 1000;
    while (runs.* == before and uptime.uptimeUs() < deadline) {}
    shell.print("caused twice under Disable: ran %d time(s) while disabled, %d after Enable\n", .{ while_disabled, runs.* - before - while_disabled });
}

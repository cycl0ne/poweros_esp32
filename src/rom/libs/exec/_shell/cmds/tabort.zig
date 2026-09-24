// SPDX-License-Identifier: MPL-2.0
//! tabort <ms> <after-ms>: a timer.device wait sent, and AbortIO'd
//! before it is due.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const uptime = @import("../../../../../arch/esp32s3/timer.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const timer = sdk.devices.timer;

pub const name = "tabort";
pub const usage = "tabort <ms> <after-ms>";
pub const help =
    \\  tabort <ms> <after-ms>  send a timer.device wait, AbortIO it after <after-ms>
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const sys = shell.base.iface();
    const ms = try args.number();
    const after = try args.number();
    const req = try _shell.openTimer(shell, timer.UNIT_MICROHZ);
    defer _shell.closeTimer(shell, req);
    req.node.command = timer.TR_ADDREQUEST;
    req.time = timer.TimeVal.fromMicros(@as(u64, ms) * 1000);
    const start = uptime.uptimeUs();
    sys.SendIO(&req.node);
    _shell.sleepMs(shell, after);
    const aborted = sys.AbortIO(&req.node);
    const err = sys.WaitIO(&req.node);
    shell.print("AbortIO after %d ms: %d; WaitIO: error %d, after %ld us\n", .{ after, aborted, err, uptime.uptimeUs() - start });
}

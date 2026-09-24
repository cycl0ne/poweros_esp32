// SPDX-License-Identifier: MPL-2.0
//! syscall <nr> [arg]: a trap into the kernel (0 ping, 1 ticks,
//! 2 uptime in ms) and its answer.

const _shell = @import("../shell.zig");
const trap = @import("../../../../../arch/esp32s3/trap.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "syscall";
pub const usage = "syscall <nr> [arg]";
pub const help =
    \\  syscall <nr> [arg]   trap into the kernel (0=ping 1=ticks 2=uptime_ms)
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const nr = try args.number();
    const arg = try args.numberOr(0);
    shell.print("syscall(%d, %d) = %d\n", .{ nr, arg, trap.syscall(nr, arg) });
}

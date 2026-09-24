// SPDX-License-Identifier: MPL-2.0
//! fault [load|ill]: a CPU exception on purpose - a load from an address
//! nothing answers, or an illegal instruction.

const reg = @import("sdk").hardware.mmio.reg;
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "fault";
pub const usage = "fault [load|ill]";
pub const help =
    \\  fault [load|ill]     raise a CPU exception
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const kind = args.next() orelse "load";
    if (_shell.same(kind, "ill")) {
        asm volatile ("ill");
    } else if (_shell.same(kind, "load")) {
        shell.print("value: %x\n", .{reg(0x10).*});
    } else return error.Usage;
}

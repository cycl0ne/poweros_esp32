// SPDX-License-Identifier: MPL-2.0
//! poke <addr> <value>: one 32-bit word written.

const reg = @import("sdk").hardware.mmio.reg;
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "poke";
pub const usage = "poke <addr> <value>";
pub const help =
    \\  poke <addr> <value>  write a 32-bit word
    \\
;

pub fn run(_: *Shell, args: *Args) anyerror!void {
    const address = (try args.number()) & ~@as(u32, 3);
    const value = try args.number();
    reg(address).* = value;
}

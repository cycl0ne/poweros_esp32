// SPDX-License-Identifier: MPL-2.0
//! peek <addr> [words]: 32-bit words of memory, four to a line.

const reg = @import("sdk").hardware.mmio.reg;
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "peek";
pub const usage = "peek <addr> [words]";
pub const help =
    \\  peek <addr> [words]  dump memory
    \\
;

/// How an address is printed: as wide as the machine's.
const address_format = if (@sizeOf(usize) == 8) "%s0x%010lx:" else "%s0x%08x:";

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const address = (try args.address()) & ~@as(usize, 3);
    const words = try args.numberOr(4);
    var i: u32 = 0;
    while (i < words) : (i += 1) {
        const at = address + i * 4;
        if (i % 4 == 0) shell.print(address_format, .{ if (i == 0) "" else "\n", at });
        shell.print(" %08x", .{reg(at).*});
    }
    shell.print("\n", .{});
}

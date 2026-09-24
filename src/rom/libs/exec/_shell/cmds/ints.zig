// SPDX-License-Identifier: MPL-2.0
//! ints: exec's interrupt vectors in use - the source, the CPU line the
//! interrupt matrix routed it to, how often it fired, and its handler or
//! servers.

const sdk = @import("sdk");
const exec = @import("../../exec.zig");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const intmatrix = @import("../../../../../arch/esp32s3/intmatrix.zig");

pub const name = "ints";
pub const usage = "ints";
pub const help =
    \\  ints                 exec interrupt vectors in use
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    shell.print("source  cpu line      count  handler / servers\n", .{});
    for (&shell.base.int_vects, 0..) |*vector, n| {
        if (!exec.inUse(vector)) continue;
        const source: u32 = @intCast(n);
        shell.print("%6d  %8d  %9d ", .{ source, @as(i32, if (intmatrix.lineOf(source)) |line| line else -1), @as(*volatile u32, &vector.count).* });
        if (vector.handler) |handler| shell.print(" handler \"%s\"", .{_shell.nodeName(&handler.node)});
        var it = vector.servers.iterator();
        while (it.next()) |node| shell.print(" server \"%s\" (%d)", .{ _shell.nodeName(node), node.pri });
        shell.print("\n", .{});
    }
}

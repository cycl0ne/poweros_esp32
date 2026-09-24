// SPDX-License-Identifier: MPL-2.0
//! resources: exec's resource list, what OpenResource finds.

const sdk = @import("sdk");
const exec = @import("../../exec.zig");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "resources";
pub const usage = "resources";
pub const help =
    \\  resources            exec's resources (OpenResource)
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    shell.print("base        name                    pri\n", .{});
    sys.Forbid();
    defer sys.Permit();
    var it = shell.base.resource_list.iterator();
    while (it.next()) |node| shell.print("0x%08x  %-22s %4d\n", .{ @intFromPtr(node), _shell.nodeName(node), node.pri });
}

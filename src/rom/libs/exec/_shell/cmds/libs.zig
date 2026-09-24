// SPDX-License-Identifier: MPL-2.0
//! libs: exec's library list.

const sdk = @import("sdk");
const exec = @import("../../exec.zig");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "libs";
pub const usage = "libs";
pub const help =
    \\  libs                 list exec's libraries
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    shell.print("base        name                   version  open  flags\n", .{});
    sys.Forbid();
    defer sys.Permit();
    var it = shell.base.lib_list.iterator();
    while (it.next()) |node| {
        const lib: *sdk.exec.Library = @fieldParentPtr("node", node);
        const pending = if (lib.flags & sdk.exec.LIBF_DELEXP != 0) "  expunge pending" else "";
        shell.print("0x%08x  %-22s %3d.%-4d %4d  0x%02x%s\n", .{ @intFromPtr(lib), lib.name(), lib.version, lib.revision, lib.open_cnt, lib.flags, pending });
    }
}

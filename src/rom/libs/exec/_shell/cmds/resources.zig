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

/// What is printed of one resource, copied out under the list's lock.
const Row = struct {
    address: usize,
    name: [23]u8,
    pri: i8,
};

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    var rows: [_shell.max_rows]Row = undefined;
    var count: usize = 0;
    var more: u32 = 0;
    const list = sys.LockExecList(sdk.exec.EXECLIST_RESOURCES).?;
    var it = list.iterator();
    while (it.next()) |node| {
        if (count == rows.len) {
            more += 1;
            continue;
        }
        rows[count] = .{ .address = @intFromPtr(node), .name = undefined, .pri = node.pri };
        _ = _shell.copyName(&rows[count].name, node.name);
        count += 1;
    }
    sys.UnlockExecList(sdk.exec.EXECLIST_RESOURCES);

    shell.print("base        name                    pri\n", .{});
    for (rows[0..count]) |*row| shell.print("0x%08x  %-22s %4d\n", .{ row.address, @as([*:0]const u8, @ptrCast(&row.name)), row.pri });
    if (more != 0) shell.print("... and %u more\n", .{more});
}

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

/// What is printed of one library, copied out under the list's lock.
const Row = struct {
    address: usize,
    name: [23]u8,
    version: u16,
    revision: u16,
    open_cnt: u16,
    flags: u8,
};

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    var rows: [_shell.max_rows]Row = undefined;
    var count: usize = 0;
    var more: u32 = 0;
    const list = sys.LockExecList(sdk.exec.EXECLIST_LIBRARIES).?;
    var it = list.iterator();
    while (it.next()) |node| {
        if (count == rows.len) {
            more += 1;
            continue;
        }
        const lib: *sdk.exec.Library = @fieldParentPtr("node", node);
        rows[count] = .{ .address = @intFromPtr(lib), .name = undefined, .version = lib.version, .revision = lib.revision, .open_cnt = lib.open_cnt, .flags = lib.flags };
        _ = _shell.copyName(&rows[count].name, node.name);
        count += 1;
    }
    sys.UnlockExecList(sdk.exec.EXECLIST_LIBRARIES);

    shell.print("base        name                   version  open  flags\n", .{});
    for (rows[0..count]) |*row| {
        const pending = if (row.flags & sdk.exec.LIBF_DELEXP != 0) "  expunge pending" else "";
        shell.print("0x%08x  %-22s %3d.%-4d %4d  0x%02x%s\n", .{ row.address, @as([*:0]const u8, @ptrCast(&row.name)), row.version, row.revision, row.open_cnt, row.flags, pending });
    }
    if (more != 0) shell.print("... and %u more\n", .{more});
}

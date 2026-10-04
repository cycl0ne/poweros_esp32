// SPDX-License-Identifier: MPL-2.0
//! memlist: exec's memory regions, the MemHeaders on its memory list.

const sdk = @import("sdk");
const exec = @import("../../exec.zig");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "memlist";
pub const usage = "memlist";
pub const help =
    \\  memlist              exec's memory regions (MemHeaders)
    \\
;

/// What is printed of one region, copied out under exec's memory lock.
const Row = struct {
    address: usize,
    lower: usize,
    upper: usize,
    pri: i8,
    free: u32,
    attributes: u32,
    name: [23]u8,
};

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    var rows: [_shell.max_rows]Row = undefined;
    var count: usize = 0;
    var more: u32 = 0;
    const list = sys.LockExecList(sdk.exec.EXECLIST_MEMORY).?;
    var it = list.iterator();
    while (it.next()) |node| {
        if (count == rows.len) {
            more += 1;
            continue;
        }
        const mh: *sdk.exec.MemHeader = @fieldParentPtr("node", node);
        rows[count] = .{ .address = @intFromPtr(mh), .lower = @intFromPtr(mh.lower), .upper = @intFromPtr(mh.upper), .pri = node.pri, .free = @intCast(mh.free), .attributes = mh.attributes, .name = undefined };
        _ = _shell.copyName(&rows[count].name, node.name);
        count += 1;
    }
    sys.UnlockExecList(sdk.exec.EXECLIST_MEMORY);

    shell.print("header      range                    pri  free      attributes          name\n", .{});
    for (rows[0..count]) |*row| {
        var buf: [48]u8 = undefined;
        var n: usize = 0;
        const names = [_]struct { flag: u32, name: []const u8 }{
            .{ .flag = sdk.exec.MEMF_INTERNAL, .name = "internal" },
            .{ .flag = sdk.exec.MEMF_EXTERNAL, .name = "external" },
            .{ .flag = sdk.exec.MEMF_DMA, .name = "dma" },
        };
        for (names) |attribute| {
            if (row.attributes & attribute.flag == 0) continue;
            @memcpy(buf[n..][0..attribute.name.len], attribute.name);
            buf[n + attribute.name.len] = ' ';
            n += attribute.name.len + 1;
        }
        buf[n] = 0;
        shell.print("0x%08x  0x%08x-0x%08x  %4d  %8d  %-18s  %s\n", .{
            row.address,                             row.lower, row.upper,
            row.pri,                                 row.free,  buf[0..n :0],
            @as([*:0]const u8, @ptrCast(&row.name)),
        });
    }
    if (more != 0) shell.print("... and %u more\n", .{more});
}

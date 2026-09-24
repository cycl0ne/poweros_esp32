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

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    shell.print("header      range                    pri  free      attributes          name\n", .{});
    sys.Forbid();
    defer sys.Permit();
    var it = shell.base.mem_list.iterator();
    while (it.next()) |node| {
        const mh: *sdk.exec.MemHeader = @fieldParentPtr("node", node);
        var buf: [48]u8 = undefined;
        var n: usize = 0;
        const names = [_]struct { flag: u32, name: []const u8 }{
            .{ .flag = sdk.exec.MEMF_INTERNAL, .name = "internal" },
            .{ .flag = sdk.exec.MEMF_EXTERNAL, .name = "external" },
            .{ .flag = sdk.exec.MEMF_DMA, .name = "dma" },
        };
        for (names) |attribute| {
            if (mh.attributes & attribute.flag == 0) continue;
            @memcpy(buf[n..][0..attribute.name.len], attribute.name);
            buf[n + attribute.name.len] = ' ';
            n += attribute.name.len + 1;
        }
        buf[n] = 0;
        shell.print("0x%08x  0x%08x-0x%08x  %4d  %8d  %-18s  %s\n", .{
            @intFromPtr(mh), @intFromPtr(mh.lower), @intFromPtr(mh.upper),
            mh.node.pri,     mh.free,               buf[0..n :0],
            mh.name(),
        });
    }
}

// SPDX-License-Identifier: MPL-2.0
//! padimage <in.bin> <out.bin> <bytes>: a disk image made as large as its
//! disk, the rest erased (0xFF). mkfs writes only the blocks it touched
//! and stops there, which on flash leaves the rest as the chip has it -
//! erased. A disk image the loader puts in RAM (a RISC-V 64 machine's,
//! src/rom/devs/flash/rv64sbi/ramflash.zig) is the whole disk, so it has
//! to have every byte of it.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: padimage <in.bin> <out.bin> <bytes>\n", .{});
        std.process.exit(2);
    }
    const size = std.fmt.parseInt(usize, args[3], 0) catch return fail("{s} is not a size", .{args[3]});
    const cwd = std.Io.Dir.cwd();
    const image = try cwd.readFileAlloc(io, args[1], arena, .limited(size + 1));
    if (image.len > size) return fail("{s} is larger than {d} bytes", .{ args[1], size });
    const out = try arena.alloc(u8, size);
    @memcpy(out[0..image.len], image);
    @memset(out[image.len..], 0xFF);
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out });
}

fn fail(comptime format: []const u8, args: anytype) error{Invalid} {
    std.debug.print("padimage: " ++ format ++ "\n", args);
    return error.Invalid;
}

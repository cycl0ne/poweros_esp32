// SPDX-License-Identifier: MPL-2.0
//! audiogolden <out.pcm>: the golden mix of audio.device's mixer written
//! as its reference file (`src/rom/devs/audio/golden.zig`). Run by
//! `./zig build audio-golden` after a change to the mixer that is meant to
//! change what is heard; the test then holds the mixer to the new file.

const std = @import("std");
const golden = @import("golden");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: audiogolden <out.pcm>\n", .{});
        std.process.exit(2);
    }
    const mix = try arena.create([golden.frames * 2]i16);
    golden.render(mix);
    const bytes = try arena.create([golden.bytes]u8);
    golden.bytesOf(mix, bytes);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = bytes });
}

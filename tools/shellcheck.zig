// SPDX-License-Identifier: MPL-2.0
//! shellcheck <_shell>: fail when a command file in `<_shell>/cmds/` is
//! missing from the command list in `<_shell>/shell.zig`.
//!
//! The kernel shell's table and its `help` are made at compile time from
//! that list, and Zig cannot list a directory, so a command file nobody
//! added to it would build and never run. Every `cmds/<name>.zig` has to
//! appear there as `@import("cmds/<name>.zig")`; a missing one is reported
//! and the tool exits non-zero.

const std = @import("std");
const mem = std.mem;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: shellcheck <_shell>\n", .{});
        std.process.exit(2);
    }

    var shell_dir = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer shell_dir.close(io);
    const list = try shell_dir.readFileAlloc(io, "shell.zig", arena, .unlimited);
    var cmds = try shell_dir.openDir(io, "cmds", .{ .iterate = true });
    defer cmds.close(io);

    var missing: u32 = 0;
    var it = cmds.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.name, ".zig")) continue;
        const wanted = try std.fmt.allocPrint(arena, "@import(\"cmds/{s}\")", .{entry.name});
        if (mem.indexOf(u8, list, wanted) != null) continue;
        std.debug.print("{s}/cmds/{s}: not in shell.zig's command list\n", .{ args[1], entry.name });
        missing += 1;
    }
    if (missing != 0) std.process.exit(1);
}

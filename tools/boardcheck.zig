// SPDX-License-Identifier: MPL-2.0
//! boardcheck <src>: fail when a module reaches into what is the kernel's.
//!
//! Two rules, checked on every `.zig` file under `<src>`:
//!
//! - **The board's description** (`src/boards/`) is imported only by the
//!   kernel's own code: `main.zig`, which links the board's ROM tags and its
//!   system tag list, `arch/`, which runs before any library does, and
//!   `boards/` itself. A module asks
//!   expansion.library for its part.
//! - **exec's hardware** (`src/arch/`) is imported by the kernel, exec, and
//!   platform.resource, which reports the kernel's own measurements. A
//!   module's peripheral is in its own folder or in `sdk/hardware/`.
//!
//! Each `@import("...")` of a path is resolved against the file's
//! directory; one that breaks a rule is reported with its file and line,
//! and the tool exits non-zero.

const std = @import("std");
const mem = std.mem;
const path = std.fs.path;

const Rule = struct {
    /// What is guarded, as a prefix of a resolved path under `<src>`.
    target: []const u8,
    /// Who may import it: a file name, or a directory ending in "/".
    allowed: []const []const u8,
    why: []const u8,
};

const rules = [_]Rule{
    .{
        .target = "boards/",
        .allowed = &.{ "main.zig", "arch/", "boards/" },
        .why = "a module asks expansion.library for its part",
    },
    .{
        .target = "arch/",
        .allowed = &.{ "main.zig", "bootstrap.zig", "arch/", "rom/libs/exec/", "rom/resources/platform/" },
        .why = "a module's peripheral is in its own folder or in sdk/hardware",
    },
};

fn isAllowed(file: []const u8, allowed: []const []const u8) bool {
    for (allowed) |prefix| {
        if (mem.endsWith(u8, prefix, "/")) {
            if (mem.startsWith(u8, file, prefix)) return true;
        } else if (mem.eql(u8, file, prefix)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: boardcheck <src>\n", .{});
        std.process.exit(2);
    }

    var src = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(arena);
    defer walker.deinit();

    var found: u32 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.basename, ".zig")) continue;
        const file = try arena.dupe(u8, entry.path);
        const text = try src.readFileAlloc(io, file, arena, .unlimited);
        const dir = path.dirname(file) orelse "";

        var line_number: u32 = 1;
        var lines = mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| : (line_number += 1) {
            var rest = line;
            while (mem.indexOf(u8, rest, "@import(\"")) |at| {
                rest = rest[at + "@import(\"".len ..];
                const end = mem.indexOfScalar(u8, rest, '"') orelse break;
                const target = rest[0..end];
                rest = rest[end..];
                if (!mem.endsWith(u8, target, ".zig")) continue;
                const resolved = try path.resolvePosix(arena, &.{ dir, target });
                for (rules) |rule| {
                    if (!mem.startsWith(u8, resolved, rule.target)) continue;
                    if (isAllowed(file, rule.allowed)) continue;
                    std.debug.print("{s}/{s}:{d}: imports {s}; {s}\n", .{ args[1], file, line_number, target, rule.why });
                    found += 1;
                }
            }
        }
    }
    if (found != 0) std.process.exit(1);
}

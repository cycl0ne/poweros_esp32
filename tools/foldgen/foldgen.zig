// SPDX-License-Identifier: MPL-2.0
//! foldgen <CaseFolding.txt> <out.zig>: writes posfs's case fold table
//! (sdk/libs/dos/posfs/fold1.zig) from the Unicode Character Database's
//! CaseFolding.txt.
//!
//! The table is simple case folding: the file's C and S lines, one code
//! point to one, without the full (F) and the Turkic (T) ones. It is part
//! of the format - a name's hash is the hash of its folded form - so a
//! table once written is never written again: a later Unicode version
//! becomes a table of its own (`fold2.zig`), and a directory says which it
//! was made with. This tool is run once per table, by hand; the build
//! does not run it.
//!
//! The mappings come in runs: code points one or two apart that all move
//! by the same amount (A-Z by +32; Ā, Ă, Ą... by +1 every second one).
//! The table is those runs, 210 for Unicode 16 against 1484 mappings, each
//! one packed into a u64, found by a binary search.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;

const Mapping = struct { from: u21, to: u21 };
const Run = struct { first: u21, count: u8, stride: u2, delta: i32 };

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("foldgen: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) fatal("usage: foldgen <CaseFolding.txt> <out.zig>", .{});
    const cwd = Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, args[1], arena, .limited(4 * 1024 * 1024));

    var version: []const u8 = "";
    var mappings: std.ArrayList(Mapping) = .empty;
    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (version.len == 0 and mem.startsWith(u8, line, "# CaseFolding-")) {
            version = mem.trim(u8, line["# CaseFolding-".len..], " .txt");
        }
        const data = mem.trim(u8, line[0 .. mem.indexOfScalar(u8, line, '#') orelse line.len], " \t");
        if (data.len == 0) continue;
        var fields = mem.splitScalar(u8, data, ';');
        const from = mem.trim(u8, fields.next() orelse continue, " ");
        const status = mem.trim(u8, fields.next() orelse continue, " ");
        const to = mem.trim(u8, fields.next() orelse continue, " ");
        if (!mem.eql(u8, status, "C") and !mem.eql(u8, status, "S")) continue;
        try mappings.append(arena, .{
            .from = try std.fmt.parseInt(u21, from, 16),
            .to = try std.fmt.parseInt(u21, to, 16),
        });
    }
    if (version.len == 0) fatal("{s}: no CaseFolding version line", .{args[1]});
    std.mem.sort(Mapping, mappings.items, {}, struct {
        fn lessThan(_: void, a: Mapping, b: Mapping) bool {
            return a.from < b.from;
        }
    }.lessThan);

    var runs: std.ArrayList(Run) = .empty;
    const all = mappings.items;
    var at: usize = 0;
    while (at < all.len) {
        const delta: i32 = @as(i32, all[at].to) - @as(i32, all[at].from);
        var count: usize = 1;
        var stride: u21 = 1;
        if (at + 1 < all.len) {
            const step = all[at + 1].from - all[at].from;
            const next_delta: i32 = @as(i32, all[at + 1].to) - @as(i32, all[at + 1].from);
            if ((step == 1 or step == 2) and next_delta == delta) {
                stride = step;
                count = 2;
                while (at + count < all.len and count < 255) : (count += 1) {
                    const here = all[at + count];
                    if (here.from - all[at + count - 1].from != stride) break;
                    if (@as(i32, here.to) - @as(i32, here.from) != delta) break;
                }
            }
        }
        try runs.append(arena, .{ .first = all[at].from, .count = @intCast(count), .stride = @intCast(stride), .delta = delta });
        at += count;
    }

    var out: std.ArrayList(u8) = .empty;
    const writer = &out;
    try writer.print(arena,
        \\// SPDX-License-Identifier: MIT
        \\//! posfs's case fold 1: Unicode {s} simple case folding (the C and S
        \\//! lines of CaseFolding.txt), as runs of code points that fold by the
        \\//! same amount. Written by tools/foldgen and frozen: it is part of the
        \\//! format, and a later table is a file of its own.
        \\//!
        \\//! {d} mappings in {d} runs, sorted by their first code point.
        \\
        \\/// The Unicode version the table is from.
        \\pub const unicode_version = "{s}";
        \\
        \\/// Code points `first`, `first + stride`, ... (`count` of them) each
        \\/// fold to themselves plus `delta`.
        \\pub const Run = packed struct(u64) {{
        \\    first: u21,
        \\    count: u8,
        \\    stride: u2,
        \\    delta: i32,
        \\    reserved: u1 = 0,
        \\}};
        \\
        \\pub const runs = [_]Run{{
        \\
    , .{ version, all.len, runs.items.len, version });
    for (runs.items) |run| {
        try writer.print(arena, "    .{{ .first = 0x{X:0>4}, .count = {d}, .stride = {d}, .delta = {d} }},\n", .{ run.first, run.count, run.stride, run.delta });
    }
    try writer.appendSlice(arena, "};\n");
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.items });
}

// SPDX-License-Identifier: MPL-2.0
//! sums <dir>: the SHA-256 of every archive in a release directory,
//! written to `<dir>/SHA256SUMS` in the form `sha256sum -c` reads - the
//! digest in lower-case hex, two spaces, the name - so that somebody who
//! downloaded one can hold it against what was built, and so that a
//! build can be named later by the sum of what came out of it.
//!
//! It sums what is in the directory rather than what a build graph says
//! should be: a release is assembled by more than one run. The
//! `SYS:Storage/Boot` of a disk image is filled for the board the build
//! was for and empty for the others, so a whole set of archives comes
//! from one `release` run per board, and only the directory knows which
//! ones were kept. That is also why `SHA256SUMS` is written last and on
//! its own - `./zig build sums` after the last run.
//!
//! Every `*.tar.gz` counts and nothing else does: the packages beside
//! them are directories with a manifest of their own over them, which
//! already holds a length and a CRC-32 for every file in them.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;

/// What the list is called, as the other such files are.
const list_name = "SHA256SUMS";

/// What an archive's name ends in.
const suffix = ".tar.gz";

/// The largest archive that will be read in one piece. The archives are
/// six to ten megabytes; this is only there so that a wrong directory
/// cannot ask for a machine's worth of memory.
const largest: usize = 512 * 1024 * 1024;

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("sums: " ++ format ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) fatal("usage: sums <release dir>", .{});
    const dir_path = args[1];

    const cwd = Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err|
        fatal("{s}: {t}", .{ dir_path, err });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.name, suffix)) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    if (names.items.len == 0)
        fatal("{s} holds no {s}: `./zig build release -Ddisk-tree=false` makes them", .{ dir_path, suffix });

    // In name order, so that two runs over the same archives write the
    // same file and a line can be found by eye.
    mem.sort([]const u8, names.items, {}, lessThan);

    const Sha256 = std.crypto.hash.sha2.Sha256;
    var list: std.ArrayList(u8) = .empty;
    for (names.items) |name| {
        const content = dir.readFileAlloc(io, name, gpa, .limited(largest)) catch |err|
            fatal("{s}/{s}: {t}", .{ dir_path, name, err });
        defer gpa.free(content);
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(content, &digest, .{});
        try list.print(arena, "{x}  {s}\n", .{ &digest, name });
    }
    try dir.writeFile(io, .{ .sub_path = list_name, .data = list.items });
    std.debug.print("sums: {d} archives -> {s}/{s}\n", .{ names.items.len, dir_path, list_name });
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return mem.order(u8, left, right) == .lt;
}

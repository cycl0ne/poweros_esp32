// SPDX-License-Identifier: MPL-2.0
//! mkpackage: gathers a release package - the volume's files, the kernel
//! and the files the firmware reads - into one directory and writes the
//! manifest over it, so a machine installs from that directory and is
//! later brought up to date against it.
//!
//! usage: mkpackage --into=<dir> --chip=<chip> [--board=<name>]
//!                  [--system=<dir>] [<path in the package>=<file> ...]
//!        mkpackage --check <dir>
//!
//! A package has two halves, and every path in it begins with one
//! (`sdk.install`): `system/` is the volume - what is under `SYS:` on an
//! installed disk - and `boot/` is what the board's firmware loads, each
//! file under the name that firmware looks for. `--system=<dir>` copies a
//! whole tree in under `system/`, drawers with nothing in them included;
//! an argument with `=` is one file, `boot/kernel.bin=<file on the host>`.
//!
//! Then the finished directory is walked and `<dir>/manifest` written
//! from what is in it: a line for each drawer and file, the length and
//! the CRC-32 of the bytes that are there (`sdk.install.manifest`). The
//! manifest is of the package as it is, not as a build meant it to be,
//! and it is written last - so it is also the mark of a package that was
//! gathered to the end.
//!
//! **CHIP and BOARD.** Every machine's package holds the same paths, so
//! the manifest says which chip the files are built for; and two boards
//! share a chip while their kernels differ in what the board has and
//! where it is, so a package with a kernel says which board as well. A
//! command on the machine compares both against the machine it is
//! installing onto before it writes anything.
//!
//! `--check <dir>` is the other direction: the manifest is read and held
//! against the directory - every line's length and sum, and every file
//! and drawer in the directory named by a line. It is what the build runs
//! over a package it has just gathered, and what says a copied or
//! downloaded package arrived whole.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const Allocator = mem.Allocator;
const sdk = @import("sdk");
const install = sdk.install;
const manifest = install.manifest;

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("mkpackage: " ++ format ++ "\n", args);
    std.process.exit(1);
}

/// The longest line a manifest can hold: a path at its longest, a sum,
/// a length and the word before it.
const max_line = manifest.max_path + 64;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(arena);
    var into: ?[]const u8 = null;
    var chip: ?sdk.hardware.Chip = null;
    var board: []const u8 = &.{};
    var system: ?[]const u8 = null;
    var check: ?[]const u8 = null;
    var given: std.ArrayList([]const u8) = .empty;
    for (all_args, 0..) |arg, index| {
        if (index == 0) continue;
        if (mem.startsWith(u8, arg, "--into=")) {
            into = arg["--into=".len..];
        } else if (mem.startsWith(u8, arg, "--chip=")) {
            const name = arg["--chip=".len..];
            chip = std.meta.stringToEnum(sdk.hardware.Chip, name) orelse fatal("{s}: no such chip", .{name});
        } else if (mem.startsWith(u8, arg, "--board=")) {
            board = arg["--board=".len..];
            if (!manifest.boardOk(board)) fatal("{s}: no board is named that", .{board});
        } else if (mem.startsWith(u8, arg, "--system=")) {
            system = arg["--system=".len..];
        } else if (mem.eql(u8, arg, "--check")) {
            check = "";
        } else if (mem.startsWith(u8, arg, "--")) {
            fatal("{s}: no such option", .{arg});
        } else if (check != null and check.?.len == 0) {
            check = arg;
        } else {
            try given.append(arena, arg);
        }
    }

    const cwd = Io.Dir.cwd();
    if (check) |dir_path| {
        if (dir_path.len == 0) fatal("--check: it takes the package's directory", .{});
        try checkPackage(io, cwd, dir_path, init.gpa, arena);
        return;
    }
    const into_path = into orelse fatal("usage: mkpackage --into=<dir> --chip=<chip> [--board=<name>] [--system=<dir>] [<path>=<file> ...]", .{});
    const for_chip = chip orelse fatal("--chip: a package says which chip its files are built for", .{});

    try cwd.createDirPath(io, into_path);
    var package = cwd.openDir(io, into_path, .{ .iterate = true }) catch |err|
        fatal("{s}: {s}", .{ into_path, @errorName(err) });
    defer package.close(io);

    // The volume's files, drawers with nothing in them included: an empty
    // WBStartup or Trashcan is part of an installed system.
    if (system) |tree| {
        var source = cwd.openDir(io, tree, .{ .iterate = true }) catch |err|
            fatal("{s}: {s}", .{ tree, @errorName(err) });
        defer source.close(io);
        const half = install.half_names[@intFromEnum(install.Half.system)];
        try package.createDirPath(io, half);
        var walker = try source.walk(init.gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ half, entry.path });
            switch (entry.kind) {
                .directory => package.createDirPath(io, path) catch |err|
                    fatal("{s}: {s}", .{ path, @errorName(err) }),
                .file => {
                    if (std.fs.path.dirname(path)) |parent| try package.createDirPath(io, parent);
                    entry.dir.copyFile(entry.basename, package, path, io, .{}) catch |err|
                        fatal("{s}: {s}", .{ path, @errorName(err) });
                },
                else => fatal("{s}/{s}: neither a file nor a drawer", .{ tree, entry.path }),
            }
        }
    }

    // The files named one by one: the kernel, the disk image, whatever
    // the board's firmware reads beside them.
    for (given.items) |entry| {
        const split = mem.indexOfScalar(u8, entry, '=') orelse
            fatal("{s}: it is <path in the package>=<file on the host>", .{entry});
        const path = entry[0..split];
        const host = entry[split + 1 ..];
        if (!manifest.pathOk(path)) fatal("{s}: no path in a package", .{path});
        if (install.halfOf(path) == null) fatal("{s}: it is in neither half - system/ or boot/", .{path});
        if (std.fs.path.dirname(path)) |parent| try package.createDirPath(io, parent);
        cwd.copyFile(host, package, path, io, .{}) catch |err|
            fatal("{s}: {s}", .{ host, @errorName(err) });
    }

    // The manifest of what is now there, written last.
    const entries = try entriesOf(io, package, init.gpa, arena);
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, manifest.preamble);
    var counts: manifest.Counts = .{};
    for (entries) |entry| counts.add(entry);
    var head: [manifest.max_header]u8 = undefined;
    const header: manifest.Header = .{ .chip = for_chip, .board = board, .counts = counts };
    try text.appendSlice(arena, head[0..manifest.headerLine(header, &head)]);
    var line: [max_line]u8 = undefined;
    for (entries) |entry| try text.appendSlice(arena, line[0..manifest.entryLine(entry, &line)]);
    try package.writeFile(io, .{ .sub_path = install.package_manifest, .data = text.items });
}

/// Every drawer and file under `package`, sorted as the manifest has
/// them, its own manifest left out: it is the list of the rest, and is
/// written after they are all there.
fn entriesOf(io: Io, package: Io.Dir, gpa: Allocator, arena: Allocator) ![]manifest.Entry {
    var entries: std.ArrayList(manifest.Entry) = .empty;
    var walker = try package.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (mem.eql(u8, entry.path, install.package_manifest)) continue;
        const path = try arena.dupe(u8, entry.path);
        if (!manifest.pathOk(path)) fatal("{s}: a manifest cannot name this file", .{path});
        switch (entry.kind) {
            .directory => try entries.append(arena, .{ .kind = .drawer, .path = path }),
            .file => {
                const content = entry.dir.readFileAlloc(io, entry.basename, gpa, .unlimited) catch |err|
                    fatal("{s}: {s}", .{ path, @errorName(err) });
                defer gpa.free(content);
                try entries.append(arena, .{
                    .kind = .file,
                    .path = path,
                    .crc = std.hash.Crc32.hash(content),
                    .size = content.len,
                });
            },
            else => fatal("{s}: neither a file nor a drawer", .{path}),
        }
    }
    const Sort = struct {
        fn before(_: void, a: manifest.Entry, b: manifest.Entry) bool {
            return manifest.orderPaths(a.path, b.path) == .before;
        }
    };
    mem.sort(manifest.Entry, entries.items, {}, Sort.before);
    // Two names a volume cannot tell apart are two files here and one
    // there, and which of them arrived would be the order of a walk.
    if (entries.items.len > 1) {
        for (entries.items[1..], entries.items[0 .. entries.items.len - 1]) |entry, before| {
            if (manifest.samePath(before.path, entry.path))
                fatal("{s} and {s}: one name on a volume", .{ before.path, entry.path });
        }
    }
    return entries.items;
}

/// A package held against its own manifest: every line's length and sum
/// as the file has them, and nothing in the directory that no line names.
fn checkPackage(io: Io, cwd: Io.Dir, dir_path: []const u8, gpa: Allocator, arena: Allocator) !void {
    var package = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err|
        fatal("{s}: {s}", .{ dir_path, @errorName(err) });
    defer package.close(io);
    const text = package.readFileAlloc(io, install.package_manifest, arena, .unlimited) catch |err|
        fatal("{s}/{s}: {s}", .{ dir_path, install.package_manifest, @errorName(err) });

    const there = try entriesOf(io, package, gpa, arena);
    var reader = manifest.Reader.init(text) catch |err|
        fatal("{s}/{s}: {s}", .{ dir_path, install.package_manifest, mem.span(manifest.why(err)) });
    var at: usize = 0;
    var wrong: usize = 0;
    while (reader.next() catch |err| fatal("{s}: {s}", .{ dir_path, mem.span(manifest.why(err)) })) |entry| {
        // Both lists are in the manifest's order, so they are walked
        // together: a line with nothing there, or a file with no line.
        while (at < there.len and manifest.orderPaths(there[at].path, entry.path) == .before) {
            std.debug.print("mkpackage: {s}: in the package and in no line\n", .{there[at].path});
            wrong += 1;
            at += 1;
        }
        if (at == there.len or !manifest.samePath(there[at].path, entry.path)) {
            std.debug.print("mkpackage: {s}: in the manifest and not in the package\n", .{entry.path});
            wrong += 1;
            continue;
        }
        const found = there[at];
        at += 1;
        if (found.kind != entry.kind) {
            std.debug.print("mkpackage: {s}: a {s} where the manifest says {s}\n", .{ entry.path, @tagName(found.kind), @tagName(entry.kind) });
            wrong += 1;
        } else if (entry.kind == .file and (found.size != entry.size or found.crc != entry.crc)) {
            std.debug.print("mkpackage: {s}: {d} bytes summing {x:0>8}, where the manifest says {d} and {x:0>8}\n", .{ entry.path, found.size, found.crc, entry.size, entry.crc });
            wrong += 1;
        }
    }
    while (at < there.len) : (at += 1) {
        std.debug.print("mkpackage: {s}: in the package and in no line\n", .{there[at].path});
        wrong += 1;
    }
    if (wrong != 0) fatal("{s}: {d} of them", .{ dir_path, wrong });
}

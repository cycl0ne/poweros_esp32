// SPDX-License-Identifier: MPL-2.0
//! autodoc [--check] <fd dir> <rom dir> <out dir>: a reference per module,
//! made from the doc comments of its calls.
//!
//! For every `<stem>_lib.fd` in <fd dir> it writes `<stem>.doc`, plain
//! text, and `<stem>.md`, Markdown, into <out dir>: the module's name and
//! description, an index of its public calls, then each call in
//! alphabetical order. A call's text is the `///` block above its
//! `pub fn <Name>(` somewhere under `<rom dir>/{libs,devs,resources}/<stem>/`,
//! split at the section headers (`SYNOPSIS:`, `INPUTS:`, ...). A call
//! with no such block gets its `.fd` text instead: the prototype as
//! SYNOPSIS, the rest as BEHAVIOR.
//!
//! With --check it writes nothing and fails if a file in <out dir> is not
//! what it would write, or has no `.fd` any more: the build's check that
//! the autodocs are up to date. Without it, such a leftover is removed.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const Allocator = mem.Allocator;

/// The section headers of a call's doc comment, in the order written.
const sections = [_][]const u8{
    "SYNOPSIS",  "SINCE", "INPUTS", "RESULT",   "BEHAVIOR", "CONTEXT",
    "OWNERSHIP", "NOTES", "BUGS",   "SEE ALSO", "EXAMPLES",
};

/// Where a module's source may live, under <rom dir>.
const homes = [_][]const u8{ "libs", "devs", "resources" };

const Section = struct { title: []const u8, lines: []const []const u8 };

const Call = struct {
    name: []const u8,
    summary: []const u8,
    sections: []const Section,
};

const Module = struct {
    name: []const u8,
    about: []const []const u8,
    calls: []Call,
};

/// A public call as the `.fd` has it.
const FdCall = struct { name: []const u8, prototype: []const u8, doc: []const []const u8 };

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("autodoc: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const check = args.len == 5 and mem.eql(u8, args[1], "--check");
    if (args.len != 4 and !check) fatal("usage: autodoc [--check] <fd dir> <rom dir> <out dir>", .{});
    const fd_path = args[args.len - 3];
    const rom_path = args[args.len - 2];
    const out_path = args[args.len - 1];

    const cwd = Io.Dir.cwd();
    var fd_dir = try cwd.openDir(io, fd_path, .{ .iterate = true });
    defer fd_dir.close(io);
    var rom_dir = try cwd.openDir(io, rom_path, .{});
    defer rom_dir.close(io);
    if (!check) try cwd.createDirPath(io, out_path);
    var out_dir = try cwd.openDir(io, out_path, .{ .iterate = true });
    defer out_dir.close(io);

    var stems: std.ArrayList([]const u8) = .empty;
    var it = fd_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.name, "_lib.fd")) continue;
        try stems.append(arena, try arena.dupe(u8, entry.name[0 .. entry.name.len - "_lib.fd".len]));
    }

    var stale: u32 = 0;
    for (stems.items) |stem| {
        const fd_name = try std.fmt.allocPrint(arena, "{s}_lib.fd", .{stem});
        const fd = try fd_dir.readFileAlloc(io, fd_name, arena, .unlimited);
        const source = try findHome(io, rom_dir, stem) orelse
            fatal("{s}/{s}: no {s}/{{libs,devs,resources}}/{s}/ holds its source", .{ fd_path, fd_name, rom_path, stem });
        var home = source;
        defer home.close(io);
        const module = try readModule(io, arena, fd_name, fd, home);

        const outputs = [_]struct { ext: []const u8, text: []const u8 }{
            .{ .ext = "doc", .text = try writeDoc(arena, module) },
            .{ .ext = "md", .text = try writeMarkdown(arena, module) },
        };
        for (outputs) |output| {
            const name = try std.fmt.allocPrint(arena, "{s}.{s}", .{ stem, output.ext });
            if (check) {
                const current = out_dir.readFileAlloc(io, name, arena, .unlimited) catch "";
                if (mem.eql(u8, current, output.text)) continue;
                std.debug.print("autodoc: {s}/{s} is out of date: run `./zig build autodoc`\n", .{ out_path, name });
                stale += 1;
            } else {
                try out_dir.writeFile(io, .{ .sub_path = name, .data = output.text });
            }
        }
    }

    // A .doc or .md whose module has no .fd any more.
    var leftovers: std.ArrayList([]const u8) = .empty;
    var out_it = out_dir.iterate();
    while (try out_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const dot = mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
        const ext = entry.name[dot + 1 ..];
        if (!mem.eql(u8, ext, "doc") and !mem.eql(u8, ext, "md")) continue;
        const stem = entry.name[0..dot];
        for (stems.items) |known| {
            if (mem.eql(u8, known, stem)) break;
        } else try leftovers.append(arena, try arena.dupe(u8, entry.name));
    }
    for (leftovers.items) |name| {
        if (check) {
            std.debug.print("autodoc: {s}/{s} has no .fd: run `./zig build autodoc`\n", .{ out_path, name });
            stale += 1;
        } else {
            try out_dir.deleteFile(io, name);
        }
    }
    if (stale != 0) std.process.exit(1);
}

/// The first of `<rom dir>/{libs,devs,resources}/<stem>/` there is, opened
/// to walk.
fn findHome(io: Io, rom_dir: Io.Dir, stem: []const u8) !?Io.Dir {
    var buffer: [256]u8 = undefined;
    for (homes) |home| {
        const sub = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ home, stem });
        return rom_dir.openDir(io, sub, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
    }
    return null;
}

/// A module: its `.fd`'s name, description and public calls, each with
/// the text its source gives it.
fn readModule(io: Io, arena: Allocator, fd_name: []const u8, fd: []const u8, home: Io.Dir) !Module {
    var name: []const u8 = "";
    var about: std.ArrayList([]const u8) = .empty;
    var fd_calls: std.ArrayList(FdCall) = .empty;
    var doc: std.ArrayList([]const u8) = .empty;
    var public = true;

    var lines = mem.splitScalar(u8, fd, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (mem.startsWith(u8, line, "//!")) {
            try about.append(arena, stripComment(line, "//!"));
        } else if (mem.startsWith(u8, line, "///")) {
            try doc.append(arena, stripComment(line, "///"));
        } else if (mem.startsWith(u8, line, "//")) {
            continue;
        } else if (mem.startsWith(u8, line, "##")) {
            if (mem.startsWith(u8, line, "##name")) name = mem.trim(u8, line["##name".len..], " \t");
            if (mem.eql(u8, line, "##public")) public = true;
            if (mem.eql(u8, line, "##private")) public = false;
            if (mem.eql(u8, line, "##end")) break;
        } else {
            defer doc.clearRetainingCapacity();
            if (!public) continue;
            const paren = mem.indexOfScalar(u8, line, '(') orelse fatal("{s}: not a function: {s}", .{ fd_name, line });
            const head = mem.trimEnd(u8, line[0..paren], " \t");
            const space = mem.lastIndexOfAny(u8, head, " \t") orelse fatal("{s}: not a function: {s}", .{ fd_name, line });
            try fd_calls.append(arena, .{
                .name = head[space + 1 ..],
                .prototype = line,
                .doc = try arena.dupe([]const u8, doc.items),
            });
        }
    }
    if (name.len == 0) fatal("{s}: no ##name", .{fd_name});

    // Every `pub fn` doc block under the module's folder, by name.
    var blocks: std.StringHashMapUnmanaged(Found) = .empty;
    var walker = try home.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try arena.dupe(u8, entry.path);
        const text = try entry.dir.readFileAlloc(io, entry.basename, arena, .unlimited);
        try collectBlocks(arena, &blocks, path, text);
    }

    const calls = try arena.alloc(Call, fd_calls.items.len);
    for (fd_calls.items, calls) |fd_call, *call| {
        call.* = if (blocks.get(fd_call.name)) |found|
            try fromBlock(arena, fd_call.name, found.lines)
        else
            try fromFd(arena, fd_call);
    }
    mem.sort(Call, calls, {}, struct {
        fn lessThan(_: void, a: Call, b: Call) bool {
            return mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return .{ .name = name, .about = about.items, .calls = calls };
}

/// A doc block found above a `pub fn`, and the file it is in.
const Found = struct { path: []const u8, lines: []const []const u8 };

/// Each `pub fn <Name>(` in `text` with a `///` block right above it. Two
/// files with a block for the same name: the first path in sort order
/// wins, so the walk's order does not matter.
fn collectBlocks(arena: Allocator, blocks: *std.StringHashMapUnmanaged(Found), path: []const u8, text: []const u8) !void {
    var all: std.ArrayList([]const u8) = .empty;
    var split = mem.splitScalar(u8, text, '\n');
    while (split.next()) |line| try all.append(arena, mem.trimEnd(u8, line, "\r"));
    const lines = all.items;

    for (lines, 0..) |line, index| {
        if (!mem.startsWith(u8, line, "pub fn ")) continue;
        const rest = line["pub fn ".len..];
        const paren = mem.indexOfScalar(u8, rest, '(') orelse continue;
        const name = rest[0..paren];
        var start = index;
        while (start > 0 and mem.startsWith(u8, lines[start - 1], "///")) start -= 1;
        if (start == index) continue;
        const block = try arena.alloc([]const u8, index - start);
        for (lines[start..index], block) |raw, *stripped| stripped.* = stripComment(raw, "///");
        const entry = try blocks.getOrPut(arena, name);
        if (entry.found_existing and mem.lessThan(u8, entry.value_ptr.path, path)) continue;
        entry.value_ptr.* = .{ .path = path, .lines = block };
    }
}

/// `line` without its comment marker and the one space after it.
fn stripComment(line: []const u8, marker: []const u8) []const u8 {
    const rest = line[marker.len..];
    return if (mem.startsWith(u8, rest, " ")) rest[1..] else rest;
}

/// The section `line` opens, and what follows the colon on it; null when
/// it opens none.
fn sectionHeader(line: []const u8) ?struct { title: []const u8, rest: []const u8 } {
    for (sections) |title| {
        if (line.len > title.len and mem.startsWith(u8, line, title) and line[title.len] == ':')
            return .{ .title = title, .rest = mem.trim(u8, line[title.len + 1 ..], " ") };
    }
    return null;
}

/// A call from its doc comment: the first paragraph is its summary, and
/// the section headers split the rest. Headers inside a code block are
/// text.
fn fromBlock(arena: Allocator, name: []const u8, block: []const []const u8) !Call {
    var summary: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < block.len and block[index].len != 0 and sectionHeader(block[index]) == null) : (index += 1) {
        if (summary.items.len != 0) try summary.append(arena, ' ');
        try summary.appendSlice(arena, mem.trim(u8, block[index], " "));
    }

    var found: std.ArrayList(Section) = .empty;
    var title: ?[]const u8 = null;
    var body: std.ArrayList([]const u8) = .empty;
    var in_code = false;
    for (block[index..]) |line| {
        if (!in_code) if (sectionHeader(line)) |header| {
            if (title) |t| try found.append(arena, .{ .title = t, .lines = try trimBlank(arena, body.items) });
            title = header.title;
            body = .empty;
            if (header.rest.len != 0) try body.append(arena, header.rest);
            continue;
        };
        if (mem.startsWith(u8, mem.trimStart(u8, line, " "), "```")) in_code = !in_code;
        if (title != null) try body.append(arena, line);
    }
    if (title) |t| try found.append(arena, .{ .title = t, .lines = try trimBlank(arena, body.items) });
    return .{ .name = name, .summary = summary.items, .sections = found.items };
}

/// A call from its `.fd` alone: the first sentence of its text is the
/// summary, the prototype its synopsis, the rest its behaviour.
fn fromFd(arena: Allocator, fd_call: FdCall) !Call {
    const text = try mem.join(arena, " ", fd_call.doc);
    const end = if (mem.indexOf(u8, text, ". ")) |dot| dot + 1 else text.len;
    const summary = text[0..end];
    const rest = mem.trim(u8, text[end..], " ");

    var found: std.ArrayList(Section) = .empty;
    const synopsis = try arena.dupe([]const u8, &.{ "```zig", fd_call.prototype, "```" });
    try found.append(arena, .{ .title = "SYNOPSIS", .lines = synopsis });
    if (rest.len != 0) try found.append(arena, .{ .title = "BEHAVIOR", .lines = try wrap(arena, rest, 72) });
    return .{ .name = fd_call.name, .summary = summary, .sections = found.items };
}

/// `text` broken into lines of at most `width`, at spaces.
fn wrap(arena: Allocator, text: []const u8, width: usize) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var words = mem.tokenizeScalar(u8, text, ' ');
    var line: std.ArrayList(u8) = .empty;
    while (words.next()) |word| {
        if (line.items.len != 0 and line.items.len + 1 + word.len > width) {
            try lines.append(arena, line.items);
            line = .empty;
        }
        if (line.items.len != 0) try line.append(arena, ' ');
        try line.appendSlice(arena, word);
    }
    if (line.items.len != 0) try lines.append(arena, line.items);
    return lines.items;
}

/// `lines` without the empty ones at either end.
fn trimBlank(arena: Allocator, lines: []const []const u8) ![]const []const u8 {
    var start: usize = 0;
    var end = lines.len;
    while (start < end and lines[start].len == 0) start += 1;
    while (end > start and lines[end - 1].len == 0) end -= 1;
    return arena.dupe([]const u8, lines[start..end]);
}

/// The plain-text form: a table of contents, then each call on a page of
/// its own (a form feed before it), headed by its full name at both
/// margins, its sections indented under their titles. Code blocks lose
/// their fences and are indented further.
fn writeDoc(arena: Allocator, module: Module) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("TABLE OF CONTENTS\n\n");
    for (module.calls) |call| try w.print("{s}/{s}\n", .{ module.name, call.name });

    for (module.calls) |call| {
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ module.name, call.name });
        try w.print("\x0c{s}", .{full});
        const gap = if (78 > 2 * full.len) 78 - 2 * full.len else 1;
        try w.splatByteAll(' ', gap);
        try w.print("{s}\n\n   NAME\n\t{s} -- {s}\n", .{ full, call.name, call.summary });
        for (call.sections) |section| {
            try w.print("\n   {s}\n", .{section.title});
            var in_code = false;
            for (section.lines) |line| {
                if (mem.startsWith(u8, mem.trimStart(u8, line, " "), "```")) {
                    in_code = !in_code;
                    continue;
                }
                if (line.len == 0) {
                    try w.writeAll("\n");
                } else {
                    try w.print("\t{s}{s}\n", .{ if (in_code) "    " else "", line });
                }
            }
        }
    }
    return out.written();
}

/// The Markdown form: the module's description, an index linking to
/// each call with its summary, then each call under a heading of its
/// name, its sections under bold titles.
fn writeMarkdown(arena: Allocator, module: Module) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("# {s}\n\n", .{module.name});
    for (module.about) |line| try w.print("{s}\n", .{line});
    if (module.about.len != 0) try w.writeAll("\n");
    try w.writeAll("Generated from the source by `./zig build autodoc`.\n\n## Index\n\n");
    for (module.calls) |call| {
        const anchor = try std.ascii.allocLowerString(arena, call.name);
        try w.print("- [{s}](#{s}) - {s}\n", .{ call.name, anchor, call.summary });
    }
    for (module.calls) |call| {
        try w.print("\n## {s}\n\n{s}\n", .{ call.name, call.summary });
        for (call.sections) |section| {
            try w.print("\n**{s}**\n\n", .{section.title});
            for (section.lines) |line| try w.print("{s}\n", .{line});
        }
    }
    return out.written();
}

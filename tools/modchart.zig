// SPDX-License-Identifier: MPL-2.0
//! modchart [--check] <modules.md> <src dir> <sdk dir> <disk modules>:
//! the charts of which module opens which, made from the source.
//!
//! The modules are the ROM's, found by their place under <src dir> -
//! `rom/libs/<m>/<m>.zig` is `<m>.library`, `rom/devs/` holds devices,
//! `rom/resources/` resources, `rom/handler/` `<m>-handler`s,
//! `rom/shell/shell.zig` is the Shell, and the display drivers under
//! `rom/libs/rtg_driver/` are one node - and the disk's, a
//! `<name>=<root file>` line each in the file <disk modules> (the build
//! writes it from the disk package's list).
//!
//! A module's code is its root file and every file it imports from inside
//! its own folder, tests left out. It opens another module when that code
//! names it: by a constant whose value is the module's name
//! (`timer.TIMERNAME`, `sdk.interface.dos.NAME`), found among the
//! `const X = "<name>";` under <sdk dir> and <src dir>, or by the name as
//! a string of its own. No arrow goes to a handler: dos.library names each
//! to start it, and reaches it by packets. A name that arrives at run time - a mount entry's
//! device, a caller's, a file's type - the source cannot show: those opens
//! are listed below (`run_time`) and drawn dashed.
//!
//! <modules.md> holds each chart between `<!-- modchart <chart> -->` and
//! `<!-- modchart end -->`; the chart is written afresh and the text
//! around it left alone. The charts: `rom`, every arrow between two ROM
//! modules; `disk`, every arrow from a library, device or handler on the
//! disk, with the classes drawn as two nodes; `classes`, every arrow from
//! or to a class. exec, utility and expansion are in none of them.
//!
//! With --check it writes nothing and fails if a chart is not what it
//! would write: the build's check that the charts are up to date.

const std = @import("std");
const mem = std.mem;
const path = std.fs.path;
const Io = std.Io;
const Allocator = mem.Allocator;
const Token = std.zig.Token;
const Tokenizer = std.zig.Tokenizer;

const display_drivers = "display drivers";
const gadget_classes = "gadget classes";
const datatype_classes = "datatype classes";

/// In no chart, as nearly every module uses them: exec, which every module
/// is built on; utility, for tag lists; expansion, which every driver asks
/// for its part of the board.
const left_out = [_][]const u8{ "exec.library", "utility.library", "expansion.library" };

/// Opens by a name that arrives at run time, which the source cannot show.
const run_time = [_][2][]const u8{
    // The device in the mount entry: the flash disk's partitions, SD0:.
    .{ "flashfs-handler", "flash.device" },
    .{ "fat-handler", "sdcard.device" },
    // The disk the caller names.
    .{ "rdb.library", "flash.device" },
    .{ "rdb.library", "sdcard.device" },
    // The device an interface's file in DEVS:NetInterfaces/ names.
    .{ "bsdsocket.library", "openeth.device" },
    .{ "bsdsocket.library", "wifi.device" },
    // A session runs over the caller's bsdsocket.library base.
    .{ "tls.library", "bsdsocket.library" },
    // The class a file's type names.
    .{ "datatypes.library", datatype_classes },
};

/// Where the ROM's modules are under <src dir>, and what their folder adds
/// to their name.
const rom_homes = [_]struct { dir: []const u8, suffix: []const u8 }{
    .{ .dir = "rom/libs", .suffix = ".library" },
    .{ .dir = "rom/devs", .suffix = ".device" },
    .{ .dir = "rom/resources", .suffix = ".resource" },
    .{ .dir = "rom/handler", .suffix = "-handler" },
};

const Chart = enum { rom, disk, classes };

/// How a node is drawn: by what it is, or grey for a ROM module in a chart
/// about the disk.
const Style = enum {
    lib,
    dev,
    res,
    hand,
    cls,
    rom,

    fn classDef(style: Style) []const u8 {
        return switch (style) {
            .lib => "fill:#dbeafe,stroke:#2563eb,color:#111827",
            .dev => "fill:#dcfce7,stroke:#16a34a,color:#111827",
            .res => "fill:#fef3c7,stroke:#d97706,color:#111827",
            .hand => "fill:#fce7f3,stroke:#db2777,color:#111827",
            .cls => "fill:#ede9fe,stroke:#7c3aed,color:#111827",
            .rom => "fill:#f3f4f6,stroke:#9ca3af,color:#374151",
        };
    }
};

const Module = struct { name: []const u8, root: []const u8, rom: bool };

const Edge = struct {
    from: []const u8,
    to: []const u8,
    run_time: bool,

    fn lessThan(_: void, a: Edge, b: Edge) bool {
        const order = mem.order(u8, a.from, b.from);
        return if (order == .eq) mem.lessThan(u8, a.to, b.to) else order == .lt;
    }
};

/// A constant whose value is a module's name, and the file it is in.
const Definition = struct { stem: []const u8, value: []const u8 };

const Graph = struct {
    modules: std.ArrayList(Module) = .empty,
    /// Every constant naming a module, by the constant's name.
    constants: std.StringHashMapUnmanaged(std.ArrayList(Definition)) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn find(graph: *const Graph, name: []const u8) ?Module {
        for (graph.modules.items) |module| {
            if (mem.eql(u8, module.name, name)) return module;
        }
        if (mem.eql(u8, name, gadget_classes) or mem.eql(u8, name, datatype_classes)) {
            return .{ .name = name, .root = "", .rom = false };
        }
        return null;
    }

    fn add(graph: *Graph, arena: Allocator, from: []const u8, to: []const u8, is_run_time: bool) !void {
        if (mem.eql(u8, from, to) or isLeftOut(from) or isLeftOut(to)) return;
        // Started by dos.library, which names it for that, not opened.
        if (mem.endsWith(u8, to, "-handler")) return;
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ from, to });
        if ((try graph.seen.getOrPut(arena, key)).found_existing) return;
        try graph.edges.append(arena, .{ .from = from, .to = to, .run_time = is_run_time });
    }

    /// The module a constant names, from where it is used: `qualifier` is
    /// what stands before it (`timer` in `timer.TIMERNAME`), `aliases` what
    /// the file's own constants stand for.
    fn resolve(graph: *const Graph, qualifier: []const u8, name: []const u8, aliases: *const std.StringHashMapUnmanaged([]const u8)) ?[]const u8 {
        const definitions = (graph.constants.get(name) orelse return null).items;
        if (sameValue(definitions, null)) |value| return value;
        if (sameValue(definitions, qualifier)) |value| return value;
        if (aliases.get(qualifier)) |stem| return sameValue(definitions, stem);
        return null;
    }
};

/// The one value the definitions give - all of them, or the ones in a file
/// named `stem` - or null if there are none or they differ.
fn sameValue(definitions: []const Definition, stem: ?[]const u8) ?[]const u8 {
    var value: ?[]const u8 = null;
    for (definitions) |definition| {
        if (stem) |wanted| if (!mem.eql(u8, definition.stem, wanted)) continue;
        if (value) |found| {
            if (!mem.eql(u8, found, definition.value)) return null;
        } else value = definition.value;
    }
    return value;
}

fn isLeftOut(name: []const u8) bool {
    for (left_out) |out| {
        if (mem.eql(u8, out, name)) return true;
    }
    return false;
}

fn isClass(name: []const u8) bool {
    return mem.endsWith(u8, name, ".gadget") or mem.endsWith(u8, name, ".datatype");
}

fn isGroup(name: []const u8) bool {
    return mem.eql(u8, name, gadget_classes) or mem.eql(u8, name, datatype_classes);
}

/// A name as a module is known by: `gadgets/keyboard.gadget` opens
/// `keyboard.gadget`.
fn moduleName(value: []const u8) []const u8 {
    const slash = mem.lastIndexOfScalar(u8, value, '/') orelse return value;
    return value[slash + 1 ..];
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("modchart: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const check = args.len > 1 and mem.eql(u8, args[1], "--check");
    const first: usize = if (check) 2 else 1;
    if (args.len != first + 4) fatal("usage: modchart [--check] <modules.md> <src dir> <sdk dir> <disk modules>", .{});
    const chart_path = args[first];
    const src_path = args[first + 1];
    const sdk_path = args[first + 2];
    const list_path = args[first + 3];

    var graph: Graph = .{};
    try findRomModules(io, arena, &graph, src_path);
    const list = try Io.Dir.cwd().readFileAlloc(io, list_path, arena, .unlimited);
    var lines = mem.splitScalar(u8, list, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const equals = mem.indexOfScalar(u8, line, '=') orelse fatal("{s}: not <name>=<root file>: {s}", .{ list_path, line });
        try graph.modules.append(arena, .{ .name = line[0..equals], .root = line[equals + 1 ..], .rom = false });
    }

    for ([_][]const u8{ sdk_path, src_path }) |tree| try collectConstants(io, arena, &graph, tree);
    for (graph.modules.items) |module| {
        if (isLeftOut(module.name)) continue;
        try scanModule(io, arena, &graph, module);
    }
    for (run_time) |edge| {
        for (edge) |end| {
            if (graph.find(end) == null) fatal("a run-time open names {s}, which is no module: see run_time", .{end});
        }
        try graph.add(arena, edge[0], edge[1], true);
    }
    mem.sort(Edge, graph.edges.items, {}, Edge.lessThan);

    const cwd = Io.Dir.cwd();
    const current = try cwd.readFileAlloc(io, chart_path, arena, .unlimited);
    const written = try writeCharts(arena, &graph, chart_path, current);
    if (check) {
        if (mem.eql(u8, current, written)) return;
        fatal("{s} is out of date: run `./zig build modchart`", .{chart_path});
    }
    if (!mem.eql(u8, current, written)) try cwd.writeFile(io, .{ .sub_path = chart_path, .data = written });
}

/// The ROM's modules, by their place under <src dir>.
fn findRomModules(io: Io, arena: Allocator, graph: *Graph, src_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    for (rom_homes) |home| {
        const home_path = try path.join(arena, &.{ src_path, home.dir });
        var dir = try cwd.openDir(io, home_path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            const folder = try arena.dupe(u8, entry.name);
            if (mem.eql(u8, folder, "rtg_driver")) {
                try findDrivers(io, arena, graph, try path.join(arena, &.{ home_path, folder }));
                continue;
            }
            const root = try std.fmt.allocPrint(arena, "{s}/{s}/{s}.zig", .{ home_path, folder, folder });
            cwd.access(io, root, .{}) catch continue;
            const name = try std.fmt.allocPrint(arena, "{s}{s}", .{ folder, home.suffix });
            try graph.modules.append(arena, .{ .name = name, .root = root, .rom = true });
        }
    }
    const shell = try path.join(arena, &.{ src_path, "rom/shell/shell.zig" });
    cwd.access(io, shell, .{}) catch fatal("no {s}", .{shell});
    try graph.modules.append(arena, .{ .name = "Shell", .root = shell, .rom = true });
}

/// Every display driver, as the one node they are drawn as.
fn findDrivers(io: Io, arena: Allocator, graph: *Graph, drivers_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var dir = try cwd.openDir(io, drivers_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const root = try std.fmt.allocPrint(arena, "{s}/{s}/{s}.zig", .{ drivers_path, entry.name, entry.name });
        cwd.access(io, root, .{}) catch continue;
        try graph.modules.append(arena, .{ .name = display_drivers, .root = root, .rom = true });
    }
}

/// Every `const X = "<name>";` under `tree` whose value is a module's name,
/// tests and the disk's programs left out.
fn collectConstants(io: Io, arena: Allocator, graph: *Graph, tree: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, tree, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (mem.indexOf(u8, entry.path, "tests") != null or mem.startsWith(u8, entry.path, "disk/c/") or
            mem.startsWith(u8, entry.path, "disk/programs/")) continue;
        const source = try entry.dir.readFileAllocOptions(io, entry.basename, arena, .unlimited, .of(u8), 0);
        const tokens = try tokenize(arena, source);
        const stem = try arena.dupe(u8, path.stem(entry.basename));
        for (tokens, 0..) |token, i| {
            if (token.tag != .keyword_const or i + 1 >= tokens.len or tokens[i + 1].tag != .identifier) continue;
            const equal = nextTag(tokens, i + 2, .equal) orelse continue;
            if (equal + 2 >= tokens.len or tokens[equal + 1].tag != .string_literal or tokens[equal + 2].tag != .semicolon) continue;
            const value = moduleName(stringValue(source, tokens[equal + 1]) orelse continue);
            if (graph.find(value) == null) continue;
            const name = text(source, tokens[i + 1]);
            const entry_list = try graph.constants.getOrPut(arena, name);
            if (!entry_list.found_existing) entry_list.value_ptr.* = .empty;
            try entry_list.value_ptr.append(arena, .{ .stem = stem, .value = value });
        }
    }
}

/// A module's code - its root file and what that imports from inside its
/// folder - and every module it names.
fn scanModule(io: Io, arena: Allocator, graph: *Graph, module: Module) !void {
    const cwd = Io.Dir.cwd();
    const folder = path.dirname(module.root) orelse ".";
    var queue: std.ArrayList([]const u8) = .empty;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    try queue.append(arena, module.root);
    try visited.put(arena, module.root, {});
    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        const file = queue.items[next];
        const source = try cwd.readFileAllocOptions(io, file, arena, .unlimited, .of(u8), 0);
        const tokens = try withoutTests(arena, try tokenize(arena, source));

        var aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (tokens, 0..) |token, i| {
            if (token.tag != .keyword_const or i + 1 >= tokens.len or tokens[i + 1].tag != .identifier) continue;
            const equal = nextTag(tokens, i + 2, .equal) orelse continue;
            const end = nextTag(tokens, equal + 1, .semicolon) orelse continue;
            if (aliasOf(source, tokens[equal + 1 .. end])) |stem| try aliases.put(arena, text(source, tokens[i + 1]), stem);
        }

        for (tokens, 0..) |token, i| {
            switch (token.tag) {
                .identifier => if (i >= 2 and tokens[i - 1].tag == .period and tokens[i - 2].tag == .identifier) {
                    if (graph.resolve(text(source, tokens[i - 2]), text(source, token), &aliases)) |name| {
                        try graph.add(arena, module.name, name, false);
                    }
                },
                .string_literal => if (stringValue(source, token)) |value| {
                    if (graph.find(moduleName(value)) != null) try graph.add(arena, module.name, moduleName(value), false);
                },
                .builtin => if (importOf(source, tokens, i)) |imported| {
                    if (!mem.endsWith(u8, imported, ".zig")) continue;
                    const resolved = try path.resolve(arena, &.{ path.dirname(file) orelse ".", imported });
                    if (!mem.startsWith(u8, resolved, folder) or resolved.len <= folder.len or resolved[folder.len] != '/') continue;
                    if ((try visited.getOrPut(arena, resolved)).found_existing) continue;
                    try queue.append(arena, resolved);
                },
                else => {},
            }
        }
    }
}

fn tokenize(arena: Allocator, source: [:0]const u8) ![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var tokenizer = Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(arena, token);
    }
    return tokens.items;
}

/// The tokens without the file's `test` declarations.
fn withoutTests(arena: Allocator, tokens: []const Token) ![]const Token {
    var kept: std.ArrayList(Token) = .empty;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (token.tag == .keyword_test and depth == 0) {
            const open = nextTag(tokens, i + 1, .l_brace) orelse break;
            var nesting: usize = 0;
            i = open;
            while (i < tokens.len) : (i += 1) {
                if (tokens[i].tag == .l_brace) nesting += 1;
                if (tokens[i].tag == .r_brace) {
                    nesting -= 1;
                    if (nesting == 0) break;
                }
            }
            continue;
        }
        if (token.tag == .l_brace) depth += 1;
        if (token.tag == .r_brace and depth > 0) depth -= 1;
        try kept.append(arena, token);
    }
    return kept.items;
}

/// The first token from `start` on with `tag`, before the statement ends.
fn nextTag(tokens: []const Token, start: usize, tag: Token.Tag) ?usize {
    var i = start;
    while (i < tokens.len) : (i += 1) {
        if (tokens[i].tag == tag) return i;
        if (tokens[i].tag == .semicolon) return null;
    }
    return null;
}

/// What a constant stands for, as a file's stem: the last name in its
/// value (`sdk.devices.timer` is `timer`), or the file it imports.
fn aliasOf(source: [:0]const u8, value: []const Token) ?[]const u8 {
    var i = value.len;
    while (i > 0) {
        i -= 1;
        if (value[i].tag == .identifier) return text(source, value[i]);
    }
    for (value, 0..) |token, j| {
        if (token.tag == .builtin) if (importOf(source, value, j)) |imported| return path.stem(imported);
    }
    return null;
}

/// The path of an `@import("...")` that starts at `tokens[i]`.
fn importOf(source: [:0]const u8, tokens: []const Token, i: usize) ?[]const u8 {
    if (!mem.eql(u8, text(source, tokens[i]), "@import")) return null;
    if (i + 2 >= tokens.len or tokens[i + 1].tag != .l_paren or tokens[i + 2].tag != .string_literal) return null;
    return stringValue(source, tokens[i + 2]);
}

/// A string literal's text, or null for one with escapes - no module name
/// has any.
fn stringValue(source: [:0]const u8, token: Token) ?[]const u8 {
    const quoted = text(source, token);
    if (quoted.len < 2 or mem.indexOfScalar(u8, quoted, '\\') != null) return null;
    return quoted[1 .. quoted.len - 1];
}

fn text(source: [:0]const u8, token: Token) []const u8 {
    return source[token.loc.start..token.loc.end];
}

/// `current` with every chart between its markers written afresh.
fn writeCharts(arena: Allocator, graph: *const Graph, chart_path: []const u8, current: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = mem.splitScalar(u8, current, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        try out.appendSlice(arena, line);
        const marker = mem.trim(u8, line, " \t\r");
        if (!mem.startsWith(u8, marker, "<!-- modchart ") or !mem.endsWith(u8, marker, " -->")) continue;
        const chart_name = marker["<!-- modchart ".len .. marker.len - " -->".len];
        if (mem.eql(u8, chart_name, "end")) fatal("{s}: <!-- modchart end --> with no chart before it", .{chart_path});
        const chart = std.meta.stringToEnum(Chart, chart_name) orelse fatal("{s}: no chart called {s}", .{ chart_path, chart_name });
        try out.append(arena, '\n');
        try writeChart(arena, &out, graph, chart);
        while (lines.next()) |skipped| {
            if (mem.eql(u8, mem.trim(u8, skipped, " \t\r"), "<!-- modchart end -->")) {
                try out.appendSlice(arena, skipped);
                break;
            }
        } else fatal("{s}: chart {s} has no <!-- modchart end -->", .{ chart_path, chart_name });
    }
    return out.items;
}

/// One chart as a Mermaid flowchart: the nodes by name, the arrows, and
/// the colours.
fn writeChart(arena: Allocator, out: *std.ArrayList(u8), graph: *const Graph, chart: Chart) !void {
    var edges: std.ArrayList(Edge) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (graph.edges.items) |edge| {
        const drawn = inChart(graph, chart, edge) orelse continue;
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ drawn.from, drawn.to });
        if ((try seen.getOrPut(arena, key)).found_existing) continue;
        try edges.append(arena, drawn);
    }
    mem.sort(Edge, edges.items, {}, Edge.lessThan);

    var nodes: std.ArrayList([]const u8) = .empty;
    var listed: std.StringHashMapUnmanaged(void) = .empty;
    for (edges.items) |edge| {
        for ([_][]const u8{ edge.from, edge.to }) |name| {
            if (!(try listed.getOrPut(arena, name)).found_existing) try nodes.append(arena, name);
        }
    }
    mem.sort([]const u8, nodes.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.lessThan(u8, a, b);
        }
    }.lessThan);

    const print = struct {
        fn line(list: *std.ArrayList(u8), allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
            try list.appendSlice(allocator, try std.fmt.allocPrint(allocator, fmt ++ "\n", args));
        }
    }.line;
    try print(out, arena, "```mermaid", .{});
    try print(out, arena, "flowchart TB", .{});
    for (nodes.items) |name| try print(out, arena, "    {s}[\"{s}\"]", .{ try nodeId(arena, name), name });
    try print(out, arena, "", .{});
    for (edges.items) |edge| {
        const arrow = if (edge.run_time) "-.->" else "-->";
        try print(out, arena, "    {s} {s} {s}", .{ try nodeId(arena, edge.from), arrow, try nodeId(arena, edge.to) });
    }
    try print(out, arena, "", .{});
    for (std.enums.values(Style)) |style| {
        var members: std.ArrayList(u8) = .empty;
        for (nodes.items) |name| {
            if (styleOf(graph, chart, name) != style) continue;
            if (members.items.len != 0) try members.append(arena, ',');
            try members.appendSlice(arena, try nodeId(arena, name));
        }
        if (members.items.len == 0) continue;
        try print(out, arena, "    classDef {s} {s}", .{ @tagName(style), style.classDef() });
        try print(out, arena, "    class {s} {s}", .{ members.items, @tagName(style) });
    }
    try print(out, arena, "```", .{});
}

/// The arrow as `chart` draws it, or null if it is not in that chart.
fn inChart(graph: *const Graph, chart: Chart, edge: Edge) ?Edge {
    const from = graph.find(edge.from).?;
    const to = graph.find(edge.to).?;
    switch (chart) {
        .rom => return if (from.rom and to.rom) edge else null,
        .disk => {
            if (from.rom or isClass(from.name) or isGroup(from.name)) return null;
            var drawn = edge;
            if (mem.endsWith(u8, to.name, ".gadget")) drawn.to = gadget_classes;
            if (mem.endsWith(u8, to.name, ".datatype")) drawn.to = datatype_classes;
            return drawn;
        },
        .classes => {
            if (isGroup(from.name) or isGroup(to.name)) return null;
            return if (isClass(from.name) or isClass(to.name)) edge else null;
        },
    }
}

fn styleOf(graph: *const Graph, chart: Chart, name: []const u8) Style {
    if (chart != .rom and graph.find(name).?.rom) return .rom;
    if (isClass(name) or isGroup(name)) return .cls;
    if (mem.endsWith(u8, name, ".device")) return .dev;
    if (mem.endsWith(u8, name, ".resource")) return .res;
    if (mem.endsWith(u8, name, "-handler") or mem.eql(u8, name, "Shell")) return .hand;
    return .lib;
}

/// A name as a Mermaid node's id: `dos.library` is `m_dos_library`.
fn nodeId(arena: Allocator, name: []const u8) ![]const u8 {
    const id = try arena.alloc(u8, name.len + 2);
    @memcpy(id[0..2], "m_");
    for (name, id[2..]) |byte, *slot| slot.* = if (std.ascii.isAlphanumeric(byte)) byte else '_';
    return id;
}

// SPDX-License-Identifier: MIT
//! fd2zig [--check] <lib_lib.fd> <interface.zig>: the SDK's interface to a
//! library's jump table, from the library's .fd file. The format: Zig types
//! and `##` directives.
//!
//!   //! text             the interface's doc comment
//!   ##include p as a     `const a = @import("../p.zig");`, p relative to sdk/
//!   ##basetype T         the base type: an opaque with the functions as methods
//!   ##name n             the library's name (NAME)
//!   ##bias n             the first function's vector (4 in a library: the
//!                        vectors after Open, Close, Expunge and ExtFunc)
//!   ##public             the functions from here on are in the interface
//!   ##private            the functions from here on only take their slot
//!   ##reserve n          n empty slots (the .sfd's ==reserve)
//!   ##end                the end
//!   /// text             the next function's doc comment
//!   Ret Name(Type a, ...)  a function, in the next slot
//!   // text              a comment
//!
//! With --check it writes nothing and fails if <interface.zig> isn't what
//! it would write: the build's check that the SDK is up to date.

const std = @import("std");
const mem = std.mem;

const Param = struct { ty: []const u8, name: []const u8 };

const Function = struct {
    ret: []const u8,
    name: []const u8,
    params: []const Param,
    slot: usize,
    public: bool,
    doc: []const []const u8,
};

const Include = struct { path: []const u8, alias: []const u8 };

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fd2zig: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const check = args.len == 4 and mem.eql(u8, args[1], "--check");
    if (args.len != 3 and !check) fatal("usage: fd2zig [--check] <lib_lib.fd> <interface.zig>", .{});
    const in_path = args[args.len - 2];
    const out_path = args[args.len - 1];
    const fd_name = std.fs.path.basename(in_path);

    const cwd = std.Io.Dir.cwd();
    const fd = try cwd.readFileAlloc(io, in_path, arena, .unlimited);
    const text = try generate(arena, fd_name, fd);
    if (check) {
        const current = cwd.readFileAlloc(io, out_path, arena, .unlimited) catch "";
        if (!mem.eql(u8, current, text)) fatal("{s} is out of date with sdk/fd/{s}: run `zig build fd`", .{ out_path, fd_name });
        return;
    }
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = text });
}

fn generate(gpa: mem.Allocator, fd_name: []const u8, fd: []const u8) ![]const u8 {
    var header: std.ArrayList([]const u8) = .empty;
    var includes: std.ArrayList(Include) = .empty;
    var functions: std.ArrayList(Function) = .empty;
    var doc: std.ArrayList([]const u8) = .empty;
    var basetype: []const u8 = "";
    var lib_name: []const u8 = "";
    var slot: ?usize = null;
    var public = true;

    var lines = mem.splitScalar(u8, fd, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (mem.startsWith(u8, line, "//!")) {
            try header.append(gpa, line);
        } else if (mem.startsWith(u8, line, "///")) {
            try doc.append(gpa, line);
        } else if (mem.startsWith(u8, line, "//")) {
            continue;
        } else if (mem.startsWith(u8, line, "##")) {
            const space = mem.indexOfAny(u8, line, " \t");
            const key = line[2 .. space orelse line.len];
            const value = if (space) |s| mem.trim(u8, line[s..], " \t") else "";
            if (mem.eql(u8, key, "include")) {
                var it = mem.tokenizeAny(u8, value, " \t");
                const path = it.next() orelse fatal("line {d}: ##include needs a path", .{line_no});
                const alias = if (it.next()) |as| alias: {
                    if (!mem.eql(u8, as, "as")) fatal("line {d}: ##include <path> as <alias>", .{line_no});
                    break :alias it.next() orelse fatal("line {d}: ##include <path> as <alias>", .{line_no});
                } else std.fs.path.basename(path);
                try includes.append(gpa, .{ .path = path, .alias = alias });
            } else if (mem.eql(u8, key, "basetype")) {
                basetype = value;
            } else if (mem.eql(u8, key, "name")) {
                lib_name = value;
            } else if (mem.eql(u8, key, "bias")) {
                slot = std.fmt.parseInt(usize, value, 10) catch fatal("line {d}: ##bias <n>", .{line_no});
            } else if (mem.eql(u8, key, "reserve")) {
                const n = std.fmt.parseInt(usize, value, 10) catch fatal("line {d}: ##reserve <n>", .{line_no});
                slot = (slot orelse fatal("line {d}: ##reserve before ##bias", .{line_no})) + n;
            } else if (mem.eql(u8, key, "public")) {
                public = true;
            } else if (mem.eql(u8, key, "private")) {
                public = false;
            } else if (mem.eql(u8, key, "end")) {
                break;
            } else {
                fatal("line {d}: unknown directive ##{s}", .{ line_no, key });
            }
        } else {
            const s = slot orelse fatal("line {d}: a function before ##bias", .{line_no});
            var f = parseFunction(gpa, line) catch fatal("line {d}: not a function: {s}", .{ line_no, line });
            f.slot = s;
            f.public = public;
            f.doc = try doc.toOwnedSlice(gpa);
            try functions.append(gpa, f);
            slot = s + 1;
        }
    }
    if (basetype.len == 0 or lib_name.len == 0) fatal("{s}: ##basetype and ##name are needed", .{fd_name});

    var out: Output = .{ .gpa = gpa };
    // The interface is the SDK's, under the SDK's license.
    try out.print("// SPDX-License-Identifier: MIT\n", .{});
    for (header.items) |line| try out.print("{s}\n", .{line});
    if (header.items.len != 0) try out.print("//!\n", .{});
    try out.print(
        \\//! Generated by sdk/tools/fd2zig from sdk/fd/{s}: change that file
        \\//! and run `zig build fd`, not this one.
        \\
        \\const libraries = @import("../libs/exec/libraries.zig");
        \\
    , .{fd_name});
    for (includes.items) |inc| try out.print("const {s} = @import(\"../{s}.zig\");\n", .{ inc.alias, inc.path });

    // A library with no functions of its own yet is a `struct {}` on one
    // line, so that what is generated is what `zig fmt` would leave.
    const any_public = for (functions.items) |f| {
        if (f.public) break true;
    } else false;
    const body_start: []const u8 = if (any_public) "{\n" else "{";

    try out.print(
        \\
        \\/// The name to open it by (OpenLibrary, OpenDevice).
        \\pub const NAME = "{s}";
        \\
        \\/// Each function's offset in the jump table (its LVO).
        \\pub const LVO = struct {s}
    , .{ lib_name, body_start });
    for (functions.items) |f| {
        if (f.public) try out.print("    pub const {s} = libraries.lvo({d});\n", .{ f.name, f.slot });
    }
    try out.print(
        \\}};
        \\
        \\/// Each function's type, by its name in LVO. The first argument is the
        \\/// library's base.
        \\pub const Fn = struct {s}
    , .{body_start});
    for (functions.items) |f| {
        if (!f.public) continue;
        try out.print("    pub const {s} = *const fn (*{s}", .{ f.name, basetype });
        for (f.params) |p| try out.print(", {s}", .{p.ty});
        try out.print(") callconv(.c) {s};\n", .{f.ret});
    }
    try out.print(
        \\}};
        \\
        \\/// The library's base. Its methods are the library's functions, and
        \\/// each calls through the jump table.
        \\pub const {0s} = opaque {{
        \\    /// The Library header at the base.
        \\    pub fn lib(self: *{0s}) *libraries.Library {{
        \\        return @ptrCast(@alignCast(self));
        \\    }}
        \\
    , .{basetype});
    for (functions.items) |f| {
        if (!f.public) continue;
        try out.print("\n", .{});
        for (f.doc) |line| try out.print("    {s}\n", .{line});
        try out.print("    pub fn {s}(self: *{s}", .{ f.name, basetype });
        for (f.params) |p| try out.print(", {s}: {s}", .{ p.name, p.ty });
        try out.print(") {s} {{\n        return libraries.call(self, LVO.{s}, Fn.{s}, .{{", .{ f.ret, f.name, f.name });
        switch (f.params.len) {
            0 => {},
            1 => try out.print("{s}", .{f.params[0].name}),
            else => {
                try out.print(" ", .{});
                for (f.params, 0..) |p, i| try out.print("{s}{s}", .{ if (i == 0) "" else ", ", p.name });
                try out.print(" ", .{});
            },
        }
        try out.print("}});\n    }}\n", .{});
    }
    try out.print("}};\n", .{});
    return out.text.items;
}

const Output = struct {
    gpa: mem.Allocator,
    text: std.ArrayList(u8) = .empty,

    fn print(out: *Output, comptime fmt: []const u8, args: anytype) !void {
        try out.text.appendSlice(out.gpa, try std.fmt.allocPrint(out.gpa, fmt, args));
    }
};

/// `Ret Name(Type a, Type b)`: the types may hold spaces, brackets and
/// parentheses; each parameter's name is its last word.
fn parseFunction(gpa: mem.Allocator, line: []const u8) !Function {
    const open = mem.indexOfScalar(u8, line, '(') orelse return error.Syntax;
    const close = mem.lastIndexOfScalar(u8, line, ')') orelse return error.Syntax;
    if (close < open or mem.trim(u8, line[close + 1 ..], " \t").len != 0) return error.Syntax;
    const head = mem.trim(u8, line[0..open], " \t");
    const split = mem.lastIndexOfAny(u8, head, " \t") orelse return error.Syntax;
    const name = head[split + 1 ..];
    if (!isIdentifier(name)) return error.Syntax;

    var params: std.ArrayList(Param) = .empty;
    const list = mem.trim(u8, line[open + 1 .. close], " \t");
    var depth: usize = 0;
    var start: usize = 0;
    for (0..list.len + 1) |i| {
        if (i < list.len) {
            switch (list[i]) {
                '(', '[' => depth += 1,
                ')', ']' => depth -|= 1,
                else => {},
            }
        }
        if (i == list.len or (list[i] == ',' and depth == 0)) {
            const param = mem.trim(u8, list[start..i], " \t");
            start = i + 1;
            if (param.len == 0) {
                if (i == list.len and params.items.len == 0) break;
                return error.Syntax;
            }
            const cut = mem.lastIndexOfAny(u8, param, " \t") orelse return error.Syntax;
            const param_name = param[cut + 1 ..];
            if (!isIdentifier(param_name)) return error.Syntax;
            try params.append(gpa, .{ .ty = mem.trim(u8, param[0..cut], " \t"), .name = param_name });
        }
    }
    return .{
        .ret = mem.trim(u8, head[0..split], " \t"),
        .name = name,
        .params = try params.toOwnedSlice(gpa),
        .slot = 0,
        .public = true,
        .doc = &.{},
    };
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

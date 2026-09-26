// SPDX-License-Identifier: MIT
//! romld: a program's linker script with the chip ROM's addresses added.
//!
//! usage: romld <program.ld> <out.ld> <rom.ld>...
//!
//! A vendor archive linked into a program (wifi.device's radio libraries)
//! calls functions and reads data that live in the chip's mask ROM, at
//! fixed addresses its vendor's linker scripts name. Those scripts hold
//! more than names - memory regions, sections of their own system - so
//! only their symbol assignments are taken: `name = 0x...;` and
//! `PROVIDE ( name = other );`, each written as a PROVIDE. A PROVIDE only
//! answers a reference nothing else defines, so a program's own memcpy
//! stays its own and the ROM fills in what is left. The program's script
//! comes first, unchanged.

const std = @import("std");
const mem = std.mem;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("romld: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn isName(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text, 0..) |char, i| switch (char) {
        'A'...'Z', 'a'...'z', '_' => {},
        '0'...'9' => if (i == 0) return false,
        else => return false,
    };
    return true;
}

fn isHex(text: []const u8) bool {
    if (text.len < 3 or !mem.startsWith(u8, text, "0x")) return false;
    for (text[2..]) |char| if (!std.ascii.isHex(char)) return false;
    return true;
}

/// `name = value` out of one line, or null when the line is anything else.
fn assignment(line: []const u8) ?struct { name: []const u8, value: []const u8 } {
    var rest = mem.trim(u8, line, " \t\r");
    if (!mem.endsWith(u8, rest, ";")) return null;
    rest = mem.trim(u8, rest[0 .. rest.len - 1], " \t");
    if (mem.startsWith(u8, rest, "PROVIDE")) {
        rest = mem.trim(u8, rest["PROVIDE".len..], " \t");
        if (rest.len < 2 or rest[0] != '(' or rest[rest.len - 1] != ')') return null;
        rest = rest[1 .. rest.len - 1];
    }
    const equals = mem.indexOfScalar(u8, rest, '=') orelse return null;
    const name = mem.trim(u8, rest[0..equals], " \t");
    const value = mem.trim(u8, rest[equals + 1 ..], " \t");
    if (!isName(name) or !(isHex(value) or isName(value))) return null;
    return .{ .name = name, .value = value };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) fatal("usage: romld <program.ld> <out.ld> <rom.ld>...", .{});

    const cwd = std.Io.Dir.cwd();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, try cwd.readFileAlloc(io, args[1], arena, .unlimited));
    try out.appendSlice(arena, "\n/* The chip ROM's addresses (romld). */\n");
    var count: usize = 0;
    for (args[3..]) |path| {
        const text = try cwd.readFileAlloc(io, path, arena, .unlimited);
        var lines = mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const found = assignment(line) orelse continue;
            try out.print(arena, "PROVIDE({s} = {s});\n", .{ found.name, found.value });
            count += 1;
        }
    }
    if (count == 0) fatal("no addresses in the ROM scripts", .{});
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.items });
}

test assignment {
    const plain = assignment("memcpy = 0x400011f4;").?;
    try std.testing.expectEqualStrings("memcpy", plain.name);
    try std.testing.expectEqualStrings("0x400011f4", plain.value);
    const alias = assignment("PROVIDE ( esp_rom_crc32_le = crc32_le );").?;
    try std.testing.expectEqualStrings("crc32_le", alias.value);
    try std.testing.expect(assignment("MEMORY {") == null);
    try std.testing.expect(assignment("  /* Group libgcc */") == null);
}

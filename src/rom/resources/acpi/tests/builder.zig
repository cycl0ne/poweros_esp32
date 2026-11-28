// SPDX-License-Identifier: MPL-2.0
//! A table of bytecode written by calls, for the host tests: each term a
//! call that appends its bytes - a scope, a device, a name and its data,
//! a method, a region and its fields - a term that holds others given a
//! function that writes them, and the table finished with its header and
//! its checksum. Package lengths, name strings and constants are
//! encoded the shortest way, as a compiler does.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Table = struct {
    allocator: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    signature: [4]u8 = "SSDT".*,
    revision: u8 = 2,
    finished: ?[]u8 = null,

    pub fn init(allocator: Allocator, signature: *const [4]u8, revision: u8) Table {
        return .{ .allocator = allocator, .signature = signature.*, .revision = revision };
    }

    pub fn deinit(table: *Table) void {
        table.bytes.deinit(table.allocator);
        if (table.finished) |done| table.allocator.free(done);
    }

    /// The table, header first, its checksum holding; the builder's.
    pub fn finish(table: *Table) ![]const u8 {
        const length = 36 + table.bytes.items.len;
        const done = try table.allocator.alloc(u8, length);
        @memset(done[0..36], 0);
        @memcpy(done[0..4], &table.signature);
        std.mem.writeInt(u32, done[4..8], @intCast(length), .little);
        done[8] = table.revision;
        @memcpy(done[10..16], "POWER ");
        @memcpy(done[16..24], "TESTTABL");
        std.mem.writeInt(u32, done[24..28], 1, .little);
        @memcpy(done[28..32], "TEST");
        @memcpy(done[36..], table.bytes.items);
        var sum: u8 = 0;
        for (done) |byte| sum +%= byte;
        done[9] = 0 -% sum;
        if (table.finished) |old| table.allocator.free(old);
        table.finished = done;
        return done;
    }

    /// Bytes as they are.
    pub fn raw(table: *Table, bytes: []const u8) !void {
        try table.bytes.appendSlice(table.allocator, bytes);
    }

    fn nested(table: *Table) Table {
        return .{ .allocator = table.allocator };
    }

    /// `opcode`, a package length, then `content`.
    pub fn package(table: *Table, opcode: []const u8, content: []const u8) !void {
        try table.raw(opcode);
        try table.pkgLength(content.len);
        try table.raw(content);
    }

    /// A package length for `content` bytes: it counts itself.
    pub fn pkgLength(table: *Table, content: usize) !void {
        if (content + 1 <= 0x3F) return table.raw(&.{@intCast(content + 1)});
        var follow: usize = 1;
        while (follow <= 3) : (follow += 1) {
            const total = content + 1 + follow;
            if (total < @as(usize, 1) << @intCast(4 + 8 * follow)) {
                try table.raw(&.{@as(u8, @intCast(follow << 6 | (total & 0x0F)))});
                var index: usize = 0;
                while (index < follow) : (index += 1) try table.raw(&.{@truncate(total >> @intCast(4 + 8 * index))});
                return;
            }
        }
        return error.TooLong;
    }

    /// A length in a package length's encoding that counts nothing but
    /// its value: a field's width in bits.
    pub fn lengthValue(table: *Table, value: usize) !void {
        if (value <= 0x3F) return table.raw(&.{@intCast(value)});
        var follow: usize = 1;
        while (follow <= 3) : (follow += 1) {
            if (value < @as(usize, 1) << @intCast(4 + 8 * follow)) {
                try table.raw(&.{@as(u8, @intCast(follow << 6 | (value & 0x0F)))});
                var index: usize = 0;
                while (index < follow) : (index += 1) try table.raw(&.{@truncate(value >> @intCast(4 + 8 * index))});
                return;
            }
        }
        return error.TooLong;
    }

    /// A name string from a path as written in the source: "\\_SB.PCI0",
    /// "^FOO", "PCI0"; each name filled out with `_`.
    pub fn name(table: *Table, path: []const u8) !void {
        var rest = path;
        while (rest.len > 0 and (rest[0] == '\\' or rest[0] == '^')) {
            try table.raw(rest[0..1]);
            rest = rest[1..];
        }
        if (rest.len == 0) return table.raw(&.{0});
        var count: usize = 1;
        for (rest) |char| {
            if (char == '.') count += 1;
        }
        if (count == 2) try table.raw(&.{0x2E}) else if (count > 2) try table.raw(&.{ 0x2F, @intCast(count) });
        var parts = std.mem.splitScalar(u8, rest, '.');
        while (parts.next()) |part| {
            var segment: [4]u8 = "____".*;
            @memcpy(segment[0..part.len], part);
            try table.raw(&segment);
        }
    }

    /// An integer the shortest way.
    pub fn integer(table: *Table, value: u64) !void {
        if (value == 0) return table.raw(&.{0x00});
        if (value == 1) return table.raw(&.{0x01});
        if (value <= 0xFF) return table.raw(&.{ 0x0A, @intCast(value) });
        if (value <= 0xFFFF) {
            try table.raw(&.{0x0B});
            return table.raw(&std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(value))));
        }
        if (value <= 0xFFFF_FFFF) {
            try table.raw(&.{0x0C});
            return table.raw(&std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(value))));
        }
        try table.raw(&.{0x0E});
        try table.raw(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }

    pub fn string(table: *Table, text: []const u8) !void {
        try table.raw(&.{0x0D});
        try table.raw(text);
        try table.raw(&.{0});
    }

    /// A buffer of `size` bytes, its first ones `initial`.
    pub fn buffer(table: *Table, size: u64, initial: []const u8) !void {
        var inner = table.nested();
        defer inner.deinit();
        try inner.integer(size);
        try inner.raw(initial);
        try table.package(&.{0x11}, inner.bytes.items);
    }

    pub const Body = fn (*Table) anyerror!void;

    /// A package declared with `count` elements, those `elements` writes.
    pub fn packageOf(table: *Table, count: u8, comptime elements: Body) !void {
        var inner = table.nested();
        defer inner.deinit();
        try inner.raw(&.{count});
        try elements(&inner);
        try table.package(&.{0x12}, inner.bytes.items);
    }

    /// A defining term: `opcode`, its package, `path`, then `head` and
    /// what `body` writes.
    fn opened(table: *Table, opcode: []const u8, path: []const u8, head: []const u8, comptime body: Body) !void {
        var inner = table.nested();
        defer inner.deinit();
        try inner.name(path);
        try inner.raw(head);
        try body(&inner);
        try table.package(opcode, inner.bytes.items);
    }

    pub fn scope(table: *Table, path: []const u8, comptime body: Body) !void {
        try table.opened(&.{0x10}, path, &.{}, body);
    }

    pub fn device(table: *Table, path: []const u8, comptime body: Body) !void {
        try table.opened(&.{ 0x5B, 0x82 }, path, &.{}, body);
    }

    pub fn thermalZone(table: *Table, path: []const u8, comptime body: Body) !void {
        try table.opened(&.{ 0x5B, 0x85 }, path, &.{}, body);
    }

    pub fn processor(table: *Table, path: []const u8, id: u8, block: u32, length: u8, comptime body: Body) !void {
        var head: [6]u8 = undefined;
        head[0] = id;
        std.mem.writeInt(u32, head[1..5], block, .little);
        head[5] = length;
        try table.opened(&.{ 0x5B, 0x83 }, path, &head, body);
    }

    pub fn powerResource(table: *Table, path: []const u8, level: u8, order: u16, comptime body: Body) !void {
        var head: [3]u8 = undefined;
        head[0] = level;
        std.mem.writeInt(u16, head[1..3], order, .little);
        try table.opened(&.{ 0x5B, 0x84 }, path, &head, body);
    }

    /// A method whose body is `code`, already bytecode.
    pub fn method(table: *Table, path: []const u8, flags: u8, code: []const u8) !void {
        var inner = table.nested();
        defer inner.deinit();
        try inner.name(path);
        try inner.raw(&.{flags});
        try inner.raw(code);
        try table.package(&.{0x14}, inner.bytes.items);
    }

    pub fn nameInteger(table: *Table, path: []const u8, value: u64) !void {
        try table.raw(&.{0x08});
        try table.name(path);
        try table.integer(value);
    }

    pub fn nameText(table: *Table, path: []const u8, text: []const u8) !void {
        try table.raw(&.{0x08});
        try table.name(path);
        try table.string(text);
    }

    /// `Name (path, ...)` holding what `data` writes.
    pub fn nameOf(table: *Table, path: []const u8, comptime data: Body) !void {
        try table.raw(&.{0x08});
        try table.name(path);
        try data(table);
    }

    pub fn mutex(table: *Table, path: []const u8, level: u8) !void {
        try table.raw(&.{ 0x5B, 0x01 });
        try table.name(path);
        try table.raw(&.{level});
    }

    pub fn event(table: *Table, path: []const u8) !void {
        try table.raw(&.{ 0x5B, 0x02 });
        try table.name(path);
    }

    pub fn alias(table: *Table, source: []const u8, other: []const u8) !void {
        try table.raw(&.{0x06});
        try table.name(source);
        try table.name(other);
    }

    pub fn external(table: *Table, path: []const u8, kind: u8, args: u8) !void {
        try table.raw(&.{0x15});
        try table.name(path);
        try table.raw(&.{ kind, args });
    }

    pub fn region(table: *Table, path: []const u8, space: u8, offset: u64, length: u64) !void {
        try table.raw(&.{ 0x5B, 0x80 });
        try table.name(path);
        try table.raw(&.{space});
        try table.integer(offset);
        try table.integer(length);
    }

    /// An element of a field list: a named field of `bits`, bits left out
    /// (`name` null), or an AccessAs (`access`).
    pub const Unit = struct {
        name: ?[]const u8 = null,
        bits: u32 = 0,
        access: ?[2]u8 = null,
    };

    fn fieldList(inner: *Table, flags: u8, units: []const Unit) !void {
        try inner.raw(&.{flags});
        for (units) |unit| {
            if (unit.access) |access| {
                try inner.raw(&.{ 0x01, access[0], access[1] });
            } else if (unit.name) |field_name| {
                var segment: [4]u8 = "____".*;
                @memcpy(segment[0..field_name.len], field_name);
                try inner.raw(&segment);
                try inner.lengthValue(unit.bits);
            } else {
                try inner.raw(&.{0x00});
                try inner.lengthValue(unit.bits);
            }
        }
    }

    pub fn field(table: *Table, region_path: []const u8, flags: u8, units: []const Unit) !void {
        var inner = table.nested();
        defer inner.deinit();
        try inner.name(region_path);
        try fieldList(&inner, flags, units);
        try table.package(&.{ 0x5B, 0x81 }, inner.bytes.items);
    }

    pub fn indexField(table: *Table, index_path: []const u8, data_path: []const u8, flags: u8, units: []const Unit) !void {
        var inner = table.nested();
        defer inner.deinit();
        try inner.name(index_path);
        try inner.name(data_path);
        try fieldList(&inner, flags, units);
        try table.package(&.{ 0x5B, 0x86 }, inner.bytes.items);
    }

    pub fn bankField(table: *Table, region_path: []const u8, bank_path: []const u8, value: u64, flags: u8, units: []const Unit) !void {
        var inner = table.nested();
        defer inner.deinit();
        try inner.name(region_path);
        try inner.name(bank_path);
        try inner.integer(value);
        try fieldList(&inner, flags, units);
        try table.package(&.{ 0x5B, 0x87 }, inner.bytes.items);
    }

    /// `If (predicate) { body }`, both already bytecode.
    pub fn ifThen(table: *Table, predicate: []const u8, body: []const u8) !void {
        var inner = table.nested();
        defer inner.deinit();
        try inner.raw(predicate);
        try inner.raw(body);
        try table.package(&.{0xA0}, inner.bytes.items);
    }
};

// SPDX-License-Identifier: MIT
//! SSH's data types on the wire (RFC 4251, 5): a message read field by
//! field and written field by field - bytes, booleans, 32-bit numbers
//! (most significant byte first), strings (a length and the bytes),
//! mpints (a number as a string, two's complement, no needless leading
//! byte) and name-lists (names between commas, as a string).

/// A message read field by field. A field past the end leaves nothing
/// read and marks the reader bad, so a message is checked once, at its
/// end.
pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    bad: bool = false,

    fn take(reader: *Reader, count: usize) ?[]const u8 {
        if (reader.bad or reader.bytes.len - reader.at < count) {
            reader.bad = true;
            return null;
        }
        const part = reader.bytes[reader.at..][0..count];
        reader.at += count;
        return part;
    }

    pub fn byte(reader: *Reader) u8 {
        const part = reader.take(1) orelse return 0;
        return part[0];
    }

    pub fn boolean(reader: *Reader) bool {
        return reader.byte() != 0;
    }

    pub fn uint32(reader: *Reader) u32 {
        const part = reader.take(4) orelse return 0;
        return get32(part);
    }

    pub fn string(reader: *Reader) []const u8 {
        const length = reader.uint32();
        return reader.take(length) orelse &.{};
    }
};

pub fn get32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
}

pub fn put32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value >> 24);
    bytes[1] = @truncate(value >> 16);
    bytes[2] = @truncate(value >> 8);
    bytes[3] = @truncate(value);
}

/// A message written field by field into `bytes`. A field that does not
/// fit is not written and marks the writer full.
pub const Writer = struct {
    bytes: []u8,
    at: usize = 0,
    full: bool = false,

    pub fn raw(writer: *Writer, data: []const u8) void {
        if (writer.full or writer.bytes.len - writer.at < data.len) {
            writer.full = true;
            return;
        }
        @memcpy(writer.bytes[writer.at..][0..data.len], data);
        writer.at += data.len;
    }

    pub fn byte(writer: *Writer, value: u8) void {
        writer.raw(&.{value});
    }

    pub fn boolean(writer: *Writer, value: bool) void {
        writer.byte(@intFromBool(value));
    }

    pub fn uint32(writer: *Writer, value: u32) void {
        var four: [4]u8 = undefined;
        put32(&four, value);
        writer.raw(&four);
    }

    pub fn string(writer: *Writer, data: []const u8) void {
        writer.uint32(@intCast(data.len));
        writer.raw(data);
    }

    /// `magnitude`, unsigned and most significant byte first, as an
    /// mpint: its leading zero bytes dropped, and one put back before a
    /// first byte whose top bit is set.
    pub fn mpint(writer: *Writer, magnitude: []const u8) void {
        var start: usize = 0;
        while (start < magnitude.len and magnitude[start] == 0) start += 1;
        const digits = magnitude[start..];
        const sign: usize = if (digits.len > 0 and digits[0] & 0x80 != 0) 1 else 0;
        writer.uint32(@intCast(digits.len + sign));
        if (sign != 0) writer.byte(0);
        writer.raw(digits);
    }

    pub fn written(writer: *const Writer) []u8 {
        return writer.bytes[0..writer.at];
    }
};

/// Whether the name-list `list` holds `name`.
pub fn hasName(list: []const u8, name: []const u8) bool {
    var names = Names{ .list = list };
    while (names.next()) |each| {
        if (same(each, name)) return true;
    }
    return false;
}

/// The client's first name in `client` that `ours` holds too - the
/// choice RFC 4253 (7.1) makes - as `ours` spells it; null when they
/// share none.
pub fn choose(client: []const u8, ours: []const u8) ?[]const u8 {
    var names = Names{ .list = client };
    while (names.next()) |each| {
        var mine = Names{ .list = ours };
        while (mine.next()) |own| {
            if (same(each, own)) return own;
        }
    }
    return null;
}

/// The names of a name-list in turn.
pub const Names = struct {
    list: []const u8,
    at: usize = 0,

    pub fn next(names: *Names) ?[]const u8 {
        if (names.at >= names.list.len) return null;
        const start = names.at;
        while (names.at < names.list.len and names.list[names.at] != ',') names.at += 1;
        const name = names.list[start..names.at];
        names.at += 1;
        return name;
    }
};

/// The first name of a name-list.
pub fn first(list: []const u8) []const u8 {
    var names = Names{ .list = list };
    return names.next() orelse &.{};
}

pub fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

// SPDX-License-Identifier: MIT
//! TLS's own encoding: big-endian numbers of one to three bytes, and
//! vectors that start with their length in one, two or three bytes. A
//! reader that answers null at the first thing past the end, and a
//! writer into a buffer the caller sized.

pub const Reader = struct {
    data: []const u8,

    pub fn of(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn atEnd(reader: *const Reader) bool {
        return reader.data.len == 0;
    }

    pub fn bytes(reader: *Reader, count: usize) ?[]const u8 {
        if (reader.data.len < count) return null;
        const taken = reader.data[0..count];
        reader.data = reader.data[count..];
        return taken;
    }

    pub fn number(reader: *Reader, comptime size: usize) ?u32 {
        const taken = reader.bytes(size) orelse return null;
        var value: u32 = 0;
        for (taken) |byte| value = value << 8 | byte;
        return value;
    }

    pub fn u8_(reader: *Reader) ?u8 {
        return @intCast(reader.number(1) orelse return null);
    }

    pub fn u16_(reader: *Reader) ?u16 {
        return @intCast(reader.number(2) orelse return null);
    }

    /// A vector whose length takes `size` bytes.
    pub fn vector(reader: *Reader, comptime size: usize) ?[]const u8 {
        const length = reader.number(size) orelse return null;
        return reader.bytes(length);
    }
};

pub const Writer = struct {
    buffer: []u8,
    length: usize = 0,

    pub fn of(buffer: []u8) Writer {
        return .{ .buffer = buffer };
    }

    pub fn bytes(writer: *Writer, data: []const u8) void {
        @memcpy(writer.buffer[writer.length..][0..data.len], data);
        writer.length += data.len;
    }

    pub fn number(writer: *Writer, comptime size: usize, value: u32) void {
        var index: usize = size;
        while (index > 0) {
            index -= 1;
            writer.buffer[writer.length] = @truncate(value >> @intCast(8 * index));
            writer.length += 1;
        }
    }

    /// Room for a length of `size` bytes, filled in by `close`.
    pub fn open(writer: *Writer, comptime size: usize) usize {
        const at = writer.length;
        writer.length += size;
        return at;
    }

    /// The length of what was written since `open`, into its room.
    pub fn close(writer: *Writer, comptime size: usize, at: usize) void {
        const length = writer.length - at - size;
        var index: usize = 0;
        while (index < size) : (index += 1) {
            writer.buffer[at + index] = @truncate(length >> @intCast(8 * (size - 1 - index)));
        }
    }

    pub fn written(writer: *const Writer) []u8 {
        return writer.buffer[0..writer.length];
    }
};

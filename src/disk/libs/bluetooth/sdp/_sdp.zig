// SPDX-License-Identifier: MIT
//! SDP's data elements (sdk.bluetooth.sdp) read and written: an element's
//! type and data found, a sequence's elements one after the other, a UUID
//! of any size made 128 bits, an unsigned integer read; the elements of
//! the library's own records made at compile time; a PDU's big-endian
//! fields.
//!
//! An element is read only where the bytes hold it whole: nothing here
//! reads past the end of what a device sent.

const sdk = @import("sdk");
const sdp = sdk.bluetooth.sdp;

/// One data element.
pub const Element = struct {
    /// Its type (sdp.DE_*).
    kind: u8,
    /// Its data, past its descriptor and its length.
    data: []const u8,
    /// How many bytes it takes, its descriptor on.
    whole: usize,
};

/// The element `bytes` begins with; null where they do not hold it whole.
pub fn element(bytes: []const u8) ?Element {
    if (bytes.len == 0) return null;
    const kind = bytes[0] >> 3;
    const size_index = bytes[0] & 0x7;
    if (kind == sdp.DE_NIL) return .{ .kind = kind, .data = bytes[1..1], .whole = 1 };
    var header: usize = 1;
    var length: usize = 0;
    switch (size_index) {
        sdp.DE_SIZE_LENGTH8 => {
            if (bytes.len < 2) return null;
            length = bytes[1];
            header = 2;
        },
        sdp.DE_SIZE_LENGTH16 => {
            if (bytes.len < 3) return null;
            length = be16(bytes[1..3]);
            header = 3;
        },
        sdp.DE_SIZE_LENGTH32 => {
            if (bytes.len < 5) return null;
            length = be32(bytes[1..5]);
            header = 5;
        },
        else => length = @as(usize, 1) << @intCast(size_index),
    }
    if (bytes.len - header < length) return null;
    return .{ .kind = kind, .data = bytes[header..][0..length], .whole = header + length };
}

/// A sequence's or an alternative's elements, one after the other.
pub const Items = struct {
    rest: []const u8,

    pub fn next(items: *Items) ?Element {
        const item = element(items.rest) orelse return null;
        items.rest = items.rest[item.whole..];
        return item;
    }
};

/// The elements of `list`, a sequence or an alternative; none for another
/// element.
pub fn itemsOf(list: Element) Items {
    if (list.kind != sdp.DE_SEQUENCE and list.kind != sdp.DE_ALTERNATIVE) return .{ .rest = &.{} };
    return .{ .rest = list.data };
}

/// A UUID element's value as 128 bits, big-endian; null for an element
/// that is not a UUID of 2, 4 or 16 bytes.
pub fn uuid(item: Element) ?[16]u8 {
    if (item.kind != sdp.DE_UUID) return null;
    var full = sdp.BASE_UUID;
    switch (item.data.len) {
        2 => {
            full[2] = item.data[0];
            full[3] = item.data[1];
        },
        4 => @memcpy(full[0..4], item.data),
        16 => @memcpy(&full, item.data),
        else => return null,
    }
    return full;
}

/// The value of a UUID on the base as 16 bits; 0 where it is not one.
pub fn short(full: [16]u8) u16 {
    if (full[0] != 0 or full[1] != 0) return 0;
    for (full[4..], sdp.BASE_UUID[4..]) |byte, base_byte| {
        if (byte != base_byte) return 0;
    }
    return @as(u16, full[2]) << 8 | full[3];
}

/// An unsigned integer element of 1, 2 or 4 bytes; null for another.
pub fn unsigned(item: Element) ?u32 {
    if (item.kind != sdp.DE_UINT) return null;
    return switch (item.data.len) {
        1 => item.data[0],
        2 => be16(item.data[0..2]),
        4 => be32(item.data[0..4]),
        else => null,
    };
}

/// How deep `holds` looks into sequences within sequences.
const DEPTH_MOST = 8;

/// Whether `bytes` - the elements of a record - hold the UUID `wanted`
/// anywhere, in sequences and alternatives as well.
pub fn holds(bytes: []const u8, wanted: [16]u8) bool {
    return holdsWithin(bytes, wanted, DEPTH_MOST);
}

fn holdsWithin(bytes: []const u8, wanted: [16]u8, depth: u32) bool {
    var items: Items = .{ .rest = bytes };
    while (items.next()) |item| {
        switch (item.kind) {
            sdp.DE_UUID => if (uuid(item)) |found| {
                if (sameUuid(found, wanted)) return true;
            },
            sdp.DE_SEQUENCE, sdp.DE_ALTERNATIVE => if (depth > 0 and holdsWithin(item.data, wanted, depth - 1)) return true,
            else => {},
        }
    }
    return false;
}

pub fn sameUuid(one: [16]u8, other: [16]u8) bool {
    for (one, other) |mine, theirs| {
        if (mine != theirs) return false;
    }
    return true;
}

// --- a record's elements, made at compile time --------------------------------------

pub fn uint16(comptime value: u16) [3]u8 {
    return .{ sdp.DE_UINT << 3 | 1, @truncate(value >> 8), @truncate(value) };
}

pub fn uint32(comptime value: u32) [5]u8 {
    return .{ sdp.DE_UINT << 3 | 2, @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
}

pub fn uuid16(comptime value: u16) [3]u8 {
    return .{ sdp.DE_UUID << 3 | 1, @truncate(value >> 8), @truncate(value) };
}

/// A sequence of up to 255 bytes of elements.
pub fn sequence(comptime body: []const u8) [2 + body.len]u8 {
    return [_]u8{ sdp.DE_SEQUENCE << 3 | sdp.DE_SIZE_LENGTH8, @intCast(body.len) } ++ body[0..body.len].*;
}

/// The descriptor and length of a sequence of `length` bytes, as an
/// answer writes it: always with 16 bits of length, 3 bytes.
pub fn putSequence16(into: *[3]u8, length: usize) void {
    into[0] = sdp.DE_SEQUENCE << 3 | sdp.DE_SIZE_LENGTH16;
    put16(into[1..3], @intCast(length));
}

// --- a PDU's fields ---------------------------------------------------------------

pub fn be16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

pub fn be32(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
}

pub fn put16(into: *[2]u8, value: u16) void {
    into[0] = @truncate(value >> 8);
    into[1] = @truncate(value);
}

pub fn put32(into: *[4]u8, value: u32) void {
    into[0] = @truncate(value >> 24);
    into[1] = @truncate(value >> 16);
    into[2] = @truncate(value >> 8);
    into[3] = @truncate(value);
}

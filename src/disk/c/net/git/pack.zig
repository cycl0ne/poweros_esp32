// SPDX-License-Identifier: MIT
//! A pack: `PACK`, version 2, how many entries, the entries, and the
//! SHA-1 of everything before it.
//!
//! **An entry** starts with its type in three bits and its size - the
//! object's, or the delta's - in a number of seven bits a byte, the
//! first byte giving four; a byte with its top bit set has another after
//! it. An OFS_DELTA follows with how far back its base starts, a
//! REF_DELTA with its base's id; then the zlib stream of the body.
//!
//! **A delta** is the base's size and the result's, each seven bits a
//! byte, and instructions: a byte with its top bit set copies from the
//! base - which of the offset's four bytes and the size's three follow
//! is in its low seven bits, a size of 0 meaning 65536 - and one without
//! inserts that many bytes that follow it.

const _git = @import("_git.zig");
const object = @import("object.zig");
const Id = _git.Id;
const Type = object.Type;

pub const header_bytes = 12;
pub const trailer_bytes = 20;

/// A pack's head: how many entries; null for no pack of version 2 or 3.
pub fn parseHeader(bytes: []const u8) ?u32 {
    if (bytes.len < header_bytes or !_git.same(bytes[0..4], "PACK")) return null;
    const version = _git.get32(bytes[4..8]);
    if (version != 2 and version != 3) return null;
    return _git.get32(bytes[8..12]);
}

/// A pack's head for `count` entries.
pub fn putHeader(into: *[header_bytes]u8, count: u32) void {
    @memcpy(into[0..4], "PACK");
    _git.put32(into[4..8], 2);
    _git.put32(into[8..12], count);
}

pub const EntryHead = struct {
    kind: Type,
    /// The object's size, or for a delta the delta's.
    size: u64,
    /// How many bytes the head took: the body's zlib stream starts there.
    length: usize,
    /// For an OFS_DELTA, how far before this entry its base starts.
    base_distance: u64 = 0,
    /// For a REF_DELTA, its base's id.
    base_id: Id = _git.zero_id,
};

pub const HeadError = enum { short, bad };

/// The head of the entry at the start of `bytes`: `.short` when `bytes`
/// end before it does, `.bad` when it is none.
pub fn parseEntryHead(bytes: []const u8) union(enum) { head: EntryHead, err: HeadError } {
    if (bytes.len == 0) return .{ .err = .short };
    var byte = bytes[0];
    const kind = object.typeOfBits(@truncate(byte >> 4)) orelse return .{ .err = .bad };
    var size: u64 = byte & 15;
    var shift: u32 = 4;
    var at: usize = 1;
    while (byte & 0x80 != 0) {
        if (at == bytes.len) return .{ .err = .short };
        if (shift > 60) return .{ .err = .bad };
        byte = bytes[at];
        at += 1;
        size |= @as(u64, byte & 0x7F) << @intCast(shift);
        shift += 7;
    }
    var head: EntryHead = .{ .kind = kind, .size = size, .length = at };
    switch (kind) {
        .ofs_delta => {
            // Each byte after the first adds one before it shifts: the
            // numbers each length can say do not overlap.
            if (at == bytes.len) return .{ .err = .short };
            byte = bytes[at];
            at += 1;
            var distance: u64 = byte & 0x7F;
            while (byte & 0x80 != 0) {
                if (at == bytes.len) return .{ .err = .short };
                if (distance > (~@as(u64, 0)) >> 8) return .{ .err = .bad };
                byte = bytes[at];
                at += 1;
                distance = ((distance + 1) << 7) | (byte & 0x7F);
            }
            head.base_distance = distance;
        },
        .ref_delta => {
            if (at + 20 > bytes.len) return .{ .err = .short };
            head.base_id = bytes[at..][0..20].*;
            at += 20;
        },
        else => {},
    }
    head.length = at;
    return .{ .head = head };
}

/// The head of an entry of `kind` and `size` - a whole object's, as a
/// pack written here holds only those: at most 10 bytes.
pub fn putEntryHead(into: *[10]u8, kind: Type, size: u64) []const u8 {
    var rest = size;
    var first: u8 = @as(u8, @intFromEnum(kind)) << 4 | @as(u8, @truncate(rest & 15));
    rest >>= 4;
    var at: usize = 0;
    while (rest != 0) {
        into[at] = first | 0x80;
        at += 1;
        first = @truncate(rest & 0x7F);
        rest >>= 7;
    }
    into[at] = first;
    return into[0 .. at + 1];
}

/// A delta's two sizes, and where its instructions start; null when the
/// sizes are cut short.
pub fn deltaSizes(delta: []const u8) ?struct { base: u64, result: u64, at: usize } {
    var at: usize = 0;
    const base = number(delta, &at) orelse return null;
    const result = number(delta, &at) orelse return null;
    return .{ .base = base, .result = result, .at = at };
}

fn number(bytes: []const u8, at: *usize) ?u64 {
    var value: u64 = 0;
    var shift: u32 = 0;
    while (true) {
        if (at.* == bytes.len or shift > 63) return null;
        const byte = bytes[at.*];
        at.* += 1;
        value |= @as(u64, byte & 0x7F) << @intCast(shift);
        if (byte & 0x80 == 0) return value;
        shift += 7;
    }
}

/// `delta` applied to `base`, into `into`, which holds exactly the
/// result's size: false when the delta does not fit the base or the
/// result.
pub fn applyDelta(base: []const u8, delta: []const u8, into: []u8) bool {
    const sizes = deltaSizes(delta) orelse return false;
    if (sizes.base != base.len or sizes.result != into.len) return false;
    var at = sizes.at;
    var out: usize = 0;
    while (at < delta.len) {
        const op = delta[at];
        at += 1;
        if (op & 0x80 != 0) {
            var offset: u64 = 0;
            var size: u64 = 0;
            inline for (0..4) |bit| {
                if (op & (1 << bit) != 0) {
                    if (at == delta.len) return false;
                    offset |= @as(u64, delta[at]) << (8 * bit);
                    at += 1;
                }
            }
            inline for (0..3) |bit| {
                if (op & (0x10 << bit) != 0) {
                    if (at == delta.len) return false;
                    size |= @as(u64, delta[at]) << (8 * bit);
                    at += 1;
                }
            }
            if (size == 0) size = 0x10000;
            if (offset + size > base.len or out + size > into.len) return false;
            const start: usize = @intCast(offset);
            const count: usize = @intCast(size);
            @memcpy(into[out..][0..count], base[start..][0..count]);
            out += count;
        } else if (op != 0) {
            const count: usize = op;
            if (at + count > delta.len or out + count > into.len) return false;
            @memcpy(into[out..][0..count], delta[at..][0..count]);
            out += count;
            at += count;
        } else {
            // 0 is reserved.
            return false;
        }
    }
    return out == into.len;
}

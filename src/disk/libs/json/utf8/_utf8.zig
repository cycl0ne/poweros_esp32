// SPDX-License-Identifier: MIT
//! UTF-8 as RFC 3629 has it, for reading and writing: how long the
//! character at a byte is - 0 for bytes that are not one, an overlong
//! form, a surrogate or past U+10FFFF among them - what it is, and a code
//! point put down as bytes.

/// The length of the character at `text[at]`, `end` the first byte past
/// the text: 1 to 4, or 0 when the bytes there are not UTF-8.
pub fn lengthAt(text: [*]const u8, at: usize, end: usize) u32 {
    const lead = text[at];
    if (lead < 0x80) return 1;
    // A continuation byte or the overlong lead of a 2-byte form.
    if (lead < 0xC2) return 0;
    const length: u32 = if (lead < 0xE0) 2 else if (lead < 0xF0) 3 else if (lead < 0xF5) 4 else return 0;
    if (at + length > end) return 0;
    // The second byte's range is narrower after some leads: no overlong
    // 3- or 4-byte form, no surrogate, nothing past U+10FFFF.
    const second = text[at + 1];
    const low: u8 = switch (lead) {
        0xE0 => 0xA0,
        0xF0 => 0x90,
        else => 0x80,
    };
    const high: u8 = switch (lead) {
        0xED => 0x9F,
        0xF4 => 0x8F,
        else => 0xBF,
    };
    if (second < low or second > high) return 0;
    var next: u32 = 2;
    while (next < length) : (next += 1) {
        const byte = text[at + next];
        if (byte < 0x80 or byte > 0xBF) return 0;
    }
    return length;
}

/// The code point of the character of `length` bytes at `text[at]`,
/// checked already.
pub fn decode(text: [*]const u8, at: usize, length: u32) u21 {
    const lead = text[at];
    var point: u21 = switch (length) {
        1 => return lead,
        2 => lead & 0x1F,
        3 => lead & 0x0F,
        else => lead & 0x07,
    };
    var next: u32 = 1;
    while (next < length) : (next += 1) point = (point << 6) | (text[at + next] & 0x3F);
    return point;
}

/// `point` put down as UTF-8 at `into`: how many bytes it took.
pub fn encode(point: u21, into: [*]u8) u32 {
    if (point < 0x80) {
        into[0] = @intCast(point);
        return 1;
    }
    if (point < 0x800) {
        into[0] = @intCast(0xC0 | (point >> 6));
        into[1] = @intCast(0x80 | (point & 0x3F));
        return 2;
    }
    if (point < 0x10000) {
        into[0] = @intCast(0xE0 | (point >> 12));
        into[1] = @intCast(0x80 | ((point >> 6) & 0x3F));
        into[2] = @intCast(0x80 | (point & 0x3F));
        return 3;
    }
    into[0] = @intCast(0xF0 | (point >> 18));
    into[1] = @intCast(0x80 | ((point >> 12) & 0x3F));
    into[2] = @intCast(0x80 | ((point >> 6) & 0x3F));
    into[3] = @intCast(0x80 | (point & 0x3F));
    return 4;
}

/// What stands for a character that cannot be: U+FFFD.
pub const replacement: u21 = 0xFFFD;

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "UTF-8: the forms RFC 3629 allows, and none of the others" {
    const good = [_][]const u8{ "A", "\xC3\xA4", "\xE2\x82\xAC", "\xF0\x9F\x98\x80", "\xF4\x8F\xBF\xBF", "\xED\x9F\xBF" };
    for (good) |text| try testing.expectEqual(@as(u32, @intCast(text.len)), lengthAt(text.ptr, 0, text.len));
    const bad = [_][]const u8{ "\x80", "\xC0\xAF", "\xC1\xBF", "\xE0\x80\xAF", "\xED\xA0\x80", "\xF0\x8F\xBF\xBF", "\xF4\x90\x80\x80", "\xF5\x80\x80\x80", "\xC3", "\xE2\x82" };
    for (bad) |text| try testing.expectEqual(@as(u32, 0), lengthAt(text.ptr, 0, text.len));
}

test "UTF-8: code points out and back" {
    var into: [4]u8 = undefined;
    for ([_]u21{ 0x41, 0xE4, 0x20AC, 0x1F600, 0x10FFFF }) |point| {
        const length = encode(point, &into);
        try testing.expectEqual(length, lengthAt(&into, 0, length));
        try testing.expectEqual(point, decode(&into, 0, length));
    }
}

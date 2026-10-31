// SPDX-License-Identifier: MIT
//! A container's H.264 and H.265 packets turned into the form the chip is
//! fed: Annex B, each unit after a start code.
//!
//! **In an MP4** a packet is a picture's units one after the other, each
//! with its length in front - 1, 2 or 4 bytes, high byte first, as many
//! as the track's setup says - and the parameter sets the decoder needs
//! first are in the setup, not among the packets: H.264's avcC record
//! (ISO 14496-15 5.3.3) holds the SPS and the PPS, H.265's hvcC (8.3.3)
//! arrays of units, the VPS, the SPS and the PPS among them.
//!
//! **Annex B** puts a start code - 00 00 00 01 - in front of each unit
//! instead, and the parameter sets go in front of a picture as units like
//! the rest. They are put in front of every key picture, so a decoder
//! that starts there after a seek has them; a decoder takes them again as
//! they are.

/// The start code put in front of every unit.
pub const start_code = [4]u8{ 0, 0, 0, 1 };

/// What a track's setup says: how many bytes each unit's length takes,
/// and how long its parameter sets are in Annex B form.
pub const Setup = struct {
    length_size: u8,
    header_size: usize,
};

/// An avcC record read: its length size, and its parameter sets in Annex
/// B form written into `out` when it is given (`header_size` bytes).
/// Null for a record that is not one.
pub fn avcSetup(config: []const u8, out: ?[]u8) ?Setup {
    // version, profile, compatibility, level, then the length size.
    if (config.len < 7 or config[0] != 1) return null;
    const length_size = (config[4] & 3) + 1;
    if (length_size == 3) return null;
    var at: usize = 5;
    var size: usize = 0;
    // The SPS (a count of five bits), then the PPS (a count of eight).
    const sps = config[at] & 0x1F;
    at += 1;
    size = units(config, &at, sps, size, out) orelse return null;
    if (at >= config.len) return null;
    const pps = config[at];
    at += 1;
    size = units(config, &at, pps, size, out) orelse return null;
    return .{ .length_size = length_size, .header_size = size };
}

/// An hvcC record read, as avcSetup.
pub fn hevcSetup(config: []const u8, out: ?[]u8) ?Setup {
    // 21 bytes of profile, level and format, then the length size, then
    // how many arrays of units.
    if (config.len < 23 or config[0] != 1) return null;
    const length_size = (config[21] & 3) + 1;
    if (length_size == 3) return null;
    const arrays = config[22];
    var at: usize = 23;
    var size: usize = 0;
    for (0..arrays) |_| {
        // The array's kind of unit, then how many.
        if (at + 3 > config.len) return null;
        const count = be16(config[at + 1 ..]);
        at += 3;
        size = units(config, &at, count, size, out) orelse return null;
    }
    return .{ .length_size = length_size, .header_size = size };
}

/// `count` units each after a two-byte length, from `at` on, written
/// after start codes into `out` from `size` on: how far `out` is filled,
/// or null when they run past the record.
fn units(config: []const u8, at: *usize, count: usize, size: usize, out: ?[]u8) ?usize {
    var filled = size;
    for (0..count) |_| {
        if (at.* + 2 > config.len) return null;
        const length = be16(config[at.*..]);
        at.* += 2;
        if (at.* + length > config.len) return null;
        if (out) |into| {
            @memcpy(into[filled..][0..4], &start_code);
            @memcpy(into[filled + 4 ..][0..length], config[at.*..][0..length]);
        }
        filled += 4 + length;
        at.* += length;
    }
    return filled;
}

/// How many bytes `packet` takes in Annex B form; null when its lengths
/// do not add up to it.
pub fn convertedSize(packet: []const u8, length_size: u8) ?usize {
    var at: usize = 0;
    var size: usize = 0;
    while (at < packet.len) {
        if (at + length_size > packet.len) return null;
        const length = lengthAt(packet[at..], length_size);
        at += length_size;
        if (length > packet.len - at) return null;
        size += 4 + length;
        at += length;
    }
    return size;
}

/// `packet` in Annex B form into `out`, which is `convertedSize` long at
/// least: how many bytes it took. The units are copied by `copy`.
pub fn convert(packet: []const u8, length_size: u8, out: []u8, copy: anytype) usize {
    var at: usize = 0;
    var filled: usize = 0;
    while (at + length_size <= packet.len) {
        const length = lengthAt(packet[at..], length_size);
        at += length_size;
        @memcpy(out[filled..][0..4], &start_code);
        copy.bytes(packet[at..][0..length], out[filled + 4 ..][0..length]);
        filled += 4 + length;
        at += length;
    }
    return filled;
}

fn lengthAt(bytes: []const u8, length_size: u8) usize {
    var length: usize = 0;
    for (bytes[0..length_size]) |byte| length = (length << 8) | byte;
    return length;
}

fn be16(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

const Plain = struct {
    fn bytes(_: Plain, from: []const u8, into: []u8) void {
        @memcpy(into, from);
    }
};

test "an avcC record: its length size, its SPS and PPS after start codes" {
    // Version 1, High profile 4.0, four-byte lengths, one SPS of 4 bytes,
    // one PPS of 3.
    const record = [_]u8{ 1, 0x64, 0, 0x28, 0xFF, 0xE1, 0, 4, 0x67, 0x64, 0, 0x28, 1, 0, 3, 0x68, 0xEE, 0x3C };
    const setup = avcSetup(&record, null).?;
    try testing.expectEqual(@as(u8, 4), setup.length_size);
    try testing.expectEqual(@as(usize, 8 + 7), setup.header_size);
    var header: [15]u8 = undefined;
    _ = avcSetup(&record, &header).?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x67, 0x64, 0, 0x28, 0, 0, 0, 1, 0x68, 0xEE, 0x3C }, &header);
    // Cut short, or of another version: none.
    try testing.expect(avcSetup(record[0..12], null) == null);
    var other = record;
    other[0] = 0;
    try testing.expect(avcSetup(&other, null) == null);
}

test "an hvcC record: its arrays of units" {
    var record: [23 + 3 + 2 + 3 + 3 + 2 + 2]u8 = @splat(0);
    record[0] = 1;
    record[21] = 0x0D; // two-byte lengths
    record[22] = 2; // two arrays
    // The VPS: one unit of 3 bytes.
    @memcpy(record[23..31], &[_]u8{ 0x20, 0, 1, 0, 3, 0x40, 1, 0x0C });
    // The SPS: one unit of 2 bytes.
    @memcpy(record[31..38], &[_]u8{ 0x21, 0, 1, 0, 2, 0x42, 1 });
    const setup = hevcSetup(record[0..38], null).?;
    try testing.expectEqual(@as(u8, 2), setup.length_size);
    try testing.expectEqual(@as(usize, 7 + 6), setup.header_size);
    var header: [13]u8 = undefined;
    _ = hevcSetup(record[0..38], &header).?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x40, 1, 0x0C, 0, 0, 0, 1, 0x42, 1 }, &header);
    record[22] = 3; // an array more than there is
    try testing.expect(hevcSetup(record[0..38], null) == null);
}

test "a packet's units after start codes, whatever their lengths' size" {
    // Two units, of 2 and 3 bytes, with one-byte lengths.
    const one = [_]u8{ 2, 0xAA, 0xBB, 3, 1, 2, 3 };
    try testing.expectEqual(@as(?usize, 13), convertedSize(&one, 1));
    var out: [13]u8 = undefined;
    try testing.expectEqual(@as(usize, 13), convert(&one, 1, &out, Plain{}));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0xAA, 0xBB, 0, 0, 0, 1, 1, 2, 3 }, &out);
    // Four-byte lengths: the same size.
    const four = [_]u8{ 0, 0, 0, 2, 0xAA, 0xBB };
    try testing.expectEqual(@as(?usize, 6), convertedSize(&four, 4));
    // A length past the packet, or one cut in two: not a packet.
    try testing.expect(convertedSize(&[_]u8{ 4, 1, 2 }, 1) == null);
    try testing.expect(convertedSize(&[_]u8{ 0, 0, 1 }, 4) == null);
    try testing.expectEqual(@as(?usize, 0), convertedSize(&[_]u8{}, 4));
}

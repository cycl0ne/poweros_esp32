// SPDX-License-Identifier: MIT
//! Modbus RTU's frame: the unit's number, the PDU, and a CRC-16 over
//! both, low byte first. The CRC is the reflected one of polynomial
//! 0x8005 from 0xFFFF (CRC-16/MODBUS), worked a bit at a time.
//!
//! A frame ends where the line goes quiet for three and a half
//! characters; above 19200 bit/s the protocol fixes that at 1750 µs
//! (`gapTenths`), so fast lines are not held up by a gap that has
//! become very short.

const sdk = @import("sdk");
const modbus = sdk.modbus;

/// The unit, the longest PDU and the CRC.
pub const max_frame = 1 + modbus.MB_MAX_PDU + 2;

pub fn crc(bytes: []const u8) u16 {
    var value: u16 = 0xFFFF;
    for (bytes) |byte| {
        value ^= byte;
        for (0..8) |_| {
            const low = value & 1 != 0;
            value >>= 1;
            if (low) value ^= 0xA001;
        }
    }
    return value;
}

/// A frame for `unit` round `pdu`, into `into`; its length.
pub fn frame(unit: u32, pdu: []const u8, into: []u8) usize {
    into[0] = @truncate(unit);
    @memcpy(into[1..][0..pdu.len], pdu);
    const sum = crc(into[0 .. 1 + pdu.len]);
    into[1 + pdu.len] = @truncate(sum);
    into[2 + pdu.len] = @truncate(sum >> 8);
    return 3 + pdu.len;
}

/// The unit and the PDU of a frame whose CRC is right, or null.
pub fn open(bytes: []const u8) ?struct { unit: u8, pdu: []const u8 } {
    if (bytes.len < 4) return null;
    const body = bytes[0 .. bytes.len - 2];
    const sum = crc(body);
    if (bytes[bytes.len - 2] != @as(u8, @truncate(sum)) or bytes[bytes.len - 1] != @as(u8, @truncate(sum >> 8))) return null;
    return .{ .unit = bytes[0], .pdu = body[1..] };
}

/// The quiet time that ends a frame, in tenths of a character of
/// `character_bits`: 3.5 characters, or 1750 µs above 19200 bit/s.
pub fn gapTenths(baud: u32, character_bits: u32) u32 {
    if (baud <= 19200) return 35;
    const tenths = (@as(u64, 1750) * baud * 10 + @as(u64, character_bits) * 1_000_000 - 1) / (@as(u64, character_bits) * 1_000_000);
    return @intCast(@max(tenths, 15));
}

const testing = @import("std").testing;

test "the CRC of a known frame" {
    // Read 10 holding registers from 0 of unit 1: 01 03 00 00 00 0A C5 CD.
    var into: [16]u8 = undefined;
    const length = frame(1, &.{ 3, 0, 0, 0, 10 }, &into);
    try testing.expectEqualSlices(u8, &.{ 1, 3, 0, 0, 0, 10, 0xC5, 0xCD }, into[0..length]);
    const opened = open(into[0..length]).?;
    try testing.expectEqual(@as(u8, 1), opened.unit);
    try testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0, 10 }, opened.pdu);
    into[3] ^= 1;
    try testing.expect(open(into[0..length]) == null);
}

test "the gap" {
    try testing.expectEqual(@as(u32, 35), gapTenths(9600, 11));
    // 1750 µs at 115200 bit/s is about 18.3 characters of 11 bits.
    try testing.expectEqual(@as(u32, 184), gapTenths(115200, 11));
}

// SPDX-License-Identifier: MIT
//! Modbus TCP's header (MBAP), seven bytes before each PDU: the
//! transaction's number, which the answer repeats; the protocol, always
//! 0; the length of what follows (the unit and the PDU); and the unit.

const sdk = @import("sdk");
const modbus = sdk.modbus;

pub const header_length = 7;
/// The header and the longest PDU.
pub const max_message = header_length + modbus.MB_MAX_PDU;

pub const Header = struct { transaction: u16, length: u16, unit: u8 };

/// A message for `unit` round `pdu`, into `into`; its length.
pub fn message(transaction: u16, unit: u32, pdu: []const u8, into: []u8) usize {
    into[0] = @truncate(transaction >> 8);
    into[1] = @truncate(transaction);
    into[2] = 0;
    into[3] = 0;
    const length: u16 = @intCast(pdu.len + 1);
    into[4] = @truncate(length >> 8);
    into[5] = @truncate(length);
    into[6] = @truncate(unit);
    @memcpy(into[header_length..][0..pdu.len], pdu);
    return header_length + pdu.len;
}

/// A header read, or null when it is not Modbus's or says a length no
/// PDU has.
pub fn header(bytes: *const [header_length]u8) ?Header {
    if (bytes[2] != 0 or bytes[3] != 0) return null;
    const length: u16 = @as(u16, bytes[4]) << 8 | bytes[5];
    if (length < 2 or length > modbus.MB_MAX_PDU + 1) return null;
    return .{ .transaction = @as(u16, bytes[0]) << 8 | bytes[1], .length = length, .unit = bytes[6] };
}

const testing = @import("std").testing;

test "a header both ways" {
    var into: [32]u8 = undefined;
    const length = message(0x1234, 17, &.{ 3, 0, 1, 0, 2 }, &into);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0, 0, 0, 6, 17, 3, 0, 1, 0, 2 }, into[0..length]);
    const read = header(into[0..header_length]).?;
    try testing.expectEqual(@as(u16, 0x1234), read.transaction);
    try testing.expectEqual(@as(u16, 6), read.length);
    try testing.expectEqual(@as(u8, 17), read.unit);
    into[2] = 1;
    try testing.expect(header(into[0..header_length]) == null);
}

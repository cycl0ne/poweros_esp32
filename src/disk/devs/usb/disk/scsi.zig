// SPDX-License-Identifier: MIT
//! The SCSI commands a stick is driven with, and what their answers say:
//! command blocks built, data read - with no hardware and no system, so
//! the host tests hold it.
//!
//! A command block's numbers are big-endian. The commands are the few a
//! disk needs: INQUIRY (what the unit is, whether its medium comes out),
//! TEST UNIT READY (whether a medium is in), READ CAPACITY (10, and 16
//! for a medium past 2 TiB), READ and WRITE (10, and 16 past 2^32
//! blocks), REQUEST SENSE (why the last command failed) and MODE SENSE(6)
//! (whether the medium is write-protected).

pub const OP_TEST_UNIT_READY: u8 = 0x00;
pub const OP_REQUEST_SENSE: u8 = 0x03;
pub const OP_INQUIRY: u8 = 0x12;
pub const OP_MODE_SENSE_6: u8 = 0x1A;
pub const OP_READ_CAPACITY_10: u8 = 0x25;
pub const OP_READ_10: u8 = 0x28;
pub const OP_WRITE_10: u8 = 0x2A;
pub const OP_READ_16: u8 = 0x88;
pub const OP_WRITE_16: u8 = 0x8A;
pub const OP_SERVICE_ACTION_IN_16: u8 = 0x9E;
/// SERVICE ACTION IN(16)'s action: READ CAPACITY(16).
const SA_READ_CAPACITY_16: u8 = 0x10;

/// What the answers are asked to fill.
pub const inquiry_bytes = 36;
pub const sense_bytes = 18;
pub const capacity_10_bytes = 8;
pub const capacity_16_bytes = 32;
pub const mode_sense_bytes = 4;

/// A command block: up to 16 bytes, and how many of them it is.
pub const Command = struct {
    bytes: [16]u8 = @splat(0),
    len: u8 = 6,

    pub fn slice(cdb: *const Command) []const u8 {
        return cdb.bytes[0..cdb.len];
    }
};

fn put32(into: []u8, value: u32) void {
    into[0] = @truncate(value >> 24);
    into[1] = @truncate(value >> 16);
    into[2] = @truncate(value >> 8);
    into[3] = @truncate(value);
}

fn put64(into: []u8, value: u64) void {
    put32(into[0..4], @truncate(value >> 32));
    put32(into[4..8], @truncate(value));
}

pub fn get32(from: []const u8) u32 {
    return @as(u32, from[0]) << 24 | @as(u32, from[1]) << 16 | @as(u32, from[2]) << 8 | from[3];
}

fn get64(from: []const u8) u64 {
    return @as(u64, get32(from[0..4])) << 32 | get32(from[4..8]);
}

pub fn testUnitReady() Command {
    return .{};
}

pub fn requestSense() Command {
    var cdb: Command = .{};
    cdb.bytes[0] = OP_REQUEST_SENSE;
    cdb.bytes[4] = sense_bytes;
    return cdb;
}

pub fn inquiry() Command {
    var cdb: Command = .{};
    cdb.bytes[0] = OP_INQUIRY;
    cdb.bytes[4] = inquiry_bytes;
    return cdb;
}

/// MODE SENSE(6) of every page, its header only wanted: the header's
/// third byte carries the write protection.
pub fn modeSense() Command {
    var cdb: Command = .{};
    cdb.bytes[0] = OP_MODE_SENSE_6;
    cdb.bytes[2] = 0x3F;
    cdb.bytes[4] = mode_sense_bytes;
    return cdb;
}

pub fn readCapacity10() Command {
    var cdb: Command = .{ .len = 10 };
    cdb.bytes[0] = OP_READ_CAPACITY_10;
    return cdb;
}

pub fn readCapacity16() Command {
    var cdb: Command = .{ .len = 16 };
    cdb.bytes[0] = OP_SERVICE_ACTION_IN_16;
    cdb.bytes[1] = SA_READ_CAPACITY_16;
    put32(cdb.bytes[10..14], capacity_16_bytes);
    return cdb;
}

/// READ or WRITE of `count` blocks from `block` on: the 10-byte form
/// while the numbers fit it, else the 16-byte one.
pub fn readWrite(write: bool, block: u64, count: u32) Command {
    if (block + count <= 0xFFFF_FFFF and count <= 0xFFFF) {
        var cdb: Command = .{ .len = 10 };
        cdb.bytes[0] = if (write) OP_WRITE_10 else OP_READ_10;
        put32(cdb.bytes[2..6], @truncate(block));
        cdb.bytes[7] = @truncate(count >> 8);
        cdb.bytes[8] = @truncate(count);
        return cdb;
    }
    var cdb: Command = .{ .len = 16 };
    cdb.bytes[0] = if (write) OP_WRITE_16 else OP_READ_16;
    put64(cdb.bytes[2..10], block);
    put32(cdb.bytes[10..14], count);
    return cdb;
}

/// What INQUIRY says about a unit.
pub const Inquiry = struct {
    /// The peripheral device type: 0 a disk.
    device_type: u8,
    /// Its medium can be taken out (RMB).
    removable: bool,
    /// The vendor's and the product's names, padded with spaces.
    vendor: [8]u8,
    product: [16]u8,
};

/// Device types a block device of 512-byte or larger blocks serves: a
/// disk, and an optical memory one.
pub const TYPE_DISK: u8 = 0x00;
pub const TYPE_OPTICAL_MEMORY: u8 = 0x07;

pub fn inquiryOf(data: []const u8) ?Inquiry {
    if (data.len < inquiry_bytes) return null;
    return .{
        .device_type = data[0] & 0x1F,
        .removable = data[1] & 0x80 != 0,
        .vendor = data[8..16].*,
        .product = data[16..32].*,
    };
}

/// A medium's size: the bytes of a block, and how many blocks.
pub const Capacity = struct { block_bytes: u32, blocks: u64 };

/// READ CAPACITY(10)'s answer. A last block of 0xFFFFFFFF says the medium
/// is too large for it: null, and READ CAPACITY(16) is asked.
pub fn capacity10Of(data: []const u8) ?Capacity {
    if (data.len < capacity_10_bytes) return null;
    const last = get32(data[0..4]);
    if (last == 0xFFFF_FFFF) return null;
    return .{ .blocks = @as(u64, last) + 1, .block_bytes = get32(data[4..8]) };
}

pub fn capacity16Of(data: []const u8) ?Capacity {
    if (data.len < 12) return null;
    return .{ .blocks = get64(data[0..8]) +% 1, .block_bytes = get32(data[8..12]) };
}

/// Whether a medium's size is one a block device can serve: a block of
/// 512 bytes to 64 KiB, a power of two, and at least one of them.
pub fn usable(capacity: Capacity) bool {
    const size = capacity.block_bytes;
    return capacity.blocks != 0 and size >= 512 and size <= 65536 and size & (size - 1) == 0;
}

/// The sense key and its codes: why a command ended in CHECK CONDITION.
pub const Sense = struct {
    key: u8,
    /// The additional sense code and its qualifier.
    code: u8,
    qualifier: u8,

    /// The medium is not there: NOT READY, MEDIUM NOT PRESENT.
    pub fn noMedium(sense: Sense) bool {
        return sense.key == KEY_NOT_READY and sense.code == ASC_MEDIUM_NOT_PRESENT;
    }

    /// The medium may have changed: UNIT ATTENTION, of any code.
    pub fn changed(sense: Sense) bool {
        return sense.key == KEY_UNIT_ATTENTION;
    }

    /// It is becoming ready: NOT READY, LOGICAL UNIT IS IN PROCESS OF
    /// BECOMING READY - asked again a little later.
    pub fn becomingReady(sense: Sense) bool {
        return sense.key == KEY_NOT_READY and sense.code == ASC_NOT_READY and sense.qualifier == 0x01;
    }

    pub fn writeProtected(sense: Sense) bool {
        return sense.key == KEY_DATA_PROTECT;
    }
};

pub const KEY_NO_SENSE: u8 = 0x0;
pub const KEY_NOT_READY: u8 = 0x2;
pub const KEY_MEDIUM_ERROR: u8 = 0x3;
pub const KEY_UNIT_ATTENTION: u8 = 0x6;
pub const KEY_DATA_PROTECT: u8 = 0x7;
const ASC_NOT_READY: u8 = 0x04;
const ASC_MEDIUM_NOT_PRESENT: u8 = 0x3A;

/// REQUEST SENSE's answer, fixed format; null for one too short to say.
pub fn senseOf(data: []const u8) ?Sense {
    if (data.len < 14) return null;
    const response = data[0] & 0x7F;
    if (response != 0x70 and response != 0x71) return null;
    return .{ .key = data[2] & 0x0F, .code = data[12], .qualifier = data[13] };
}

/// MODE SENSE(6)'s header: whether the medium is write-protected (WP, the
/// device-specific byte's top bit).
pub fn writeProtectedOf(data: []const u8) bool {
    if (data.len < 3) return false;
    return data[2] & 0x80 != 0;
}

/// A name of `bytes` with the spaces around it cut off.
pub fn trimmed(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] == ' ' or bytes[end - 1] == 0)) end -= 1;
    var start: usize = 0;
    while (start < end and bytes[start] == ' ') start += 1;
    return bytes[start..end];
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "a read is READ(10) while it fits, READ(16) past 2^32 blocks" {
    const small = readWrite(false, 0x1234, 8);
    try testing.expectEqual(@as(u8, 10), small.len);
    try testing.expectEqualSlices(u8, &.{ OP_READ_10, 0, 0, 0, 0x12, 0x34, 0, 0, 8, 0 }, small.slice());
    const write = readWrite(true, 7, 0x0102);
    try testing.expectEqual(OP_WRITE_10, write.bytes[0]);
    try testing.expectEqual(@as(u8, 0x01), write.bytes[7]);
    try testing.expectEqual(@as(u8, 0x02), write.bytes[8]);
    const large = readWrite(false, 0x1_0000_0000, 1);
    try testing.expectEqual(@as(u8, 16), large.len);
    try testing.expectEqualSlices(u8, &.{ OP_READ_16, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0 }, large.slice());
}

test "INQUIRY: a removable disk and its names" {
    var data: [inquiry_bytes]u8 = @splat(' ');
    data[0] = 0x00;
    data[1] = 0x80;
    @memcpy(data[8..15], "SanDisk");
    @memcpy(data[16..26], "Cruzer Fit");
    const said = inquiryOf(&data).?;
    try testing.expectEqual(TYPE_DISK, said.device_type);
    try testing.expect(said.removable);
    try testing.expectEqualStrings("SanDisk", trimmed(&said.vendor));
    try testing.expectEqualStrings("Cruzer Fit", trimmed(&said.product));
    try testing.expectEqualStrings("USB", trimmed(" USB    "));
    try testing.expect(inquiryOf(data[0..20]) == null);
}

test "capacity: the 10-byte answer, and the one that sends to the 16-byte" {
    const eight_gb = [_]u8{ 0x00, 0xEE, 0x7F, 0xFF, 0x00, 0x00, 0x02, 0x00 };
    const said = capacity10Of(&eight_gb).?;
    try testing.expectEqual(@as(u64, 0xEE8000), said.blocks);
    try testing.expectEqual(@as(u32, 512), said.block_bytes);
    try testing.expect(usable(said));
    try testing.expect(capacity10Of(&.{ 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 2, 0 }) == null);
    var long: [capacity_16_bytes]u8 = @splat(0);
    long[3] = 0x01; // the last block 0x1_FFFF_FFFF: 2^33 blocks
    long[4] = 0xFF;
    long[5] = 0xFF;
    long[6] = 0xFF;
    long[7] = 0xFF;
    long[10] = 0x10; // 4096-byte blocks
    const big = capacity16Of(&long).?;
    try testing.expectEqual(@as(u64, 0x2_0000_0000), big.blocks);
    try testing.expectEqual(@as(u32, 4096), big.block_bytes);
    try testing.expect(!usable(.{ .blocks = 10, .block_bytes = 520 }));
    try testing.expect(!usable(.{ .blocks = 0, .block_bytes = 512 }));
}

test "sense: no medium, a change, becoming ready, write-protected" {
    var data: [sense_bytes]u8 = @splat(0);
    data[0] = 0x70;
    data[2] = KEY_NOT_READY;
    data[12] = 0x3A;
    try testing.expect(senseOf(&data).?.noMedium());
    data[2] = KEY_UNIT_ATTENTION;
    data[12] = 0x28;
    try testing.expect(senseOf(&data).?.changed());
    data[2] = KEY_NOT_READY;
    data[12] = 0x04;
    data[13] = 0x01;
    try testing.expect(senseOf(&data).?.becomingReady());
    data[2] = KEY_DATA_PROTECT;
    try testing.expect(senseOf(&data).?.writeProtected());
    data[0] = 0x00;
    try testing.expect(senseOf(&data) == null);
}

test "MODE SENSE's header says write-protected in its third byte" {
    try testing.expect(writeProtectedOf(&.{ 3, 0, 0x80, 0 }));
    try testing.expect(!writeProtectedOf(&.{ 3, 0, 0x00, 0 }));
}

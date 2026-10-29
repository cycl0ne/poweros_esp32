// SPDX-License-Identifier: MPL-2.0
//! What the calls share: where the bits are, whether what is there adds
//! up, and bits moved between it and a caller's buffer.

const sdk = @import("sdk");
const hardware = sdk.hardware;
const battmem = sdk.resources.battmem;
const _base = @import("../battmem_base.zig");
const BattMemBase = _base.BattMemBase;
const Store = _base.Store;

const magic: u32 = 0x424D_454D; // "BMEM"

comptime {
    if (hardware.chip != .rv64sbi and hardware.chip != .a64psci and @sizeOf(Store) > hardware.rtc_timer.batt_memory_size) @compileError("the bits do not fit their memory");
}

/// Where a chip keeps the bits: the RTC memory past the clock's on the
/// ESP32s, the base itself on a chip with none.
pub fn storeOf(mb: *BattMemBase) *Store {
    return switch (hardware.chip) {
        .rv64sbi, .a64psci => &mb.own,
        else => @ptrFromInt(hardware.rtc_timer.batt_memory),
    };
}

/// FNV-1a over the magic number and the bits.
fn checksumOf(store: *const Store) u32 {
    const head: [4]u8 = @bitCast(store.magic);
    var hash: u32 = 0x811C_9DC5;
    for (head) |byte| hash = (hash ^ byte) *% 0x0100_0193;
    for (store.bytes) |byte| hash = (hash ^ byte) *% 0x0100_0193;
    return hash;
}

/// What is in `store` if it adds up; every bit 0 otherwise - after a
/// power-on, or a reset in the middle of a write.
pub fn settle(store: *Store) void {
    if (store.magic == magic and store.checksum == checksumOf(store)) return;
    var fresh: Store = .{ .magic = magic, .checksum = 0, .bytes = @splat(0) };
    fresh.checksum = checksumOf(&fresh);
    store.* = fresh;
}

/// Whether `length` bits from `offset` are all within the memory.
pub fn within(offset: u32, length: u32) bool {
    return length <= battmem.BATTMEM_BITS and offset <= battmem.BATTMEM_BITS - length;
}

/// `length` bits of `from`, from bit `from_at`, into `into` from bit
/// `into_at`; the other bits of `into` stay as they are.
pub fn copyBits(into: [*]u8, into_at: u32, from: [*]const u8, from_at: u32, length: u32) void {
    var done: u32 = 0;
    while (done < length) : (done += 1) {
        const source = from_at + done;
        const target = into_at + done;
        const bit: u8 = from[source / 8] >> @intCast(source % 8) & 1;
        const place: u3 = @intCast(target % 8);
        into[target / 8] = into[target / 8] & ~(@as(u8, 1) << place) | bit << place;
    }
}

/// `length` bits of `buffer` written at `offset`: into a copy, which goes
/// back whole with its check sum.
pub fn write(store: *Store, buffer: [*]const u8, offset: u32, length: u32) void {
    var copy = store.*;
    copyBits(&copy.bytes, offset, buffer, 0, length);
    copy.checksum = checksumOf(&copy);
    store.* = copy;
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "bits nobody wrote, or that do not add up, are all 0" {
    var store: Store = .{ .magic = 0x1234, .checksum = 5, .bytes = @splat(0xA5) };
    settle(&store);
    try testing.expectEqual(magic, store.magic);
    for (store.bytes) |byte| try testing.expectEqual(@as(u8, 0), byte);
    // Written, it adds up and stays.
    write(&store, &[_]u8{0xFF}, 3, 5);
    settle(&store);
    try testing.expectEqual(@as(u8, 0xF8), store.bytes[0]);
    // A bit turned over is a reset in the middle of a write.
    store.bytes[10] ^= 1;
    settle(&store);
    try testing.expectEqual(@as(u8, 0), store.bytes[0]);
}

test "bits across bytes, both ways, and the bits around them left alone" {
    var store: Store = .{ .magic = 0, .checksum = 0, .bytes = @splat(0) };
    settle(&store);
    const value: u64 = 0x8123_4567_89AB_CDEF;
    const bytes: [8]u8 = @bitCast(value);
    write(&store, &bytes, 13, 64);
    var back: [8]u8 = @splat(0);
    copyBits(&back, 0, &store.bytes, 13, 64);
    try testing.expectEqual(value, @as(u64, @bitCast(back)));
    try testing.expectEqual(@as(u8, 0), store.bytes[0]);
    try testing.expectEqual(@as(u8, 0), store.bytes[1] & 0x1F);
    try testing.expectEqual(@as(u8, 0), store.bytes[9] & 0xE0);
    // A read of fewer bits leaves the rest of the last byte.
    var part: [2]u8 = .{ 0xFF, 0xFF };
    copyBits(&part, 0, &store.bytes, 13, 12);
    try testing.expectEqual(@as(u8, 0xEF), part[0]);
    try testing.expectEqual(@as(u8, 0xFD), part[1]);
}

test "only bits within the memory" {
    try testing.expect(within(0, battmem.BATTMEM_BITS));
    try testing.expect(within(battmem.BATTMEM_BITS, 0));
    try testing.expect(!within(1, battmem.BATTMEM_BITS));
    try testing.expect(!within(0xFFFF_FFFF, 2));
    try testing.expect(!within(2, 0xFFFF_FFFF));
}

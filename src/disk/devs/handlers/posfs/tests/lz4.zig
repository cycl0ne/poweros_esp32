// SPDX-License-Identifier: MPL-2.0
//! LZ4's block format (sdk/libs/lz4): blocks built by hand decode to what
//! they say, everything compressed comes back the same, and a damaged
//! block is an error - never a read or write outside its buffers.

const std = @import("std");
const testing = std.testing;
const lz4 = @import("sdk").lz4;

fn expectDecodes(block: []const u8, expected: []const u8) !void {
    var out: [256]u8 = undefined;
    const len = lz4.decompress(block, &out) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(expected, out[0..len]);
}

test "a block built by hand decodes to what it says" {
    // Literals only.
    try expectDecodes("\x50hello", "hello");
    // Four literals, a match of eight from four back, a last literal.
    try expectDecodes("\x44abcd\x04\x00\x10x", "abcdabcdabcdx");
    // A match one back: a run.
    try expectDecodes("\x1fa\x01\x00\x02\x00", "a" ++ "a" ** 21);
    // A literal length past 15.
    try expectDecodes("\xf0\x02" ++ "q" ** 17, "q" ** 17);
}

test "a damaged block is an error" {
    var out: [64]u8 = undefined;
    // A distance of 0, one past the start, and a block ending in a match.
    try testing.expectEqual(@as(?usize, null), lz4.decompress("\x14abcd\x00\x00\x00", &out));
    try testing.expectEqual(@as(?usize, null), lz4.decompress("\x14abcd\x05\x00\x00", &out));
    try testing.expectEqual(@as(?usize, null), lz4.decompress("\x44abcd\x04\x00", &out));
    // Literals past the input's end, and output past the buffer's.
    try testing.expectEqual(@as(?usize, null), lz4.decompress("\x50hel", &out));
    var small: [3]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), lz4.decompress("\x50hello", &small));
    try testing.expectEqual(@as(?usize, null), lz4.decompress("", &out));
}

fn roundTrip(data: []const u8) !usize {
    var work: lz4.Work = .{};
    const packed_bytes = try testing.allocator.alloc(u8, lz4.bound(data.len));
    defer testing.allocator.free(packed_bytes);
    const len = lz4.compress(data, packed_bytes, &work) orelse return error.TestUnexpectedResult;
    const back = try testing.allocator.alloc(u8, data.len);
    defer testing.allocator.free(back);
    const got = lz4.decompress(packed_bytes[0..len], back) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(data.len, got);
    try testing.expectEqualSlices(u8, data, back);
    return len;
}

test "everything compressed comes back the same" {
    var prng = std.Random.DefaultPrng.init(0x504F53);
    const random = prng.random();
    const data = try testing.allocator.alloc(u8, lz4.max_block);
    defer testing.allocator.free(data);

    @memset(data, 0);
    try testing.expect(try roundTrip(data) < 400);
    random.bytes(data);
    _ = try roundTrip(data);
    // Text-like: a few words over and over, with noise.
    const words = [_][]const u8{ "posfs ", "journal ", "checkpoint ", "the ", "block ", "\n" };
    var at: usize = 0;
    while (at < data.len) {
        const word = words[random.uintLessThan(usize, words.len)];
        const take = @min(word.len, data.len - at);
        @memcpy(data[at..][0..take], word[0..take]);
        at += take;
    }
    try testing.expect(try roundTrip(data) < data.len / 2);
    for ([_]usize{ 0, 1, 5, 12, 13, 14, 100, 4096 }) |len| {
        random.bytes(data[0..len]);
        _ = try roundTrip(data[0..len]);
        @memset(data[0..len], 'z');
        _ = try roundTrip(data[0..len]);
    }
}

test "what does not fit is refused" {
    var work: lz4.Work = .{};
    var prng = std.Random.DefaultPrng.init(7);
    var data: [4096]u8 = undefined;
    prng.random().bytes(&data);
    var out: [4095]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), lz4.compress(&data, &out, &work));
}

test "every cut and every changed byte decodes in bounds or fails" {
    var work: lz4.Work = .{};
    var data: [3000]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @intCast((i * 7 / 13) & 0xFF);
    var packed_bytes: [lz4.bound(3000)]u8 = undefined;
    const len = lz4.compress(&data, &packed_bytes, &work).?;
    var out: [3000]u8 = undefined;
    for (0..len) |cut| _ = lz4.decompress(packed_bytes[0..cut], &out);
    var damaged: [lz4.bound(3000)]u8 = undefined;
    for (0..len) |at| {
        for ([_]u8{ 0x00, 0xFF, 0x0F, 0xF0, 0x01 }) |value| {
            @memcpy(damaged[0..len], packed_bytes[0..len]);
            damaged[at] = value;
            _ = lz4.decompress(damaged[0..len], &out);
        }
    }
}

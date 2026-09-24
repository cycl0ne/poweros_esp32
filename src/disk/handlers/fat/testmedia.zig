// SPDX-License-Identifier: MIT
//! A block medium in memory for the host tests, sparse: only the blocks
//! something has written are kept, and one nothing has written reads as
//! zeroes.
//!
//! **Why sparse.** A card of 64 GB has 124 million blocks. A volume on it
//! has a FAT of 15 MB and clusters of 32 KiB, and the arithmetic that
//! goes wrong on such a volume - a cluster number past 16 bits, an offset
//! past 4 GiB, a FAT sector past what a 32-bit byte count holds - goes
//! wrong nowhere else. A dense medium of that size cannot be built in a
//! test, and a small one would never reach any of it. Sparse means the
//! tests run against the real geometry and hold only the few hundred
//! blocks they touch.
//!
//! It also cuts the power: `budget` is how many more blocks may be
//! written before every further write is dropped, so a test can stop a
//! file system half way through and see what mounting makes of it.

const std = @import("std");
const dos = @import("sdk").dos;

pub const TestMedia = struct {
    /// The blocks that have been written, by block number.
    written: std.AutoHashMap(u64, []u8),
    block_bytes: u32,
    block_count: u64,
    /// Counters the tests look at.
    reads: u32 = 0,
    writes: u32 = 0,
    /// Blocks read and written, to tell one block moved a thousand times
    /// from a thousand blocks moved once.
    blocks_read: u64 = 0,
    blocks_written: u64 = 0,
    /// After this many more blocks are written every further write is
    /// dropped: the card went. Null means it does not.
    budget: ?u32 = null,
    /// Whether the medium takes writes at all.
    read_only: bool = false,
    /// What `present` answers, and what `changeNum` counts.
    in: bool = true,
    changes: u32 = 1,
    /// Allocations still out, so a test can insist the file system gave
    /// everything back.
    live: usize = 0,
    clock: u32 = 0,

    pub fn init(block_bytes: u32, block_count: u64) TestMedia {
        return .{
            .written = std.AutoHashMap(u64, []u8).init(std.testing.allocator),
            .block_bytes = block_bytes,
            .block_count = block_count,
        };
    }

    pub fn deinit(m: *TestMedia) void {
        var it = m.written.valueIterator();
        while (it.next()) |block| std.testing.allocator.free(block.*);
        m.written.deinit();
    }

    // --- the medium a file system sees ------------------------------------

    pub fn blockSize(m: *TestMedia) u32 {
        return m.block_bytes;
    }

    pub fn blocks(m: *TestMedia) u64 {
        return m.block_count;
    }

    pub fn writable(m: *TestMedia) bool {
        return !m.read_only;
    }

    pub fn present(m: *TestMedia) bool {
        return m.in;
    }

    pub fn changeNum(m: *TestMedia) u32 {
        return m.changes;
    }

    pub fn read(m: *TestMedia, lba: u64, count: u32, into: []u8) bool {
        if (!m.in) return false;
        if (count == 0) return true;
        if (lba > m.block_count or count > m.block_count - lba) return false;
        if (into.len < @as(usize, count) * m.block_bytes) return false;
        m.reads += 1;
        m.blocks_read += count;
        for (0..count) |i| {
            const at = i * m.block_bytes;
            const slot = into[at..][0..m.block_bytes];
            if (m.written.get(lba + i)) |block| {
                @memcpy(slot, block);
            } else {
                @memset(slot, 0);
            }
        }
        return true;
    }

    pub fn write(m: *TestMedia, lba: u64, count: u32, from: []const u8) bool {
        if (!m.in or m.read_only) return false;
        if (count == 0) return true;
        if (lba > m.block_count or count > m.block_count - lba) return false;
        if (from.len < @as(usize, count) * m.block_bytes) return false;
        m.writes += 1;
        for (0..count) |i| {
            if (m.budget) |*left| {
                if (left.* == 0) return true; // the card went mid-write
                left.* -= 1;
            }
            m.blocks_written += 1;
            const at = i * m.block_bytes;
            m.put(lba + i, from[at..][0..m.block_bytes]) catch return false;
        }
        return true;
    }

    fn put(m: *TestMedia, lba: u64, from: []const u8) !void {
        const found = try m.written.getOrPut(lba);
        if (!found.found_existing) {
            found.value_ptr.* = try std.testing.allocator.alloc(u8, m.block_bytes);
        }
        @memcpy(found.value_ptr.*, from);
    }

    // --- what the handler gets its memory from -----------------------------

    /// Eight-byte aligned, as the device's allocator is: a file system
    /// puts structures with 64-bit fields in these.
    pub fn alloc(m: *TestMedia, bytes_wanted: u32) ?[]u8 {
        const block = std.testing.allocator.alignedAlloc(u8, .@"8", bytes_wanted) catch return null;
        m.live += 1;
        return block;
    }

    pub fn free(m: *TestMedia, block: []u8) void {
        m.live -= 1;
        const aligned: []align(8) u8 = @alignCast(block);
        std.testing.allocator.free(aligned);
    }

    /// The clock a new file is dated with: it ticks once per call, so a
    /// test can tell one date from another.
    pub fn now(m: *TestMedia) dos.DateStamp {
        m.clock += 1;
        return .{ .days = 1, .minute = 2, .tick = @intCast(m.clock) };
    }

    // --- what the tests reach for -----------------------------------------

    /// How many blocks are actually held, which is what makes a 64 GB
    /// medium possible at all.
    pub fn held(m: *TestMedia) usize {
        return m.written.count();
    }

    /// One block put there directly, to build a fixture without going
    /// through a file system.
    pub fn place(m: *TestMedia, lba: u64, from: []const u8) !void {
        var block: [4096]u8 = @splat(0);
        const len = @min(from.len, m.block_bytes);
        @memcpy(block[0..len], from[0..len]);
        try m.put(lba, block[0..m.block_bytes]);
    }
};

// --- tests ------------------------------------------------------------------

const testing = std.testing;

test "a 64 GB medium holds only what is written to it" {
    // The blocks of a card sold as 64 GB.
    var media = TestMedia.init(512, 124_747_776);
    defer media.deinit();
    try testing.expectEqual(@as(u64, 124_747_776), media.blocks());
    try testing.expectEqual(@as(usize, 0), media.held());

    // A block near the end, which is where the arithmetic goes wrong.
    var out: [512]u8 = @splat(0xAA);
    const last = media.blocks() - 1;
    try testing.expect(media.write(last, 1, &out));
    try testing.expectEqual(@as(usize, 1), media.held());

    var back: [512]u8 = @splat(0);
    try testing.expect(media.read(last, 1, &back));
    try testing.expectEqualSlices(u8, &out, &back);

    // Anything never written reads as zeroes, and costs nothing to hold.
    try testing.expect(media.read(64_000_000, 1, &back));
    for (back) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expectEqual(@as(usize, 1), media.held());
}

test "a run off the end is refused, an empty one is not" {
    var media = TestMedia.init(512, 100);
    defer media.deinit();
    var buffer: [512 * 4]u8 = @splat(0);
    try testing.expect(media.read(96, 4, &buffer));
    try testing.expect(!media.read(97, 4, &buffer));
    try testing.expect(!media.read(101, 1, &buffer));
    // Nothing at the very end is fine, as a read of no blocks is.
    try testing.expect(media.read(100, 0, &buffer));
}

test "the power going mid-write leaves the blocks before it" {
    var media = TestMedia.init(512, 1000);
    defer media.deinit();
    var out: [512 * 8]u8 = @splat(0xEE);
    media.budget = 3;
    try testing.expect(media.write(10, 8, &out));
    // Three went down, five did not.
    try testing.expectEqual(@as(usize, 3), media.held());

    var back: [512]u8 = @splat(0);
    try testing.expect(media.read(12, 1, &back));
    try testing.expectEqual(@as(u8, 0xEE), back[0]);
    try testing.expect(media.read(13, 1, &back));
    try testing.expectEqual(@as(u8, 0), back[0]);
}

test "a card that is out, and one that will not be written" {
    var media = TestMedia.init(512, 100);
    defer media.deinit();
    var buffer: [512]u8 = @splat(0);

    media.read_only = true;
    try testing.expect(!media.writable());
    try testing.expect(!media.write(0, 1, &buffer));
    try testing.expect(media.read(0, 1, &buffer));

    media.read_only = false;
    media.in = false;
    try testing.expect(!media.present());
    try testing.expect(!media.read(0, 1, &buffer));
    try testing.expect(!media.write(0, 1, &buffer));
}

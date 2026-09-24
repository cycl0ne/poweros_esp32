// SPDX-License-Identifier: MIT
//! The block cache both file systems work through: a handful of blocks
//! held in memory, written back when they are pushed out or when the file
//! system asks.
//!
//! `BlockCache(Media)` is generic over the medium, so the whole of it is
//! tested on the host against `testmedia.zig` and the handler passes a
//! medium made out of sd.device. The medium must offer
//!
//!     blockSize() u32          blocks() u64
//!     read(lba: u64, count: u32, into: []u8) bool
//!     write(lba: u64, count: u32, from: []const u8) bool
//!     alloc(u32) ?[]u8         free([]u8)
//!
//! **What it is for.** The blocks a file system reads over and over are
//! the table and the directories; the blocks it reads once are the file's
//! own. So those two go different ways: a table or directory block
//! through `get`, which keeps it, and a file's bytes through `readRun`,
//! which does not. A cache that held file data would be flushed out by
//! every large copy and hold nothing worth holding.
//!
//! **The two ways it can go wrong** are both about the runs that bypass
//! it, and both are handled here rather than left to the callers:
//!
//! - a run read over a block that is held and dirty would read what is
//!   still on the medium, not what is in memory. So a run writes back any
//!   dirty block it crosses first.
//! - a run written over a block that is held would leave the held copy
//!   standing, and the next `get` would hand back what is no longer
//!   there. So a run drops any block it crosses.

const std = @import("std");

/// One block held in memory.
const Slot = struct {
    /// The block this holds. Meaningless unless `filled`.
    lba: u64 = 0,
    /// When it was last reached, for choosing which to push out.
    used: u64 = 0,
    filled: bool = false,
    /// Held and changed: it must go back before it is dropped.
    dirty: bool = false,
};

pub const Error = error{
    NoMemory,
    ReadFailed,
    WriteFailed,
};

pub fn BlockCache(comptime Media: type) type {
    return struct {
        const Self = @This();

        media: *Media,
        slots: []Slot,
        /// The slots' bytes, `block_bytes` each, in one allocation.
        bytes: []u8,
        block_bytes: u32,
        /// Ticks once per use, so the least recently used is the smallest.
        clock: u64 = 0,
        /// What the tests count.
        hits: u32 = 0,
        misses: u32 = 0,

        /// `count` blocks' worth of cache, out of the medium's own memory.
        pub fn init(media: *Media, count: u32) Error!Self {
            const block_bytes = media.blockSize();
            const slot_bytes = @sizeOf(Slot) * count;
            const slots_memory = media.alloc(slot_bytes) orelse return Error.NoMemory;
            const bytes = media.alloc(block_bytes * count) orelse {
                media.free(slots_memory);
                return Error.NoMemory;
            };
            const first_slot: [*]Slot = @ptrCast(@alignCast(slots_memory.ptr));
            const slots = first_slot[0..count];
            for (slots) |*slot| slot.* = .{};
            return .{
                .media = media,
                .slots = slots,
                .bytes = bytes,
                .block_bytes = block_bytes,
            };
        }

        /// Everything written back and the memory given up. A block that
        /// will not go back is dropped: there is nowhere else to put it,
        /// and the caller is being taken down.
        pub fn deinit(self: *Self) void {
            _ = self.flush() catch {};
            const slot_bytes: [*]u8 = @ptrCast(self.slots.ptr);
            self.media.free(slot_bytes[0 .. self.slots.len * @sizeOf(Slot)]);
            self.media.free(self.bytes);
            self.slots = &.{};
            self.bytes = &.{};
        }

        fn slotBytes(self: *Self, at: usize) []u8 {
            return self.bytes[at * self.block_bytes ..][0..self.block_bytes];
        }

        /// The slot holding `lba`, if one does.
        fn find(self: *Self, lba: u64) ?usize {
            for (self.slots, 0..) |*slot, at| {
                if (slot.filled and slot.lba == lba) return at;
            }
            return null;
        }

        /// A slot to put `lba` in: an empty one, or the one used longest
        /// ago, written back first if it has to be.
        fn claim(self: *Self, lba: u64) Error!usize {
            var oldest: usize = 0;
            for (self.slots, 0..) |*slot, at| {
                if (!slot.filled) {
                    oldest = at;
                    break;
                }
                if (slot.used < self.slots[oldest].used) oldest = at;
            }
            try self.writeBack(oldest);
            self.slots[oldest] = .{ .lba = lba, .filled = true };
            return oldest;
        }

        fn writeBack(self: *Self, at: usize) Error!void {
            const slot = &self.slots[at];
            if (!slot.filled or !slot.dirty) return;
            if (!self.media.write(slot.lba, 1, self.slotBytes(at))) return Error.WriteFailed;
            slot.dirty = false;
        }

        fn touch(self: *Self, at: usize) void {
            self.clock += 1;
            self.slots[at].used = self.clock;
        }

        /// `lba`'s bytes, read in if they are not held already. The slice
        /// stays good until the next call that may push a block out, so a
        /// caller holds it across nothing.
        pub fn get(self: *Self, lba: u64) Error![]const u8 {
            return self.load(lba, true);
        }

        /// `lba`'s bytes to be changed: the same block, marked so it goes
        /// back to the medium.
        pub fn getForWrite(self: *Self, lba: u64) Error![]u8 {
            const bytes = try self.load(lba, true);
            const at = self.find(lba).?;
            self.slots[at].dirty = true;
            return @constCast(bytes);
        }

        /// `lba`'s bytes for a caller that is going to write all of them:
        /// the block is claimed and zeroed rather than read in, because
        /// reading what is about to be overwritten is a wasted block read.
        pub fn fresh(self: *Self, lba: u64) Error![]u8 {
            const bytes = try self.load(lba, false);
            const at = self.find(lba).?;
            self.slots[at].dirty = true;
            return @constCast(bytes);
        }

        fn load(self: *Self, lba: u64, from_medium: bool) Error![]u8 {
            if (self.find(lba)) |at| {
                self.hits += 1;
                self.touch(at);
                return self.slotBytes(at);
            }
            self.misses += 1;
            const at = try self.claim(lba);
            const bytes = self.slotBytes(at);
            if (from_medium) {
                if (!self.media.read(lba, 1, bytes)) {
                    self.slots[at] = .{};
                    return Error.ReadFailed;
                }
            } else {
                @memset(bytes, 0);
            }
            self.touch(at);
            return bytes;
        }

        /// Every changed block back on the medium.
        pub fn flush(self: *Self) Error!bool {
            for (0..self.slots.len) |at| try self.writeBack(at);
            return true;
        }

        /// Everything held is forgotten, changed or not. For a medium
        /// that has gone: what is held belongs to a card that is no
        /// longer there, and writing it to whatever replaced it would
        /// damage that one.
        pub fn invalidate(self: *Self) void {
            for (self.slots) |*slot| slot.* = .{};
        }

        /// A run of blocks straight into `into`, around the cache. Any
        /// held block it crosses goes back to the medium first, or the
        /// run would read what the medium still has rather than what is
        /// in memory.
        pub fn readRun(self: *Self, lba: u64, count: u32, into: []u8) Error!void {
            if (count == 0) return;
            try self.writeBackRange(lba, count);
            if (!self.media.read(lba, count, into)) return Error.ReadFailed;
        }

        /// A run of blocks straight from `from`, around the cache. Any
        /// held block it crosses is dropped, or the next `get` would hand
        /// back what is no longer on the medium.
        pub fn writeRun(self: *Self, lba: u64, count: u32, from: []const u8) Error!void {
            if (count == 0) return;
            self.dropRange(lba, count);
            if (!self.media.write(lba, count, from)) return Error.WriteFailed;
        }

        fn writeBackRange(self: *Self, lba: u64, count: u32) Error!void {
            for (0..self.slots.len) |at| {
                const slot = self.slots[at];
                if (!slot.filled or !slot.dirty) continue;
                if (slot.lba < lba or slot.lba - lba >= count) continue;
                try self.writeBack(at);
            }
        }

        fn dropRange(self: *Self, lba: u64, count: u32) void {
            for (self.slots) |*slot| {
                if (!slot.filled) continue;
                if (slot.lba < lba or slot.lba - lba >= count) continue;
                slot.* = .{};
            }
        }
    };
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;
const TestMedia = @import("testmedia.zig").TestMedia;
const Cache = BlockCache(TestMedia);

/// A medium of a 64 GB card's geometry, and a cache of four blocks over
/// it - small enough that the tests can push blocks out on purpose.
fn setUp(media: *TestMedia) !Cache {
    media.* = TestMedia.init(512, 124_747_776);
    return try Cache.init(media, 4);
}

test "a block is read once and held" {
    var media: TestMedia = undefined;
    var cache = try setUp(&media);
    defer media.deinit();
    defer cache.deinit();

    var block: [512]u8 = @splat(0x11);
    try testing.expect(media.write(7, 1, &block));
    media.blocks_read = 0;

    const first = try cache.get(7);
    try testing.expectEqual(@as(u8, 0x11), first[0]);
    try testing.expectEqual(@as(u64, 1), media.blocks_read);

    _ = try cache.get(7);
    _ = try cache.get(7);
    try testing.expectEqual(@as(u64, 1), media.blocks_read);
    try testing.expectEqual(@as(u32, 2), cache.hits);
    try testing.expectEqual(@as(u32, 1), cache.misses);
}

test "a changed block goes back, and only when it has to" {
    var media: TestMedia = undefined;
    var cache = try setUp(&media);
    defer media.deinit();
    defer cache.deinit();

    const bytes = try cache.getForWrite(20);
    bytes[0] = 0xAB;
    try testing.expectEqual(@as(u64, 0), media.blocks_written);

    _ = try cache.flush();
    try testing.expectEqual(@as(u64, 1), media.blocks_written);

    // A flush with nothing changed writes nothing.
    _ = try cache.flush();
    try testing.expectEqual(@as(u64, 1), media.blocks_written);

    var back: [512]u8 = @splat(0);
    try testing.expect(media.read(20, 1, &back));
    try testing.expectEqual(@as(u8, 0xAB), back[0]);
}

test "the block used longest ago is the one pushed out, and it is written back" {
    var media: TestMedia = undefined;
    var cache = try setUp(&media);
    defer media.deinit();
    defer cache.deinit();

    // Four blocks fill it; block 100 is changed and then left alone.
    const bytes = try cache.getForWrite(100);
    bytes[0] = 0x5A;
    _ = try cache.get(101);
    _ = try cache.get(102);
    _ = try cache.get(103);
    // 100 is the oldest, so a fifth block pushes it out and it goes back.
    try testing.expectEqual(@as(u64, 0), media.blocks_written);
    _ = try cache.get(104);
    try testing.expectEqual(@as(u64, 1), media.blocks_written);

    var back: [512]u8 = @splat(0);
    try testing.expect(media.read(100, 1, &back));
    try testing.expectEqual(@as(u8, 0x5A), back[0]);

    // Touching a block keeps it: reach 101 again, and 102 goes instead.
    _ = try cache.get(101);
    _ = try cache.get(105);
    try testing.expect(cache.find(101) != null);
    try testing.expect(cache.find(102) == null);
}

test "a run read over a changed block sees the change, not the medium" {
    var media: TestMedia = undefined;
    var cache = try setUp(&media);
    defer media.deinit();
    defer cache.deinit();

    // Block 51 is held and changed, and never written back.
    const bytes = try cache.getForWrite(51);
    bytes[0] = 0x99;

    // A run across 50..53 must show it.
    var into: [512 * 4]u8 = @splat(0);
    try cache.readRun(50, 4, &into);
    try testing.expectEqual(@as(u8, 0x99), into[512]);
}

test "a run written over a held block does not leave the old one behind" {
    var media: TestMedia = undefined;
    var cache = try setUp(&media);
    defer media.deinit();
    defer cache.deinit();

    var old: [512]u8 = @splat(0x22);
    try testing.expect(media.write(61, 1, &old));
    // Held, so a later get would be served from memory.
    const held = try cache.get(61);
    try testing.expectEqual(@as(u8, 0x22), held[0]);

    var new: [512 * 4]u8 = @splat(0x33);
    try cache.writeRun(60, 4, &new);

    const again = try cache.get(61);
    try testing.expectEqual(@as(u8, 0x33), again[0]);
}

test "a fresh block is not read from the medium first" {
    var media: TestMedia = undefined;
    var cache = try setUp(&media);
    defer media.deinit();
    defer cache.deinit();

    var block: [512]u8 = @splat(0x44);
    try testing.expect(media.write(80, 1, &block));
    media.blocks_read = 0;

    const bytes = try cache.fresh(80);
    try testing.expectEqual(@as(u64, 0), media.blocks_read);
    // Zeroed, not what was there.
    try testing.expectEqual(@as(u8, 0), bytes[0]);
}

test "what a card that has gone holds is dropped, not written to its replacement" {
    var media: TestMedia = undefined;
    var cache = try setUp(&media);
    defer media.deinit();
    defer cache.deinit();

    const bytes = try cache.getForWrite(90);
    bytes[0] = 0x77;
    cache.invalidate();
    _ = try cache.flush();
    try testing.expectEqual(@as(u64, 0), media.blocks_written);
}

test "the cache works at the far end of a 64 GB card" {
    var media: TestMedia = undefined;
    var cache = try setUp(&media);
    defer media.deinit();
    defer cache.deinit();

    // Past 4 GiB in bytes, and past what 32 bits holds in blocks of 512.
    const far = media.blocks() - 2;
    try testing.expect(far * 512 > 0xFFFF_FFFF);
    const bytes = try cache.getForWrite(far);
    bytes[0] = 0x6D;
    _ = try cache.flush();

    var back: [512]u8 = @splat(0);
    try testing.expect(media.read(far, 1, &back));
    try testing.expectEqual(@as(u8, 0x6D), back[0]);
}

test "a read that fails leaves no block claiming to hold anything" {
    var media: TestMedia = undefined;
    var cache = try setUp(&media);
    defer media.deinit();
    defer cache.deinit();

    media.in = false;
    try testing.expectError(Error.ReadFailed, cache.get(5));
    try testing.expect(cache.find(5) == null);

    media.in = true;
    _ = try cache.get(5);
    try testing.expect(cache.find(5) != null);
}

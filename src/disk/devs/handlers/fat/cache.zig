// SPDX-License-Identifier: MIT
//! The block cache both file systems work through: a handful of blocks
//! held in memory, written back when they are pushed out or when the file
//! system asks.
//!
//! `BlockCache(Media)` is generic over the medium, so the whole of it is
//! tested on the host against `testmedia.zig` and the handler passes a
//! medium made out of sdcard.device. The medium must offer
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
//! every large copy and hold nothing worth holding - but for a sector a
//! write covers only part of, which the next small write goes back to.
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
//!
//! **Its size can change while it holds blocks** (`resize`, which
//! ACTION_MORE_CACHE comes to): the blocks used most lately move over,
//! and those that no longer fit go back to the medium first. A block is
//! found by looking through every slot, so a larger cache saves reads and
//! pays for it in that look.

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

/// The blocks a cache holds when nothing says otherwise.
pub const default_blocks: u32 = 32;

/// The fewest it is made with: the blocks one packet goes back to over and
/// over - an exFAT entry set across two directory blocks, the table sector
/// of its chain and the bitmap block it takes clusters from.
pub const least_blocks: u32 = 4;

/// A cache's two allocations: its slots, and their bytes.
const Memory = struct { slots: []Slot, bytes: []u8 };

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

        /// `count` blocks' worth of cache, out of the medium's own memory;
        /// one at the least.
        pub fn init(media: *Media, count: u32) Error!Self {
            const block_bytes = media.blockSize();
            const memory = try allocate(media, block_bytes, @max(count, 1));
            return .{
                .media = media,
                .slots = memory.slots,
                .bytes = memory.bytes,
                .block_bytes = block_bytes,
            };
        }

        /// Everything written back and the memory given up. A block that
        /// will not go back is dropped: there is nowhere else to put it,
        /// and the caller is being taken down.
        pub fn deinit(self: *Self) void {
            _ = self.flush() catch {};
            giveBack(self.media, .{ .slots = self.slots, .bytes = self.bytes });
            self.slots = &.{};
            self.bytes = &.{};
        }

        /// How many blocks it holds at the most.
        pub fn size(self: *const Self) u32 {
            return @intCast(self.slots.len);
        }

        /// Made `count` blocks big, one at the least. The blocks used most
        /// lately stay held, changed or not; those that no longer fit go
        /// back to the medium first if they have changed. When the memory
        /// cannot be had, or a block will not go back, it stays the size
        /// it was, with every block it held.
        pub fn resize(self: *Self, count: u32) Error!void {
            const wanted: u32 = @max(count, 1);
            if (wanted == self.slots.len) return;
            const memory = try allocate(self.media, self.block_bytes, wanted);
            errdefer giveBack(self.media, memory);
            const since = self.keptSince(wanted);
            for (0..self.slots.len) |at| {
                if (self.slots[at].used < since) try self.writeBack(at);
            }
            var into: usize = 0;
            for (self.slots, 0..) |slot, at| {
                if (!slot.filled or slot.used < since) continue;
                memory.slots[into] = slot;
                @memcpy(memory.bytes[into * self.block_bytes ..][0..self.block_bytes], self.slotBytes(at));
                into += 1;
            }
            giveBack(self.media, .{ .slots = self.slots, .bytes = self.bytes });
            self.slots = memory.slots;
            self.bytes = memory.bytes;
        }

        /// The last use the blocks a cache of `count` keeps have had at
        /// the earliest: 0 when every block held fits. Each use ticks the
        /// clock, so no two held blocks share one, and the `count` newest
        /// are found by stepping down from the newest.
        fn keptSince(self: *const Self, count: u32) u64 {
            var held: u32 = 0;
            for (self.slots) |slot| held += @intFromBool(slot.filled);
            if (held <= count) return 0;
            var since: u64 = std.math.maxInt(u64);
            for (0..count) |_| {
                var newest: u64 = 0;
                for (self.slots) |slot| {
                    if (slot.filled and slot.used < since and slot.used > newest) newest = slot.used;
                }
                since = newest;
            }
            return since;
        }

        /// The slots and bytes of `count` blocks, every slot empty; none
        /// when either would not fit in 32 bits.
        fn allocate(media: *Media, block_bytes: u32, count: u32) Error!Memory {
            const slot_bytes = @as(u64, @sizeOf(Slot)) * count;
            const bytes_wanted = @as(u64, block_bytes) * count;
            if (slot_bytes > std.math.maxInt(u32) or bytes_wanted > std.math.maxInt(u32)) return Error.NoMemory;
            const slots_memory = media.alloc(@intCast(slot_bytes)) orelse return Error.NoMemory;
            const bytes = media.alloc(@intCast(bytes_wanted)) orelse {
                media.free(slots_memory);
                return Error.NoMemory;
            };
            const first_slot: [*]Slot = @ptrCast(@alignCast(slots_memory.ptr));
            const slots = first_slot[0..count];
            for (slots) |*slot| slot.* = .{};
            return .{ .slots = slots, .bytes = bytes };
        }

        fn giveBack(media: *Media, memory: Memory) void {
            const slot_bytes: [*]u8 = @ptrCast(memory.slots.ptr);
            media.free(slot_bytes[0 .. memory.slots.len * @sizeOf(Slot)]);
            media.free(memory.bytes);
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
        /// A block held already is zeroed too: it may be a file's sector
        /// whose cluster has since become a directory's.
        pub fn fresh(self: *Self, lba: u64) Error![]u8 {
            const bytes = try self.load(lba, false);
            @memset(bytes, 0);
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

        /// `lba` back on the medium now if it is held and changed: a
        /// block that must be there before the packet goes on, while the
        /// others wait.
        pub fn writeBackBlock(self: *Self, lba: u64) Error!void {
            if (self.find(lba)) |at| try self.writeBack(at);
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

test "one block written back alone, the others left changed" {
    var media: TestMedia = undefined;
    var cache = try setUp(&media);
    defer media.deinit();
    defer cache.deinit();

    (try cache.getForWrite(20))[0] = 1;
    (try cache.getForWrite(21))[0] = 2;
    try cache.writeBackBlock(21);
    try testing.expectEqual(@as(u64, 1), media.blocks_written);
    // Once more, or for a block not held, nothing.
    try cache.writeBackBlock(21);
    try cache.writeBackBlock(99);
    try testing.expectEqual(@as(u64, 1), media.blocks_written);
    // Still held: the next change to it is not a read.
    const reads = media.reads;
    (try cache.getForWrite(21))[1] = 3;
    try testing.expectEqual(reads, media.reads);
    _ = try cache.flush();
    try testing.expectEqual(@as(u64, 3), media.blocks_written);
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

    // Held already, and changed: zeroed all the same.
    (try cache.getForWrite(81))[5] = 0x55;
    const again = try cache.fresh(81);
    for (again) |byte| try testing.expectEqual(@as(u8, 0), byte);
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

test "a cache made larger keeps every block it held, changed ones changed" {
    var media: TestMedia = undefined;
    var cache = try setUp(&media);
    defer media.deinit();
    defer cache.deinit();

    const bytes = try cache.getForWrite(10);
    bytes[0] = 0x3C;
    _ = try cache.get(11);
    _ = try cache.get(12);
    try cache.resize(8);
    try testing.expectEqual(@as(u32, 8), cache.size());
    try testing.expectEqual(@as(u64, 0), media.blocks_written);

    media.blocks_read = 0;
    try testing.expectEqual(@as(u8, 0x3C), (try cache.get(10))[0]);
    _ = try cache.get(11);
    _ = try cache.get(12);
    try testing.expectEqual(@as(u64, 0), media.blocks_read);

    // Eight blocks fit now: five more push nothing out.
    for (13..18) |lba| _ = try cache.get(lba);
    try testing.expect(cache.find(10) != null);
    _ = try cache.flush();
    try testing.expectEqual(@as(u64, 1), media.blocks_written);
}

test "a cache made smaller keeps the blocks used last and writes back the rest" {
    var media: TestMedia = undefined;
    var cache = try setUp(&media);
    defer media.deinit();
    defer cache.deinit();

    // 20 changed and then left alone; 21 changed and used last.
    (try cache.getForWrite(20))[0] = 0x01;
    _ = try cache.get(22);
    _ = try cache.get(23);
    (try cache.getForWrite(21))[0] = 0x02;
    try cache.resize(2);
    try testing.expectEqual(@as(u32, 2), cache.size());

    // 20 went back on its way out; 22 went unwritten, as it was not changed.
    try testing.expectEqual(@as(u64, 1), media.blocks_written);
    try testing.expect(cache.find(20) == null);
    try testing.expect(cache.find(22) == null);
    try testing.expect(cache.find(23) != null);
    try testing.expect(cache.find(21) != null);
    var back: [512]u8 = @splat(0);
    try testing.expect(media.read(20, 1, &back));
    try testing.expectEqual(@as(u8, 0x01), back[0]);

    // 21 is still changed, and goes back at the flush.
    _ = try cache.flush();
    try testing.expectEqual(@as(u64, 2), media.blocks_written);
    try testing.expect(media.read(21, 1, &back));
    try testing.expectEqual(@as(u8, 0x02), back[0]);
}

test "a cache that cannot be made smaller stays as it was" {
    var media: TestMedia = undefined;
    var cache = try setUp(&media);
    defer media.deinit();
    defer cache.deinit();

    (try cache.getForWrite(30))[0] = 0x0F;
    _ = try cache.get(31);
    _ = try cache.get(32);
    const live = media.live;
    // 30 cannot go back, so nothing changes.
    media.read_only = true;
    try testing.expectError(Error.WriteFailed, cache.resize(1));
    try testing.expectEqual(@as(u32, 4), cache.size());
    try testing.expectEqual(live, media.live);
    for ([_]u64{ 30, 31, 32 }) |lba| try testing.expect(cache.find(lba) != null);

    // More than 32 bits of bytes is refused, and changes nothing either.
    try testing.expectError(Error.NoMemory, cache.resize(0x0100_0000));
    try testing.expectEqual(@as(u32, 4), cache.size());
    media.read_only = false;
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

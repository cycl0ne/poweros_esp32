// SPDX-License-Identifier: MPL-2.0
//! The blocks posfs has read lately, kept by address.
//!
//! A block on the medium that the file system refers to is never written
//! over, so what the cache holds is never stale and never dirty: there is
//! nothing to write back, and a block leaves the cache by being forgotten
//! when its address is freed and taken again (`forget`). The trees' nodes
//! that are being changed are not here at all: they live in memory, with
//! no address yet, until a checkpoint gives them one (btree.zig).
//!
//! The cache is a fixed number of buffers, each one block, found through
//! a table of chains by address and reused least recently used first. A
//! view into one is good until the next block is asked for, which may
//! reuse its buffer. On a medium that can be read as memory the cache is
//! not used for reading at all.

const media = @import("media.zig");

const none: u32 = 0xFFFF_FFFF;

const Entry = struct {
    addr: u64 = 0,
    buffer: []u8 = &.{},
    /// Less and more recently used; the chain of its bucket.
    older: u32 = none,
    newer: u32 = none,
    chain: u32 = none,
    used: bool = false,
};

pub const Cache = struct {
    dev: media.Device,
    block_size: u32 = 0,
    entries: []Entry = &.{},
    buckets: []u32 = &.{},
    /// The least and the most recently used entry.
    oldest: u32 = none,
    newest: u32 = none,
    /// Entries never used yet, from `fresh` on.
    fresh: u32 = 0,
    hits: u64 = 0,
    misses: u64 = 0,

    /// A cache of `capacity` blocks of `block_size` bytes. False when the
    /// memory is not there; the cache is then empty and still works,
    /// reading every block again.
    pub fn init(cache: *Cache, dev: media.Device, block_size: u32, blocks: u32) bool {
        cache.* = .{ .dev = dev, .block_size = block_size };
        return cache.resize(blocks);
    }

    pub fn deinit(cache: *Cache) void {
        cache.release();
    }

    fn release(cache: *Cache) void {
        for (cache.entries) |entry| {
            if (entry.buffer.len != 0) cache.dev.free(entry.buffer);
        }
        if (cache.entries.len != 0) cache.dev.free(sliceBytes(Entry, cache.entries));
        if (cache.buckets.len != 0) cache.dev.free(sliceBytes(u32, cache.buckets));
        cache.entries = &.{};
        cache.buckets = &.{};
        cache.oldest = none;
        cache.newest = none;
        cache.fresh = 0;
    }

    /// The cache made `blocks` blocks large; what it held is dropped.
    pub fn resize(cache: *Cache, blocks: u32) bool {
        cache.release();
        if (blocks == 0) return true;
        const entry_bytes = cache.dev.alloc(@as(usize, blocks) * @sizeOf(Entry)) orelse return false;
        const entries: [*]Entry = @ptrCast(@alignCast(entry_bytes.ptr));
        cache.entries = entries[0..blocks];
        for (cache.entries) |*entry| entry.* = .{};
        var bucket_count: u32 = 16;
        while (bucket_count < blocks) bucket_count *= 2;
        const bucket_bytes = cache.dev.alloc(@as(usize, bucket_count) * 4) orelse {
            cache.release();
            return false;
        };
        const buckets: [*]u32 = @ptrCast(@alignCast(bucket_bytes.ptr));
        cache.buckets = buckets[0..bucket_count];
        @memset(cache.buckets, none);
        for (cache.entries) |*entry| {
            entry.buffer = cache.dev.alloc(cache.block_size) orelse {
                cache.release();
                return false;
            };
        }
        return true;
    }

    pub fn capacity(cache: *const Cache) u32 {
        return @intCast(cache.entries.len);
    }

    fn bucketOf(cache: *const Cache, addr: u64) usize {
        const mixed = addr *% 0x9E37_79B9_7F4A_7C15;
        return @intCast((mixed >> 32) & (cache.buckets.len - 1));
    }

    /// The block at `addr`, if the cache has it.
    pub fn find(cache: *Cache, addr: u64) ?[]u8 {
        if (cache.buckets.len == 0) return null;
        var at = cache.buckets[cache.bucketOf(addr)];
        while (at != none) : (at = cache.entries[at].chain) {
            if (cache.entries[at].addr == addr) {
                cache.touch(at);
                cache.hits += 1;
                return cache.entries[at].buffer;
            }
        }
        cache.misses += 1;
        return null;
    }

    /// A buffer to read the block at `addr` into, now the cache's entry
    /// for it. If the read fails the caller forgets the address.
    pub fn insert(cache: *Cache, addr: u64) ?[]u8 {
        if (cache.entries.len == 0) return null;
        cache.forget(addr);
        var at: u32 = undefined;
        if (cache.fresh < cache.entries.len) {
            at = cache.fresh;
            cache.fresh += 1;
        } else {
            at = cache.oldest;
            cache.unlink(at);
        }
        const entry = &cache.entries[at];
        entry.addr = addr;
        entry.used = true;
        const bucket = cache.bucketOf(addr);
        entry.chain = cache.buckets[bucket];
        cache.buckets[bucket] = at;
        cache.pushNewest(at);
        return entry.buffer;
    }

    /// The block at `addr` is no longer what the cache holds for it.
    pub fn forget(cache: *Cache, addr: u64) void {
        if (cache.buckets.len == 0) return;
        var at = cache.buckets[cache.bucketOf(addr)];
        while (at != none) : (at = cache.entries[at].chain) {
            if (cache.entries[at].addr == addr and cache.entries[at].used) {
                cache.unlink(at);
                // Back to the oldest end, to be reused first.
                cache.pushOldest(at);
                return;
            }
        }
    }

    /// Everything dropped: a medium changed, a volume formatted over.
    pub fn clear(cache: *Cache) void {
        @memset(cache.buckets, none);
        for (cache.entries) |*entry| {
            entry.used = false;
            entry.older = none;
            entry.newer = none;
            entry.chain = none;
        }
        cache.oldest = none;
        cache.newest = none;
        cache.fresh = 0;
    }

    /// Taken out of its bucket and the order of use.
    fn unlink(cache: *Cache, at: u32) void {
        const entry = &cache.entries[at];
        if (entry.used) {
            const bucket = cache.bucketOf(entry.addr);
            var link = &cache.buckets[bucket];
            while (link.* != none) : (link = &cache.entries[link.*].chain) {
                if (link.* == at) {
                    link.* = entry.chain;
                    break;
                }
            }
            entry.used = false;
            entry.chain = none;
        }
        if (entry.older != none) cache.entries[entry.older].newer = entry.newer else if (cache.oldest == at) cache.oldest = entry.newer;
        if (entry.newer != none) cache.entries[entry.newer].older = entry.older else if (cache.newest == at) cache.newest = entry.older;
        entry.older = none;
        entry.newer = none;
    }

    fn touch(cache: *Cache, at: u32) void {
        if (cache.newest == at) return;
        const entry = &cache.entries[at];
        if (entry.older != none) cache.entries[entry.older].newer = entry.newer else cache.oldest = entry.newer;
        if (entry.newer != none) cache.entries[entry.newer].older = entry.older;
        entry.older = none;
        entry.newer = none;
        cache.pushNewest(at);
    }

    fn pushNewest(cache: *Cache, at: u32) void {
        const entry = &cache.entries[at];
        entry.older = cache.newest;
        entry.newer = none;
        if (cache.newest != none) cache.entries[cache.newest].newer = at;
        cache.newest = at;
        if (cache.oldest == none) cache.oldest = at;
    }

    fn pushOldest(cache: *Cache, at: u32) void {
        const entry = &cache.entries[at];
        entry.newer = cache.oldest;
        entry.older = none;
        if (cache.oldest != none) cache.entries[cache.oldest].older = at;
        cache.oldest = at;
        if (cache.newest == none) cache.newest = at;
    }
};

fn sliceBytes(comptime T: type, items: []T) []u8 {
    const bytes: [*]u8 = @ptrCast(items.ptr);
    return bytes[0 .. items.len * @sizeOf(T)];
}

test "the cache keeps the newest blocks and forgets on request" {
    const std = @import("std");
    const TestMedia = @import("testmedia.zig").TestMedia;
    var m = try TestMedia.init(.sd, 64 * 1024, 9);
    defer m.deinit();
    var cache: Cache = undefined;
    try std.testing.expect(cache.init(m.device(), 512, 3));
    defer cache.deinit();
    for (0..3) |addr| cache.insert(addr).?[0] = @intCast(addr);
    try std.testing.expectEqual(@as(u8, 1), cache.find(1).?[0]);
    // 0 is now the oldest, so 3 takes its buffer.
    cache.insert(3).?[0] = 3;
    try std.testing.expect(cache.find(0) == null);
    try std.testing.expect(cache.find(2) != null);
    cache.forget(2);
    try std.testing.expect(cache.find(2) == null);
    // 2's buffer is reused before 1's.
    _ = cache.insert(4);
    try std.testing.expect(cache.find(1) != null);
    try std.testing.expect(cache.find(3) != null);
    try std.testing.expect(cache.find(4) != null);
    cache.clear();
    try std.testing.expect(cache.find(4) == null);
    try std.testing.expectEqual(@as(usize, 3 + 2), m.live);
}

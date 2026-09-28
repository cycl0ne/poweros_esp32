// SPDX-License-Identifier: MIT
//! The allocation bitmap: one bit per cluster, set while the cluster is in
//! use. On exFAT it, not the table, says which clusters are free.
//!
//! **Its bits are read and changed through the block cache**, a block of
//! them at a time, so a packet that takes several clusters writes the
//! block they are in once. The bitmap's own clusters are nearly always one
//! run; `init` checks, and one that is not is walked through the table.
//!
//! **The free count is counted once**, when the volume is mounted - a
//! 64 GB card's bitmap is 61 KB, read in a few blocks at a time - and kept
//! from then on as clusters are taken and given back. Where the next
//! search starts is remembered too, so filling a volume does not search
//! from its start every time.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const _fat = @import("../_fat.zig");
const cache_area = @import("../cache.zig");
const layout = @import("layout.zig");
const table_area = @import("table.zig");
const Error = _fat.Error;
const Geometry = layout.Geometry;
const Chain = table_area.Chain;
const Place = table_area.Place;

pub fn Bitmap(comptime Media: type) type {
    return struct {
        const Self = @This();
        const Cache = cache_area.BlockCache(Media);
        const Table = table_area.Table(Media);

        cache: *Cache,
        geo: *const Geometry,
        table: *Table,
        /// Where the bitmap's clusters are.
        chain: Chain,
        free_count: u32 = 0,
        /// Where the next search for a free cluster starts.
        next_free: u32 = fat.exfat_first_cluster,

        /// The bitmap whose entry says it starts at `first` and is `length`
        /// bytes long: long enough for every cluster, or the volume is
        /// refused. Its free clusters are counted, a block at a time
        /// through `scratch`.
        pub fn init(cache: *Cache, geo: *const Geometry, table: *Table, first: u32, length: u64, scratch: []u8) Error!Self {
            if (length < (@as(u64, geo.cluster_count) + 7) / 8) return error.MediumFailed;
            if (!geo.usable(first)) return error.MediumFailed;
            var self: Self = .{ .cache = cache, .geo = geo, .table = table, .chain = .{ .first = first } };
            // One run if the table links it that way: then a block of it is
            // found by arithmetic and never by walking.
            const clusters = geo.clustersFor(length);
            var cluster = first;
            var run = true;
            var ordinal: u64 = 1;
            while (ordinal < clusters) : (ordinal += 1) {
                const following = try table.next(cluster) orelse return error.MediumFailed;
                if (following != cluster + 1) run = false;
                cluster = following;
            }
            self.chain.contiguous = run;
            try self.count(scratch);
            return self;
        }

        /// The block holding cluster `cluster`'s bit, and the byte in it.
        fn spotOf(self: *Self, cluster: u32) Error!struct { block: u64, byte: u32, bit: u3 } {
            const index = cluster - fat.exfat_first_cluster;
            const byte = index / 8;
            const block_in_bitmap = byte >> self.geo.sector_shift;
            var place: Place = .{};
            const holding = try self.table.clusterAt(self.chain, &place, block_in_bitmap >> self.geo.cluster_shift);
            const sector = block_in_bitmap & (self.geo.sectors_per_cluster - 1);
            return .{
                .block = self.geo.clusterBlock(holding) + sector,
                .byte = byte & (self.geo.sector_bytes - 1),
                .bit = @intCast(index % 8),
            };
        }

        /// Every free cluster counted, the bitmap read a block at a time.
        fn count(self: *Self, scratch: []u8) Error!void {
            var free: u32 = 0;
            const blocks_total = ((@as(u64, self.geo.cluster_count) + 7) / 8 + self.geo.sector_bytes - 1) >> self.geo.sector_shift;
            var place: Place = .{};
            var block_in_bitmap: u64 = 0;
            var cluster_index: u64 = 0;
            while (block_in_bitmap < blocks_total) : (block_in_bitmap += 1) {
                const holding = try self.table.clusterAt(self.chain, &place, block_in_bitmap >> self.geo.cluster_shift);
                const sector = block_in_bitmap & (self.geo.sectors_per_cluster - 1);
                self.cache.readRun(self.geo.clusterBlock(holding) + sector, 1, scratch) catch return error.MediumFailed;
                for (scratch[0..self.geo.sector_bytes]) |byte| {
                    const left = self.geo.cluster_count - cluster_index;
                    if (left == 0) break;
                    const bits: u8 = if (left >= 8) byte else byte & @as(u8, @intCast((@as(u16, 1) << @intCast(left)) - 1));
                    free += if (left >= 8) 8 - @popCount(bits) else @as(u32, @intCast(left)) - @popCount(bits);
                    cluster_index += @min(left, 8);
                }
            }
            self.free_count = free;
        }

        /// Whether a cluster is in use.
        pub fn used(self: *Self, cluster: u32) Error!bool {
            const spot = try self.spotOf(cluster);
            const block = self.cache.get(spot.block) catch return error.MediumFailed;
            return block[spot.byte] & (@as(u8, 1) << spot.bit) != 0;
        }

        /// A cluster marked in use or free, and the count kept.
        pub fn mark(self: *Self, cluster: u32, in_use: bool) Error!void {
            const spot = try self.spotOf(cluster);
            const block = self.cache.getForWrite(spot.block) catch return error.MediumFailed;
            const bit = @as(u8, 1) << spot.bit;
            const was = block[spot.byte] & bit != 0;
            if (was == in_use) return;
            if (in_use) {
                block[spot.byte] |= bit;
                self.free_count -= 1;
            } else {
                block[spot.byte] &= ~bit;
                self.free_count += 1;
            }
        }

        /// A free cluster, taken: searched for from where the last search
        /// ended, round to the start. The search goes a block of bits at a
        /// time and passes over whole bytes that are full.
        pub fn allocate(self: *Self) Error!u32 {
            if (self.free_count == 0) return error.DiskFull;
            const first = fat.exfat_first_cluster;
            const total = self.geo.cluster_count;
            var index: u32 = self.next_free - first;
            var looked: u32 = 0;
            while (looked < total) {
                const spot = try self.spotOf(first + index);
                const block = self.cache.get(spot.block) catch return error.MediumFailed;
                // A byte whose every bit is set holds nothing for us.
                if (spot.bit == 0 and block[spot.byte] == 0xFF and total - index >= 8) {
                    index = (index + 8) % total;
                    looked += 8;
                    continue;
                }
                if (block[spot.byte] & (@as(u8, 1) << spot.bit) == 0) {
                    const cluster = first + index;
                    try self.mark(cluster, true);
                    self.next_free = if (index + 1 < total) cluster + 1 else first;
                    return cluster;
                }
                index = (index + 1) % total;
                looked += 1;
            }
            return error.DiskFull;
        }

        /// The cluster right after `cluster` taken if it is free: what keeps
        /// a growing file in one run. False if it is not there to take.
        pub fn allocateAfter(self: *Self, cluster: u32) Error!bool {
            const following = cluster + 1;
            if (!self.geo.usable(following)) return false;
            if (try self.used(following)) return false;
            try self.mark(following, true);
            if (self.next_free == following) self.next_free = if (self.geo.usable(following + 1)) following + 1 else fat.exfat_first_cluster;
            return true;
        }

        /// Clusters given back.
        pub fn release(self: *Self, cluster: u32) Error!void {
            try self.mark(cluster, false);
        }
    };
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;
const TestMedia = @import("../testmedia.zig").TestMedia;
const fixture = @import("testfixture.zig");
const TestBitmap = Bitmap(TestMedia);

const Rig = struct {
    media: TestMedia,
    cache: TestBitmap.Cache,
    geo: Geometry,
    table: TestBitmap.Table,
    bitmap: TestBitmap,
    scratch: [512]u8,

    fn init(rig: *Rig) !void {
        rig.media = TestMedia.init(512, fixture.blocks());
        try fixture.load(&rig.media, 0);
        var boot: [512]u8 = undefined;
        try testing.expect(rig.media.read(0, 1, &boot));
        rig.geo = try Geometry.of(&boot, 0, rig.media.blocks(), 512);
        rig.cache = try TestBitmap.Cache.init(&rig.media, 8);
        rig.table = TestBitmap.Table.init(&rig.cache, &rig.geo);
        // The fixture's bitmap: cluster 2, 448 bytes (3584 clusters).
        rig.bitmap = try TestBitmap.init(&rig.cache, &rig.geo, &rig.table, 2, 448, &rig.scratch);
    }

    fn deinit(rig: *Rig) void {
        rig.cache.deinit();
        rig.media.deinit();
    }
};

test "the kernel's volume has the free clusters it says" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try testing.expect(rig.bitmap.chain.contiguous);
    // The bitmap, the up-case table (two), the root, and what the files
    // and directories took.
    try testing.expect(try rig.bitmap.used(2));
    try testing.expect(try rig.bitmap.used(3));
    try testing.expect(try rig.bitmap.used(fixture.root_cluster));
    try testing.expect(rig.bitmap.free_count < fixture.cluster_count - 4);
    try testing.expect(rig.bitmap.free_count > fixture.cluster_count - 200);
    try testing.expect(!try rig.bitmap.used(fixture.cluster_count));
}

test "clusters taken and given back keep the count" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const free = rig.bitmap.free_count;
    const one = try rig.bitmap.allocate();
    try testing.expect(try rig.bitmap.used(one));
    try testing.expectEqual(free - 1, rig.bitmap.free_count);
    try testing.expect(try rig.bitmap.allocateAfter(one));
    try testing.expect(try rig.bitmap.used(one + 1));
    try rig.bitmap.release(one);
    try rig.bitmap.release(one + 1);
    try testing.expectEqual(free, rig.bitmap.free_count);
    // Taken again, the count is counted again from the medium the same.
    _ = try rig.cache.flush();
    const again = try TestBitmap.init(&rig.cache, &rig.geo, &rig.table, 2, 448, &rig.scratch);
    try testing.expectEqual(free, again.free_count);
}

test "a cluster that is taken is not taken again, and a full volume says so" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var seen = std.AutoHashMap(u32, void).init(testing.allocator);
    defer seen.deinit();
    while (rig.bitmap.free_count > 0) {
        const cluster = try rig.bitmap.allocate();
        try testing.expect(!seen.contains(cluster));
        try seen.put(cluster, {});
    }
    try testing.expectError(error.DiskFull, rig.bitmap.allocate());
    // The last cluster of the volume was among them.
    try testing.expect(seen.contains(fat.exfat_first_cluster + fixture.cluster_count - 1));
}

test "a run grows in place only into a free cluster" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    // Cluster 3 is followed by 4, the up-case table's: taken.
    try testing.expect(!try rig.bitmap.allocateAfter(3));
    // The volume's last cluster has nothing after it.
    try testing.expect(!try rig.bitmap.allocateAfter(fat.exfat_first_cluster + fixture.cluster_count - 1));
}

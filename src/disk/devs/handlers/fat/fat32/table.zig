// SPDX-License-Identifier: MIT
//! The table: which cluster follows which, which are free, and how many.
//!
//! Every entry is read from one copy and written to every copy that is
//! kept (`Geometry.copies`), through the block cache, so a table sector
//! that is changed twice in one packet goes to the medium once.
//!
//! **The free count and where to look for a free cluster** are kept in
//! memory and written to the free-count sector when the table is
//! flushed. Both are hints on the medium - a volume whose count is wrong
//! is still a good volume - so a count that cannot be true is dropped,
//! and an unknown one is counted from the table the first time something
//! asks for it rather than at mount: counting a 64 GB card's table reads
//! 15 MB.
//!
//! **A chain is never trusted to end.** Following one stops at the
//! volume's cluster count, so a table with a loop in it answers an error
//! instead of hanging the handler.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const _fat = @import("../_fat.zig");
const cache_area = @import("../cache.zig");
const layout = @import("layout.zig");
const Error = _fat.Error;
const Geometry = layout.Geometry;

/// Table sectors read at once when counting the free clusters.
const count_run: u32 = 16;

pub fn Table(comptime Media: type) type {
    return struct {
        const Self = @This();
        const Cache = cache_area.BlockCache(Media);

        cache: *Cache,
        geo: *const Geometry,
        /// Free clusters, when known.
        free_count: ?u32 = null,
        /// Where the next search for a free cluster starts.
        next_free: u32 = fat.first_cluster,
        /// Whether the free-count sector was sound when read: only then
        /// is it written back, so a volume that had none is not given one
        /// in a place something else may be using.
        fsinfo_sound: bool = false,
        /// The hints changed since they were last written.
        hints_changed: bool = false,

        pub fn init(cache: *Cache, geo: *const Geometry) Self {
            return .{ .cache = cache, .geo = geo };
        }

        /// The medium's cache, through the error set everything above
        /// answers with.
        fn get(self: *Self, block: u64) Error![]const u8 {
            return self.cache.get(block) catch error.MediumFailed;
        }

        fn getForWrite(self: *Self, block: u64) Error![]u8 {
            return self.cache.getForWrite(block) catch error.MediumFailed;
        }

        /// The free count and the search hint from the free-count sector,
        /// each dropped if it cannot be true.
        pub fn loadHints(self: *Self) Error!void {
            self.free_count = null;
            self.next_free = fat.first_cluster;
            self.fsinfo_sound = false;
            const at = self.geo.fsinfo orelse return;
            const block = try self.get(self.geo.first + at);
            if (!fat.fsinfoSound(block)) return;
            self.fsinfo_sound = true;
            const count = fat.u32At(block, fat.fsinfo_free_count_at);
            if (count != fat.fsinfo_unknown and count <= self.geo.cluster_count) self.free_count = count;
            const hint = fat.u32At(block, fat.fsinfo_next_free_at);
            if (self.geo.usable(hint)) self.next_free = hint;
        }

        // --- entries ---------------------------------------------------------

        /// A cluster's entry: the cluster that follows it, a chain end, or
        /// a free or bad mark.
        pub fn entry(self: *Self, cluster: u32) Error!u32 {
            if (!self.geo.usable(cluster)) return error.MediumFailed;
            const spot = self.geo.entrySpot(self.geo.readCopy(), cluster);
            const block = try self.get(spot.block);
            return fat.clusterOf(fat.u32At(block, spot.at));
        }

        /// A cluster's entry set in every copy that is kept, with the four
        /// bits that are not the cluster number left as each copy has them.
        pub fn setEntry(self: *Self, cluster: u32, value: u32) Error!void {
            if (!self.geo.usable(cluster)) return error.MediumFailed;
            const copies = self.geo.copies();
            var copy = copies.first;
            while (copy < copies.end) : (copy += 1) {
                const spot = self.geo.entrySpot(copy, cluster);
                const block = try self.getForWrite(spot.block);
                fat.putU32(block, spot.at, fat.entryWith(fat.u32At(block, spot.at), value));
            }
        }

        /// The cluster after `cluster` in its chain, or null where the
        /// chain ends. A chain that runs into a free or bad cluster, or off
        /// the volume, is broken, and says so.
        pub fn next(self: *Self, cluster: u32) Error!?u32 {
            const following = try self.entry(cluster);
            if (fat.endsChain(following)) return null;
            if (!self.geo.usable(following)) return error.MediumFailed;
            return following;
        }

        /// The cluster `steps` along a chain from `first`.
        pub fn walk(self: *Self, first: u32, steps: u32) Error!u32 {
            var cluster = first;
            var left = steps;
            while (left > 0) : (left -= 1) {
                cluster = try self.next(cluster) orelse return error.MediumFailed;
            }
            return cluster;
        }

        /// How many clusters a chain has. A chain longer than the volume
        /// has clusters goes round in a loop.
        pub fn length(self: *Self, first: u32) Error!u32 {
            var count: u32 = 1;
            var cluster = first;
            while (try self.next(cluster)) |following| {
                count += 1;
                if (count > self.geo.cluster_count) return error.MediumFailed;
                cluster = following;
            }
            return count;
        }

        // --- allocating ------------------------------------------------------

        /// A free cluster, taken: marked as the end of a chain, and linked
        /// after `after` when there is one. The search starts where the
        /// last one ended, so a file written in one go gets clusters in a
        /// row.
        pub fn allocate(self: *Self, after: ?u32) Error!u32 {
            if (self.free_count) |count| if (count == 0) return error.DiskFull;
            const count = self.geo.cluster_count;
            var cluster = if (self.geo.usable(self.next_free)) self.next_free else fat.first_cluster;
            var looked: u32 = 0;
            while (looked < count) : (looked += 1) {
                if (try self.entry(cluster) == fat.free_cluster) {
                    try self.setEntry(cluster, fat.eoc);
                    if (after) |previous| try self.setEntry(previous, cluster);
                    if (self.free_count) |*left| left.* -= 1;
                    self.next_free = if (cluster + 1 < fat.first_cluster + count) cluster + 1 else fat.first_cluster;
                    self.hints_changed = true;
                    return cluster;
                }
                cluster += 1;
                if (cluster >= fat.first_cluster + count) cluster = fat.first_cluster;
            }
            // Nothing free, whatever the count said.
            self.free_count = 0;
            self.hints_changed = true;
            return error.DiskFull;
        }

        /// Every cluster of the chain from `first` given back.
        pub fn freeChain(self: *Self, first: u32) Error!void {
            var cluster = first;
            var freed: u32 = 0;
            while (true) {
                // Read before the entry is cleared: clearing it is what
                // loses where the chain goes.
                const following = try self.next(cluster);
                try self.setEntry(cluster, fat.free_cluster);
                freed += 1;
                if (freed > self.geo.cluster_count) return error.MediumFailed;
                cluster = following orelse break;
            }
            if (self.free_count) |*count| count.* = @min(count.* + freed, self.geo.cluster_count);
            // What was just freed is where the next file should go: it
            // keeps the volume's clusters packed towards the front.
            if (first < self.next_free) self.next_free = first;
            self.hints_changed = true;
        }

        /// The chain ends at `last`: whatever followed it is given back.
        pub fn cutAfter(self: *Self, last: u32) Error!void {
            const following = try self.next(last);
            try self.setEntry(last, fat.eoc);
            if (following) |rest| try self.freeChain(rest);
        }

        // --- counting ----------------------------------------------------------

        /// Free clusters, counted from the table if the count is not known.
        pub fn freeClusters(self: *Self) Error!u32 {
            if (self.free_count) |count| return count;
            const count = try self.countFree();
            self.free_count = count;
            self.hints_changed = true;
            return count;
        }

        /// The table read in runs around the cache - it would push out
        /// everything worth keeping - and every free entry counted.
        fn countFree(self: *Self) Error!u32 {
            const geo = self.geo;
            const run_bytes = count_run * geo.sector_bytes;
            const buffer = self.cache.media.alloc(run_bytes) orelse return error.NoMemory;
            defer self.cache.media.free(buffer);

            const entries_per_sector = geo.sector_bytes / 4;
            const last_entry: u64 = @as(u64, fat.first_cluster) + geo.cluster_count;
            const table = geo.entrySpot(geo.readCopy(), 0).block;
            var free: u32 = 0;
            var sector: u32 = 0;
            while (@as(u64, sector) * entries_per_sector < last_entry) : (sector += count_run) {
                const sectors = @min(count_run, geo.fat_sectors - sector);
                self.cache.readRun(table + sector, sectors, buffer[0 .. sectors * geo.sector_bytes]) catch
                    return error.MediumFailed;
                for (0..@as(usize, sectors) * entries_per_sector) |index| {
                    const cluster: u64 = @as(u64, sector) * entries_per_sector + index;
                    if (cluster < fat.first_cluster) continue;
                    if (cluster >= last_entry) break;
                    if (fat.clusterOf(fat.u32At(buffer, index * 4)) == fat.free_cluster) free += 1;
                }
            }
            return free;
        }

        // --- writing back ------------------------------------------------------

        /// The hints into the free-count sector, if it is one, and every
        /// changed block of the table to the medium.
        pub fn flush(self: *Self) Error!void {
            if (self.hints_changed and self.fsinfo_sound) {
                const block = try self.getForWrite(self.geo.first + self.geo.fsinfo.?);
                fat.putU32(block, fat.fsinfo_free_count_at, self.free_count orelse fat.fsinfo_unknown);
                fat.putU32(block, fat.fsinfo_next_free_at, self.next_free);
            }
            self.hints_changed = false;
            _ = self.cache.flush() catch return error.MediumFailed;
        }
    };
}

// --- tests ----------------------------------------------------------------

const testing = std.testing;
const TestMedia = @import("../testmedia.zig").TestMedia;
const testvolume = @import("testvolume.zig");
const TestTable = Table(TestMedia);

test "a chain is followed, and ends" {
    var volume = try testvolume.Volume.init(.{});
    defer volume.deinit();
    var table = TestTable.init(&volume.cache, &volume.geo);
    try table.loadHints();

    // The root directory is one cluster that ends at once.
    try testing.expectEqual(@as(?u32, null), try table.next(volume.geo.root_cluster));
    try testing.expectEqual(@as(u32, 1), try table.length(volume.geo.root_cluster));

    // Three clusters taken in a row make a chain of three.
    const one = try table.allocate(null);
    const two = try table.allocate(one);
    const three = try table.allocate(two);
    try testing.expectEqual(@as(?u32, two), try table.next(one));
    try testing.expectEqual(@as(?u32, three), try table.next(two));
    try testing.expectEqual(@as(u32, 3), try table.length(one));
    try testing.expectEqual(three, try table.walk(one, 2));
    // And they are next to each other, which is what makes a file read
    // in one run.
    try testing.expectEqual(one + 1, two);
    try testing.expectEqual(two + 1, three);
}

test "both copies of the table are written, and the top bits kept" {
    var volume = try testvolume.Volume.init(.{});
    defer volume.deinit();
    var table = TestTable.init(&volume.cache, &volume.geo);
    try table.loadHints();

    const cluster = try table.allocate(null);
    try table.flush();
    for (0..2) |copy| {
        const spot = volume.geo.entrySpot(@intCast(copy), cluster);
        var block: [512]u8 = undefined;
        try testing.expect(volume.media.read(spot.block, 1, &block));
        try testing.expectEqual(fat.eoc, fat.clusterOf(fat.u32At(&block, spot.at)));
    }

    // Four bits someone else wrote on top survive a change.
    const spot = volume.geo.entrySpot(0, cluster);
    const block = try volume.cache.getForWrite(spot.block);
    fat.putU32(block, spot.at, 0xA000_0000 | fat.eoc);
    try table.setEntry(cluster, 1234);
    try testing.expectEqual(@as(u32, 0xA000_0000 | 1234), fat.u32At(try volume.cache.get(spot.block), spot.at));
}

test "freeing a chain gives every cluster back and counts it" {
    var volume = try testvolume.Volume.init(.{});
    defer volume.deinit();
    var table = TestTable.init(&volume.cache, &volume.geo);
    try table.loadHints();

    const before = try table.freeClusters();
    const one = try table.allocate(null);
    const two = try table.allocate(one);
    _ = try table.allocate(two);
    try testing.expectEqual(before - 3, try table.freeClusters());

    // Cut after the first: two come back.
    try table.cutAfter(one);
    try testing.expectEqual(@as(u32, 1), try table.length(one));
    try testing.expectEqual(before - 1, try table.freeClusters());
    try testing.expectEqual(fat.free_cluster, try table.entry(two));

    try table.freeChain(one);
    try testing.expectEqual(before, try table.freeClusters());
    // And the next file goes where that one was.
    try testing.expectEqual(one, try table.allocate(null));
}

test "the free count is counted when the volume does not say" {
    var volume = try testvolume.Volume.init(.{ .fsinfo_count = fat.fsinfo_unknown });
    defer volume.deinit();
    var table = TestTable.init(&volume.cache, &volume.geo);
    try table.loadHints();
    try testing.expectEqual(@as(?u32, null), table.free_count);
    // Every cluster but the root directory's.
    try testing.expectEqual(volume.geo.cluster_count - 1, try table.freeClusters());

    // A count larger than the volume is not believed either.
    var second = try testvolume.Volume.init(.{ .fsinfo_count = 0xFFFF_FFF0 });
    defer second.deinit();
    var other = TestTable.init(&second.cache, &second.geo);
    try other.loadHints();
    try testing.expectEqual(@as(?u32, null), other.free_count);
}

test "the hints go back to the free-count sector" {
    var volume = try testvolume.Volume.init(.{});
    defer volume.deinit();
    var table = TestTable.init(&volume.cache, &volume.geo);
    try table.loadHints();
    const before = try table.freeClusters();
    const cluster = try table.allocate(null);
    try table.flush();

    var block: [512]u8 = undefined;
    try testing.expect(volume.media.read(volume.geo.first + volume.geo.fsinfo.?, 1, &block));
    try testing.expect(fat.fsinfoSound(&block));
    try testing.expectEqual(before - 1, fat.u32At(&block, fat.fsinfo_free_count_at));
    try testing.expectEqual(cluster + 1, fat.u32At(&block, fat.fsinfo_next_free_at));
}

test "a full volume says so, whatever its count claimed" {
    var volume = try testvolume.Volume.init(.{ .clusters = 4 });
    defer volume.deinit();
    var table = TestTable.init(&volume.cache, &volume.geo);
    try table.loadHints();
    // The root has one of the four.
    _ = try table.allocate(null);
    _ = try table.allocate(null);
    _ = try table.allocate(null);
    try testing.expectError(error.DiskFull, table.allocate(null));

    // A count that says there is room, on a table that has none.
    table.free_count = 10;
    try testing.expectError(error.DiskFull, table.allocate(null));
    try testing.expectEqual(@as(?u32, 0), table.free_count);
}

test "a chain that loops is an error, not a hang" {
    var volume = try testvolume.Volume.init(.{});
    defer volume.deinit();
    var table = TestTable.init(&volume.cache, &volume.geo);
    try table.loadHints();
    const one = try table.allocate(null);
    const two = try table.allocate(one);
    try table.setEntry(two, one);
    try testing.expectError(error.MediumFailed, table.length(one));

    // And one that runs into a free cluster is broken.
    try table.setEntry(two, two + 5);
    try testing.expectError(error.MediumFailed, table.length(one));
}

test "the search wraps round to the start of the volume" {
    var volume = try testvolume.Volume.init(.{ .clusters = 8 });
    defer volume.deinit();
    var table = TestTable.init(&volume.cache, &volume.geo);
    try table.loadHints();
    // Pointing past everything free: the search comes round.
    table.next_free = volume.geo.cluster_count + 1;
    const cluster = try table.allocate(null);
    try testing.expect(volume.geo.usable(cluster));
}

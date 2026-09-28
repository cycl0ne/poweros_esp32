// SPDX-License-Identifier: MIT
//! The table (FAT) of an exFAT volume, and the chains of clusters a file,
//! a directory, the bitmap and the up-case table are kept in.
//!
//! **A chain is one of two things.** Its clusters follow one another - the
//! stream says so with NoFatChain, and the table's entries for them mean
//! nothing - or they are linked through the table as on FAT32. `Chain`
//! holds which, and `clusterAt` answers the cluster at a place in either
//! the same way, so nothing above it has to care. A chain that could stay
//! one run and cannot - its next cluster is taken - is linked through the
//! table as it stands (`link`) and goes on from there as a linked chain.
//!
//! **Which clusters are in use is not the table's to say**: that is the
//! allocation bitmap's (`bitmap.zig`). The table only links.
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

/// Where a chain's clusters are.
pub const Chain = struct {
    /// Its first cluster; 0 for a chain with no clusters.
    first: u32 = 0,
    /// Its clusters follow one another, with no table entries.
    contiguous: bool = false,
};

/// Where a walk along a chain got to: the cluster `ordinal` steps in. A
/// cluster of 0 is nowhere yet.
pub const Place = struct { ordinal: u64 = 0, cluster: u32 = 0 };

pub fn Table(comptime Media: type) type {
    return struct {
        const Self = @This();
        const Cache = cache_area.BlockCache(Media);

        cache: *Cache,
        geo: *const Geometry,

        pub fn init(cache: *Cache, geo: *const Geometry) Self {
            return .{ .cache = cache, .geo = geo };
        }

        /// The cluster after `cluster` in a linked chain, or null where it
        /// ends. A value that is no cluster of this volume - a bad
        /// cluster, a free one, one past the end - is a damaged table.
        pub fn next(self: *Self, cluster: u32) Error!?u32 {
            const spot = self.geo.entrySpot(cluster);
            const block = self.cache.get(spot.block) catch return error.MediumFailed;
            const value = fat.u32At(block, spot.at);
            if (value == fat.exfat_eoc) return null;
            if (!self.geo.usable(value)) return error.MediumFailed;
            return value;
        }

        /// `cluster`'s entry in the table.
        pub fn set(self: *Self, cluster: u32, value: u32) Error!void {
            const spot = self.geo.entrySpot(cluster);
            const block = self.cache.getForWrite(spot.block) catch return error.MediumFailed;
            fat.putU32(block, spot.at, value);
        }

        /// The cluster `ordinal` steps into `chain`, walked from `place` if
        /// that is not past it. The place is moved there.
        pub inline fn clusterAt(self: *Self, chain: Chain, place: *Place, ordinal: u64) Error!u32 {
            // No chain is longer than a volume has clusters, which a u32
            // counts.
            if (ordinal > std.math.maxInt(u32)) return error.MediumFailed;
            return self.walkTo(chain, place, @intCast(ordinal));
        }

        /// clusterAt's walk. Every argument is 32 bits, so a call to it
        /// passes them all in registers: with a 64-bit one among them the
        /// compiler passed it on the stack and failed on the caller
        /// (an LLVM register-scavenger error in exfat's spotOf).
        noinline fn walkTo(self: *Self, chain: Chain, place: *Place, ordinal: u32) Error!u32 {
            if (!self.geo.usable(chain.first)) return error.MediumFailed;
            if (chain.contiguous) {
                const cluster = @as(u64, chain.first) + ordinal;
                if (cluster > std.math.maxInt(u32) or !self.geo.usable(@intCast(cluster))) return error.MediumFailed;
                place.* = .{ .ordinal = ordinal, .cluster = @intCast(cluster) };
                return place.cluster;
            }
            if (place.cluster == 0 or place.ordinal > ordinal) place.* = .{ .cluster = chain.first };
            while (place.ordinal < ordinal) {
                place.cluster = try self.next(place.cluster) orelse return error.MediumFailed;
                place.ordinal += 1;
                if (place.ordinal > self.geo.cluster_count) return error.MediumFailed;
            }
            return place.cluster;
        }

        /// How many clusters a linked chain has, walked to its end.
        pub fn length(self: *Self, first: u32) Error!u64 {
            if (!self.geo.usable(first)) return error.MediumFailed;
            var count: u64 = 1;
            var cluster = first;
            while (try self.next(cluster)) |following| : (count += 1) {
                if (count > self.geo.cluster_count) return error.MediumFailed;
                cluster = following;
            }
            return count;
        }

        /// A run of `count` clusters from `first`, linked through the table
        /// as it stands and ended there: what a chain that was one run
        /// becomes when it cannot grow in place.
        pub fn link(self: *Self, first: u32, count: u64) Error!void {
            if (count == 0) return;
            var at: u64 = 0;
            while (at + 1 < count) : (at += 1) {
                const cluster: u32 = @intCast(first + at);
                try self.set(cluster, cluster + 1);
            }
            try self.set(@intCast(first + count - 1), fat.exfat_eoc);
        }

        /// Every cluster of a chain of `count` clusters, handed to `each`:
        /// for freeing one. A linked chain is walked; a run is counted.
        pub fn forEach(self: *Self, chain: Chain, count: u64, context: anytype, each: fn (@TypeOf(context), u32) Error!void) Error!void {
            if (count == 0 or chain.first == 0) return;
            var place: Place = .{};
            var ordinal: u64 = 0;
            while (ordinal < count) : (ordinal += 1) {
                try each(context, try self.clusterAt(chain, &place, ordinal));
            }
        }
    };
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;
const TestMedia = @import("../testmedia.zig").TestMedia;
const fixture = @import("testfixture.zig");
const TestTable = Table(TestMedia);

const Rig = struct {
    media: TestMedia,
    cache: TestTable.Cache,
    geo: Geometry,
    table: TestTable,

    fn init(rig: *Rig) !void {
        rig.media = TestMedia.init(512, fixture.blocks());
        try fixture.load(&rig.media, 0);
        var boot: [512]u8 = undefined;
        try testing.expect(rig.media.read(0, 1, &boot));
        rig.geo = try Geometry.of(&boot, 0, rig.media.blocks(), 512);
        rig.cache = try TestTable.Cache.init(&rig.media, 8);
        rig.table = TestTable.init(&rig.cache, &rig.geo);
    }

    fn deinit(rig: *Rig) void {
        rig.cache.deinit();
        rig.media.deinit();
    }
};

test "the kernel's chains are read as it linked them" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    // The up-case table: 5836 bytes, two clusters from cluster 3, linked.
    try testing.expectEqual(@as(?u32, 4), try rig.table.next(3));
    try testing.expectEqual(@as(?u32, null), try rig.table.next(4));
    try testing.expectEqual(@as(u64, 2), try rig.table.length(3));
    // The root directory, one cluster.
    try testing.expectEqual(@as(u64, 1), try rig.table.length(fixture.root_cluster));
}

test "a run and a linked chain are walked alike" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var place: Place = .{};
    const run: Chain = .{ .first = 100, .contiguous = true };
    try testing.expectEqual(@as(u32, 103), try rig.table.clusterAt(run, &place, 3));
    try testing.expectEqual(@as(u32, 101), try rig.table.clusterAt(run, &place, 1));

    // The same run linked, then walked through the table.
    try rig.table.link(100, 4);
    const linked: Chain = .{ .first = 100 };
    place = .{};
    try testing.expectEqual(@as(u32, 103), try rig.table.clusterAt(linked, &place, 3));
    try testing.expectEqual(@as(u32, 3), @as(u32, @intCast(place.ordinal)));
    try testing.expectError(error.MediumFailed, rig.table.clusterAt(linked, &place, 4));
    try testing.expectEqual(@as(u64, 4), try rig.table.length(100));
}

test "a chain with a loop in it is an error, not a hang" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.table.set(200, 201);
    try rig.table.set(201, 200);
    try testing.expectError(error.MediumFailed, rig.table.length(200));
}

test "a run past the volume's last cluster is an error" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var place: Place = .{};
    const run: Chain = .{ .first = fixture.cluster_count, .contiguous = true };
    try testing.expectError(error.MediumFailed, rig.table.clusterAt(run, &place, 5));
}

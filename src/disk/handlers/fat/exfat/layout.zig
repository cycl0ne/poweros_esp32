// SPDX-License-Identifier: MIT
//! Where things are on an exFAT volume: its boot sector checked and turned
//! into the numbers every other part of the file system addresses the
//! medium by.
//!
//! **One sector is one block**, as on FAT32: a volume whose sector size is
//! not the medium's block size is refused.
//!
//! **Every address this answers is the medium's**, counted from its first
//! block, with the volume's own first block already added in.
//!
//! The boot sector is checked for what would make the arithmetic after it
//! wrong - a table too short for its clusters, a cluster heap that starts
//! inside the table or runs past the volume, a root directory outside the
//! heap - and, separately, against the checksum its boot region carries
//! (`checksumHolds`). What is only untidy is let through.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const _fat = @import("../_fat.zig");
const Error = _fat.Error;

/// The largest cluster the format allows: 32 MiB.
const max_cluster_shift: u8 = 25;
/// The most clusters a volume may have: the table's values from here up
/// mark bad clusters and the end of chains.
pub const max_clusters: u32 = 0xFFFF_FFF5;

pub const Geometry = struct {
    /// The volume's first block on the medium.
    first: u64,
    /// Blocks in the volume.
    volume_blocks: u64,
    sector_bytes: u32,
    sector_shift: u5,
    sectors_per_cluster: u32,
    cluster_shift: u5,
    cluster_bytes: u32,
    /// The table in use, counted from the volume, and its length in
    /// sectors.
    fat_first: u32,
    fat_sectors: u32,
    /// The first sector of cluster 2, counted from the volume.
    heap_first: u32,
    /// Clusters there are, from cluster 2 up.
    cluster_count: u32,
    root_cluster: u32,
    serial: u32,
    /// VolumeFlags as the boot sector had them when the volume was read.
    flags: u16,

    /// The geometry of the volume whose boot sector is `boot`, which lies
    /// at block `first` of a medium of `medium_blocks` blocks of
    /// `block_bytes` bytes.
    pub fn of(boot: []const u8, first: u64, medium_blocks: u64, block_bytes: u32) Error!Geometry {
        if (fat.formatOf(boot) != .exfat) return error.MediumFailed;
        if (!fat.signed(boot)) return error.MediumFailed;
        // Where a FAT volume's BPB would be, zeroes: a volume that says
        // otherwise is something else wearing the name.
        for (boot[fat.exfat_zero_from..fat.exfat_zero_to]) |byte| if (byte != 0) return error.MediumFailed;
        if (boot[fat.exfat_revision + 1] != fat.exfat_major_revision) return error.MediumFailed;

        const sector_shift = boot[fat.exfat_sector_shift];
        const cluster_shift = boot[fat.exfat_cluster_shift];
        if (sector_shift < 9 or sector_shift > 12) return error.MediumFailed;
        if (@as(u32, 1) << @intCast(sector_shift) != block_bytes) return error.MediumFailed;
        if (@as(u32, sector_shift) + cluster_shift > max_cluster_shift) return error.MediumFailed;

        const fat_count = boot[fat.exfat_fat_count];
        if (fat_count != 1 and fat_count != 2) return error.MediumFailed;
        const flags = fat.u16At(boot, fat.exfat_volume_flags);
        const active: u32 = if (flags & fat.exfat_active_fat != 0) 1 else 0;
        if (active >= fat_count) return error.MediumFailed;

        const volume_blocks = fat.u64At(boot, fat.exfat_volume_length);
        if (first >= medium_blocks or volume_blocks > medium_blocks - first) return error.MediumFailed;

        const fat_offset = fat.u32At(boot, fat.exfat_fat_offset);
        const fat_length = fat.u32At(boot, fat.exfat_fat_length);
        const heap_offset = fat.u32At(boot, fat.exfat_heap_offset);
        const cluster_count = fat.u32At(boot, fat.exfat_cluster_count);
        const root_cluster = fat.u32At(boot, fat.exfat_root_cluster);

        // The table behind the boot regions, the heap behind the tables,
        // and the heap's clusters inside the volume. Added up in 64 bits:
        // these are sector counts of a volume that may be terabytes.
        if (fat_offset < 2 * fat.exfat_boot_sectors or fat_length == 0) return error.MediumFailed;
        const tables_end = @as(u64, fat_offset) + @as(u64, fat_count) * fat_length;
        if (heap_offset < tables_end) return error.MediumFailed;
        if (cluster_count == 0 or cluster_count > max_clusters) return error.MediumFailed;
        const heap_sectors = @as(u64, cluster_count) << @intCast(cluster_shift);
        if (@as(u64, heap_offset) + heap_sectors > volume_blocks) return error.MediumFailed;
        // The table must describe every cluster, entries 0 and 1 too.
        const entries = (@as(u64, fat_length) << @intCast(sector_shift)) / 4;
        if (entries < @as(u64, cluster_count) + fat.exfat_first_cluster) return error.MediumFailed;
        if (root_cluster < fat.exfat_first_cluster or root_cluster - fat.exfat_first_cluster >= cluster_count) return error.MediumFailed;

        return .{
            .first = first,
            .volume_blocks = volume_blocks,
            .sector_bytes = block_bytes,
            .sector_shift = @intCast(sector_shift),
            .sectors_per_cluster = @as(u32, 1) << @intCast(cluster_shift),
            .cluster_shift = @intCast(cluster_shift),
            .cluster_bytes = block_bytes << @intCast(cluster_shift),
            .fat_first = fat_offset + active * fat_length,
            .fat_sectors = fat_length,
            .heap_first = heap_offset,
            .cluster_count = cluster_count,
            .root_cluster = root_cluster,
            .serial = fat.u32At(boot, fat.exfat_serial),
            .flags = flags,
        };
    }

    /// The block a cluster starts at.
    pub fn clusterBlock(geo: *const Geometry, cluster: u32) u64 {
        return geo.first + geo.heap_first + (@as(u64, cluster - fat.exfat_first_cluster) << geo.cluster_shift);
    }

    /// Where a cluster's entry is in the table: its block, and the byte in
    /// that block.
    pub fn entrySpot(geo: *const Geometry, cluster: u32) struct { block: u64, at: u32 } {
        const byte: u64 = @as(u64, cluster) * 4;
        return .{
            .block = geo.first + geo.fat_first + (byte >> geo.sector_shift),
            .at = @intCast(byte & (geo.sector_bytes - 1)),
        };
    }

    /// Whether a value is a cluster of this volume.
    pub fn usable(geo: *const Geometry, cluster: u32) bool {
        return cluster >= fat.exfat_first_cluster and cluster - fat.exfat_first_cluster < geo.cluster_count;
    }

    /// Clusters a run of `bytes` takes.
    pub fn clustersFor(geo: *const Geometry, bytes: u64) u64 {
        return (bytes + geo.cluster_bytes - 1) >> @intCast(@as(u6, geo.sector_shift) + geo.cluster_shift);
    }

    /// The volume's first sector, the boot sector, on the medium.
    pub fn bootBlock(geo: *const Geometry) u64 {
        return geo.first;
    }
};

/// Whether the boot region at `first` carries the checksum its twelfth
/// sector says it does: the eleven sectors before it summed, and every
/// word of the twelfth that sum. `sector` is one block of scratch.
pub fn checksumHolds(media: anytype, first: u64, sector: []u8) bool {
    var sum: u32 = 0;
    for (0..fat.exfat_checksum_sector) |at| {
        if (!media.read(first + at, 1, sector)) return false;
        sum = fat.exfatBootChecksum(sum, sector, at == 0);
    }
    if (!media.read(first + fat.exfat_checksum_sector, 1, sector)) return false;
    var at: usize = 0;
    while (at + 4 <= sector.len) : (at += 4) {
        if (fat.u32At(sector, at) != sum) return false;
    }
    return true;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;
const TestMedia = @import("../testmedia.zig").TestMedia;
const fixture = @import("testfixture.zig");

fn fixtureMedia(first: u64) !TestMedia {
    var media = TestMedia.init(512, first + fixture.blocks());
    errdefer media.deinit();
    try fixture.load(&media, first);
    return media;
}

test "a volume the kernel wrote is read as it says it is" {
    var media = try fixtureMedia(0);
    defer media.deinit();
    var boot: [512]u8 = undefined;
    try testing.expect(media.read(0, 1, &boot));
    const geo = try Geometry.of(&boot, 0, media.blocks(), 512);
    try testing.expectEqual(fixture.heap_offset, geo.heap_first);
    try testing.expectEqual(fixture.fat_offset, geo.fat_first);
    try testing.expectEqual(fixture.fat_length, geo.fat_sectors);
    try testing.expectEqual(fixture.cluster_count, geo.cluster_count);
    try testing.expectEqual(fixture.root_cluster, geo.root_cluster);
    try testing.expectEqual(fixture.serial, geo.serial);
    try testing.expectEqual(fixture.sectors_per_cluster, geo.sectors_per_cluster);
    try testing.expectEqual(@as(u32, 4096), geo.cluster_bytes);
    try testing.expect(checksumHolds(&media, 0, &boot));
}

test "a volume inside a partition is addressed from the partition's start" {
    var media = try fixtureMedia(32768);
    defer media.deinit();
    var boot: [512]u8 = undefined;
    try testing.expect(media.read(32768, 1, &boot));
    const geo = try Geometry.of(&boot, 32768, media.blocks(), 512);
    try testing.expectEqual(@as(u64, 32768 + fixture.heap_offset), geo.clusterBlock(2));
    try testing.expectEqual(@as(u64, 32768 + fixture.fat_offset), geo.entrySpot(0).block);
    try testing.expectEqual(@as(u32, 5 * 4), geo.entrySpot(5).at);
    try testing.expect(checksumHolds(&media, 32768, &boot));
}

test "a boot region whose checksum does not hold is caught" {
    var media = try fixtureMedia(0);
    defer media.deinit();
    var sector: [512]u8 = undefined;
    // A byte of an extended boot sector changed behind the checksum's back.
    try testing.expect(media.read(3, 1, &sector));
    sector[100] ^= 0xFF;
    try media.place(3, &sector);
    try testing.expect(!checksumHolds(&media, 0, &sector));
}

test "the volume flags and the use count are outside the checksum" {
    var media = try fixtureMedia(0);
    defer media.deinit();
    var boot: [512]u8 = undefined;
    try testing.expect(media.read(0, 1, &boot));
    boot[fat.exfat_volume_flags] |= @truncate(fat.exfat_volume_dirty);
    boot[fat.exfat_percent_in_use] = 42;
    try media.place(0, &boot);
    try testing.expect(checksumHolds(&media, 0, &boot));
}

test "a boot sector that does not add up is refused" {
    var media = try fixtureMedia(0);
    defer media.deinit();
    var good: [512]u8 = undefined;
    try testing.expect(media.read(0, 1, &good));

    var boot = good;
    boot[20] = 1; // inside the must-be-zero range
    try testing.expectError(error.MediumFailed, Geometry.of(&boot, 0, media.blocks(), 512));

    boot = good;
    fat.putU32(&boot, fat.exfat_cluster_count, fixture.cluster_count * 16); // past the volume
    try testing.expectError(error.MediumFailed, Geometry.of(&boot, 0, media.blocks(), 512));

    boot = good;
    fat.putU32(&boot, fat.exfat_heap_offset, fixture.fat_offset + 1); // inside the table
    try testing.expectError(error.MediumFailed, Geometry.of(&boot, 0, media.blocks(), 512));

    boot = good;
    fat.putU32(&boot, fat.exfat_root_cluster, 1);
    try testing.expectError(error.MediumFailed, Geometry.of(&boot, 0, media.blocks(), 512));

    boot = good;
    boot[fat.exfat_revision + 1] = 2; // a major revision not known
    try testing.expectError(error.MediumFailed, Geometry.of(&boot, 0, media.blocks(), 512));

    // A medium of 4096-byte blocks under a volume of 512-byte sectors.
    try testing.expectError(error.MediumFailed, Geometry.of(&good, 0, media.blocks(), 4096));
    // A medium too small for the volume.
    try testing.expectError(error.MediumFailed, Geometry.of(&good, 0, 1000, 512));
}

test "the arithmetic holds at the far end of a 64 GB card" {
    // The SK64G's own numbers: heap at 32768, 488016 clusters of 128 KiB.
    var boot: [512]u8 = @splat(0);
    @memcpy(boot[3..11], fat.exfat_name);
    fat.putU64(&boot, fat.exfat_volume_length, 124_964_864);
    fat.putU32(&boot, fat.exfat_fat_offset, 16384);
    fat.putU32(&boot, fat.exfat_fat_length, 16384);
    fat.putU32(&boot, fat.exfat_heap_offset, 32768);
    fat.putU32(&boot, fat.exfat_cluster_count, 488_016);
    fat.putU32(&boot, fat.exfat_root_cluster, 4);
    fat.putU16(&boot, fat.exfat_revision, 0x0100);
    boot[fat.exfat_sector_shift] = 9;
    boot[fat.exfat_cluster_shift] = 8;
    boot[fat.exfat_fat_count] = 1;
    fat.putU16(&boot, fat.signature_at, fat.signature);
    const geo = try Geometry.of(&boot, 32768, 124_997_632, 512);
    const last = fat.exfat_first_cluster + geo.cluster_count - 1;
    try testing.expectEqual(@as(u64, 32768 + 32768 + (@as(u64, 488_015) << 8)), geo.clusterBlock(last));
    try testing.expect(geo.clusterBlock(last) * 512 > 0xFFFF_FFFF);
    try testing.expectEqual(@as(u64, 3), geo.clustersFor(2 * 131072 + 1));
}

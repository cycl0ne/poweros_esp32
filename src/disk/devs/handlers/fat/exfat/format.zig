// SPDX-License-Identifier: MIT
//! A fresh exFAT volume, as ACTION_FORMAT writes one: `plan` works out a
//! volume for a run of sectors, and `write` lays it down - the boot region
//! and its backup with their checksum, the table with its first entries
//! and three chains, the allocation bitmap, the up-case table and a root
//! directory holding the bitmap's entry, the table's and the label.
//!
//! **The cluster size** goes by the volume's size, as a PC's own format
//! picks it: 4 KiB up to 256 MiB, 32 KiB up to 32 GiB, 128 KiB up to
//! 512 GiB and 256 KiB past that.
//!
//! **The boundary.** A card is written in units of its own, megabytes
//! long. The table starts half a `boundary` in and the cluster heap on a
//! whole one, both counted from the area's start, the way a card is sold:
//! no cluster straddles two of the card's units. The table is made as
//! long as the room before the heap, which is more than it needs and what
//! the format allows.
//!
//! **The up-case table** is `upcase.freshTable`: Latin-1's capitals, which
//! is every name this system can give a file.
//!
//! **The order.** The boot regions are cleared first; the backup region is
//! written once everything else is down, and the main boot region last of
//! all. A format cut short leaves no boot sector, never one that names a
//! table not yet there.
//!
//! Generic over the medium, as the file system is.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const _fat = @import("../_fat.zig");
const layout = @import("layout.zig");
const upcase_area = @import("upcase.zig");
const Error = _fat.Error;

/// The smallest volume the format allows: one MiB.
const least_bytes: u64 = 1024 * 1024;
/// The largest cluster the format has.
const max_cluster_bytes: u32 = 32 * 1024 * 1024;
/// Sectors of zeroes a clear writes at a time, at most.
const run_most: u32 = 128;
/// What the boot sector's DriveSelect holds: a fixed disk.
const drive_select: u8 = 0x80;
const drive_select_at: usize = 111;

/// A volume worked out: where it is and how it is laid out.
pub const Plan = struct {
    /// Its first sector, counted from the area's, and how many it has.
    first: u64,
    length: u64,
    sector_bytes: u32,
    sector_shift: u5,
    /// Sectors in a cluster, as a power of two.
    cluster_shift: u5,
    /// The table and the cluster heap, in sectors from the volume's first.
    fat_offset: u32,
    fat_length: u32,
    heap_offset: u32,
    clusters: u32,
    /// The bitmap's clusters, from cluster 2; the up-case table and the
    /// root directory have one each after them.
    bitmap_clusters: u32,

    fn upcaseCluster(made: Plan) u32 {
        return fat.exfat_first_cluster + made.bitmap_clusters;
    }

    fn rootCluster(made: Plan) u32 {
        return made.upcaseCluster() + 1;
    }

    /// The clusters the fresh volume has in use: the bitmap's, the
    /// table's and the root's.
    fn used(made: Plan) u32 {
        return made.bitmap_clusters + 2;
    }

    fn clusterSector(made: Plan, cluster: u32) u64 {
        return made.first + made.heap_offset + (@as(u64, cluster - fat.exfat_first_cluster) << made.cluster_shift);
    }
};

/// The volume for `sectors` sectors of `sector_bytes` from sector `first`
/// of the area, its table half a `boundary` in and its cluster heap on a
/// whole one; null for less than the format's smallest volume, or for one
/// left with no free cluster.
pub fn plan(first: u64, sectors: u64, sector_bytes: u32, boundary: u32) ?Plan {
    return planCluster(first, sectors, sector_bytes, boundary, clusterBytesFor(sectors * sector_bytes, sector_bytes));
}

/// `plan` with clusters of `cluster_bytes`: a power of two from one sector
/// to 32 MiB. Null when the volume cannot have them.
pub fn planCluster(first: u64, sectors: u64, sector_bytes: u32, boundary: u32, cluster_bytes: u32) ?Plan {
    if (sectors * sector_bytes < least_bytes) return null;
    if (cluster_bytes < sector_bytes or cluster_bytes > max_cluster_bytes or cluster_bytes & (cluster_bytes - 1) != 0) return null;
    const sector_shift: u5 = @intCast(std.math.log2_int(u32, sector_bytes));
    const cluster_shift: u5 = @intCast(std.math.log2_int(u32, cluster_bytes / sector_bytes));
    const per_cluster: u64 = @as(u64, 1) << cluster_shift;

    const fat_offset: u64 = @max(2 * fat.exfat_boot_sectors, boundary / 2);
    // The table sized for every cluster the sectors after it could hold.
    const most_clusters = @min((sectors -| fat_offset) >> cluster_shift, layout.max_clusters);
    const fat_needed = ((most_clusters + fat.exfat_first_cluster) * 4 + sector_bytes - 1) / sector_bytes;
    const heap_at = std.mem.alignForward(u64, first + fat_offset + fat_needed, @max(boundary, per_cluster));
    const heap_offset = heap_at - first;
    if (heap_offset >= sectors or heap_offset > std.math.maxInt(u32)) return null;
    const clusters = @min((sectors - heap_offset) >> cluster_shift, layout.max_clusters);

    const bitmap_bytes = (clusters + 7) / 8;
    const bitmap_clusters = (bitmap_bytes + cluster_bytes - 1) / cluster_bytes;
    if (clusters <= bitmap_clusters + 2) return null;
    return .{
        .first = first,
        .length = sectors,
        .sector_bytes = sector_bytes,
        .sector_shift = sector_shift,
        .cluster_shift = cluster_shift,
        .fat_offset = @intCast(fat_offset),
        .fat_length = @intCast(heap_offset - fat_offset),
        .heap_offset = @intCast(heap_offset),
        .clusters = @intCast(clusters),
        .bitmap_clusters = @intCast(bitmap_clusters),
    };
}

/// The cluster a volume of `bytes` gets.
fn clusterBytesFor(bytes: u64, sector_bytes: u32) u32 {
    const mib: u64 = 1024 * 1024;
    const chosen: u32 = if (bytes <= 256 * mib)
        4 * 1024
    else if (bytes <= 32 * 1024 * mib)
        32 * 1024
    else if (bytes <= 512 * 1024 * mib)
        128 * 1024
    else
        256 * 1024;
    return @max(chosen, sector_bytes);
}

/// The volume `made` laid down on the medium, labelled `label` (at most
/// `fat.exfat_label_max` characters of Latin-1; null for none) and
/// numbered `serial`.
pub fn write(media: anytype, made: Plan, label: ?[]const u8, serial: u32) Error!void {
    if (label) |name| if (name.len > fat.exfat_label_max) return error.InvalidName;
    const sector_bytes = made.sector_bytes;
    const run_sectors: u32 = @min(@as(u32, 1) << made.cluster_shift, run_most);
    const run = media.alloc(sector_bytes * run_sectors) orelse return error.NoMemory;
    defer media.free(run);
    @memset(run, 0);
    const sector = media.alloc(sector_bytes) orelse return error.NoMemory;
    defer media.free(sector);

    // Both boot regions cleared, with whatever was there before the table.
    try clear(media, made.first, made.fat_offset, run, run_sectors);

    // The table cleared, then its first entries and the three chains.
    const fat_first = made.first + made.fat_offset;
    try clear(media, fat_first, made.fat_length, run, run_sectors);
    const per_sector = sector_bytes / 4;
    var entry: u32 = 0;
    while (entry <= made.rootCluster()) {
        @memset(sector, 0);
        const sector_first = entry;
        while (entry <= made.rootCluster() and entry - sector_first < per_sector) : (entry += 1) {
            fat.putU32(sector, (entry - sector_first) * 4, tableEntry(made, entry));
        }
        if (!media.write(fat_first + sector_first / per_sector, 1, sector)) return error.MediumFailed;
    }

    // The clusters in use cleared: the bitmap's, the table's, the root's.
    const cluster_sectors = @as(u64, made.used()) << made.cluster_shift;
    try clear(media, made.clusterSector(fat.exfat_first_cluster), cluster_sectors, run, run_sectors);

    // The bitmap: a bit for each cluster in use, from cluster 2.
    const bits_per_sector = sector_bytes * 8;
    var bit: u32 = 0;
    while (bit < made.used()) {
        @memset(sector, 0);
        const sector_first = bit;
        while (bit < made.used() and bit - sector_first < bits_per_sector) : (bit += 1) {
            const at = bit - sector_first;
            sector[at / 8] |= @as(u8, 1) << @intCast(at % 8);
        }
        if (!media.write(made.clusterSector(fat.exfat_first_cluster) + sector_first / bits_per_sector, 1, sector)) return error.MediumFailed;
    }

    // The up-case table.
    @memset(sector, 0);
    const table_len = upcase_area.freshTable(sector);
    const table_sum = fat.exfatTableChecksum(0, sector[0..table_len]);
    if (!media.write(made.clusterSector(made.upcaseCluster()), 1, sector)) return error.MediumFailed;

    // The root: the bitmap's entry, the table's, and the label.
    @memset(sector, 0);
    sector[0] = fat.exfat_type_bitmap;
    fat.putU32(sector, fat.exfat_region_cluster, fat.exfat_first_cluster);
    fat.putU64(sector, fat.exfat_region_length, (@as(u64, made.clusters) + 7) / 8);
    const upcase = sector[fat.entry_bytes..];
    upcase[0] = fat.exfat_type_upcase;
    fat.putU32(upcase, fat.exfat_upcase_checksum, table_sum);
    fat.putU32(upcase, fat.exfat_region_cluster, made.upcaseCluster());
    fat.putU64(upcase, fat.exfat_region_length, table_len);
    if (label) |name| {
        const named = sector[2 * fat.entry_bytes ..];
        named[0] = fat.exfat_type_label;
        named[fat.exfat_label_length] = @intCast(name.len);
        for (name, 0..) |char, at| fat.putU16(named, fat.exfat_label_chars + at * 2, char);
    }
    if (!media.write(made.clusterSector(made.rootCluster()), 1, sector)) return error.MediumFailed;

    // The boot regions: the backup, then the main one, last of all.
    try bootRegion(media, made, serial, made.first + fat.exfat_boot_sectors, sector);
    try bootRegion(media, made, serial, made.first, sector);
}

/// What the table holds for `entry` on the fresh volume: the medium and
/// the end marks in 0 and 1, the bitmap's clusters one after the other,
/// the up-case table's and the root's one each.
fn tableEntry(made: Plan, entry: u32) u32 {
    if (entry == 0) return 0xFFFF_FFF8;
    if (entry == 1) return fat.exfat_eoc;
    if (entry + 1 < made.upcaseCluster()) return entry + 1;
    return fat.exfat_eoc;
}

/// `count` sectors from `first` written with the zeroes in `run`, which
/// holds `run_sectors` of them.
fn clear(media: anytype, first: u64, count: u64, run: []const u8, run_sectors: u32) Error!void {
    var done: u64 = 0;
    while (done < count) {
        const piece: u32 = @intCast(@min(count - done, run_sectors));
        if (!media.write(first + done, piece, run)) return error.MediumFailed;
        done += piece;
    }
}

/// One boot region at `at`: the boot sector, eight extended boot sectors,
/// the parameters sector and one more, both empty, and the checksum over
/// the eleven, which fills the twelfth. `sector` is scratch.
fn bootRegion(media: anytype, made: Plan, serial: u32, at: u64, sector: []u8) Error!void {
    bootSector(sector, made, serial);
    var sum = fat.exfatBootChecksum(0, sector, true);
    if (!media.write(at, 1, sector)) return error.MediumFailed;
    @memset(sector, 0);
    fat.putU32(sector, sector.len - 4, extended_signature);
    for (1..9) |which| {
        sum = fat.exfatBootChecksum(sum, sector, false);
        if (!media.write(at + which, 1, sector)) return error.MediumFailed;
    }
    @memset(sector, 0);
    for (9..11) |_| sum = fat.exfatBootChecksum(sum, sector, false);
    var word: usize = 0;
    while (word < sector.len) : (word += 4) fat.putU32(sector, word, sum);
    if (!media.write(at + fat.exfat_checksum_sector, 1, sector)) return error.MediumFailed;
}

/// The mark at the end of an extended boot sector.
const extended_signature: u32 = 0xAA55_0000;

/// The boot sector of the volume, into `sector`.
fn bootSector(sector: []u8, made: Plan, serial: u32) void {
    @memset(sector, 0);
    // A jump over the parameters, which a reader checks for.
    sector[0] = 0xEB;
    sector[1] = 0x76;
    sector[2] = 0x90;
    @memcpy(sector[3..11], fat.exfat_name);
    fat.putU64(sector, fat.exfat_partition_offset, made.first);
    fat.putU64(sector, fat.exfat_volume_length, made.length);
    fat.putU32(sector, fat.exfat_fat_offset, made.fat_offset);
    fat.putU32(sector, fat.exfat_fat_length, made.fat_length);
    fat.putU32(sector, fat.exfat_heap_offset, made.heap_offset);
    fat.putU32(sector, fat.exfat_cluster_count, made.clusters);
    fat.putU32(sector, fat.exfat_root_cluster, made.rootCluster());
    fat.putU32(sector, fat.exfat_serial, serial);
    fat.putU16(sector, fat.exfat_revision, @as(u16, fat.exfat_major_revision) << 8);
    sector[fat.exfat_sector_shift] = made.sector_shift;
    sector[fat.exfat_cluster_shift] = made.cluster_shift;
    sector[fat.exfat_fat_count] = 1;
    sector[drive_select_at] = drive_select;
    sector[fat.exfat_percent_in_use] = @intCast(@as(u64, made.used()) * 100 / made.clusters);
    fat.putU16(sector, fat.signature_at, fat.signature);
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "a card as it is sold: the table and the heap on its boundaries" {
    // A 64 GB card's partition, from block 32768, on 16 MiB boundaries.
    const card = plan(32768, 124_964_864, 512, 32768).?;
    try testing.expectEqual(@as(u5, 8), card.cluster_shift);
    try testing.expectEqual(@as(u32, 16384), card.fat_offset);
    try testing.expectEqual(@as(u32, 32768), card.heap_offset);
    try testing.expectEqual(@as(u32, 16384), card.fat_length);
    try testing.expect(@as(u64, card.fat_length) * 128 >= @as(u64, card.clusters) + 2);
    try testing.expect(@as(u64, card.heap_offset) + (@as(u64, card.clusters) << 8) <= card.length);
}

test "small volumes: the boot regions before the table, and none below a MiB" {
    const small = plan(0, 4096, 512, 16).?;
    try testing.expectEqual(@as(u32, 24), small.fat_offset);
    try testing.expectEqual(@as(u5, 3), small.cluster_shift);
    try testing.expect(small.heap_offset >= small.fat_offset + small.fat_length);
    try testing.expectEqual(@as(?Plan, null), plan(0, 2047, 512, 16));
}

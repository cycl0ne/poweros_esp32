// SPDX-License-Identifier: MIT
//! A fresh FAT32 volume, as ACTION_FORMAT writes one: `plan` works out a
//! volume for a run of sectors, and `write` lays it down - the reserved
//! sectors with the boot sector, the free-count sector and their backups,
//! both copies of the table with their first entries, and the root
//! directory, empty but for the label.
//!
//! **The cluster size** goes by the volume's size, as a PC's own format
//! picks it: 512 bytes up to 260 MiB, 4 KiB up to 8 GiB, then twice as
//! much for each doubling, up to 32 KiB past 32 GiB. A volume is FAT32
//! only with at least `min_clusters` clusters - fewer, and every reader
//! takes it for an older format - so a cluster is made smaller until there
//! are, and an area too small for that is not given a plan at all.
//!
//! **The boundary.** A card is written in units of its own, megabytes
//! long, and a cluster that straddles two costs two of them each time it
//! is written. The reserved sectors are made as many as put the first
//! cluster on a multiple of `boundary` sectors from the area's start, so
//! no cluster straddles one.
//!
//! **The order.** The reserved sectors are cleared first, which takes the
//! old volume's boot sector with them; the boot sector is the last thing
//! written. A format cut short leaves no boot sector, never one that names
//! tables not yet there.
//!
//! Generic over the medium, as the file system is.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const _fat = @import("../_fat.zig");
const layout = @import("layout.zig");
const Error = _fat.Error;

/// The fewest clusters a FAT32 volume has.
pub const min_clusters: u32 = 65525;
/// The fewest reserved sectors: the boot sector, the free-count sector,
/// their backups at 6 and 7, and room.
const least_reserved: u32 = 32;
/// The largest cluster.
const max_cluster_bytes: u32 = 32 * 1024;
const fsinfo_sector: u32 = 1;
const backup_sector: u32 = 6;
/// What the table's entry 0 holds: the medium byte of a fixed disk.
const media_byte: u8 = 0xF8;
/// The heads and sectors in a track the boot sector names, for a reader
/// that still counts so.
const bpb_heads_value: u16 = 255;
const bpb_track_value: u16 = 63;

/// A volume worked out: where it is and how it is laid out.
pub const Plan = struct {
    /// Its first sector, counted from the area's, and how many it has.
    first: u64,
    total: u32,
    sector_bytes: u32,
    sectors_per_cluster: u32,
    reserved: u32,
    fat_sectors: u32,
    clusters: u32,
};

/// The volume for `sectors` sectors of `sector_bytes` from sector `first`
/// of the area, its first cluster on a multiple of `boundary` sectors from
/// the area's start; null when FAT32 cannot have that many - fewer than
/// `min_clusters` clusters of the smallest size, or more sectors than its
/// count holds.
pub fn plan(first: u64, sectors: u64, sector_bytes: u32, boundary: u32) ?Plan {
    if (sectors > std.math.maxInt(u32) or sectors <= least_reserved) return null;
    var cluster_bytes = clusterBytesFor(sectors * sector_bytes, sector_bytes);
    while (true) : (cluster_bytes /= 2) {
        if (planWith(first, @intCast(sectors), sector_bytes, cluster_bytes / sector_bytes, boundary)) |made| return made;
        if (cluster_bytes == sector_bytes) return null;
    }
}

/// `plan` with clusters of `cluster_bytes`, as a format was asked for: a
/// power of two from one sector to 32 KiB, and at least `min_clusters` of
/// them. Null when the volume cannot have them.
pub fn planCluster(first: u64, sectors: u64, sector_bytes: u32, boundary: u32, cluster_bytes: u32) ?Plan {
    if (sectors > std.math.maxInt(u32) or sectors <= least_reserved) return null;
    if (cluster_bytes < sector_bytes or cluster_bytes > max_cluster_bytes or cluster_bytes & (cluster_bytes - 1) != 0) return null;
    return planWith(first, @intCast(sectors), sector_bytes, cluster_bytes / sector_bytes, boundary);
}

/// The cluster a volume of `bytes` gets.
fn clusterBytesFor(bytes: u64, sector_bytes: u32) u32 {
    const mib: u64 = 1024 * 1024;
    const chosen: u32 = if (bytes <= 260 * mib)
        512
    else if (bytes <= 8 * 1024 * mib)
        4096
    else if (bytes <= 16 * 1024 * mib)
        8192
    else if (bytes <= 32 * 1024 * mib)
        16384
    else
        max_cluster_bytes;
    return @max(chosen, sector_bytes);
}

/// The volume with clusters of `per_cluster` sectors, if it has enough of
/// them. The table is sized for every cluster the sectors could hold
/// before the table takes its own, which is at most a few sectors more
/// than it needs.
fn planWith(first: u64, total: u32, sector_bytes: u32, per_cluster: u32, boundary: u32) ?Plan {
    const per_fat_sector: u64 = sector_bytes / 4;
    const most_clusters: u64 = (total - least_reserved) / per_cluster;
    const fat_sectors: u64 = (most_clusters + fat.first_cluster + per_fat_sector - 1) / per_fat_sector;
    const tables = 2 * fat_sectors;
    // The first cluster on the boundary, counted from the area's start.
    const data_at = std.mem.alignForward(u64, first + least_reserved + tables, boundary);
    const reserved = data_at - first - tables;
    if (reserved > std.math.maxInt(u16)) return null;
    const data_first = reserved + tables;
    if (data_first >= total) return null;
    const clusters = (total - data_first) / per_cluster;
    if (clusters < min_clusters or clusters > layout.max_clusters) return null;
    return .{
        .first = first,
        .total = total,
        .sector_bytes = sector_bytes,
        .sectors_per_cluster = per_cluster,
        .reserved = @intCast(reserved),
        .fat_sectors = @intCast(fat_sectors),
        .clusters = @intCast(clusters),
    };
}

/// The volume `made` laid down on the medium, labelled `label` (eleven
/// characters, as `_fat.shortLabel` makes them; null for none) and
/// numbered `serial`. `stamp` dates the label's entry.
pub fn write(media: anytype, made: Plan, label: ?[fat.bpb_volume_label_bytes]u8, serial: u32, stamp: _fat.Stamp) Error!void {
    const sector_bytes = made.sector_bytes;
    // A run of zeroes to clear with, as many sectors as a cluster, and a
    // sector to build each one that is not zeroes in.
    const run = media.alloc(sector_bytes * made.sectors_per_cluster) orelse return error.NoMemory;
    defer media.free(run);
    @memset(run, 0);
    const sector = media.alloc(sector_bytes) orelse return error.NoMemory;
    defer media.free(sector);
    @memset(sector, 0);

    // The reserved sectors cleared, and with them the old boot sector.
    try clear(media, made.first, made.reserved, run, made.sectors_per_cluster);

    // Both tables cleared, then their first sector: the medium byte, the
    // flags that say the volume is clean, and the root's one cluster.
    const fat_first = made.first + made.reserved;
    try clear(media, fat_first, 2 * made.fat_sectors, run, made.sectors_per_cluster);
    fat.putU32(sector, 0, @as(u32, 0x0FFF_FF00) | media_byte);
    fat.putU32(sector, 4, fat.eoc);
    fat.putU32(sector, 8, fat.eoc);
    for (0..2) |copy| {
        if (!media.write(fat_first + copy * made.fat_sectors, 1, sector)) return error.MediumFailed;
    }

    // The root directory: cluster 2, cleared, and the label in its first
    // entry.
    @memset(sector, 0);
    const root = fat_first + 2 * made.fat_sectors;
    try clear(media, root, made.sectors_per_cluster, run, made.sectors_per_cluster);
    if (label) |name| {
        @memcpy(sector[0..fat.ent_name_bytes], &name);
        sector[fat.ent_attr] = _fat.ATTR_VOLUME_LABEL;
        fat.putU16(sector, fat.ent_write_time, stamp.time);
        fat.putU16(sector, fat.ent_write_date, stamp.date);
        if (!media.write(root, 1, sector)) return error.MediumFailed;
    }

    // The free-count sector and its backup: every cluster but the root's
    // free, and the search to start after it.
    @memset(sector, 0);
    fat.putU32(sector, fat.fsinfo_lead_at, fat.fsinfo_lead);
    fat.putU32(sector, fat.fsinfo_struct_at, fat.fsinfo_struct);
    fat.putU32(sector, fat.fsinfo_free_count_at, made.clusters - 1);
    fat.putU32(sector, fat.fsinfo_next_free_at, fat.first_cluster + 1);
    fat.putU32(sector, fat.fsinfo_trail_at, fat.fsinfo_trail);
    if (!media.write(made.first + backup_sector + fsinfo_sector, 1, sector)) return error.MediumFailed;
    if (!media.write(made.first + fsinfo_sector, 1, sector)) return error.MediumFailed;

    // The boot sector: its backup, then itself, last of all.
    bootSector(sector, made, label, serial);
    if (!media.write(made.first + backup_sector, 1, sector)) return error.MediumFailed;
    if (!media.write(made.first, 1, sector)) return error.MediumFailed;
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

/// The boot sector of the volume, into `sector`.
fn bootSector(sector: []u8, made: Plan, label: ?[fat.bpb_volume_label_bytes]u8, serial: u32) void {
    @memset(sector, 0);
    // A jump over the parameters, which a reader checks for.
    sector[0] = 0xEB;
    sector[1] = 0x58;
    sector[2] = 0x90;
    @memcpy(sector[3..11], "POWEROS ");
    fat.putU16(sector, fat.bpb_bytes_per_sector, @intCast(made.sector_bytes));
    sector[fat.bpb_sectors_per_cluster] = @intCast(made.sectors_per_cluster);
    fat.putU16(sector, fat.bpb_reserved_sectors, @intCast(made.reserved));
    sector[fat.bpb_fat_count] = 2;
    sector[fat.bpb_media] = media_byte;
    fat.putU16(sector, fat.bpb_sectors_per_track, bpb_track_value);
    fat.putU16(sector, fat.bpb_heads, bpb_heads_value);
    fat.putU32(sector, fat.bpb_hidden_sectors, @truncate(made.first));
    fat.putU32(sector, fat.bpb_total_sectors_32, made.total);
    fat.putU32(sector, fat.bpb_sectors_per_fat_32, made.fat_sectors);
    fat.putU32(sector, fat.bpb_root_cluster, fat.first_cluster);
    fat.putU16(sector, fat.bpb_fs_info, fsinfo_sector);
    fat.putU16(sector, fat.bpb_backup_boot, backup_sector);
    sector[bpb_drive_number] = 0x80;
    sector[bpb_boot_signature] = 0x29;
    fat.putU32(sector, fat.bpb_volume_id, serial);
    const name = label orelse "NO NAME    ".*;
    @memcpy(sector[fat.bpb_volume_label..][0..fat.bpb_volume_label_bytes], &name);
    @memcpy(sector[fat.fat32_label_at..][0..8], "FAT32   ");
    fat.putU16(sector, fat.signature_at, fat.signature);
}

/// The drive number and the mark that says the three fields after it
/// (the serial, the label and the type) are there.
const bpb_drive_number: usize = 64;
const bpb_boot_signature: usize = 66;

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "a card's sizes get a PC's cluster sizes, and enough clusters" {
    const sectors_per_gib: u64 = 1024 * 1024 * 1024 / 512;
    // 16 GB, from 8192: 8 KiB clusters, the first cluster on a 4 MiB
    // boundary.
    const card = plan(8192, 30_000_000, 512, 8192).?;
    try testing.expectEqual(@as(u32, 16), card.sectors_per_cluster);
    try testing.expectEqual(@as(u64, 0), (card.first + card.reserved + 2 * card.fat_sectors) % 8192);
    try testing.expect(card.reserved >= 32);
    try testing.expect(@as(u64, card.fat_sectors) * 128 >= @as(u64, card.clusters) + 2);
    // 2 GiB: 4 KiB.
    try testing.expectEqual(@as(u32, 8), plan(0, 2 * sectors_per_gib, 512, 8192).?.sectors_per_cluster);
    // 64 GB: 32 KiB, the largest.
    try testing.expectEqual(@as(u32, 64), plan(32768, 124_000_000, 512, 32768).?.sectors_per_cluster);
}

test "an area too small for FAT32 gets no plan, and one just large enough small clusters" {
    // 16 MiB: not 65525 clusters even of one sector.
    try testing.expectEqual(@as(?Plan, null), plan(0, 32768, 512, 1));
    const small = plan(0, 70_000, 512, 1).?;
    try testing.expectEqual(@as(u32, 1), small.sectors_per_cluster);
    try testing.expect(small.clusters >= min_clusters);
    // More sectors than the count holds.
    try testing.expectEqual(@as(?Plan, null), plan(0, 1 << 33, 512, 8192));
}

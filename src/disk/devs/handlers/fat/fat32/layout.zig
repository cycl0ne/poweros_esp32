// SPDX-License-Identifier: MIT
//! Where things are on a FAT32 volume: its boot sector checked and turned
//! into the numbers every other part of the file system addresses the
//! medium by.
//!
//! **One sector is one block.** A volume's sector size is taken to be the
//! medium's block size, and a volume that says otherwise is refused. A
//! card has 512-byte blocks and every card is formatted with 512-byte
//! sectors, so the one case that is refused is one no card presents, and
//! nothing above this layer has to convert between the two.
//!
//! **Every address this answers is the medium's**, counted from its first
//! block, with the volume's own first block (`first`, where the partition
//! starts) already added in. So a caller never adds it, and never forgets
//! to.
//!
//! The boot sector is checked for what would make the arithmetic after it
//! wrong - a table too short for the clusters it has to describe, a data
//! area that starts past the end, a root directory outside the volume -
//! and not for what is only untidy. A volume a PC reads should be read
//! here too.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const _fat = @import("../_fat.zig");
const Error = _fat.Error;

/// The most clusters a table can describe: past this the values that end
/// a chain and mark a bad cluster would be cluster numbers.
pub const max_clusters: u32 = fat.bad - fat.first_cluster;

pub const Geometry = struct {
    /// The volume's first block on the medium.
    first: u64,
    /// Bytes in a sector, which is a block of the medium.
    sector_bytes: u32,
    sectors_per_cluster: u32,
    cluster_bytes: u32,
    /// Sectors before the first table, the boot sector among them.
    reserved: u32,
    fat_count: u32,
    /// Sectors in one copy of the table.
    fat_sectors: u32,
    /// The one copy of the table in use when the volume says its copies
    /// are not kept alike; null when every copy is written.
    active_fat: ?u32,
    /// The volume's first sector of cluster 2, counted from the volume.
    data_first: u32,
    /// Clusters there are, from cluster 2 up.
    cluster_count: u32,
    root_cluster: u32,
    /// The free-count sector, counted from the volume, if it has one.
    fsinfo: ?u32,
    /// The sectors the volume has.
    total_sectors: u32,
    volume_id: u32,
    /// The label the boot sector carries, spaces and all. The label that
    /// counts is the one in the root directory; this is what is left when
    /// there is none.
    label: [fat.bpb_volume_label_bytes]u8,

    /// The geometry of the volume whose boot sector is `boot`, which lies
    /// at block `first` of a medium of `medium_blocks` blocks of
    /// `block_bytes` bytes.
    pub fn of(boot: []const u8, first: u64, medium_blocks: u64, block_bytes: u32) Error!Geometry {
        if (fat.formatOf(boot) != .fat32) return error.MediumFailed;
        const sector_bytes: u32 = fat.u16At(boot, fat.bpb_bytes_per_sector);
        if (sector_bytes != block_bytes) return error.MediumFailed;
        // A version the format has not had yet may lay things out
        // differently; it is not guessed at.
        if (fat.u16At(boot, fat.bpb_version) != 0) return error.MediumFailed;

        const sectors_per_cluster: u32 = boot[fat.bpb_sectors_per_cluster];
        const reserved: u32 = fat.u16At(boot, fat.bpb_reserved_sectors);
        const fat_count: u32 = boot[fat.bpb_fat_count];
        const fat_sectors = fat.u32At(boot, fat.bpb_sectors_per_fat_32);
        const total_16: u32 = fat.u16At(boot, fat.bpb_total_sectors_16);
        const total_sectors = if (total_16 != 0) total_16 else fat.u32At(boot, fat.bpb_total_sectors_32);

        // The volume has to be on the medium.
        if (first >= medium_blocks or total_sectors > medium_blocks - first) return error.MediumFailed;

        // The tables and the data area, in that order, inside it. Added
        // up in 64 bits: two tables of a 2 TB volume do not fit in 32.
        const data_first: u64 = @as(u64, reserved) + @as(u64, fat_count) * fat_sectors;
        if (data_first >= total_sectors) return error.MediumFailed;
        const cluster_count: u64 = (total_sectors - data_first) / sectors_per_cluster;
        if (cluster_count == 0 or cluster_count > max_clusters) return error.MediumFailed;
        // The table must describe every cluster, entries 0 and 1 too.
        const entries: u64 = @as(u64, fat_sectors) * sector_bytes / 4;
        if (entries < cluster_count + fat.first_cluster) return error.MediumFailed;

        const root_cluster = fat.u32At(boot, fat.bpb_root_cluster);
        if (!fat.usable(root_cluster, @intCast(cluster_count))) return error.MediumFailed;

        // Bit 7 set: only the copy the low four bits name is used.
        const flags = fat.u16At(boot, fat.bpb_ext_flags);
        const active_fat: ?u32 = if (flags & 0x80 != 0) @as(u32, flags & 0x0F) else null;
        if (active_fat) |which| if (which >= fat_count) return error.MediumFailed;

        // 0 and 0xFFFF both mean there is none; one that would land in
        // the boot sector or past the reserved area is none either.
        const fsinfo_at: u32 = fat.u16At(boot, fat.bpb_fs_info);
        const fsinfo: ?u32 = if (fsinfo_at == 0 or fsinfo_at >= reserved) null else fsinfo_at;

        var label: [fat.bpb_volume_label_bytes]u8 = undefined;
        @memcpy(&label, boot[fat.bpb_volume_label..][0..fat.bpb_volume_label_bytes]);

        return .{
            .first = first,
            .sector_bytes = sector_bytes,
            .sectors_per_cluster = sectors_per_cluster,
            .cluster_bytes = sector_bytes * sectors_per_cluster,
            .reserved = reserved,
            .fat_count = fat_count,
            .fat_sectors = fat_sectors,
            .active_fat = active_fat,
            .data_first = @intCast(data_first),
            .cluster_count = @intCast(cluster_count),
            .root_cluster = root_cluster,
            .fsinfo = fsinfo,
            .total_sectors = total_sectors,
            .volume_id = fat.u32At(boot, fat.bpb_volume_id),
            .label = label,
        };
    }

    /// The block a cluster starts at.
    pub fn clusterBlock(geo: *const Geometry, cluster: u32) u64 {
        return geo.first + geo.data_first + @as(u64, cluster - fat.first_cluster) * geo.sectors_per_cluster;
    }

    /// Where a cluster's entry is in copy `copy` of the table: its block,
    /// and the byte in that block.
    pub fn entrySpot(geo: *const Geometry, copy: u32, cluster: u32) struct { block: u64, at: u32 } {
        const byte: u64 = @as(u64, cluster) * 4;
        return .{
            .block = geo.first + geo.reserved + @as(u64, copy) * geo.fat_sectors + byte / geo.sector_bytes,
            .at = @intCast(byte % geo.sector_bytes),
        };
    }

    /// Whether a value is a cluster of this volume.
    pub fn usable(geo: *const Geometry, cluster: u32) bool {
        return fat.usable(cluster, geo.cluster_count);
    }

    /// The copies of the table that are written: every one, or the one
    /// in use. `first` and `end` for a loop over them.
    pub fn copies(geo: *const Geometry) struct { first: u32, end: u32 } {
        if (geo.active_fat) |which| return .{ .first = which, .end = which + 1 };
        return .{ .first = 0, .end = geo.fat_count };
    }

    /// The copy of the table that is read.
    pub fn readCopy(geo: *const Geometry) u32 {
        return geo.active_fat orelse 0;
    }
};

// --- tests ----------------------------------------------------------------

const testing = std.testing;

/// The boot sector of the 4 GB card the device was first tried with, as
/// it was read off the card: 32 KiB clusters, 6290 reserved sectors, two
/// tables of 951 sectors, the data area 4 MiB into the partition.
fn cardBootSector(block: *[512]u8) void {
    @memset(block, 0);
    const head = [_]u8{
        0xEB, 0x00, 0x90, 'S',  'D',  ' ',  ' ',  ' ',  ' ',  ' ',  ' ',  0x00, 0x02, 0x40, 0x92, 0x18,
        0x02, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x00, 0x00, 0x3F, 0x00, 0x80, 0x00, 0x00, 0x20, 0x00, 0x00,
        0x00, 0xE0, 0x76, 0x00, 0xB7, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x80, 0x01, 0x29, 0x01, 0x02, 0x03, 0x04, ' ',  ' ',  ' ',  ' ',  ' ',  ' ',  ' ',  ' ',  ' ',
        ' ',  ' ',  'F',  'A',  'T',  '3',  '2',  ' ',  ' ',  ' ',
    };
    @memcpy(block[0..head.len], &head);
    fat.putU16(block, fat.signature_at, fat.signature);
}

/// That card's partition: its first block and the card's size.
const card_first: u64 = 8192;
const card_blocks: u64 = 7_798_784;

test "the card's own boot sector" {
    var boot: [512]u8 = undefined;
    cardBootSector(&boot);
    const geo = try Geometry.of(&boot, card_first, card_blocks, 512);

    try testing.expectEqual(@as(u32, 32 * 1024), geo.cluster_bytes);
    try testing.expectEqual(@as(u32, 6290), geo.reserved);
    try testing.expectEqual(@as(u32, 951), geo.fat_sectors);
    // 6290 + 2 * 951: the data area is 4 MiB into the partition.
    try testing.expectEqual(@as(u32, 8192), geo.data_first);
    // (7 790 592 - 8192) / 64.
    try testing.expectEqual(@as(u32, 121_600), geo.cluster_count);
    try testing.expectEqual(@as(u32, 2), geo.root_cluster);
    try testing.expectEqual(@as(?u32, 1), geo.fsinfo);
    try testing.expectEqual(@as(?u32, null), geo.active_fat);
    try testing.expectEqual(@as(u32, 0x0403_0201), geo.volume_id);

    // Cluster 2 is the first block of the data area, on the card.
    try testing.expectEqual(@as(u64, 16384), geo.clusterBlock(2));
    try testing.expectEqual(@as(u64, 16384 + 64), geo.clusterBlock(3));
    // Cluster 2's entry is the third word of the first table sector, and
    // the second copy is a table's length further on.
    const entry = geo.entrySpot(0, 2);
    try testing.expectEqual(@as(u64, 8192 + 6290), entry.block);
    try testing.expectEqual(@as(u32, 8), entry.at);
    try testing.expectEqual(@as(u64, 8192 + 6290 + 951), geo.entrySpot(1, 2).block);
    // The last cluster's entry is in the table's last sector.
    const last = geo.entrySpot(0, geo.cluster_count + 1);
    try testing.expectEqual(@as(u64, 8192 + 6290 + 950), last.block);
}

test "a volume that does not fit, or whose table is short, is refused" {
    var boot: [512]u8 = undefined;
    cardBootSector(&boot);

    // Past the end of the medium.
    try testing.expectError(error.MediumFailed, Geometry.of(&boot, card_first, card_blocks - 1, 512));
    // A sector size that is not the medium's block size.
    try testing.expectError(error.MediumFailed, Geometry.of(&boot, card_first, card_blocks, 4096));

    // A table one sector too short for the clusters it has to describe.
    var short = boot;
    fat.putU32(&short, fat.bpb_sectors_per_fat_32, 950);
    // With the table shorter the data area starts earlier and there are
    // more clusters, not fewer; either way the table cannot hold them.
    try testing.expectError(error.MediumFailed, Geometry.of(&short, card_first, card_blocks, 512));

    // A root directory past the last cluster.
    var rootless = boot;
    fat.putU32(&rootless, fat.bpb_root_cluster, 121_602);
    try testing.expectError(error.MediumFailed, Geometry.of(&rootless, card_first, card_blocks, 512));

    // A version of the format this does not know.
    var newer = boot;
    fat.putU16(&newer, fat.bpb_version, 1);
    try testing.expectError(error.MediumFailed, Geometry.of(&newer, card_first, card_blocks, 512));
}

test "a volume that keeps one copy of its table writes only that one" {
    var boot: [512]u8 = undefined;
    cardBootSector(&boot);
    fat.putU16(&boot, fat.bpb_ext_flags, 0x80 | 1);
    const geo = try Geometry.of(&boot, card_first, card_blocks, 512);
    try testing.expectEqual(@as(?u32, 1), geo.active_fat);
    try testing.expectEqual(@as(u32, 1), geo.readCopy());
    const copies = geo.copies();
    try testing.expectEqual(@as(u32, 1), copies.first);
    try testing.expectEqual(@as(u32, 2), copies.end);

    // Naming a copy that is not there is refused.
    fat.putU16(&boot, fat.bpb_ext_flags, 0x80 | 2);
    try testing.expectError(error.MediumFailed, Geometry.of(&boot, card_first, card_blocks, 512));
}

test "the arithmetic holds on a 64 GB card" {
    // A 64 GB card as mkfs.vfat lays it out: 32 KiB clusters, a table of
    // 15 232 sectors.
    var boot: [512]u8 = undefined;
    cardBootSector(&boot);
    fat.putU16(&boot, fat.bpb_reserved_sectors, 32);
    fat.putU32(&boot, fat.bpb_total_sectors_32, 124_739_584);
    fat.putU32(&boot, fat.bpb_sectors_per_fat_32, 15_232);
    const geo = try Geometry.of(&boot, 8192, 124_747_776, 512);

    // Past 16 bits of clusters, and the last one's first byte past 32
    // bits of bytes: the two places a narrow type gives way.
    try testing.expect(geo.cluster_count > 0xFFFF);
    const last = geo.cluster_count + 1;
    try testing.expect(geo.clusterBlock(last) * 512 > 0xFFFF_FFFF);
    try testing.expect(geo.clusterBlock(last) + geo.sectors_per_cluster <= 8192 + 124_739_584);
}

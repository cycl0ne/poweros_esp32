// SPDX-License-Identifier: MIT
//! A FAT32 volume laid down on the sparse test medium, for the host
//! tests: a partition table, the boot sector and its backup, the
//! free-count sector, the first entries of both tables and an empty root
//! directory - and nothing else, because everything else of a fresh
//! volume is zeroes, which the sparse medium answers without holding.
//!
//! By default it is a 64 GB card as mkfs.vfat lays it out, so the tests
//! run at the geometry where the arithmetic breaks; `clusters` makes a
//! small one, for a test that has to fill it up.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const TestMedia = @import("../testmedia.zig").TestMedia;
const cache_area = @import("../cache.zig");
const layout = @import("layout.zig");

pub const Cache = cache_area.BlockCache(TestMedia);

pub const Options = struct {
    /// How many clusters; null is a 64 GB card's.
    clusters: ?u32 = null,
    sectors_per_cluster: u8 = 64,
    /// Where the partition starts.
    first: u32 = 8192,
    /// What the free-count sector says; null is the truth.
    fsinfo_count: ?u32 = null,
    /// A label in the root directory, if any.
    label: ?[]const u8 = null,
    cache_blocks: u32 = 16,
};

/// The numbers of a 64 GB card.
const card_clusters: u32 = 1_948_579;
const card_fat_sectors: u32 = 15_232;
const card_total: u32 = 124_739_584;

const reserved: u32 = 32;

pub const Volume = struct {
    media: TestMedia,
    cache: Cache,
    geo: layout.Geometry,

    /// A fresh volume on a fresh medium, with a cache over it. On the
    /// heap, so the cache's pointer to the medium stays good.
    pub fn init(options: Options) !*Volume {
        const volume = try std.testing.allocator.create(Volume);
        errdefer std.testing.allocator.destroy(volume);

        const spc: u32 = options.sectors_per_cluster;
        const clusters = options.clusters orelse card_clusters;
        const fat_sectors = if (options.clusters == null)
            card_fat_sectors
        else
            ((clusters + fat.first_cluster) * 4 + 511) / 512;
        const total = if (options.clusters == null) card_total else reserved + 2 * fat_sectors + clusters * spc;

        volume.media = TestMedia.init(512, @as(u64, options.first) + total);
        errdefer volume.media.deinit();
        try lay(&volume.media, options, clusters, fat_sectors, total);

        var boot: [512]u8 = undefined;
        if (!volume.media.read(options.first, 1, &boot)) return error.Unexpected;
        volume.geo = try layout.Geometry.of(&boot, options.first, volume.media.blocks(), 512);
        volume.cache = try Cache.init(&volume.media, options.cache_blocks);
        return volume;
    }

    pub fn deinit(volume: *Volume) void {
        volume.cache.deinit();
        std.testing.expectEqual(@as(usize, 0), volume.media.live) catch {};
        volume.media.deinit();
        std.testing.allocator.destroy(volume);
    }
};

fn lay(media: *TestMedia, options: Options, clusters: u32, fat_sectors: u32, total: u32) !void {
    const first = options.first;
    var block: [512]u8 = @splat(0);

    // The card's first block: one partition, the rest empty.
    if (first != 0) {
        const at = fat.partition_table_at;
        block[at + 4] = fat.TYPE_FAT32_LBA;
        fat.putU32(&block, at + 8, first);
        fat.putU32(&block, at + 12, total);
        fat.putU16(&block, fat.signature_at, fat.signature);
        try media.place(0, &block);
    }

    // The boot sector, and its backup six sectors on.
    @memset(&block, 0);
    block[0] = 0xEB;
    block[1] = 0x58;
    block[2] = 0x90;
    @memcpy(block[3..11], "mkfs.fat");
    fat.putU16(&block, fat.bpb_bytes_per_sector, 512);
    block[fat.bpb_sectors_per_cluster] = options.sectors_per_cluster;
    fat.putU16(&block, fat.bpb_reserved_sectors, reserved);
    block[fat.bpb_fat_count] = 2;
    block[fat.bpb_media] = 0xF8;
    fat.putU32(&block, fat.bpb_hidden_sectors, first);
    fat.putU32(&block, fat.bpb_total_sectors_32, total);
    fat.putU32(&block, fat.bpb_sectors_per_fat_32, fat_sectors);
    fat.putU32(&block, fat.bpb_root_cluster, fat.first_cluster);
    fat.putU16(&block, fat.bpb_fs_info, 1);
    fat.putU16(&block, fat.bpb_backup_boot, 6);
    block[64] = 0x80;
    block[66] = 0x29;
    fat.putU32(&block, fat.bpb_volume_id, 0x1234_ABCD);
    @memcpy(block[fat.bpb_volume_label..][0..11], "NO NAME    ");
    @memcpy(block[fat.fat32_label_at..][0..8], "FAT32   ");
    fat.putU16(&block, fat.signature_at, fat.signature);
    try media.place(first, &block);
    try media.place(first + 6, &block);

    // The free-count sector: every cluster but the root's is free, and
    // the search starts after it.
    @memset(&block, 0);
    fat.putU32(&block, fat.fsinfo_lead_at, fat.fsinfo_lead);
    fat.putU32(&block, fat.fsinfo_struct_at, fat.fsinfo_struct);
    fat.putU32(&block, fat.fsinfo_free_count_at, options.fsinfo_count orelse clusters - 1);
    fat.putU32(&block, fat.fsinfo_next_free_at, fat.first_cluster + 1);
    fat.putU32(&block, fat.fsinfo_trail_at, fat.fsinfo_trail);
    try media.place(first + 1, &block);
    try media.place(first + 7, &block);

    // Both tables: the medium byte, the volume's flags, and the root
    // directory's one cluster.
    @memset(&block, 0);
    fat.putU32(&block, 0, 0x0FFF_FFF8);
    fat.putU32(&block, 4, 0x0FFF_FFFF);
    fat.putU32(&block, 8, fat.eoc);
    try media.place(first + reserved, &block);
    try media.place(first + reserved + fat_sectors, &block);

    // A label, if asked for, as the first entry of the root directory.
    if (options.label) |label| {
        @memset(&block, 0);
        @memset(block[0..11], ' ');
        @memcpy(block[0..label.len], label);
        block[fat.ent_attr] = 0x08;
        try media.place(first + reserved + 2 * fat_sectors, &block);
    }
}

// SPDX-License-Identifier: MIT
//! A fresh exFAT volume laid down on the sparse test medium, for the host
//! tests: a partition table, the boot region and its backup with their
//! checksums, the table's first entries and the three chains a volume
//! starts with, the allocation bitmap, an up-case table and a root
//! directory holding the bitmap's and the table's entries - and nothing
//! else, because everything else of a fresh volume is zeroes, which the
//! sparse medium answers without holding.
//!
//! By default it is the 64 GB card the 7B was tested with (an SK64G as it
//! is sold): the partition at block 32768, the table at 16384 and the
//! cluster heap at 32768 inside it, 488016 clusters of 128 KiB, the root
//! in cluster 4. `clusters` and `cluster_shift` make a small one, for a
//! test that has to fill it up.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const TestMedia = @import("../testmedia.zig").TestMedia;
const upcase_area = @import("upcase.zig");

pub const Options = struct {
    /// How many clusters; null is the 64 GB card's.
    clusters: ?u32 = null,
    /// Sectors in a cluster, as a power of two: 8 is 128 KiB.
    cluster_shift: u5 = 8,
    /// Where the partition starts.
    first: u32 = 32768,
    /// A label, if any (ASCII).
    label: ?[]const u8 = null,
};

/// The 64 GB card's numbers.
const card_clusters: u32 = 488_016;
const card_fat_offset: u32 = 16384;
const card_fat_length: u32 = 16384;
const card_heap_offset: u32 = 32768;
const card_medium: u64 = 124_997_632;

pub const Volume = struct {
    media: TestMedia,
    /// Where the volume starts on the medium, and its clusters.
    first: u32,
    clusters: u32,

    /// A fresh volume on a fresh medium. On the heap, so a file system
    /// can hold a pointer to its medium.
    pub fn init(options: Options) !*Volume {
        const volume = try std.testing.allocator.create(Volume);
        errdefer std.testing.allocator.destroy(volume);

        const clusters = options.clusters orelse card_clusters;
        const spc: u32 = @as(u32, 1) << options.cluster_shift;
        const fat_offset: u32 = if (options.clusters == null) card_fat_offset else 128;
        const fat_length: u32 = if (options.clusters == null) card_fat_length else ((clusters + 2) * 4 + 511) / 512;
        const heap_offset: u32 = if (options.clusters == null) card_heap_offset else std.mem.alignForward(u32, fat_offset + fat_length, spc);
        const volume_length: u64 = @as(u64, heap_offset) + @as(u64, clusters) * spc;
        const medium: u64 = if (options.clusters == null) card_medium else options.first + volume_length + 64;

        volume.* = .{ .media = TestMedia.init(512, medium), .first = options.first, .clusters = clusters };
        errdefer volume.media.deinit();
        const m = &volume.media;
        const first: u64 = options.first;

        // The card's first block: one partition, exFAT's type.
        var block: [512]u8 = @splat(0);
        const at = fat.partition_table_at;
        block[at + 4] = fat.TYPE_NTFS_OR_EXFAT;
        fat.putU32(&block, at + 8, options.first);
        fat.putU32(&block, at + 12, @intCast(volume_length));
        fat.putU16(&block, fat.signature_at, fat.signature);
        try m.place(0, &block);

        // The bitmap in cluster 2 on, the up-case table after it, the root
        // after that - each one run.
        const bitmap_bytes: u64 = (@as(u64, clusters) + 7) / 8;
        const cluster_bytes: u64 = @as(u64, spc) * 512;
        const bitmap_clusters: u32 = @intCast((bitmap_bytes + cluster_bytes - 1) / cluster_bytes);
        const upcase_cluster: u32 = 2 + bitmap_clusters;
        const root_cluster: u32 = upcase_cluster + 1;

        // The boot region, then its backup, with the checksum over each.
        var boot: [512]u8 = @splat(0);
        boot[0] = 0xEB;
        boot[1] = 0x76;
        boot[2] = 0x90;
        @memcpy(boot[3..11], fat.exfat_name);
        fat.putU64(&boot, fat.exfat_partition_offset, first);
        fat.putU64(&boot, fat.exfat_volume_length, volume_length);
        fat.putU32(&boot, fat.exfat_fat_offset, fat_offset);
        fat.putU32(&boot, fat.exfat_fat_length, fat_length);
        fat.putU32(&boot, fat.exfat_heap_offset, heap_offset);
        fat.putU32(&boot, fat.exfat_cluster_count, clusters);
        fat.putU32(&boot, fat.exfat_root_cluster, root_cluster);
        fat.putU32(&boot, fat.exfat_serial, 0x1234_ABCD);
        fat.putU16(&boot, fat.exfat_revision, 0x0100);
        boot[fat.exfat_sector_shift] = 9;
        boot[fat.exfat_cluster_shift] = options.cluster_shift;
        boot[fat.exfat_fat_count] = 1;
        boot[111] = 0x80; // DriveSelect
        boot[fat.exfat_percent_in_use] = 0;
        fat.putU16(&boot, fat.signature_at, fat.signature);
        var extended: [512]u8 = @splat(0);
        fat.putU32(&extended, 508, 0xAA55_0000);
        const empty: [512]u8 = @splat(0);
        var sum: u32 = 0;
        sum = fat.exfatBootChecksum(sum, &boot, true);
        for (1..9) |_| sum = fat.exfatBootChecksum(sum, &extended, false);
        sum = fat.exfatBootChecksum(sum, &empty, false); // OEM parameters
        sum = fat.exfatBootChecksum(sum, &empty, false); // reserved
        var checksum: [512]u8 = undefined;
        var word: usize = 0;
        while (word < 512) : (word += 4) fat.putU32(&checksum, word, sum);
        for ([_]u64{ first, first + fat.exfat_boot_sectors }) |region| {
            try m.place(region, &boot);
            for (1..9) |sector| try m.place(region + sector, &extended);
            try m.place(region + fat.exfat_checksum_sector, &checksum);
        }

        // The table: its two first entries, and the three chains ended.
        var table: [512]u8 = @splat(0);
        fat.putU32(&table, 0, 0xFFFF_FFF8);
        fat.putU32(&table, 4, 0xFFFF_FFFF);
        var cluster: u32 = 2;
        while (cluster < 2 + bitmap_clusters) : (cluster += 1) {
            fat.putU32(&table, cluster * 4, if (cluster + 1 < 2 + bitmap_clusters) cluster + 1 else fat.exfat_eoc);
        }
        fat.putU32(&table, upcase_cluster * 4, fat.exfat_eoc);
        fat.putU32(&table, root_cluster * 4, fat.exfat_eoc);
        try m.place(first + fat_offset, &table);

        // The bitmap: the clusters the volume starts with, in use.
        var bits: [512]u8 = @splat(0);
        const used = root_cluster - 1; // clusters 2 .. root
        for (0..used) |bit| bits[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
        const heap = first + heap_offset;
        try m.place(heap, &bits);

        // The up-case table.
        var table_bytes: [512]u8 = @splat(0);
        const table_len = upcase_area.freshTable(&table_bytes);
        try m.place(heap + (@as(u64, upcase_cluster - 2) << options.cluster_shift), &table_bytes);

        // The root: the bitmap's entry, the table's, and a label.
        var root: [512]u8 = @splat(0);
        root[0] = fat.exfat_type_bitmap;
        fat.putU32(&root, fat.exfat_region_cluster, 2);
        fat.putU64(&root, fat.exfat_region_length, bitmap_bytes);
        root[32] = fat.exfat_type_upcase;
        fat.putU32(root[32..], fat.exfat_upcase_checksum, fat.exfatTableChecksum(0, table_bytes[0..table_len]));
        fat.putU32(root[32..], fat.exfat_region_cluster, upcase_cluster);
        fat.putU64(root[32..], fat.exfat_region_length, table_len);
        if (options.label) |label| {
            root[64] = fat.exfat_type_label;
            root[64 + fat.exfat_label_length] = @intCast(label.len);
            for (label, 0..) |char, index| fat.putU16(root[64..], fat.exfat_label_chars + index * 2, char);
        }
        try m.place(heap + (@as(u64, root_cluster - 2) << options.cluster_shift), &root);
        return volume;
    }

    pub fn deinit(volume: *Volume) void {
        volume.media.deinit();
        std.testing.allocator.destroy(volume);
    }
};

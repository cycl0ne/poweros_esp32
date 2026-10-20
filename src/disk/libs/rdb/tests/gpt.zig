// SPDX-License-Identifier: MIT
//! Host tests of `sdk.dos.gpt` on its own: GUIDs and their text, a fresh
//! table made and read back from both copies, and the tables a reader
//! refuses. rdb.library's GPT calls are tested in rdb.zig beside this.

const std = @import("std");
const sdk = @import("sdk");
const gpt = sdk.dos.gpt;
const fat = sdk.dos.fat;

const testing = std.testing;

test "a GUID's text: the first three fields least significant byte first, the rest as written" {
    try testing.expectEqualSlices(u8, &.{ 0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B }, &gpt.TYPE_EFI_SYSTEM);
    var text: [gpt.guid_text_len:0]u8 = undefined;
    gpt.formatGuid(&gpt.TYPE_CONTAINER, &text);
    try testing.expectEqualStrings("4CA96E42-B070-42FB-A098-B3C5B1F92837", &text);
    try testing.expectEqual(gpt.TYPE_LINUX, gpt.parseGuid("0fc63daf-8483-4772-8e79-3d69d8477de4").?);
    try testing.expect(gpt.parseGuid("0FC63DAF-8483-4772-8E79-3D69D8477DE") == null);
    try testing.expect(gpt.parseGuid("0FC63DAF+8483-4772-8E79-3D69D8477DE4") == null);
    try testing.expect(gpt.parseGuid("0FC63DAF-8483-4772-8E79-3D69D8477DEX") == null);
    try testing.expectEqualStrings("EFI System", std.mem.span(gpt.typeName(&gpt.TYPE_EFI_SYSTEM).?));
    try testing.expect(gpt.typeName(&gpt.parseGuid("00000000-0000-0000-0000-000000000001").?) == null);

    var random: gpt.Guid = @splat(0xFF);
    gpt.markRandom(&random);
    gpt.formatGuid(&random, &text);
    try testing.expectEqual(@as(u8, '4'), text[14]);
    try testing.expectEqual(@as(u8, 'B'), text[19]);
}

test "crc32 is the one zip and PNG use" {
    try testing.expectEqual(@as(u32, 0xCBF4_3926), sdk.dos.flashfs.crc32("123456789"));
}

/// A medium in memory: its blocks, a table made on it as a writer makes it.
const Disk = struct {
    block_bytes: u32,
    bytes: []u8,

    fn make(block_count: u64, block_bytes: u32) !Disk {
        const bytes = try testing.allocator.alloc(u8, @intCast(block_count * block_bytes));
        @memset(bytes, 0);
        return .{ .block_bytes = block_bytes, .bytes = bytes };
    }

    fn free(disk: *Disk) void {
        testing.allocator.free(disk.bytes);
    }

    fn blocks(disk: *const Disk) u64 {
        return disk.bytes.len / disk.block_bytes;
    }

    fn block(disk: *Disk, number: u64) []u8 {
        return disk.bytes[@intCast(number * disk.block_bytes)..][0..disk.block_bytes];
    }

    fn at(disk: *Disk, number: u64, length: u64) []u8 {
        return disk.bytes[@intCast(number * disk.block_bytes)..][0..@intCast(length)];
    }

    /// A fresh table with `entries` in it, both copies and the protective
    /// MBR, as rdb.library's WriteGPT lays them down.
    fn write(disk: *Disk, entries: []const gpt.Entry) !gpt.Header {
        const guid = gpt.parseGuid("01234567-89AB-4DEF-8123-456789ABCDEF").?;
        var primary = gpt.freshHeader(disk.blocks(), disk.block_bytes, &guid) orelse return error.TooSmall;
        const length = gpt.entriesLength(&primary);
        const array = disk.at(primary.partition_entry_lba, length);
        @memset(array, 0);
        for (entries, 0..) |*entry, index| gpt.putEntry(&primary, array, @intCast(index), entry);
        var backup = gpt.backupOf(&primary);
        @memcpy(disk.at(backup.partition_entry_lba, length), array);
        gpt.putHeader(&primary, gpt.entriesCrc(&primary, array), disk.block(primary.my_lba));
        gpt.putHeader(&backup, gpt.entriesCrc(&backup, array), disk.block(backup.my_lba));
        gpt.makeProtective(disk.block(0), disk.blocks());
        return primary;
    }

    /// The header in `number` and its entries, as a reader takes them, or
    /// null.
    fn read(disk: *Disk, number: u64) ?gpt.Header {
        const header = gpt.readHeader(disk.block(number), number, disk.blocks()) orelse return null;
        const entries = disk.at(header.partition_entry_lba, gpt.entriesBlocks(&header, disk.block_bytes) * disk.block_bytes);
        if (!gpt.entriesSound(&header, entries)) return null;
        return header;
    }
};

fn makeEntry(type_guid: gpt.Guid, first: u64, last: u64, name: []const u8) gpt.Entry {
    var made: gpt.Entry = .{ .partition_type_guid = type_guid, .starting_lba = first, .ending_lba = last };
    made.unique_partition_guid[0] = @truncate(first);
    gpt.setName(&made, name);
    return made;
}

test "a fresh table on 512-byte blocks: 32 blocks of entries each side, read back from both copies" {
    var disk = try Disk.make(8192, 512);
    defer disk.free();
    const written = try disk.write(&.{
        makeEntry(gpt.TYPE_EFI_SYSTEM, 2048, 4095, "EFI"),
        makeEntry(gpt.TYPE_CONTAINER, 4096, 8158, "PowerOS"),
    });
    try testing.expectEqual(@as(u64, 34), written.first_usable_lba);
    try testing.expectEqual(@as(u64, 8192 - 34), written.last_usable_lba);
    try testing.expectEqual(@as(u64, 8191), written.alternate_lba);
    try testing.expect(gpt.protective(disk.block(0)));

    const primary = disk.read(1) orelse return error.NoPrimary;
    const backup = disk.read(8191) orelse return error.NoBackup;
    try testing.expectEqual(@as(u64, 8192 - 33), backup.partition_entry_lba);
    try testing.expectEqual(primary.partition_entry_array_crc32, backup.partition_entry_array_crc32);
    try testing.expectEqual(gpt.parseGuid("01234567-89AB-4DEF-8123-456789ABCDEF").?, backup.disk_guid);

    const entries = disk.at(primary.partition_entry_lba, gpt.entriesLength(&primary));
    const found = gpt.containerIn(&primary, entries) orelse return error.NoContainer;
    try testing.expectEqual(@as(u32, 1), found.index);
    try testing.expectEqual(@as(u64, 4096), found.entry.starting_lba);
    var name: [gpt.name_units:0]u8 = undefined;
    try testing.expectEqualStrings("PowerOS", gpt.nameText(&found.entry, &name));
    const efi = gpt.entryAt(&primary, entries, 0);
    try testing.expectEqualStrings("EFI", gpt.nameText(&efi, &name));
    try testing.expect(!gpt.used(&gpt.entryAt(&primary, entries, 2)));

    // A header read from a block it does not name, or with a byte changed.
    try testing.expect(gpt.readHeader(disk.block(1), 2, disk.blocks()) == null);
    disk.block(1)[60] ^= 1;
    try testing.expect(disk.read(1) == null);
    try testing.expect(disk.read(8191) != null);
}

test "4096-byte blocks: four blocks of entries, partitions on 256-block steps" {
    var disk = try Disk.make(1024, 4096);
    defer disk.free();
    const written = try disk.write(&.{makeEntry(gpt.TYPE_CONTAINER, 256, 1017, "PowerOS")});
    try testing.expectEqual(@as(u64, 6), written.first_usable_lba);
    try testing.expectEqual(@as(u64, 1024 - 6), written.last_usable_lba);
    try testing.expect(disk.read(1) != null);
    try testing.expect(disk.read(1023) != null);
    try testing.expectEqual(@as(u64, 256), gpt.alignUp(6, 4096));
    try testing.expectEqual(@as(u64, 2048), gpt.alignUp(34, 512));
    try testing.expectEqual(@as(u64, 2048), gpt.alignUp(2048, 512));
}

test "entries a reader refuses: overlapping, outside the usable blocks, the wrong way round, or a crc that does not agree" {
    var disk = try Disk.make(8192, 512);
    defer disk.free();
    _ = try disk.write(&.{ makeEntry(gpt.TYPE_LINUX, 2048, 4095, ""), makeEntry(gpt.TYPE_LINUX, 4095, 6000, "") });
    try testing.expect(disk.read(1) == null);
    _ = try disk.write(&.{makeEntry(gpt.TYPE_LINUX, 2048, 8192 - 33, "")});
    try testing.expect(disk.read(1) == null);
    _ = try disk.write(&.{makeEntry(gpt.TYPE_LINUX, 4095, 2048, "")});
    try testing.expect(disk.read(1) == null);
    _ = try disk.write(&.{makeEntry(gpt.TYPE_LINUX, 2048, 8192 - 34, "")});
    try testing.expect(disk.read(1) != null);
    disk.block(2)[40] ^= 1;
    try testing.expect(disk.read(1) == null);
}

test "a medium too small for both copies gets no table" {
    const guid: gpt.Guid = @splat(1);
    try testing.expect(gpt.freshHeader(64, 512, &guid) == null);
    try testing.expect(gpt.freshHeader(2048 + 34, 512, &guid) != null);
}

test "a protective MBR, a hybrid one, and a PC's table that is neither" {
    var block: [512]u8 = undefined;
    gpt.makeProtective(&block, 1 << 40);
    try testing.expect(gpt.protective(&block));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), fat.partitionOf(&block, 0).blocks);
    try testing.expectEqual(@as(u32, 1), fat.partitionOf(&block, 0).first);

    @memset(&block, 0);
    block[fat.partition_table_at + 4] = fat.TYPE_FAT32_LBA;
    fat.putU16(&block, fat.signature_at, fat.signature);
    try testing.expect(!gpt.protective(&block));
    block[fat.partition_table_at + fat.partition_entry_bytes + 4] = gpt.PROTECTIVE_TYPE;
    try testing.expect(gpt.protective(&block));
    fat.putU16(&block, fat.signature_at, 0);
    try testing.expect(!gpt.protective(&block));
}

test "a name: ASCII kept, anything else a question mark, as much as fits" {
    var made: gpt.Entry = .{};
    gpt.setName(&made, "Work");
    var name: [gpt.name_units:0]u8 = undefined;
    try testing.expectEqualStrings("Work", gpt.nameText(&made, &name));
    made.partition_name[1] = 0x00E9;
    try testing.expectEqualStrings("W?rk", gpt.nameText(&made, &name));
    gpt.setName(&made, "a name of more than thirty-six characters, cut");
    try testing.expectEqual(@as(usize, gpt.name_units), gpt.nameText(&made, &name).len);
}

/// A disk as `sdk.expansion.bootdisk` reads it.
const BootDisk = struct {
    disk: *Disk,

    pub fn readBlock(boot: BootDisk, number: u32, into: []u8) bool {
        if (number >= boot.disk.blocks()) return false;
        @memcpy(into, boot.disk.block(number)[0..into.len]);
        return true;
    }
};

/// A RigidDiskBlock in block `at` of the disk, its one partition `DH0` on
/// cylinders 16 to 100 of the table in the block after it.
fn putTable(disk: *Disk, at: u64) void {
    const hardblocks = sdk.dos.hardblocks;
    var table: hardblocks.RigidDiskBlock = .{ .block_bytes = 512, .cyl_blocks = 1, .partition_list = 1, .rdb_blocks_hi = 15, .lo_cylinder = 16, .hi_cylinder = 1000 };
    table.checksum = hardblocks.checksumOf(&table);
    var part: hardblocks.PartitionBlock = .{ .environment = .{ .low_cyl = 16, .high_cyl = 100, .dos_type = sdk.dos.posfs.ID_POSFS_DISK } };
    @memcpy(part.drive_name[0..3], "DH0");
    part.checksum = hardblocks.checksumOf(&part);
    @memcpy(disk.block(at)[0..256], std.mem.asBytes(&table));
    @memcpy(disk.block(at + 1)[0..256], std.mem.asBytes(&part));
}

test "a boot disk's partitions: the table in a GPT's container, counted from the container's first block" {
    var disk = try Disk.make(8192, 512);
    defer disk.free();
    _ = try disk.write(&.{
        makeEntry(gpt.TYPE_EFI_SYSTEM, 2048, 4095, "EFI"),
        makeEntry(gpt.TYPE_CONTAINER, 4096, 8158, "PowerOS"),
    });
    putTable(&disk, 4096);
    var scratch: [512]u8 = undefined;
    const Partitions = sdk.expansion.bootdisk.Partitions(BootDisk);
    var partitions = Partitions.of(.{ .disk = &disk }, 512, &scratch) orelse return error.NoTable;
    try testing.expectEqual(@as(u32, 4096), partitions.offset);
    var pb: sdk.dos.hardblocks.PartitionBlock = undefined;
    try testing.expect(partitions.nextPartition(&pb));
    try testing.expectEqualStrings("DH0", pb.name());
    try testing.expect(!partitions.nextPartition(&pb));

    // A container that shares blocks with another partition is none.
    _ = try disk.write(&.{
        makeEntry(gpt.TYPE_EFI_SYSTEM, 2048, 4096, "EFI"),
        makeEntry(gpt.TYPE_CONTAINER, 4096, 8158, "PowerOS"),
    });
    try testing.expect(Partitions.of(.{ .disk = &disk }, 512, &scratch) == null);
    // A table of the disk's own is read first.
    putTable(&disk, 0);
    const own = Partitions.of(.{ .disk = &disk }, 512, &scratch) orelse return error.NoTable;
    try testing.expectEqual(@as(u32, 0), own.offset);
}

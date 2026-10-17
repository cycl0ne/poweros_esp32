// SPDX-License-Identifier: MPL-2.0
//! The flash disk's partitions, handed to expansion.library when the
//! device starts.
//!
//! The disk says what is on it: its first blocks hold a RigidDiskBlock
//! (sdk/libs/dos/hardblocks.zig), and its chain of PartitionBlocks names
//! each partition, its cylinders and its file system. flash.device reads
//! them once, at cold start - before dos.library is up - and hands each to
//! expansion.library as a boot node (sdk/libs/expansion/bootdisk.zig,
//! which sdcard.device's card shares).
//!
//! Nothing about the disk is written down in the kernel: a second
//! partition, or another file system on the same chip, is a matter of
//! writing blocks. A blank chip, or one with no sound RigidDiskBlock, has
//! no partitions, and the system starts without a disk; `s3> rdb init`
//! writes a first table.
//!
//! The blocks are read out of the unit's mapping, so this needs no request
//! and no task: flash.device's init calls it once the mapping is up.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const hardblocks = dos.hardblocks;
const td = sdk.devices.trackdisk;
const ExecBase = sdk.interface.exec.ExecBase;
const bootdisk = sdk.expansion.bootdisk;

/// The unit the disk is, for the handlers' OpenDevice.
const disk_unit = 0;

pub const handlerFor = bootdisk.handlerFor;

/// The disk as the mapping shows it.
const Mapped = struct {
    bytes: []const u8,
    block_bytes: u32,

    /// The start of a block, out of the mapping. False past the disk's
    /// end.
    pub fn readBlock(disk: Mapped, block: u32, into: []u8) bool {
        const offset = @as(u64, block) * disk.block_bytes;
        if (into.len > disk.block_bytes or offset + into.len > disk.bytes.len) return false;
        const start: usize = @intCast(offset);
        @memcpy(into, disk.bytes[start..][0..into.len]);
        return true;
    }
};

const Partitions = bootdisk.Partitions(Mapped);

/// Every partition the disk names, as a device node handed to
/// expansion.library for dos.
///
/// INPUTS:
/// - `sys` - exec.
/// - `disk` - the unit's bytes, as the mapping shows them.
/// - `block_bytes` - the disk's block size.
///
/// CONTEXT:
/// - Waits: in OpenLibrary, MakeDosNode and AddBootNode. - Interrupts: no.
/// - Locks: none held. - Process: a Task will do: it runs in the device's
///   init.
pub fn mountPartitions(sys: *ExecBase, disk: []const u8, block_bytes: u32) void {
    bootdisk.mountPartitions(sys, td.FLASHNAME, disk_unit, Mapped{ .bytes = disk, .block_bytes = block_bytes }, block_bytes);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const flashfs = dos.flashfs;

const test_block = 4096;

/// A disk of four blocks: the RigidDiskBlock in block 0, then a partition
/// chain of DH0 (bootable, the flash file system) and DH1 (not mounted).
fn testDisk(disk: *[4 * test_block]u8) void {
    @memset(disk, 0xFF);
    var rdb: hardblocks.RigidDiskBlock = .{
        .block_bytes = test_block,
        .partition_list = 1,
        .cylinders = 4,
        .sectors = 1,
        .heads = 1,
        .rdb_blocks_hi = hardblocks.RDB_LOCATION_LIMIT - 1,
        .lo_cylinder = hardblocks.RDB_LOCATION_LIMIT,
        .hi_cylinder = 3,
        .cyl_blocks = 1,
    };
    rdb.checksum = hardblocks.checksumOf(&rdb);
    @memcpy(disk[0..@sizeOf(hardblocks.RigidDiskBlock)], std.mem.asBytes(&rdb));
    for ([_][]const u8{ "DH0", "DH1" }, 1..) |drive, block| {
        var part: hardblocks.PartitionBlock = .{
            .next = if (block == 1) 2 else hardblocks.end_of_list,
            .flags = if (block == 1) hardblocks.PBFF_BOOTABLE else hardblocks.PBFF_NOMOUNT,
            .environment = .{ .size_block = test_block, .low_cyl = 3, .high_cyl = 3, .dos_type = flashfs.ID_FLASHFS_DISK },
        };
        @memcpy(part.drive_name[0..drive.len], drive);
        part.checksum = hardblocks.checksumOf(&part);
        @memcpy(disk[block * test_block ..][0..@sizeOf(hardblocks.PartitionBlock)], std.mem.asBytes(&part));
    }
}

test "the partitions to mount: the chain's sound blocks, PBFF_NOMOUNT passed over" {
    var disk: [4 * test_block]u8 = undefined;
    testDisk(&disk);
    var partitions = Partitions.of(.{ .bytes = &disk, .block_bytes = test_block }, test_block).?;
    var pb: hardblocks.PartitionBlock = undefined;
    try testing.expect(partitions.nextPartition(&pb));
    try testing.expectEqualStrings("DH0", pb.name());
    try testing.expect(pb.flags & hardblocks.PBFF_BOOTABLE != 0);
    try testing.expect(!partitions.nextPartition(&pb));
    // A table written for another block size is not this disk's.
    try testing.expectEqual(@as(?Partitions, null), Partitions.of(.{ .bytes = &disk, .block_bytes = 512 }, 512));
}

test "a blank disk has no partitions" {
    var disk: [4 * test_block]u8 = undefined;
    @memset(&disk, 0xFF);
    try testing.expectEqual(@as(?Partitions, null), Partitions.of(.{ .bytes = &disk, .block_bytes = test_block }, test_block));
    @memset(&disk, 0);
    try testing.expectEqual(@as(?Partitions, null), Partitions.of(.{ .bytes = &disk, .block_bytes = test_block }, test_block));
}

test "a RigidDiskBlock and a PartitionBlock are sound once they carry their checksum" {
    var rdb: hardblocks.RigidDiskBlock = .{
        .block_bytes = 4096,
        .partition_list = 1,
        .cylinders = 3840,
        .sectors = 1,
        .heads = 1,
        .rdb_blocks_hi = hardblocks.RDB_LOCATION_LIMIT - 1,
        .lo_cylinder = hardblocks.RDB_LOCATION_LIMIT,
        .hi_cylinder = 3839,
        .cyl_blocks = 1,
    };
    try testing.expect(!hardblocks.sound(&rdb, hardblocks.IDNAME_RIGIDDISK));
    rdb.checksum = hardblocks.checksumOf(&rdb);
    try testing.expect(hardblocks.sound(&rdb, hardblocks.IDNAME_RIGIDDISK));
    // Computing it again over a sound block gives the same answer.
    try testing.expectEqual(rdb.checksum, hardblocks.checksumOf(&rdb));
    // The identifier is checked too, and any change breaks the sum.
    try testing.expect(!hardblocks.sound(&rdb, hardblocks.IDNAME_PARTITION));
    rdb.cylinders += 1;
    try testing.expect(!hardblocks.sound(&rdb, hardblocks.IDNAME_RIGIDDISK));

    var part: hardblocks.PartitionBlock = .{
        .flags = hardblocks.PBFF_BOOTABLE,
        .environment = .{
            .size_block = 4096,
            .low_cyl = 16,
            .high_cyl = 3839,
            .dos_type = flashfs.ID_FLASHFS_DISK,
        },
    };
    @memcpy(part.drive_name[0..3], "DH0");
    part.checksum = hardblocks.checksumOf(&part);
    try testing.expect(hardblocks.sound(&part, hardblocks.IDNAME_PARTITION));
    try testing.expectEqualStrings("DH0", part.name());
    try testing.expectEqual(@as(u64, 3824), part.environment.blocks());
    try testing.expectEqual(@as(u64, 16 * 4096), part.environment.byteOf(0));
}

test "a partition's handler is the one its DosType asks for" {
    try testing.expectEqualStrings("flashfs-handler", std.mem.span(handlerFor(flashfs.ID_FLASHFS_DISK).?));
    try testing.expectEqualStrings("fat-handler", std.mem.span(handlerFor(dos.ID_MSDOS_DISK).?));
    try testing.expectEqualStrings("fat-handler", std.mem.span(handlerFor(dos.fat.typeWithFormat(dos.ID_MSDOS_DISK_HD, dos.fat.FORMAT_EXFAT)).?));
    try testing.expectEqual(@as(?[*:0]const u8, null), handlerFor(0x444F5300)); // "DOS\0"
}

// SPDX-License-Identifier: MPL-2.0
//! The flash disk's partitions, handed to expansion.library when the
//! device starts.
//!
//! The disk says what is on it: its first blocks hold a RigidDiskBlock
//! (sdk/libs/dos/hardblocks.zig), and its chain of PartitionBlocks names
//! each partition, its cylinders and its file system. flash.device reads
//! them once, at cold start - before dos.library is up - and makes a device
//! node for each partition not marked PBFF_NOMOUNT with expansion.library's
//! MakeDosNode: named as the partition says (pb_DriveName), with the
//! handler its de_DosType asks for (sdk/libs/dos/filesystems.zig), and the
//! partition's DosEnvec as the environment its handler is started with.
//! AddBootNode keeps the nodes until dos takes them in. A bootable
//! partition stands at its de_BootPri, the others at -128, which is never
//! booted from.
//!
//! A partition whose file system cannot serve a part of the flash is not
//! mounted: FAT, which erases nothing, a DosType whose area begins with a
//! partition table of its own (`MSH`, `POS\1`), and one there is no
//! handler for.
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
const ExpansionBase = sdk.interface.expansion.ExpansionBase;

/// The unit the disk is, for the handlers' OpenDevice.
const disk_unit = 0;

/// A runaway partition chain stops here.
const max_partitions = 16;

/// The handler for a partition of the flash, or null for one whose file
/// system cannot serve it.
///
/// INPUTS:
/// - `dos_type` - the partition's de_DosType.
/// - `erase_size` - the flash's erase unit.
pub fn handlerFor(dos_type: u32, erase_size: u32) ?[*:0]const u8 {
    if (!dos.filesystems.suits(dos_type, erase_size, false)) return null;
    return dos.filesystems.handlerFor(dos_type);
}

/// The partitions a disk names, one after the other: every sound
/// PartitionBlock on the RigidDiskBlock's chain that is not marked
/// PBFF_NOMOUNT.
pub const Partitions = struct {
    disk: []const u8,
    block_bytes: u32,
    /// The next PartitionBlock's number, or end_of_list.
    next: u32,
    seen: u32 = 0,

    /// The disk's chain, or null when the disk has no sound
    /// RigidDiskBlock, or one written for another block size: the block
    /// numbers in it count the disk's blocks.
    ///
    /// INPUTS:
    /// - `disk` - the disk's bytes.
    /// - `block_bytes` - its block size, the erase unit.
    pub fn of(disk: []const u8, block_bytes: u32) ?Partitions {
        var rdb: hardblocks.RigidDiskBlock = undefined;
        var block: u32 = 0;
        while (block < hardblocks.RDB_LOCATION_LIMIT) : (block += 1) {
            if (!readBlock(disk, block, block_bytes, &rdb)) return null;
            if (hardblocks.sound(&rdb, hardblocks.IDNAME_RIGIDDISK)) break;
        } else return null;
        if (rdb.block_bytes != block_bytes) return null;
        return .{ .disk = disk, .block_bytes = block_bytes, .next = rdb.partition_list };
    }

    /// The next partition to mount into `into`; false at the chain's end,
    /// at a block that is not a sound PartitionBlock, or after
    /// max_partitions.
    pub fn nextPartition(partitions: *Partitions, into: *hardblocks.PartitionBlock) bool {
        while (partitions.next != hardblocks.end_of_list and partitions.seen < max_partitions) {
            partitions.seen += 1;
            if (!readBlock(partitions.disk, partitions.next, partitions.block_bytes, into)) return false;
            if (!hardblocks.sound(into, hardblocks.IDNAME_PARTITION)) return false;
            partitions.next = into.next;
            if (into.flags & hardblocks.PBFF_NOMOUNT == 0) return true;
        }
        return false;
    }
};

/// One of the disk's blocks into `into`, as far as the structure goes:
/// they all live at the start of a block. False past the disk's end.
fn readBlock(disk: []const u8, block: u32, block_bytes: u32, into: anytype) bool {
    const size = @sizeOf(@TypeOf(into.*));
    const offset = @as(u64, block) * block_bytes;
    if (offset + size > disk.len) return false;
    const start: usize = @intCast(offset);
    const bytes: [*]u8 = @ptrCast(into);
    @memcpy(bytes[0..size], disk[start..][0..size]);
    return true;
}

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
    var partitions = Partitions.of(disk, block_bytes) orelse return;
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    var pb: hardblocks.PartitionBlock = undefined;
    while (partitions.nextPartition(&pb)) {
        const handler = handlerFor(pb.environment.dos_type, block_bytes) orelse continue;
        const drive = pb.name();
        if (drive.len == 0) continue;
        // The partition block holds the name as a C string of at most 31
        // characters, which may fill its 32 bytes.
        var name: [pb.drive_name.len + 1:0]u8 = @splat(0);
        @memcpy(name[0..drive.len], drive);
        const node = eb.MakeDosNode(&name, td.FLASHNAME, disk_unit, pb.dev_flags, &pb.environment) orelse continue;
        node.misc.handler.handler = handler;
        const boot_pri: i32 = if (pb.flags & hardblocks.PBFF_BOOTABLE != 0) pb.environment.boot_pri else -128;
        if (!eb.AddBootNode(boot_pri, node)) sys.FreeVec(node);
    }
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
    var partitions = Partitions.of(&disk, test_block).?;
    var pb: hardblocks.PartitionBlock = undefined;
    try testing.expect(partitions.nextPartition(&pb));
    try testing.expectEqualStrings("DH0", pb.name());
    try testing.expect(pb.flags & hardblocks.PBFF_BOOTABLE != 0);
    try testing.expect(!partitions.nextPartition(&pb));
    // A table written for another block size is not this disk's.
    try testing.expectEqual(@as(?Partitions, null), Partitions.of(&disk, 512));
}

test "a blank disk has no partitions" {
    var disk: [4 * test_block]u8 = undefined;
    @memset(&disk, 0xFF);
    try testing.expectEqual(@as(?Partitions, null), Partitions.of(&disk, test_block));
    @memset(&disk, 0);
    try testing.expectEqual(@as(?Partitions, null), Partitions.of(&disk, test_block));
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

test "a partition's handler is the one its DosType asks for, where it can serve the flash" {
    try testing.expectEqualStrings("flashfs-handler", std.mem.span(handlerFor(flashfs.ID_FLASHFS_DISK, test_block).?));
    try testing.expectEqualStrings("posfs-handler", std.mem.span(handlerFor(dos.posfs.ID_POSFS_DISK, test_block).?));
    // FAT erases nothing; `POS\1` and `MSH` begin with a table of their own.
    try testing.expectEqual(@as(?[*:0]const u8, null), handlerFor(dos.ID_MSDOS_DISK, test_block));
    try testing.expectEqual(@as(?[*:0]const u8, null), handlerFor(dos.posfs.ID_POSFS_MBR, test_block));
    try testing.expectEqual(@as(?[*:0]const u8, null), handlerFor(0x444F5300, test_block)); // "DOS\0"
}

test "the file systems: each DosType's handler, where it may go, and what a whole medium gets" {
    const filesystems = dos.filesystems;
    try testing.expectEqualStrings("fat-handler", std.mem.span(filesystems.handlerFor(dos.ID_MSDOS_DISK).?));
    try testing.expectEqualStrings("fat-handler", std.mem.span(filesystems.handlerFor(dos.fat.typeWithFormat(dos.ID_MSDOS_DISK_HD, dos.fat.FORMAT_EXFAT)).?));
    try testing.expectEqualStrings("posfs-handler", std.mem.span(filesystems.handlerFor(dos.posfs.ID_POSFS_MBR).?));
    try testing.expectEqual(@as(?[*:0]const u8, null), filesystems.handlerFor(0x444F5300));

    // A card erases for itself: FAT and posfs, in a partition or whole;
    // the flash file system never.
    try testing.expect(filesystems.suits(dos.ID_MSDOS_DISK, 0, false));
    try testing.expect(filesystems.suits(dos.ID_MSDOS_DISK_HD, 0, true));
    try testing.expect(!filesystems.suits(dos.ID_MSDOS_DISK_HD, 0, false));
    try testing.expect(filesystems.suits(dos.posfs.ID_POSFS_DISK, 0, false));
    try testing.expect(!filesystems.suits(dos.posfs.ID_POSFS_MBR, 0, false));
    try testing.expect(!filesystems.suits(flashfs.ID_FLASHFS_DISK, 0, false));
    try testing.expect(filesystems.suits(flashfs.ID_FLASHFS_DISK, test_block, false));

    // A whole medium: a posfs label, a table with a posfs partition, and
    // anything else FAT behind a table.
    var block: [512]u8 = @splat(0);
    try testing.expectEqual(dos.ID_MSDOS_DISK_HD, filesystems.wholeMediumChoice(&block).dos_type);
    try testing.expectEqual(dos.ID_MSDOS_DISK_HD, filesystems.wholeMediumChoice(&.{}).dos_type);
    dos.posfs.table.writeTable(&block, 2048, 100_000, 0x1234_5678);
    try testing.expectEqual(dos.posfs.ID_POSFS_MBR, filesystems.wholeMediumChoice(&block).dos_type);
    @memset(&block, 0);
    std.mem.writeInt(u32, block[0..4], dos.posfs.layout.label_magic, .little);
    const label = filesystems.wholeMediumChoice(&block);
    try testing.expectEqual(dos.posfs.ID_POSFS_DISK, label.dos_type);
    try testing.expectEqualStrings("posfs-handler", std.mem.span(label.handler));
}

test "a device node's startup: a FileSysStartupMsg, or a plain number" {
    const startupOf = dos.filehandler.startupOf;
    try testing.expect(startupOf(0) == null);
    try testing.expect(startupOf(1) == null);
    try testing.expect(startupOf(0xFFF) == null);
    const msg: dos.FileSysStartupMsg = .{ .unit = 3 };
    try testing.expectEqual(@as(u32, 3), startupOf(@intFromPtr(&msg)).?.unit);
    try testing.expect(startupOf(@intFromPtr(&msg) + 1) == null);
}

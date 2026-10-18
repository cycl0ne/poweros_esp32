// SPDX-License-Identifier: MIT
//! A disk's partitions handed to expansion.library when its device starts,
//! as boot nodes: what a block device in the ROM does at cold start, so
//! that dos.library finds the disks it may start from - sdcard.device in
//! the ROM of a machine that starts from its card. (flash.device has a
//! walk of its own over its mapping, src/rom/devs/flash/mount.zig, which
//! also runs the file systems its table keeps.)
//!
//! The disk says what is on it: its first blocks hold a RigidDiskBlock
//! (`dos.hardblocks`), and its chain of PartitionBlocks names each
//! partition, its cylinders and its file system. The device reads them
//! once - before dos.library is up - and makes a device node for each
//! partition not marked PBFF_NOMOUNT with MakeDosNode: named as the
//! partition says (pb_DriveName), with the handler its de_DosType asks
//! for (`dos.filesystems`), and the partition's DosEnvec as the
//! environment its handler is started with. A partition whose file system
//! cannot go on the medium - the flash file system on a card, FAT on
//! flash, a DosType whose area begins with a partition table of its own -
//! or that there is no handler for is passed over. AddBootNode keeps the
//! nodes until dos takes them in. A bootable partition stands at its
//! de_BootPri, the others at -128, which is never booted from; dos starts
//! from the highest.
//!
//! How a block is read is the device's: sdcard.device asks the card.
//! `Disk` is anything with
//!
//!     readBlock(block: u32, into: []u8) bool   the first into.len bytes
//!                                              of a block; false past
//!                                              the end or on an error

const dos = @import("../dos/dos.zig");
const hardblocks = dos.hardblocks;
const filesystems = dos.filesystems;
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const ExpansionBase = @import("../../interface/expansion.zig").ExpansionBase;
const EXPANSIONNAME = @import("expansion.zig").EXPANSIONNAME;

/// A runaway partition chain stops here.
const max_partitions = 16;

/// The handler for a partition, or null for one whose file system cannot
/// go on the medium or that there is none for.
///
/// INPUTS:
/// - `dos_type` - the partition's de_DosType.
/// - `erase_size` - the medium's erase unit, 0 for one that erases for
///   itself.
pub fn handlerFor(dos_type: u32, erase_size: u32) ?[*:0]const u8 {
    if (!filesystems.suits(dos_type, erase_size, false)) return null;
    return filesystems.handlerFor(dos_type);
}

/// The partitions a disk names, one after the other: every sound
/// PartitionBlock on the RigidDiskBlock's chain that is not marked
/// PBFF_NOMOUNT.
pub fn Partitions(comptime Disk: type) type {
    return struct {
        const Self = @This();

        disk: Disk,
        /// The next PartitionBlock's number, or end_of_list.
        next: u32,
        seen: u32 = 0,

        /// The disk's chain, or null when the disk has no sound
        /// RigidDiskBlock in its first RDB_LOCATION_LIMIT blocks, or one
        /// written for another block size: the block numbers in it count
        /// the disk's blocks.
        ///
        /// INPUTS:
        /// - `disk` - how its blocks are read.
        /// - `block_bytes` - its block size.
        pub fn of(disk: Disk, block_bytes: u32) ?Self {
            var rdb: hardblocks.RigidDiskBlock = undefined;
            var block: u32 = 0;
            while (block < hardblocks.RDB_LOCATION_LIMIT) : (block += 1) {
                if (!readInto(disk, block, &rdb)) return null;
                if (hardblocks.sound(&rdb, hardblocks.IDNAME_RIGIDDISK)) break;
            } else return null;
            if (rdb.block_bytes != block_bytes) return null;
            return .{ .disk = disk, .next = rdb.partition_list };
        }

        /// The next partition to mount into `into`; false at the chain's
        /// end, at a block that is not a sound PartitionBlock, or after
        /// max_partitions.
        pub fn nextPartition(partitions: *Self, into: *hardblocks.PartitionBlock) bool {
            while (partitions.next != hardblocks.end_of_list and partitions.seen < max_partitions) {
                partitions.seen += 1;
                if (!readInto(partitions.disk, partitions.next, into)) return false;
                if (!hardblocks.sound(into, hardblocks.IDNAME_PARTITION)) return false;
                partitions.next = into.next;
                if (into.flags & hardblocks.PBFF_NOMOUNT == 0) return true;
            }
            return false;
        }

        /// One of the disk's blocks into `into`, as far as the structure
        /// goes: they all live at the start of a block.
        fn readInto(disk: Disk, block: u32, into: anytype) bool {
            const bytes: [*]u8 = @ptrCast(into);
            return disk.readBlock(block, bytes[0..@sizeOf(@TypeOf(into.*))]);
        }
    };
}

/// Every partition the disk names, as a device node handed to
/// expansion.library for dos.
///
/// INPUTS:
/// - `sys` - exec.
/// - `device` - the device the handlers open, and `unit` its unit.
/// - `disk` - how its blocks are read (see the top of the file).
/// - `block_bytes` - the disk's block size.
/// - `erase_size` - its erase unit, 0 for a medium that erases for itself.
///
/// CONTEXT:
/// - Waits: in OpenLibrary, MakeDosNode and AddBootNode, and in reading.
/// - Interrupts: no.
/// - Locks: none held.
/// - Process: a Task will do: it runs in the device's init, or on its
///   task before the init lets go.
pub fn mountPartitions(sys: *ExecBase, device: [*:0]const u8, unit: u32, disk: anytype, block_bytes: u32, erase_size: u32) void {
    var partitions = Partitions(@TypeOf(disk)).of(disk, block_bytes) orelse return;
    const expansion_lib = sys.OpenLibrary(EXPANSIONNAME, 1) orelse return;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    var pb: hardblocks.PartitionBlock = undefined;
    while (partitions.nextPartition(&pb)) {
        const handler = handlerFor(pb.environment.dos_type, erase_size) orelse continue;
        const drive = pb.name();
        if (drive.len == 0) continue;
        // The partition block holds the name as a C string of at most 31
        // characters, which may fill its 32 bytes.
        var name: [pb.drive_name.len + 1:0]u8 = @splat(0);
        @memcpy(name[0..drive.len], drive);
        const node = eb.MakeDosNode(&name, device, unit, pb.dev_flags, &pb.environment) orelse continue;
        node.misc.handler.handler = handler;
        const boot_pri: i32 = if (pb.flags & hardblocks.PBFF_BOOTABLE != 0) pb.environment.boot_pri else -128;
        if (!eb.AddBootNode(boot_pri, node)) sys.FreeVec(node);
    }
}

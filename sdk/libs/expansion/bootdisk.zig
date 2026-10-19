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
//! **A disk with a GPT** and no RigidDiskBlock of its own has its
//! partitions in the GPT's PowerOS container (`dos.gpt`): the
//! RigidDiskBlock is looked for in the container's first blocks, its
//! block numbers count from the container's first block, and each
//! partition's cylinders are moved by the container's before its node is
//! made. Only the GPT's copy in block 1 is read here - the disk's size,
//! which says where the other is, is not known yet - with the crc32 of its
//! entries, and the container is taken when it lies inside the usable
//! blocks and shares none with another partition. The GPT's other
//! partitions get no boot node.
//!
//! How a block is read is the device's: sdcard.device asks the card.
//! `Disk` is anything with
//!
//!     readBlock(block: u32, into: []u8) bool   the first into.len bytes
//!                                              of a block; false past
//!                                              the end or on an error

const dos = @import("../dos/dos.zig");
const exec = @import("../exec/exec.zig");
const hardblocks = dos.hardblocks;
const gpt = dos.gpt;
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
        /// The block the table's block numbers count from: a GPT
        /// container's first, or 0.
        offset: u32 = 0,

        /// The disk's chain, or null when the disk has no sound
        /// RigidDiskBlock in its first RDB_LOCATION_LIMIT blocks or in
        /// those of its GPT's container, or one written for another block
        /// size: the block numbers in it count the disk's blocks.
        ///
        /// INPUTS:
        /// - `disk` - how its blocks are read.
        /// - `block_bytes` - its block size.
        /// - `scratch` - a block's room, for reading the GPT.
        pub fn of(disk: Disk, block_bytes: u32, scratch: []u8) ?Self {
            if (tableAt(disk, 0, block_bytes)) |rdb| return .{ .disk = disk, .next = rdb.partition_list };
            const container = containerOf(disk, block_bytes, scratch) orelse return null;
            const rdb = tableAt(disk, container, block_bytes) orelse return null;
            return .{ .disk = disk, .next = rdb.partition_list, .offset = container };
        }

        /// The lowest sound RigidDiskBlock of the first blocks from
        /// `first` on, when it is for this block size.
        fn tableAt(disk: Disk, first: u32, block_bytes: u32) ?hardblocks.RigidDiskBlock {
            var rdb: hardblocks.RigidDiskBlock = undefined;
            var block: u32 = 0;
            while (block < hardblocks.RDB_LOCATION_LIMIT) : (block += 1) {
                if (!readInto(disk, first + block, &rdb)) return null;
                if (hardblocks.sound(&rdb, hardblocks.IDNAME_RIGIDDISK)) break;
            } else return null;
            if (rdb.block_bytes != block_bytes) return null;
            return rdb;
        }

        /// The first block of the GPT's first container, or null for a
        /// disk with no sound GPT in block 1, none, or one whose
        /// container lies outside the usable blocks, shares some with
        /// another partition or starts past what 32 bits count.
        fn containerOf(disk: Disk, block_bytes: u32, scratch: []u8) ?u32 {
            const block = scratch[0..block_bytes];
            if (!disk.readBlock(0, block)) return null;
            const protective = gpt.protective(block);
            if (!disk.readBlock(@intCast(gpt.header_block), block)) return null;
            if (!protective and !gpt.signed(block)) return null;
            const header = gpt.readHeader(block, gpt.header_block, 0xFFFF_FFFF_FFFF_FFFF) orelse return null;
            const count = gpt.entriesBlocks(&header, block_bytes);
            if (header.partition_entry_lba + count > 0xFFFF_FFFF) return null;
            const first: u32 = @intCast(header.partition_entry_lba);
            var crc = gpt.EntriesCrc.of(&header);
            var index: u32 = 0;
            while (index < count) : (index += 1) {
                if (!disk.readBlock(first + index, block)) return null;
                crc.add(block);
            }
            if (crc.end() != header.partition_entry_array_crc32) return null;
            const found = findEntry(disk, &header, first, count, block, null) orelse return null;
            const container = &found.entry;
            if (container.starting_lba > container.ending_lba or container.starting_lba < header.first_usable_lba or
                container.ending_lba > header.last_usable_lba or container.starting_lba > 0xFFFF_FFFF) return null;
            if (findEntry(disk, &header, first, count, block, &found) != null) return null;
            return @intCast(container.starting_lba);
        }

        /// An entry and its place among the entries.
        const Found = struct { entry: gpt.Entry, number: u32 };

        /// With `beside` null, the first container among the entries;
        /// otherwise the first other used entry that shares a block with
        /// `beside`. Null for none, or a block that cannot be read.
        fn findEntry(disk: Disk, header: *const gpt.Header, first: u32, count: u64, block: []u8, beside: ?*const Found) ?Found {
            const per = gpt.entriesPerBlock(header, @intCast(block.len));
            var number: u32 = 0;
            var index: u32 = 0;
            while (index < count) : (index += 1) {
                if (!disk.readBlock(first + index, block)) return null;
                var slot: u32 = 0;
                while (slot < per and number < header.number_of_partition_entries) : ({
                    slot += 1;
                    number += 1;
                }) {
                    const entry = gpt.entryAt(header, block, slot);
                    if (!gpt.used(&entry)) continue;
                    const other = beside orelse {
                        if (gpt.isContainer(&entry)) return .{ .entry = entry, .number = number };
                        continue;
                    };
                    if (number == other.number) continue;
                    const theirs = &other.entry;
                    if (entry.starting_lba <= theirs.ending_lba and theirs.starting_lba <= entry.ending_lba) return .{ .entry = entry, .number = number };
                }
            }
            return null;
        }

        /// The next partition to mount into `into`; false at the chain's
        /// end, at a block that is not a sound PartitionBlock, or after
        /// max_partitions.
        pub fn nextPartition(partitions: *Self, into: *hardblocks.PartitionBlock) bool {
            while (partitions.next != hardblocks.end_of_list and partitions.seen < max_partitions) {
                partitions.seen += 1;
                if (!readInto(partitions.disk, partitions.offset + partitions.next, into)) return false;
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

/// A partition's environment moved by the cylinders of the container its
/// table is in; false when the container does not start on a multiple of
/// its cylinder, or the sum does not fit.
fn onDisk(env: *dos.DosEnvec, offset: u32) bool {
    if (offset == 0) return true;
    const cylinder = @as(u64, env.surfaces) * env.blocks_per_track;
    if (cylinder == 0 or offset % cylinder != 0) return false;
    const shift = offset / cylinder;
    if (shift + env.high_cyl > 0xFFFF_FFFF) return false;
    env.low_cyl += @intCast(shift);
    env.high_cyl += @intCast(shift);
    return true;
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
    const scratch = sys.AllocVec(block_bytes, exec.MEMF_ANY) orelse return;
    defer sys.FreeVec(scratch);
    var partitions = Partitions(@TypeOf(disk)).of(disk, block_bytes, @as([*]u8, @ptrCast(scratch))[0..block_bytes]) orelse return;
    const expansion_lib = sys.OpenLibrary(EXPANSIONNAME, 1) orelse return;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    var pb: hardblocks.PartitionBlock = undefined;
    while (partitions.nextPartition(&pb)) {
        const handler = handlerFor(pb.environment.dos_type, erase_size) orelse continue;
        if (!onDisk(&pb.environment, partitions.offset)) continue;
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

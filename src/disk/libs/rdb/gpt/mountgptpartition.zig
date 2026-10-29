// SPDX-License-Identifier: MIT
//! MountGPTPartition: a partition of a disk's GPT put on dos's list, as
//! the device node the handler of the file system on it is started from.
//!
//! What the partition holds is read from its first block: a GPT entry's
//! type says what a partition is for, not which file system is on it (a
//! "basic data" partition may be FAT, exFAT or NTFS), so the block decides.
//! The node is made as MountPartition makes one, by the same `add`, with
//! an environment that names the partition's blocks: cylinders of one
//! block, or on a disk of 2^32 blocks or more of the fewest - 2, 4, 8 and
//! so on - that count its last block in 32 bits and start it on one.

const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const dos = sdk.dos;
const gpt = dos.gpt;
const DosBase = sdk.interface.dos.DosBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");
const _partition = @import("../partition/_partition.zig");
const mountpartition = @import("../partition/mountpartition.zig");

/// The buffers a GPT partition's file system is given: what a partition
/// AddPartition makes is given.
const default_buffers = 32;

/// The most blocks a cylinder of the environment is made of.
const max_cyl_blocks: u64 = 1 << 31;

/// Puts a partition of a disk's GPT on dos's list as a device node, so
/// that the file system on it can be started.
///
/// SYNOPSIS:
/// ```zig
/// fn MountGPTPartition(base: *RDBBase, handle: *rdb.RDBHandle, partition: *rdb.GPTPartition, name: [*:0]const u8, mounted: ?*rdb.MountName, flags: u32) i32
/// ```
///
/// SINCE: 1.4. LVO -72.
///
/// INPUTS:
/// - `handle`: from OpenRDB, with RDBF_GPT.
/// - `partition`: one of the handle's GPT partitions, not the container.
/// - `name`: what the drive is to be called, without the colon (`SD0`,
///   `SD0P3`).
/// - `mounted`: where the name the node got goes, or null.
/// - `flags`: RDBMF_START to start the handler before the call returns;
///   0 leaves it to the drive's first use. RDBMF_FAT (1.7), with a
///   format by `rdb.mountFormat`, mounts a new partition for FAT.
///
/// RESULT:
/// RDBERR_OK when the node is on the list, and `mounted` holds its name.
/// RDBERR_NOGPT for a handle without a GPT; RDBERR_FILESYSTEM for the
/// container, or a partition whose first block holds no file system this
/// machine reads - with RDBMF_FAT, and is not a new one's - or one that
/// cannot go on this medium; RDBERR_NAME for a
/// name that is empty, too long, holds a colon or a slash, or is taken
/// with every dot that fits; RDBERR_RANGE for a partition a cylinder
/// cannot be found for (one that starts on an odd block of a disk of 2^32
/// blocks or more); RDBERR_IO when its first block cannot be read;
/// RDBERR_CHANGED when the medium in the unit is not the one the GPT was
/// read from; RDBERR_MOUNTED when a device node on the list already opens
/// some of its blocks; RDBERR_NOMEM. The list is unchanged by a failure.
///
/// BEHAVIOR:
/// The partition's first block says what it holds: a posfs label gives
/// posfs (`POS\0`), the boot sector of a FAT32 or exFAT volume FAT
/// (`MSD\0`); the handler is the one that DosType asks for. The node opens
/// the handle's device and unit, its environment names the partition's
/// blocks and no more, with the medium's block size and memory, and it is
/// called `name`, with a dot added while dos's list has a device or an
/// assign of the name, as MountPartition does.
///
/// With RDBMF_FAT a partition whose first block holds no volume is
/// mounted for FAT (`MSD`, with the format the flags name as its last
/// byte) when the block is all zeroes and the partition's type is one a
/// FAT volume is in - basic data, or EFI System for the partition a
/// firmware starts from: a new partition, whose first block the program
/// that made it cleared, so that C:Format can give it a volume. What
/// another system put there - an NTFS volume, FAT12 or FAT16 - is not
/// mistaken for one.
///
/// A node of the same unit whose area shares a block with the partition's
/// stops it, as it stops MountPartition: a drive over the whole medium,
/// or the partition mounted already.
///
/// CONTEXT:
/// - Waits: yes, on the device, for the dos list's lock, and with
///   RDBMF_START for the handler.
/// - Interrupts: no.
/// - Locks: no spinlock may be held, nor the dos list.
/// - Process: a Task will do; a Process with RDBMF_START.
///
/// OWNERSHIP:
/// The node is the list's, for the system's life; the handle and the
/// partition stay the caller's.
///
/// NOTES:
/// `gpt.ATTR_NO_AUTOMOUNT` is the caller's to honour, as PBFF_NOMOUNT is
/// MountPartition's: a medium's partitions are mounted when it comes in
/// without the ones that have it. The container's partitions are mounted
/// with MountPartition.
///
/// Once a partition is mounted the library stays in memory for the
/// system's life.
///
/// BUGS:
/// A FAT12 or FAT16 volume - a small EFI System partition is often one -
/// is not one the FAT handler reads, and is not mounted.
///
/// SEE ALSO:
/// `NextGPTPartition`, `MountPartition`, `OpenRDB`
///
/// EXAMPLES:
/// ```zig
/// var name: rdb.MountName = undefined;
/// const part = rb.NextGPTPartition(handle, null) orelse return;
/// if (rb.MountGPTPartition(handle, part, "SD0", &name, rdb.RDBMF_START) == rdb.RDBERR_OK) {
///     _ = Printf(dl, "mounted as %s:\n", .{@as([*:0]const u8, &name)});
/// }
/// ```
pub fn MountGPTPartition(base: *RDBBase, handle: *rdb.RDBHandle, partition: *rdb.GPTPartition, name: [*:0]const u8, mounted: ?*rdb.MountName, flags: u32) i32 {
    const sys = base.sys_base;
    const private = _handle.handleOf(handle);
    if (handle.flags & rdb.RDBF_GPT == 0) return rdb.RDBERR_NOGPT;
    const entry = &partition.entry;
    if (gpt.isContainer(entry)) return rdb.RDBERR_FILESYSTEM;
    const drive = _partition.nameOf(name);
    if (!_partition.validName(drive)) return rdb.RDBERR_NAME;
    if (_handle.changed(private)) return rdb.RDBERR_CHANGED;
    const first = _handle.readAt(private, entry.starting_lba) orelse return rdb.RDBERR_IO;
    const dos_type = holds(first) orelse if (flags & rdb.RDBMF_FAT != 0 and fresh(entry, first))
        dos.fat.typeWithFormat(dos.ID_MSDOS_DISK, rdb.formatOfFlags(flags))
    else
        return rdb.RDBERR_FILESYSTEM;
    if (!dos.filesystems.suits(dos_type, handle.geometry.erase_size, false)) return rdb.RDBERR_FILESYSTEM;
    const handler = dos.filesystems.handlerFor(dos_type) orelse return rdb.RDBERR_FILESYSTEM;
    const env = environmentOf(handle, entry, dos_type) orelse return rdb.RDBERR_RANGE;

    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 1) orelse return rdb.RDBERR_NOMEM;
    defer sys.CloseLibrary(dos_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return rdb.RDBERR_NOMEM;
    defer sys.CloseLibrary(expansion_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);

    var text: rdb.MountName = @splat(0);
    @memcpy(text[0..drive.len], drive);
    const answer = mountpartition.add(dl, eb, private, &env, 0, handler, null, &text, drive.len);
    if (answer != rdb.RDBERR_OK) return answer;
    @atomicStore(bool, &base.mounted, true, .release);
    if (mounted) |into| into.* = text;
    if (flags & rdb.RDBMF_START != 0) mountpartition.start(dl, &text, drive.len);
    return rdb.RDBERR_OK;
}

/// The DosType of what a partition's first block says it holds, or null
/// for nothing this machine reads.
fn holds(block: []const u8) ?u32 {
    if (dos.posfs.table.isLabel(block)) return dos.posfs.ID_POSFS_DISK;
    if (dos.fat.formatOf(block) != .unknown) return dos.ID_MSDOS_DISK;
    return null;
}

/// Whether a partition is a new one for FAT: of a type a FAT volume is
/// in, its first block all zeroes.
fn fresh(entry: *const gpt.Entry, block: []const u8) bool {
    if (!gpt.sameGuid(&entry.partition_type_guid, &gpt.TYPE_BASIC_DATA) and
        !gpt.sameGuid(&entry.partition_type_guid, &gpt.TYPE_EFI_SYSTEM)) return false;
    for (block) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

/// The environment of a partition's blocks, or null where no cylinder of
/// a power of two blocks both counts its last block in 32 bits and starts
/// it.
fn environmentOf(handle: *rdb.RDBHandle, entry: *const gpt.Entry, dos_type: u32) ?dos.DosEnvec {
    var cyl_blocks: u64 = 1;
    while (entry.ending_lba / cyl_blocks > 0xFFFF_FFFE and cyl_blocks < max_cyl_blocks) cyl_blocks *= 2;
    if (entry.starting_lba % cyl_blocks != 0 or entry.ending_lba / cyl_blocks > 0xFFFF_FFFE) return null;
    const low = entry.starting_lba / cyl_blocks;
    const end = (entry.ending_lba + 1) / cyl_blocks;
    if (end <= low) return null;
    const geometry = &handle.geometry;
    return .{
        .size_block = geometry.sector_size,
        .surfaces = 1,
        .sector_per_block = 1,
        .blocks_per_track = @intCast(cyl_blocks),
        .low_cyl = @intCast(low),
        .high_cyl = @intCast(end - 1),
        .num_buffers = default_buffers,
        .buf_mem_type = if (geometry.buf_mem_type == 0) exec.MEMF_ANY else geometry.buf_mem_type,
        .dos_type = dos_type,
    };
}

// SPDX-License-Identifier: MIT
//! WriteRDB: a handle's table checked and put on the disk.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const hardblocks = sdk.dos.hardblocks;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");
const _partition = @import("../partition/_partition.zig");

/// Checks a handle's table and writes it to the disk: a PartitionBlock
/// per partition, then the RigidDiskBlock.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteRDB(base: *RDBBase, handle: *rdb.RDBHandle) i32
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `handle`: from OpenRDB, with a table (RDBF_FOUND, or after InitRDB).
///
/// RESULT:
/// RDBERR_OK when all of it is on the disk. Before anything is written:
/// RDBERR_NORDB for a handle with no table; RDBERR_BLOCKSIZE for a medium
/// whose erase unit is larger than its blocks, where erasing one block
/// would take its neighbours with it; RDBERR_NAME for a partition whose
/// name is empty, too long, holds a colon or a slash, or is another's;
/// RDBERR_RANGE for one whose cylinders are outside the table's usable
/// ones, the wrong way round or another's; RDBERR_FULL for more
/// partitions than the table's own blocks hold. RDBERR_IO when the device
/// refused a write, part of the way through.
///
/// BEHAVIOR:
/// Every partition is checked first, as AddPartition checks a new one,
/// since the program may have changed any of them. Each then gets a
/// block in the table's own area (`rdb_blocks_lo` to `rdb_blocks_hi`),
/// never the RigidDiskBlock's and never one of the file system headers',
/// their code's or the bad-block list's; blocks the chain on the disk is
/// not in are taken first. The PartitionBlocks are written in the list's
/// order, chained the same way, each with its checksum, and the
/// RigidDiskBlock last, pointing at the first - so the disk's old table
/// stays whole until that one block replaces it, as far as the free
/// blocks allow. A medium that wants erasing has each block erased before
/// it is written.
///
/// Afterwards each partition's `at` is its block, RDBF_FOUND is set and
/// RDBF_CHANGED, RDBF_DAMAGED and RDBF_FOREIGN are cleared.
///
/// Nothing but the table's blocks is written: what is on a partition's
/// cylinders stays, whatever the table now says of them.
///
/// CONTEXT:
/// - Waits: yes, on the device.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the task that opened the handle.
///
/// OWNERSHIP:
/// The handle stays the caller's.
///
/// NOTES:
/// dos mounts what the table says at boot, so the change is seen at the
/// next one. Changing the cylinders of a partition that is mounted leaves
/// its file system on the old ones until then.
///
/// BUGS:
/// A write that fails after the first PartitionBlock that had to reuse a
/// block of the old chain can leave the old table pointing at a new
/// block.
///
/// SEE ALSO:
/// `OpenRDB`, `InitRDB`, `AddPartition`, `RemPartition`
///
/// EXAMPLES:
/// ```zig
/// const err = rb.WriteRDB(handle);
/// if (err != rdb.RDBERR_OK) _ = Printf(dl, "not written (%ld)\n", .{err});
/// ```
pub fn WriteRDB(_: *RDBBase, handle: *rdb.RDBHandle) i32 {
    const private = _handle.handleOf(handle);
    if (!private.has_table) return rdb.RDBERR_NORDB;
    const geometry = &handle.geometry;
    if (geometry.erase_size != 0 and geometry.sector_size % geometry.erase_size != 0) return rdb.RDBERR_BLOCKSIZE;

    var walk = _partition.Partitions.of(handle);
    var partitions: u32 = 0;
    while (walk.next()) |part| : (partitions += 1) {
        const name = _partition.driveName(part);
        if (!_partition.validName(name) or _partition.named(handle, name, part) != null) return rdb.RDBERR_NAME;
        const env = &part.block.environment;
        if (!_partition.rangeFree(handle, env.low_cyl, env.high_cyl, part)) return rdb.RDBERR_RANGE;
    }
    if (partitions > _partition.blocksFor(private)) return rdb.RDBERR_FULL;

    // Each partition's block, in list order: the blocks the old chain is
    // not in first, then those it is.
    var blocks: [_handle.mapped_blocks]u32 = undefined;
    var given: u32 = 0;
    for ([_]bool{ false, true }) |old_chain| {
        var block = handle.rdb.rdb_blocks_lo;
        while (block <= handle.rdb.rdb_blocks_hi and block < _handle.mapped_blocks and given < partitions) : (block += 1) {
            if (block == handle.block or private.kept.has(block)) continue;
            if (private.on_disk.has(block) != old_chain) continue;
            blocks[given] = block;
            given += 1;
        }
    }

    var written: _handle.BlockMap = .{};
    walk = _partition.Partitions.of(handle);
    var index: u32 = 0;
    while (walk.next()) |part| : (index += 1) {
        const block = &part.block;
        block.id = hardblocks.IDNAME_PARTITION;
        block.summed_longs = @sizeOf(hardblocks.PartitionBlock) / 4;
        block.next = if (index + 1 < partitions) blocks[index + 1] else hardblocks.end_of_list;
        block.drive_name[block.drive_name.len - 1] = 0;
        block.checksum = hardblocks.checksumOf(block);
        if (!_handle.writeBlock(private, blocks[index], block)) return rdb.RDBERR_IO;
        part.at = blocks[index];
        written.add(blocks[index]);
    }

    const table = &handle.rdb;
    table.id = hardblocks.IDNAME_RIGIDDISK;
    table.summed_longs = @sizeOf(hardblocks.RigidDiskBlock) / 4;
    table.block_bytes = geometry.sector_size;
    table.partition_list = if (partitions != 0) blocks[0] else hardblocks.end_of_list;
    table.checksum = hardblocks.checksumOf(table);
    if (!_handle.writeBlock(private, handle.block, table)) return rdb.RDBERR_IO;

    private.on_disk = written;
    handle.flags |= rdb.RDBF_FOUND;
    handle.flags &= ~(rdb.RDBF_CHANGED | rdb.RDBF_DAMAGED | rdb.RDBF_FOREIGN);
    return rdb.RDBERR_OK;
}

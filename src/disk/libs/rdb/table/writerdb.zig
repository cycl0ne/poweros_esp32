// SPDX-License-Identifier: MIT
//! WriteRDB: a handle's table checked and put on the disk.
//!
//! **Where the blocks go.** Every reader of a disk takes the lowest sound
//! RigidDiskBlock of the first RDB_LOCATION_LIMIT blocks, and follows its
//! chain. The new table is put down beside the old one: its PartitionBlocks
//! and its RigidDiskBlock go in blocks the old table is not in, and only
//! then are the old RigidDiskBlock and any other one wiped. Whichever of
//! the two is lower, a reader finds a whole table at every point: the old
//! one until the new is written below it or the old is wiped above it, the
//! new one after. Where the table's area has no block to spare for that,
//! the RigidDiskBlock is written over the old one.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const hardblocks = sdk.dos.hardblocks;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");
const _partition = @import("../partition/_partition.zig");

const Handle = _handle.Handle;
const no_block = _handle.no_block;

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
/// would take its neighbours with it; RDBERR_CHANGED when the medium in
/// the unit is not the one the table was read from; RDBERR_NAME for a
/// partition whose name is empty, too long, holds a colon or a slash, or
/// is another's; RDBERR_RANGE for one whose cylinders are outside the
/// table's usable ones, the wrong way round or another's; RDBERR_FULL for
/// more partitions than the table's own blocks hold. RDBERR_IO when the
/// device refused a write, part of the way through.
///
/// BEHAVIOR:
/// Every partition is checked first, as AddPartition checks a new one,
/// since the program may have changed any of them. Each then gets a
/// block in the table's own area (`rdb_blocks_lo` to `rdb_blocks_hi`),
/// never one of the file system headers', their code's or the bad-block
/// list's, and so does the RigidDiskBlock, in one of the first
/// RDB_LOCATION_LIMIT blocks. Blocks the disk's table is not in are taken
/// first.
///
/// The PartitionBlocks are written in the list's order, chained the same
/// way, each with its checksum, then the RigidDiskBlock pointing at the
/// first; then every other RigidDiskBlock in the first blocks is wiped,
/// the one the disk's readers took until now last. A reader takes the
/// lowest sound RigidDiskBlock, so whichever of the old and the new is
/// lower, the disk holds a whole table at every point of the write: the
/// old one until the new replaces it, the new one after. A medium that
/// wants erasing has each block erased before it is written, and a wiped
/// block erased; on any other a wiped block is written with zeroes.
/// CMD_UPDATE ends it, so a device that holds writes back has them on the
/// medium when the call returns.
///
/// Afterwards `block` is the RigidDiskBlock's, each partition's `at` is
/// its block, RDBF_FOUND is set and RDBF_CHANGED, RDBF_DAMAGED and
/// RDBF_FOREIGN are cleared.
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
/// A drive mounted from a partition keeps the cylinders it was mounted
/// with until the system starts again: changing a partition's cylinders
/// or file system under its drive leaves the drive on the old ones.
/// Inhibit the drive first, and restart once the table is written.
///
/// After RDBERR_IO the handle no longer says what the disk holds: close
/// it, and open the unit again to see.
///
/// BUGS:
/// Where the table's area has no block to spare, the RigidDiskBlock is
/// written over the old one, and on a medium that erases, a cut between
/// that block's erase and its write leaves the disk without a table. A
/// write that fails after the first PartitionBlock that had to reuse a
/// block of the old chain can leave the old table pointing at a new
/// block.
///
/// SEE ALSO:
/// `OpenRDB`, `InitRDB`, `AddPartition`, `RemPartition`, `MountPartition`
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
    if (_handle.changed(private)) return rdb.RDBERR_CHANGED;

    var walk = _partition.Partitions.of(handle);
    var partitions: u32 = 0;
    while (walk.next()) |part| : (partitions += 1) {
        const name = _partition.driveName(part);
        if (!_partition.validName(name) or _partition.named(handle, name, part) != null) return rdb.RDBERR_NAME;
        const env = &part.block.environment;
        if (!_partition.rangeFree(handle, env.low_cyl, env.high_cyl, part)) return rdb.RDBERR_RANGE;
    }
    if (partitions > _partition.blocksFor(private)) return rdb.RDBERR_FULL;

    // The RigidDiskBlock a reader takes now, which stays until the new
    // table is down.
    const current = private.tables.lowest();
    var blocks: [_handle.mapped_blocks]u32 = undefined;
    const table_block = place(private, partitions, current, &blocks);
    if (table_block == no_block) return rdb.RDBERR_FULL;

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
    if (!_handle.writeBlock(private, table_block, table)) return rdb.RDBERR_IO;
    written.add(table_block);

    // Every other RigidDiskBlock wiped, the one readers took until now
    // last: one between it and the new one would be taken in between.
    var other: u32 = 0;
    while (other < hardblocks.RDB_LOCATION_LIMIT) : (other += 1) {
        if (!private.tables.has(other) or other == current or written.has(other)) continue;
        if (!_handle.clearBlock(private, other)) return rdb.RDBERR_IO;
    }
    if (current != no_block and !written.has(current) and !_handle.clearBlock(private, current)) return rdb.RDBERR_IO;
    if (!_handle.update(private)) return rdb.RDBERR_IO;

    handle.block = table_block;
    private.tables = .{};
    private.tables.add(table_block);
    private.on_disk = written;
    handle.flags |= rdb.RDBF_FOUND;
    handle.flags &= ~(rdb.RDBF_CHANGED | rdb.RDBF_DAMAGED | rdb.RDBF_FOREIGN);
    return rdb.RDBERR_OK;
}

/// Where the new table goes: the RigidDiskBlock's block, answered, and
/// one block per partition into `blocks`. Beside the disk's table where
/// the area has room for that, over its RigidDiskBlock where it has not;
/// `no_block` when the partitions do not fit either way.
fn place(handle: *Handle, partitions: u32, current: u32, blocks: *[_handle.mapped_blocks]u32) u32 {
    const fresh = freshBlock(handle, current);
    if (fresh != no_block and assign(handle, partitions, fresh, current, blocks)) return fresh;
    if (current != no_block and assign(handle, partitions, current, current, blocks)) return current;
    return no_block;
}

/// The lowest block a reader looks in, of the table's area, that the
/// disk's table is not in and no kept chain is; `no_block` for none.
fn freshBlock(handle: *Handle, current: u32) u32 {
    const table = &handle.public.rdb;
    var block = table.rdb_blocks_lo;
    while (block <= table.rdb_blocks_hi and block < hardblocks.RDB_LOCATION_LIMIT) : (block += 1) {
        if (block == current or handle.kept.has(block) or handle.on_disk.has(block)) continue;
        return block;
    }
    return no_block;
}

/// A block for each partition, in list order, into `blocks`: of the
/// table's area, not the new RigidDiskBlock's or the old one's, and not
/// kept; those the old chain is not in first. Whether every partition got
/// one.
fn assign(handle: *Handle, partitions: u32, table_block: u32, current: u32, blocks: *[_handle.mapped_blocks]u32) bool {
    const table = &handle.public.rdb;
    var given: u32 = 0;
    for ([_]bool{ false, true }) |old_chain| {
        var block = table.rdb_blocks_lo;
        while (block <= table.rdb_blocks_hi and block < _handle.mapped_blocks and given < partitions) : (block += 1) {
            if (block == table_block or block == current or handle.kept.has(block)) continue;
            if (handle.on_disk.has(block) != old_chain) continue;
            blocks[given] = block;
            given += 1;
        }
    }
    return given == partitions;
}

// SPDX-License-Identifier: MIT
//! InitRDB: a fresh table for the whole medium.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const hardblocks = sdk.dos.hardblocks;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");

/// The blocks a fresh table keeps for itself: all those a RigidDiskBlock
/// may be in, which leaves room for a PartitionBlock each after it.
const kept_blocks = hardblocks.RDB_LOCATION_LIMIT;

/// The most cylinders a table counts, so that the last one's number and
/// one more still fit the table's 32-bit fields.
const max_cylinders: u64 = 0xFFFF_FFFF;

/// The most blocks a cylinder of a fresh table is made of.
const max_cyl_blocks: u32 = 1 << 31;

/// Puts a fresh RigidDiskBlock for the whole medium in a handle, with no
/// partitions.
///
/// SYNOPSIS:
/// ```zig
/// fn InitRDB(base: *RDBBase, handle: *rdb.RDBHandle) i32
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `handle`: from OpenRDB, with a table or without.
///
/// RESULT:
/// RDBERR_OK; RDBERR_RANGE for a medium with too few blocks for the
/// table and one partition (RDB_LOCATION_LIMIT and two more), or a
/// container that does not start on a multiple of the table's cylinder;
/// RDBERR_GPT for a disk with a GPT and no container in it, whose other
/// partitions the table would be written over.
///
/// BEHAVIOR:
/// The table is made for the medium as TD_GETGEOMETRY tells it: blocks of
/// the medium's own size; a cylinder of one block, or on a medium of 2^32
/// blocks or more, of the fewest blocks - 2, 4, 8 and so on - that leave
/// fewer than 2^32 cylinders; and the first RDB_LOCATION_LIMIT blocks
/// kept for the table - the RigidDiskBlock and the PartitionBlocks, which
/// WriteRDB places in them - so every cylinder from the first past them
/// to the end may be a partition's. It says nothing of its vendor or
/// product; those fields are the program's to fill in.
///
/// A medium whose first block is a PC's partition table, as OpenRDB found
/// it - a card as it is sold, or as a PC formatted it - keeps that block:
/// the table's area starts at the second, which is still among the blocks
/// the RigidDiskBlock is looked for in, and the PC goes on seeing its
/// partitions. A partition of the table may then name the same blocks as
/// one of the PC's, so the one volume is the PC's and this system's.
///
/// On a disk with a GPT the table is the container's (RDBF_CONTAINER):
/// made for the container's blocks, which `geometry` counts, from its
/// first block on. A disk with a GPT and no container gets no table:
/// AddGPTPartition adds a container, or RemGPT takes the GPT out of the
/// handle for a table over the whole disk.
///
/// Every partition and every file system is taken off its list and
/// freed, and the chains of bad blocks and drive init code the disk had
/// are forgotten: the new table has none. Only the handle changes, and
/// RDBF_CHANGED is set; WriteRDB puts it on the disk, and until then the
/// disk keeps what it had.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The partitions and file systems are freed; a pointer to any of them
/// is no use afterwards.
///
/// NOTES:
/// A partition begins and ends on a cylinder, so on a medium of 2^32
/// blocks or more it begins and ends on a multiple of the cylinder's
/// blocks; the few blocks past the last whole cylinder are no
/// partition's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenRDB`, `AddPartition`, `WriteRDB`, `InitGPT`, `RemGPT`
///
/// EXAMPLES:
/// ```zig
/// if (rb.InitRDB(handle) != rdb.RDBERR_OK) return;
/// _ = rb.AddPartition(handle, "SD0", 0, 0, dos_type);
/// const err = rb.WriteRDB(handle);
/// ```
pub fn InitRDB(_: *RDBBase, handle: *rdb.RDBHandle) i32 {
    const private = _handle.handleOf(handle);
    const geometry = &handle.geometry;
    if (handle.flags & rdb.RDBF_GPT != 0 and handle.flags & rdb.RDBF_CONTAINER == 0) return rdb.RDBERR_GPT;
    if (geometry.total_sectors < kept_blocks + 2) return rdb.RDBERR_RANGE;
    var cyl_blocks: u32 = 1;
    while (geometry.total_sectors / cyl_blocks > max_cylinders and cyl_blocks < max_cyl_blocks) cyl_blocks *= 2;
    // Its partitions are put on the disk by whole cylinders.
    if (handle.container % cyl_blocks != 0) return rdb.RDBERR_RANGE;
    const cylinders: u32 = @intCast(@min(geometry.total_sectors / cyl_blocks, max_cylinders));

    _handle.freePartitions(private);
    _handle.freeFileSystems(private);
    private.kept = .{};
    const first: u32 = if (private.pc_table) 1 else 0;
    private.stored = .{};
    handle.rdb = .{
        .block_bytes = geometry.sector_size,
        .cylinders = cylinders,
        .sectors = cyl_blocks,
        .heads = 1,
        .cyl_blocks = cyl_blocks,
        .rdb_blocks_lo = first,
        .rdb_blocks_hi = kept_blocks - 1,
        .lo_cylinder = (kept_blocks + cyl_blocks - 1) / cyl_blocks,
        .hi_cylinder = cylinders - 1,
    };
    handle.flags |= rdb.RDBF_CHANGED;
    private.has_table = true;
    return rdb.RDBERR_OK;
}

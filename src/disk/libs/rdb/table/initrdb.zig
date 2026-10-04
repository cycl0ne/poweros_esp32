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
/// RDBERR_OK, or RDBERR_RANGE for a medium with too few blocks for the
/// table and one partition (RDB_LOCATION_LIMIT and two more).
///
/// BEHAVIOR:
/// The table is made for the medium as TD_GETGEOMETRY tells it: blocks of
/// the medium's own size, a cylinder of one block, and the first
/// RDB_LOCATION_LIMIT blocks kept for the table - the RigidDiskBlock in
/// the first, the PartitionBlocks after it - so every cylinder from there
/// to the end may be a partition's. It says nothing of its vendor or
/// product; those fields are the program's to fill in.
///
/// Every partition is taken off the list and freed, and the chains of
/// file system headers the disk had are forgotten: the new table has
/// none. Only the handle changes, and RDBF_CHANGED is set; WriteRDB puts
/// it on the disk, and until then the disk keeps what it had.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The partitions are freed; a pointer to any of them is no use
/// afterwards.
///
/// NOTES:
/// A medium larger than 2^32 blocks has a table for the first 2^32 of
/// them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenRDB`, `AddPartition`, `WriteRDB`
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
    if (geometry.total_sectors < kept_blocks + 2) return rdb.RDBERR_RANGE;
    const blocks: u32 = @intCast(@min(geometry.total_sectors, 0xFFFF_FFFF));

    _handle.freePartitions(private);
    private.kept = .{};
    handle.rdb = .{
        .block_bytes = geometry.sector_size,
        .cylinders = blocks,
        .sectors = 1,
        .heads = 1,
        .cyl_blocks = 1,
        .rdb_blocks_lo = 0,
        .rdb_blocks_hi = kept_blocks - 1,
        .lo_cylinder = kept_blocks,
        .hi_cylinder = blocks - 1,
    };
    handle.block = 0;
    handle.flags |= rdb.RDBF_CHANGED;
    private.has_table = true;
    return rdb.RDBERR_OK;
}

// SPDX-License-Identifier: MIT
//! AddPartition: a new partition on a handle's list.

const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const hardblocks = sdk.dos.hardblocks;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");
const _partition = @import("_partition.zig");

/// The buffers a new partition's file system is given.
const default_buffers = 32;

/// Adds a partition to a handle's table, over cylinders no other
/// partition has.
///
/// SYNOPSIS:
/// ```zig
/// fn AddPartition(base: *RDBBase, handle: *rdb.RDBHandle, name: [*:0]const u8, low_cyl: u32, high_cyl: u32, dos_type: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `handle`: from OpenRDB, with a table (RDBF_FOUND, or after InitRDB).
/// - `name`: its drive name, without the colon (`DH1`): 1 to
///   MAX_DEVICE_NAME characters, no colon or slash, no other partition's.
/// - `low_cyl`, `high_cyl`: its first and last cylinder, both its own;
///   0 and 0 for the longest run of cylinders no partition has.
/// - `dos_type`: the file system it is for (`ID_FLASHFS_DISK`, a FAT
///   handler's), which picks its handler when it is mounted.
///
/// RESULT:
/// RDBERR_OK; RDBERR_NORDB for a handle with no table; RDBERR_NAME for a
/// name it may not have; RDBERR_RANGE for cylinders outside the table's
/// usable ones (`lo_cylinder` to `hi_cylinder`), the wrong way round or
/// another partition's, and for 0 and 0 when no cylinder is free;
/// RDBERR_FULL when the table's own blocks have no room for another
/// PartitionBlock; RDBERR_NOMEM. The table is unchanged by a failure.
///
/// BEHAVIOR:
/// The new partition goes at the end of the list, and FindPartition with
/// the name finds it. Its environment is filled in for the table's
/// geometry: blocks of the table's size, one surface, a track of a
/// cylinder's blocks, 32 buffers in the memory the medium asks for, and
/// boot priority 0. Its flags are none - not bootable, mounted at boot -
/// and are the program's to set, as is any field of the environment,
/// before WriteRDB. RDBF_CHANGED is set.
///
/// Only the table in memory changes: nothing is written, and nothing on
/// the cylinders is touched, now or by WriteRDB. A file system goes on the
/// partition with Format, once it is mounted.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The partition is the handle's, freed by RemPartition or CloseRDB.
///
/// NOTES:
/// dos reads the table at boot, so a partition written with WriteRDB is
/// mounted at the next one.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindPartition`, `RemPartition`, `WriteRDB`
///
/// EXAMPLES:
/// ```zig
/// if (rb.AddPartition(handle, "DH1", 0, 0, flashfs.ID_FLASHFS_DISK) != rdb.RDBERR_OK) return;
/// rb.FindPartition(handle, "DH1").?.block.environment.boot_pri = -10;
/// const err = rb.WriteRDB(handle);
/// ```
pub fn AddPartition(_: *RDBBase, handle: *rdb.RDBHandle, name: [*:0]const u8, low_cyl: u32, high_cyl: u32, dos_type: u32) i32 {
    const private = _handle.handleOf(handle);
    if (!private.has_table) return rdb.RDBERR_NORDB;
    const text = _partition.nameOf(name);
    if (!_partition.validName(text) or _partition.named(handle, text, null) != null) return rdb.RDBERR_NAME;

    var low = low_cyl;
    var high = high_cyl;
    if (low == 0 and high == 0) {
        const run = _partition.largestFree(handle) orelse return rdb.RDBERR_RANGE;
        low = run.low;
        high = run.high;
    } else if (!_partition.rangeFree(handle, low, high, null)) {
        return rdb.RDBERR_RANGE;
    }
    if (_partition.count(handle) >= _partition.blocksFor(private)) return rdb.RDBERR_FULL;

    const table = &handle.rdb;
    var block: hardblocks.PartitionBlock = .{
        .environment = .{
            .size_block = table.block_bytes,
            .surfaces = 1,
            .sector_per_block = 1,
            .blocks_per_track = if (table.cyl_blocks == 0) 1 else table.cyl_blocks,
            .low_cyl = low,
            .high_cyl = high,
            .num_buffers = default_buffers,
            .buf_mem_type = if (handle.geometry.buf_mem_type == 0) exec.MEMF_ANY else handle.geometry.buf_mem_type,
            .boot_pri = 0,
            .dos_type = dos_type,
        },
    };
    @memcpy(block.drive_name[0..text.len], text);
    _ = _handle.appendPartition(private, hardblocks.end_of_list, &block) orelse return rdb.RDBERR_NOMEM;
    handle.flags |= rdb.RDBF_CHANGED;
    return rdb.RDBERR_OK;
}

// SPDX-License-Identifier: MIT
//! RemPartition: a partition taken off a handle's list.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const RDBBase = @import("../rdb_base.zig").RDBBase;

/// Takes a partition off a handle's list and frees it.
///
/// SYNOPSIS:
/// ```zig
/// fn RemPartition(base: *RDBBase, handle: *rdb.RDBHandle, partition: *rdb.RDBPartition) void
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `handle`: from OpenRDB.
/// - `partition`: one of its partitions.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Only the table in memory changes, and RDBF_CHANGED is set: the disk
/// keeps the partition until WriteRDB writes a chain without it. Its
/// cylinders are free for AddPartition at once; what is on them is not
/// touched, by this or by WriteRDB.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The partition is freed; a pointer to it is no use afterwards.
///
/// NOTES:
/// A partition of another handle must not be given.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddPartition`, `FindPartition`, `WriteRDB`
///
/// EXAMPLES:
/// ```zig
/// if (rb.FindPartition(handle, "DH1")) |part| rb.RemPartition(handle, part);
/// _ = rb.WriteRDB(handle);
/// ```
pub fn RemPartition(base: *RDBBase, handle: *rdb.RDBHandle, partition: *rdb.RDBPartition) void {
    const sys = base.sys_base;
    sys.Remove(&partition.node);
    sys.FreeVec(partition);
    handle.flags |= rdb.RDBF_CHANGED;
}

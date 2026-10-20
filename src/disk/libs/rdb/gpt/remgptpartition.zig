// SPDX-License-Identifier: MIT
//! RemGPTPartition: a partition taken out of a handle's GPT.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const gpt = sdk.dos.gpt;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");
const _gpt = @import("_gpt.zig");

/// Takes a partition off a handle's GPT and frees it.
///
/// SYNOPSIS:
/// ```zig
/// fn RemGPTPartition(base: *RDBBase, handle: *rdb.RDBHandle, partition: *rdb.GPTPartition) void
/// ```
///
/// SINCE: 1.4. LVO -84.
///
/// INPUTS:
/// - `handle`: from OpenRDB.
/// - `partition`: one of the handle's GPT partitions.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The partition's entry is unused from now on, and RDBF_GPTCHANGED is
/// set. Taking out the container the table is in takes the table with
/// it, as InitGPT does: its partitions and file systems are freed, and
/// the handle has no window and no table. A second container on the GPT
/// stays a partition of the GPT to the handle. Only the handle changes;
/// WriteGPT puts the change on the disk.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The partition is freed; a pointer to it is no use afterwards, and so
/// are pointers to a dropped table's partitions.
///
/// NOTES:
/// Nothing on the partition's blocks is touched, and a drive mounted from
/// it stays until the system starts again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddGPTPartition`, `WriteGPT`, `RemGPT`
///
/// EXAMPLES:
/// ```zig
/// const part = rb.NextGPTPartition(handle, null) orelse return;
/// rb.RemGPTPartition(handle, part);
/// _ = rb.WriteGPT(handle);
/// ```
pub fn RemGPTPartition(base: *RDBBase, handle: *rdb.RDBHandle, partition: *rdb.GPTPartition) void {
    const private = _handle.handleOf(handle);
    const sys = base.sys_base;
    if (gpt.isContainer(&partition.entry) and handle.flags & rdb.RDBF_CONTAINER != 0 and
        handle.container == partition.entry.starting_lba)
    {
        _gpt.dropTable(private);
        _gpt.clearWindow(private);
    }
    sys.Remove(&partition.node);
    sys.FreeVec(partition);
    handle.flags |= rdb.RDBF_GPTCHANGED;
}

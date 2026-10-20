// SPDX-License-Identifier: MIT
//! RemGPT: the GPT taken out of a handle, for a table over the whole disk.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");
const _gpt = @import("_gpt.zig");

/// Takes the GPT out of a handle, so that InitRDB makes a table over the
/// whole disk, and WriteRDB wipes the disk's GPT once it has written it.
///
/// SYNOPSIS:
/// ```zig
/// fn RemGPT(base: *RDBBase, handle: *rdb.RDBHandle) void
/// ```
///
/// SINCE: 1.4. LVO -92.
///
/// INPUTS:
/// - `handle`: from OpenRDB.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The GPT partitions are freed, and so is a table in the container with
/// its partitions and file systems; the handle has no window, no table,
/// and none of RDBF_GPT, RDBF_GPTDAMAGED, RDBF_GPTCHANGED and
/// RDBF_CONTAINER. Where the disk holds a GPT, the next WriteRDB wipes it
/// after its table is down: the header in block 1, the copy in the last
/// block, and the protective MBR, where the new table does not use those
/// blocks. A handle without a GPT is left as it is.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The GPT partitions and the dropped table's nodes are freed; a pointer
/// to any of them is no use afterwards.
///
/// NOTES:
/// Every partition of the GPT is lost with it, the PC's and the
/// container's, once WriteRDB has run.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitRDB`, `WriteRDB`, `InitGPT`
///
/// EXAMPLES:
/// ```zig
/// rb.RemGPT(handle);
/// if (rb.InitRDB(handle) != rdb.RDBERR_OK) return;
/// _ = rb.AddPartition(handle, "DH1", 0, 0, sdk.dos.posfs.ID_POSFS_DISK);
/// _ = rb.WriteRDB(handle);
/// ```
pub fn RemGPT(_: *RDBBase, handle: *rdb.RDBHandle) void {
    const private = _handle.handleOf(handle);
    if (handle.flags & rdb.RDBF_GPT == 0) return;
    _gpt.freeGptPartitions(private);
    _gpt.dropTable(private);
    _gpt.clearWindow(private);
    handle.gpt_header = .{};
    handle.flags &= ~(rdb.RDBF_GPT | rdb.RDBF_GPTDAMAGED | rdb.RDBF_GPTCHANGED);
    private.wipe_gpt = private.gpt_on_disk;
}

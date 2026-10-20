// SPDX-License-Identifier: MIT
//! InitGPT: a fresh GPT for the whole medium.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const gpt = sdk.dos.gpt;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");
const _gpt = @import("_gpt.zig");

/// Puts a fresh GPT for the whole medium in a handle, with no partitions.
///
/// SYNOPSIS:
/// ```zig
/// fn InitGPT(base: *RDBBase, handle: *rdb.RDBHandle) i32
/// ```
///
/// SINCE: 1.4. LVO -76.
///
/// INPUTS:
/// - `handle`: from OpenRDB, with any table or none.
///
/// RESULT:
/// RDBERR_OK, or RDBERR_RANGE for a medium too small for the GPT's two
/// copies and one partition aligned between them.
///
/// BEHAVIOR:
/// The header is made for the medium as TD_GETGEOMETRY tells it: the
/// medium's own block size, room for `gpt.entries_made` entries of
/// `gpt.entry_bytes` after it in block 2 and before the copy in the last
/// block, every block between them usable, and a new random disk GUID.
/// Partitions AddGPTPartition makes start on a multiple of
/// `gpt.alignment_bytes`.
///
/// Whatever the handle held goes: the GPT partitions, a RigidDiskBlock
/// table with its partitions and file systems, the window onto a
/// container. The handle then has RDBF_GPT and RDBF_GPTCHANGED, and no
/// table until a container is added and InitRDB makes one in it. Only the
/// handle changes; WriteGPT puts the GPT on the disk, and until then the
/// disk keeps what it had.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The partitions and file systems are freed; a pointer to any of them is
/// no use afterwards.
///
/// NOTES:
/// A GPT that replaces a RigidDiskBlock table over the whole disk has
/// that table's blocks written over by WriteGPT.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddGPTPartition`, `WriteGPT`, `RemGPT`, `InitRDB`
///
/// EXAMPLES:
/// ```zig
/// if (rb.InitGPT(handle) != rdb.RDBERR_OK) return;
/// var entry: gpt.Entry = .{ .partition_type_guid = gpt.TYPE_CONTAINER };
/// gpt.setName(&entry, "PowerOS");
/// _ = rb.AddGPTPartition(handle, &entry, null) orelse return;
/// _ = rb.InitRDB(handle);
/// ```
pub fn InitGPT(_: *RDBBase, handle: *rdb.RDBHandle) i32 {
    const private = _handle.handleOf(handle);
    const guid = _gpt.newGuid(private);
    const header = gpt.freshHeader(handle.disk_blocks, handle.geometry.sector_size, &guid) orelse return rdb.RDBERR_RANGE;
    _gpt.freeGptPartitions(private);
    _gpt.dropTable(private);
    _gpt.clearWindow(private);
    private.wipe_gpt = false;
    handle.gpt_header = header;
    handle.flags |= rdb.RDBF_GPT | rdb.RDBF_GPTCHANGED;
    handle.flags &= ~rdb.RDBF_GPTDAMAGED;
    return rdb.RDBERR_OK;
}

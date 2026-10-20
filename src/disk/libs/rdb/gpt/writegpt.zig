// SPDX-License-Identifier: MIT
//! WriteGPT: a handle's GPT checked and put on the disk, both copies.
//!
//! **The order.** A reader takes the header in block 1 with its entries
//! when both are sound, and the copy at the end otherwise. The copy at
//! the end goes down first, its entries and then its header; then the
//! entries after block 1, which leaves the old header there unsound, so a
//! reader takes the new copy at the end; then the header in block 1. So
//! the disk holds a whole GPT at every point: the old one until the copy
//! at the end is down, the new one after. The protective MBR comes last,
//! where block 0 is not one already, and then any RigidDiskBlock left in
//! the first blocks is wiped, so no reader takes it over the GPT.

const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const gpt = sdk.dos.gpt;
const hardblocks = sdk.dos.hardblocks;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");
const _gpt = @import("_gpt.zig");

const Handle = _handle.Handle;

/// Checks a handle's GPT and writes it to the disk: the copy at the end,
/// then the one at the start, then the protective MBR.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteGPT(base: *RDBBase, handle: *rdb.RDBHandle) i32
/// ```
///
/// SINCE: 1.4. LVO -88.
///
/// INPUTS:
/// - `handle`: from OpenRDB with a sound GPT, or after InitGPT.
///
/// RESULT:
/// RDBERR_OK when both copies are on the disk. Before anything is
/// written: RDBERR_NOGPT for a handle without a sound GPT;
/// RDBERR_BLOCKSIZE for a medium whose erase unit is larger than its
/// blocks; RDBERR_CHANGED when the medium in the unit is not the one the
/// GPT was read from; RDBERR_RANGE for a partition whose blocks are
/// outside the usable ones, the wrong way round or another's, or a GPT
/// whose copy at the end does not fit before the disk's last block;
/// RDBERR_NOMEM. RDBERR_IO when the device refused a write, part of the
/// way through.
///
/// BEHAVIOR:
/// The entries are made from the handle's list, each partition's in its
/// place by `number`, every other entry zeroes; both headers carry their
/// crc32 and the entries'. The header in block 1 names the copy in the
/// disk's last block, its entries follow it from block 2, and the copy's
/// entries follow the last usable block. The disk's GUID, its usable
/// blocks, the entries' count and size are the handle's `gpt_header`'s,
/// as read or as InitGPT made them; a disk that has grown since keeps its
/// usable blocks, and the copy moves to its new last block.
///
/// The copy at the end is written first, then the entries and the header
/// at the start, so that the disk holds a whole GPT at every point of the
/// write (see the top of the file). Block 0 is made a protective MBR
/// where it is not one - a hybrid MBR is left as it is - and a
/// RigidDiskBlock in the first RDB_LOCATION_LIMIT blocks that the GPT did
/// not write over is wiped. A medium that wants erasing has each block
/// erased before it is written. CMD_UPDATE ends it.
///
/// Afterwards `gpt_header` is the header in block 1, and RDBF_GPTCHANGED
/// is cleared.
///
/// Nothing but the GPT's blocks and those wiped is written: what is on a
/// partition's blocks stays.
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
/// Write the GPT before the table in its container: WriteRDB refuses a
/// table in a container that is not on the disk yet (RDBERR_GPT).
///
/// A drive mounted from a partition keeps its blocks until the system
/// starts again.
///
/// BUGS:
/// A cut after the protective MBR and before a RigidDiskBlock in the
/// first blocks is wiped leaves the disk read as that table's.
///
/// SEE ALSO:
/// `InitGPT`, `AddGPTPartition`, `RemGPTPartition`, `WriteRDB`
///
/// EXAMPLES:
/// ```zig
/// if (rb.WriteGPT(handle) == rdb.RDBERR_OK) _ = rb.WriteRDB(handle);
/// ```
pub fn WriteGPT(_: *RDBBase, handle: *rdb.RDBHandle) i32 {
    const private = _handle.handleOf(handle);
    if (handle.flags & rdb.RDBF_GPT == 0 or handle.flags & rdb.RDBF_GPTDAMAGED != 0) return rdb.RDBERR_NOGPT;
    const geometry = &handle.geometry;
    if (geometry.erase_size != 0 and geometry.sector_size % geometry.erase_size != 0) return rdb.RDBERR_BLOCKSIZE;
    if (_handle.changed(private)) return rdb.RDBERR_CHANGED;
    var walk = _gpt.Partitions.of(handle);
    while (walk.next()) |part| {
        if (!_gpt.blocksFree(handle, part.entry.starting_lba, part.entry.ending_lba, part)) return rdb.RDBERR_RANGE;
        if (part.number > handle.gpt_header.number_of_partition_entries) return rdb.RDBERR_RANGE;
    }

    const bytes = geometry.sector_size;
    var primary = handle.gpt_header;
    if (primary.size_of_partition_entry > bytes) return rdb.RDBERR_RANGE;
    const count = gpt.entriesBlocks(&primary, bytes);
    primary.my_lba = gpt.header_block;
    primary.alternate_lba = handle.disk_blocks - 1;
    if (gpt.header_block + 1 + count <= primary.first_usable_lba) primary.partition_entry_lba = gpt.header_block + 1;
    if (primary.partition_entry_lba < gpt.header_block + 1 or primary.partition_entry_lba + count > primary.first_usable_lba) return rdb.RDBERR_RANGE;
    if (primary.last_usable_lba + 1 + count > primary.alternate_lba) return rdb.RDBERR_RANGE;
    var backup = gpt.backupOf(&primary);

    // One block of entries, or a header, at a time.
    const memory = private.sys.AllocVec(bytes, exec.MEMF_ANY) orelse return rdb.RDBERR_NOMEM;
    defer private.sys.FreeVec(memory);
    const scratch = @as([*]u8, @ptrCast(memory))[0..bytes];
    var crc = gpt.EntriesCrc.of(&primary);
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        fillEntries(handle, &primary, index, scratch);
        crc.add(scratch);
    }
    const entries_crc = crc.end();

    if (!writeEntries(private, &primary, backup.partition_entry_lba, scratch)) return rdb.RDBERR_IO;
    gpt.putHeader(&backup, entries_crc, scratch);
    if (!_handle.writeAt(private, backup.my_lba, scratch)) return rdb.RDBERR_IO;
    if (!writeEntries(private, &primary, primary.partition_entry_lba, scratch)) return rdb.RDBERR_IO;
    gpt.putHeader(&primary, entries_crc, scratch);
    if (!_handle.writeAt(private, primary.my_lba, scratch)) return rdb.RDBERR_IO;

    const first = _handle.readAt(private, 0) orelse return rdb.RDBERR_IO;
    if (!gpt.protective(first)) {
        gpt.makeProtective(scratch, handle.disk_blocks);
        if (!_handle.writeAt(private, 0, scratch)) return rdb.RDBERR_IO;
    }
    if (!wipeTables(private, primary.partition_entry_lba + count)) return rdb.RDBERR_IO;
    if (!_handle.update(private)) return rdb.RDBERR_IO;

    handle.gpt_header = primary;
    handle.flags &= ~rdb.RDBF_GPTCHANGED;
    private.gpt_on_disk = true;
    private.wipe_gpt = false;
    return rdb.RDBERR_OK;
}

/// Block `index` of the entries made in `into`: the partitions whose
/// place is in it, zeroes around them.
fn fillEntries(handle: *rdb.RDBHandle, header: *const gpt.Header, index: u64, into: []u8) void {
    @memset(into, 0);
    const per = gpt.entriesPerBlock(header, @intCast(into.len));
    const first = index * per;
    var walk = _gpt.Partitions.of(handle);
    while (walk.next()) |part| {
        const slot = @as(u64, part.number) - 1;
        if (slot < first or slot >= first + per) continue;
        gpt.putEntry(header, into, @intCast(slot - first), &part.entry);
    }
}

/// The entries written from block `first` of the disk on, each block
/// made in `scratch`. Whether they were.
fn writeEntries(handle: *Handle, header: *const gpt.Header, first: u64, scratch: []u8) bool {
    const count = gpt.entriesBlocks(header, @intCast(scratch.len));
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        fillEntries(&handle.public, header, index, scratch);
        if (!_handle.writeAt(handle, first + index, scratch)) return false;
    }
    return true;
}

/// Every sound RigidDiskBlock in the disk's first RDB_LOCATION_LIMIT
/// blocks from `from` on wiped. Whether it was; a block that cannot be
/// read holds none a reader takes.
fn wipeTables(handle: *Handle, from: u64) bool {
    var block = from;
    while (block < hardblocks.RDB_LOCATION_LIMIT) : (block += 1) {
        const bytes = _handle.readAt(handle, block) orelse continue;
        var table: hardblocks.RigidDiskBlock = undefined;
        @memcpy(@as([*]u8, @ptrCast(&table))[0..@sizeOf(hardblocks.RigidDiskBlock)], bytes[0..@sizeOf(hardblocks.RigidDiskBlock)]);
        if (!hardblocks.sound(&table, hardblocks.IDNAME_RIGIDDISK)) continue;
        if (!_handle.clearAt(handle, block)) return false;
    }
    return true;
}

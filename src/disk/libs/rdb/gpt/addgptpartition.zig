// SPDX-License-Identifier: MIT
//! AddGPTPartition: a new partition in a handle's GPT.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const gpt = sdk.dos.gpt;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");
const _gpt = @import("_gpt.zig");

/// Adds a partition to a handle's GPT, over blocks no other partition
/// has.
///
/// SYNOPSIS:
/// ```zig
/// fn AddGPTPartition(base: *RDBBase, handle: *rdb.RDBHandle, entry: *const gpt.Entry, err: ?*i32) ?*rdb.GPTPartition
/// ```
///
/// SINCE: 1.4. LVO -80.
///
/// INPUTS:
/// - `handle`: from OpenRDB with a sound GPT, or after InitGPT.
/// - `entry`: the partition: its type (`partition_type_guid`), its first
///   and last block (`starting_lba`, `ending_lba`; both 0 for the largest
///   free run), its attributes and its name. A `unique_partition_guid` of
///   all zeroes gets a new random one.
/// - `err`: where the reason goes when the answer is null, or null.
///
/// RESULT:
/// The new partition, on the handle's list; `err` is then RDBERR_OK.
/// Null for RDBERR_NOGPT, a handle without a sound GPT; RDBERR_GPT, a
/// type of all zeroes or a container where the GPT has one; RDBERR_RANGE,
/// blocks outside the usable ones, the wrong way round, another
/// partition's, or a first block not on a multiple of
/// `gpt.alignment_bytes` - or, for 0 and 0, no aligned block free;
/// RDBERR_FULL, every entry used; RDBERR_NOMEM.
///
/// BEHAVIOR:
/// The partition gets the lowest entry number no partition has. A
/// container (`gpt.TYPE_CONTAINER`) becomes the handle's window: RDBF_CONTAINER
/// is set, `container` is its first block and `geometry` counts its
/// blocks, and InitRDB makes a table in it. Only the handle changes, and
/// RDBF_GPTCHANGED is set; WriteGPT puts the partition on the disk.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The partition is the handle's, freed by RemGPTPartition or CloseRDB.
///
/// NOTES:
/// Nothing is written on the partition's blocks: what was there stays
/// until a file system is formatted on it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitGPT`, `RemGPTPartition`, `WriteGPT`, `MountGPTPartition`
///
/// EXAMPLES:
/// ```zig
/// var entry: gpt.Entry = .{ .partition_type_guid = gpt.TYPE_BASIC_DATA };
/// gpt.setName(&entry, "Shared");
/// var err: i32 = 0;
/// const part = rb.AddGPTPartition(handle, &entry, &err) orelse return err;
/// ```
pub fn AddGPTPartition(_: *RDBBase, handle: *rdb.RDBHandle, entry: *const gpt.Entry, err: ?*i32) ?*rdb.GPTPartition {
    var reason: i32 = rdb.RDBERR_OK;
    const part = add(handle, entry, &reason);
    if (err) |into| into.* = reason;
    return part;
}

fn add(handle: *rdb.RDBHandle, entry: *const gpt.Entry, reason: *i32) ?*rdb.GPTPartition {
    const private = _handle.handleOf(handle);
    if (handle.flags & rdb.RDBF_GPT == 0 or handle.flags & rdb.RDBF_GPTDAMAGED != 0) return fail(reason, rdb.RDBERR_NOGPT);
    if (!gpt.used(entry)) return fail(reason, rdb.RDBERR_GPT);
    const container = gpt.isContainer(entry);
    if (container and _gpt.hasContainer(handle)) return fail(reason, rdb.RDBERR_GPT);

    var made = entry.*;
    if (made.starting_lba == 0 and made.ending_lba == 0) {
        const run = _gpt.largestFree(handle) orelse return fail(reason, rdb.RDBERR_RANGE);
        made.starting_lba = run.first;
        made.ending_lba = run.last;
    } else if (gpt.alignUp(made.starting_lba, handle.geometry.sector_size) != made.starting_lba or
        !_gpt.blocksFree(handle, made.starting_lba, made.ending_lba, null))
    {
        return fail(reason, rdb.RDBERR_RANGE);
    }
    const number = _gpt.freeNumber(handle) orelse return fail(reason, rdb.RDBERR_FULL);
    if (gpt.isNull(&made.unique_partition_guid)) made.unique_partition_guid = _gpt.newGuid(private);

    const part = _gpt.appendGptPartition(private, number, &made) orelse return fail(reason, rdb.RDBERR_NOMEM);
    if (container) _gpt.setWindow(private, &part.entry);
    handle.flags |= rdb.RDBF_GPTCHANGED;
    return part;
}

fn fail(reason: *i32, err: i32) ?*rdb.GPTPartition {
    reason.* = err;
    return null;
}

// SPDX-License-Identifier: MIT
//! NextGPTPartition: a walk along a handle's GPT partitions.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const RDBBase = @import("../rdb_base.zig").RDBBase;

/// Gives the GPT partition after another on a handle's list, or the
/// first.
///
/// SYNOPSIS:
/// ```zig
/// fn NextGPTPartition(base: *RDBBase, handle: *rdb.RDBHandle, previous: ?*rdb.GPTPartition) ?*rdb.GPTPartition
/// ```
///
/// SINCE: 1.4. LVO -68.
///
/// INPUTS:
/// - `handle`: from OpenRDB.
/// - `previous`: a partition of the handle's GPT, or null for the first.
///
/// RESULT:
/// The next partition, or null after the last, and on a handle without
/// RDBF_GPT.
///
/// BEHAVIOR:
/// The list is in the order of the GPT's entries, by `number`; unused
/// entries have no node. The container is on it, as a partition of the
/// type `gpt.TYPE_CONTAINER`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The partition stays the handle's.
///
/// NOTES:
/// Taking `previous` off the list in the walk ends it: hold on to the
/// next one first.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenRDB`, `MountGPTPartition`, `AddGPTPartition`, `NextPartition`
///
/// EXAMPLES:
/// ```zig
/// var name: [gpt.name_units:0]u8 = undefined;
/// var part = rb.NextGPTPartition(handle, null);
/// while (part) |p| : (part = rb.NextGPTPartition(handle, p)) {
///     _ = Printf(dl, "%u: %s\n", .{ p.number, gpt.nameText(&p.entry, &name).ptr });
/// }
/// ```
pub fn NextGPTPartition(_: *RDBBase, handle: *rdb.RDBHandle, previous: ?*rdb.GPTPartition) ?*rdb.GPTPartition {
    const node = if (previous) |part| part.node.next() else handle.gpt_partitions.first();
    const found = node orelse return null;
    return @fieldParentPtr("node", found);
}

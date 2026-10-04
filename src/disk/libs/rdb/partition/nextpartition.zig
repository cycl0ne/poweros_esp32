// SPDX-License-Identifier: MIT
//! NextPartition: the walk along a handle's partitions.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const RDBBase = @import("../rdb_base.zig").RDBBase;

/// The partition after another on a handle's list, or the first.
///
/// SYNOPSIS:
/// ```zig
/// fn NextPartition(base: *RDBBase, handle: *rdb.RDBHandle, previous: ?*rdb.RDBPartition) ?*rdb.RDBPartition
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `handle`: from OpenRDB.
/// - `previous`: a partition of this handle, or null for the first.
///
/// RESULT:
/// The next partition, or null past the last (or for a handle with none).
///
/// BEHAVIOR:
/// The order is the list's: the disk's chain as it was read, then what
/// AddPartition added, which is the order WriteRDB writes the chain in.
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
/// RemPartition on the partition just answered ends the walk with it:
/// take the next one first.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindPartition`, `AddPartition`, `RemPartition`
///
/// EXAMPLES:
/// ```zig
/// var part = rb.NextPartition(handle, null);
/// while (part) |p| : (part = rb.NextPartition(handle, p)) {
///     _ = Printf(dl, "%s\n", .{rdb.partitionName(p)});
/// }
/// ```
pub fn NextPartition(_: *RDBBase, handle: *rdb.RDBHandle, previous: ?*rdb.RDBPartition) ?*rdb.RDBPartition {
    const node = if (previous) |part| part.node.next() else handle.partitions.first();
    const found = node orelse return null;
    return @fieldParentPtr("node", found);
}

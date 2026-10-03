// SPDX-License-Identifier: MIT
//! FindPartition: a handle's partition by its name.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _partition = @import("_partition.zig");

/// The partition of a handle that has a name, in any case.
///
/// SYNOPSIS:
/// ```zig
/// fn FindPartition(base: *RDBBase, handle: *rdb.RDBHandle, name: [*:0]const u8) ?*rdb.RDBPartition
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `handle`: from OpenRDB.
/// - `name`: the drive name, without the colon (`DH0`).
///
/// RESULT:
/// The partition, or null when none is called that.
///
/// BEHAVIOR:
/// Names are compared without regard to case, as dos compares device
/// names.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The partition stays the handle's.
///
/// NOTES:
/// A name with a colon is no partition's: none may hold one.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NextPartition`, `AddPartition`
///
/// EXAMPLES:
/// ```zig
/// const part = rb.FindPartition(handle, "DH1") orelse return;
/// part.block.flags |= hardblocks.PBFF_BOOTABLE;
/// ```
pub fn FindPartition(_: *RDBBase, handle: *rdb.RDBHandle, name: [*:0]const u8) ?*rdb.RDBPartition {
    return _partition.named(handle, _partition.nameOf(name), null);
}

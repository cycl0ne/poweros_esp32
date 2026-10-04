// SPDX-License-Identifier: MIT
//! CloseRDB: a handle and everything it holds let go of.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("_handle.zig");

/// Lets go of a handle: its partition nodes, its buffer and the unit it
/// has open.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseRDB(base: *RDBBase, handle: ?*rdb.RDBHandle) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `handle`: what OpenRDB answered, or null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Nothing is written: a table changed and not written with WriteRDB is
/// dropped, and the disk keeps the one it has. Null does nothing.
///
/// CONTEXT:
/// - Waits: yes, CloseDevice may.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the task that opened the handle.
///
/// OWNERSHIP:
/// The handle and every RDBPartition of it are freed; a pointer to any of
/// them is no use afterwards.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenRDB`, `WriteRDB`
///
/// EXAMPLES:
/// ```zig
/// const handle = rb.OpenRDB("flash.device", 0, null) orelse return;
/// defer rb.CloseRDB(handle);
/// ```
pub fn CloseRDB(_: *RDBBase, handle: ?*rdb.RDBHandle) void {
    const public = handle orelse return;
    _handle.destroy(_handle.handleOf(public));
}

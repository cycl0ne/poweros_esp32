// SPDX-License-Identifier: MIT
//! RemFileSystem: a file system taken out of a handle's table.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");

/// Takes a file system's code out of a handle's table and frees it.
///
/// SYNOPSIS:
/// ```zig
/// fn RemFileSystem(base: *RDBBase, handle: *rdb.RDBHandle, file_system: *rdb.RDBFileSystem) void
/// ```
///
/// SINCE: 1.3. LVO -64.
///
/// INPUTS:
/// - `handle`: from OpenRDB.
/// - `file_system`: one of its file systems.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Only the table in memory changes, and RDBF_CHANGED is set: the disk
/// keeps the code until WriteRDB writes a table without it, whose blocks
/// are then free for the table's own use.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The file system is freed, with the code AddFileSystem copied; a
/// pointer to it is no use afterwards.
///
/// NOTES:
/// A drive mounted with the code keeps running it until the system
/// starts again; from then on the drive's handler is the ROM's, or the
/// one its DosType names.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddFileSystem`, `NextFileSystem`, `WriteRDB`
///
/// EXAMPLES:
/// ```zig
/// if (rb.NextFileSystem(handle, null)) |file_system| rb.RemFileSystem(handle, file_system);
/// _ = rb.WriteRDB(handle);
/// ```
pub fn RemFileSystem(base: *RDBBase, handle: *rdb.RDBHandle, file_system: *rdb.RDBFileSystem) void {
    const sys = base.sys_base;
    sys.Remove(&file_system.node);
    _handle.freeFileSys(sys, file_system);
    handle.flags |= rdb.RDBF_CHANGED;
}

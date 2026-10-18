// SPDX-License-Identifier: MIT
//! NextFileSystem: the walk along the file systems a handle's table keeps.

const sdk = @import("sdk");
const rdb = sdk.rdb;
const RDBBase = @import("../rdb_base.zig").RDBBase;

/// The file system after another on a handle's list of the table's file
/// systems, or the first.
///
/// SYNOPSIS:
/// ```zig
/// fn NextFileSystem(base: *RDBBase, handle: *rdb.RDBHandle, previous: ?*rdb.RDBFileSystem) ?*rdb.RDBFileSystem
/// ```
///
/// SINCE: 1.3. LVO -56.
///
/// INPUTS:
/// - `handle`: from OpenRDB.
/// - `previous`: a file system of this handle, or null for the first.
///
/// RESULT:
/// The next file system, or null past the last (or for a table that keeps
/// none).
///
/// BEHAVIOR:
/// The order is the list's: the disk's chain of FileSysHeaderBlocks as it
/// was read, then what AddFileSystem added, which is the order WriteRDB
/// writes the chain in. A header on the disk whose chain of code breaks
/// is not on the list, and the handle is marked RDBF_DAMAGED.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The file system stays the handle's.
///
/// NOTES:
/// RemFileSystem, and AddFileSystem for the same DosType, free the node
/// just answered: take the next one first.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddFileSystem`, `RemFileSystem`, `WriteRDB`
///
/// EXAMPLES:
/// ```zig
/// var file_system = rb.NextFileSystem(handle, null);
/// while (file_system) |fs| : (file_system = rb.NextFileSystem(handle, fs)) {
///     _ = Printf(dl, "%08lx version %u.%u\n", .{ fs.header.dos_type, fs.header.version >> 16, fs.header.version & 0xFFFF });
/// }
/// ```
pub fn NextFileSystem(_: *RDBBase, handle: *rdb.RDBHandle, previous: ?*rdb.RDBFileSystem) ?*rdb.RDBFileSystem {
    const node = if (previous) |file_system| file_system.node.next() else handle.file_systems.first();
    const found = node orelse return null;
    return @fieldParentPtr("node", found);
}

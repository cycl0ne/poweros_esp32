// SPDX-License-Identifier: MIT
//! AddFileSystem: a handler's code kept in a handle's table.

const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const hardblocks = sdk.dos.hardblocks;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");

/// Keeps a handler's load file in a handle's table, for the partitions of
/// one DosType.
///
/// SYNOPSIS:
/// ```zig
/// fn AddFileSystem(base: *RDBBase, handle: *rdb.RDBHandle, dos_type: u32, code: [*]const u8, size: u32) i32
/// ```
///
/// SINCE: 1.3. LVO -60.
///
/// INPUTS:
/// - `handle`: from OpenRDB, with a table (RDBF_FOUND, or after InitRDB).
/// - `dos_type`: the de_DosType of the partitions that are to run it.
/// - `code`, `size`: the handler's load file, as it is in HANDLERS:.
///
/// RESULT:
/// RDBERR_OK. RDBERR_NORDB for a handle with no table; RDBERR_FILESYSTEM
/// for code that is not a load file for this machine holding a handler's
/// ROM tag; RDBERR_NOMEM.
///
/// BEHAVIOR:
/// The code is copied and a new RDBFileSystem goes at the end of the
/// handle's list, with a FileSysHeaderBlock for `dos_type` whose version
/// is the handler's own: its tag's rt_Version, and the revision its ID
/// string gives. One kept for the same DosType before is taken out and
/// freed, as RemFileSystem would. RDBF_CHANGED is set; nothing reaches
/// the disk before WriteRDB, which answers RDBERR_FULL when the code does
/// not fit in the table's area even grown up to the first partition.
///
/// Once written, the partitions of `dos_type` on this disk run the code
/// when the ROM has no handler for the DosType or an older one
/// (`sdk.dos.filesystems.storedWins`): mounted by MountPartition, by the
/// device that reads the table when the medium comes in, or at boot by
/// the flash disk's driver.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `code` stays the caller's; the copy is the handle's until WriteRDB has
/// written it, or the file system is taken out.
///
/// NOTES:
/// The code is for the machine it was built for: a medium given the code
/// on one chip runs it only there.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemFileSystem`, `NextFileSystem`, `WriteRDB`, `MountPartition`
///
/// EXAMPLES:
/// ```zig
/// // `code` holds HANDLERS:posfs-handler, read with Open and Read.
/// const err = rb.AddFileSystem(handle, sdk.dos.posfs.ID_POSFS_DISK, code, size);
/// if (err == rdb.RDBERR_OK) _ = rb.WriteRDB(handle);
/// ```
pub fn AddFileSystem(base: *RDBBase, handle: *rdb.RDBHandle, dos_type: u32, code: [*]const u8, size: u32) i32 {
    const sys = base.sys_base;
    const private = _handle.handleOf(handle);
    if (!private.has_table) return rdb.RDBERR_NORDB;
    const tag = _handle.handlerIn(code[0..size]) orelse return rdb.RDBERR_FILESYSTEM;
    const memory = sys.AllocVec(size, exec.MEMF_ANY) orelse return rdb.RDBERR_NOMEM;
    const image: [*]u8 = @ptrCast(memory);
    @memcpy(image[0..size], code[0..size]);
    const header: hardblocks.FileSysHeaderBlock = .{
        .dos_type = dos_type,
        .version = tag.version,
        .patch_flags = hardblocks.FHBF_SEGLIST,
    };
    const added = _handle.appendFileSys(private, hardblocks.end_of_list, &header) orelse {
        sys.FreeVec(memory);
        return rdb.RDBERR_NOMEM;
    };
    added.image = image;
    added.public.size = size;

    var node = handle.file_systems.first();
    while (node) |it| {
        node = it.next();
        const file_system: *rdb.RDBFileSystem = @fieldParentPtr("node", it);
        if (file_system == &added.public or file_system.header.dos_type != dos_type) continue;
        sys.Remove(it);
        _handle.freeFileSys(sys, file_system);
    }
    handle.flags |= rdb.RDBF_CHANGED;
    return rdb.RDBERR_OK;
}

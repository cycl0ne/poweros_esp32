// SPDX-License-Identifier: MIT
//! OpenRDB: a unit of a block device opened, and its table read into a
//! handle.

const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const trackdisk = sdk.devices.trackdisk;
const hardblocks = sdk.dos.hardblocks;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("_handle.zig");

/// Opens a unit of a block device and reads what the disk says about
/// itself into a handle.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenRDB(base: *RDBBase, device: [*:0]const u8, unit: u32, err: ?*i32) ?*rdb.RDBHandle
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `device`: the exec device, `flash.device` or `sdcard.device` or any
///   other that answers trackdisk's commands.
/// - `unit`: its unit.
/// - `err`: where the reason goes when the answer is null, or null.
///
/// RESULT:
/// The handle, with the unit open; `err` is then RDBERR_OK. Null when the
/// device or unit cannot be opened, answers no TD_GETGEOMETRY, has no
/// medium in it or blocks smaller than 256 bytes (RDBERR_DEVICE), or for
/// no memory (RDBERR_NOMEM).
///
/// BEHAVIOR:
/// The first RDB_LOCATION_LIMIT blocks are searched for a sound
/// RigidDiskBlock, and its chain of PartitionBlocks is read into one
/// RDBPartition each, on `partitions` in the chain's order. The handle's
/// flags say what was found:
/// - RDBF_FOUND: a table, in `rdb`, read from block `block`.
/// - RDBF_DAMAGED: the partition chain stops at a block that is not a
///   sound PartitionBlock, or comes round to itself; the partitions
///   before it are on the list.
/// - RDBF_FOREIGN: a RigidDiskBlock written for another block size,
///   which is left as it is and counts as none.
///
/// A disk with no table is not a failure - that is how a blank one looks -
/// and InitRDB makes it one. The blocks of the file system headers, of
/// their code and of the bad-block list are noted, so WriteRDB never puts
/// a PartitionBlock over them.
///
/// CONTEXT:
/// - Waits: yes, on the device.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do. The handle's reply port is the caller's,
///   so every call with it must come from the same task.
///
/// OWNERSHIP:
/// The handle, its nodes and the open unit are the caller's until
/// CloseRDB.
///
/// NOTES:
/// The unit stays open for the handle's life; a file system on it is not
/// disturbed by that.
///
/// BUGS:
/// Blocks past the first 256 are not looked at for the kept chains, and
/// WriteRDB uses none of them.
///
/// SEE ALSO:
/// `CloseRDB`, `NextPartition`, `InitRDB`, `WriteRDB`
///
/// EXAMPLES:
/// ```zig
/// var err: i32 = 0;
/// const handle = rb.OpenRDB("sdcard.device", 0, &err) orelse return err;
/// defer rb.CloseRDB(handle);
/// if (handle.flags & rdb.RDBF_FOUND == 0) _ = rb.InitRDB(handle);
/// ```
pub fn OpenRDB(base: *RDBBase, device: [*:0]const u8, unit: u32, err: ?*i32) ?*rdb.RDBHandle {
    var reason: i32 = rdb.RDBERR_OK;
    const handle = open(base, device, unit, &reason);
    if (err) |into| into.* = reason;
    return handle;
}

fn open(base: *RDBBase, device: [*:0]const u8, unit: u32, reason: *i32) ?*rdb.RDBHandle {
    const sys = base.sys_base;
    const handle = _handle.create(base) orelse {
        reason.* = rdb.RDBERR_NOMEM;
        return null;
    };
    const failed = fail: {
        handle.port = sys.CreateMsgPort() orelse break :fail rdb.RDBERR_NOMEM;
        const request = sys.CreateIORequest(handle.port, @sizeOf(exec.IOStdReq)) orelse break :fail rdb.RDBERR_NOMEM;
        const io: *exec.IOStdReq = @ptrCast(@alignCast(request));
        handle.io = io;
        if (sys.OpenDevice(device, unit, &io.req, 0) != 0) break :fail rdb.RDBERR_DEVICE;
        handle.unit_open = true;

        const geometry = &handle.public.geometry;
        io.req.command = trackdisk.TD_GETGEOMETRY;
        io.offset = 0;
        io.length = @sizeOf(trackdisk.DriveGeometry);
        io.data = geometry;
        if (sys.DoIO(&io.req) != 0) break :fail rdb.RDBERR_DEVICE;
        if (geometry.total_sectors == 0 or geometry.sector_size < @sizeOf(hardblocks.RigidDiskBlock)) {
            break :fail rdb.RDBERR_DEVICE;
        }

        const buffer = sys.AllocVec(geometry.sector_size, geometry.buf_mem_type | exec.MEMF_CLEAR) orelse
            break :fail rdb.RDBERR_NOMEM;
        handle.buffer = @ptrCast(buffer);
        const read = _handle.readTable(handle);
        if (read != rdb.RDBERR_OK) break :fail read;
        return &handle.public;
    };
    _handle.destroy(handle);
    reason.* = failed;
    return null;
}

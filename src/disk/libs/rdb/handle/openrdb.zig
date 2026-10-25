// SPDX-License-Identifier: MIT
//! OpenRDB: a unit of a block device opened, and its table read into a
//! handle.

const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const trackdisk = sdk.devices.trackdisk;
const hardblocks = sdk.dos.hardblocks;
const ExecBase = sdk.interface.exec.ExecBase;
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
/// medium in it or blocks smaller than 256 bytes (RDBERR_DEVICE), when
/// the medium went or changed while its blocks were read (RDBERR_CHANGED),
/// or for no memory (RDBERR_NOMEM).
///
/// BEHAVIOR:
/// The first RDB_LOCATION_LIMIT blocks are searched for a sound
/// RigidDiskBlock - the lowest is the table, as every reader of the disk
/// takes it - and its chain of PartitionBlocks is read into one
/// RDBPartition each, on `partitions` in the chain's order. The handle's
/// flags say what was found:
/// - RDBF_FOUND: a table, in `rdb`, read from block `block`.
/// - RDBF_DAMAGED: the partition chain stops at a block that is not a
///   sound PartitionBlock, or comes round to itself; the partitions
///   before it are on the list.
/// - RDBF_FOREIGN: a RigidDiskBlock written for another block size,
///   which is left as it is and counts as none.
///
/// A disk with no RigidDiskBlock of its own whose first block is a
/// protective MBR, or whose second begins with a GPT header, holds a GPT
/// (`sdk.dos.gpt`):
/// - RDBF_GPT: its partitions are on `gpt_partitions`, a GPTPartition per
///   used entry, and its header is `gpt_header` - the one in block 1 with
///   its entries where both are sound, the copy in the last block
///   otherwise, which also sets RDBF_GPTCHANGED.
/// - RDBF_GPTDAMAGED: neither copy is sound, and the list is empty.
/// - RDBF_CONTAINER: the first of its partitions of the type
///   `gpt.TYPE_CONTAINER` is where the table is looked for, as on a disk
///   of its own: `container` is its first block on the disk, every block
///   number and cylinder of the table counts from there, `geometry`
///   counts the container's blocks and `disk_blocks` the disk's.
/// A RigidDiskBlock in the disk's own first blocks is the table even where
/// the disk has a GPT too, and the GPT is not read.
///
/// A disk with no table is not a failure - that is how a blank one looks -
/// and InitRDB makes it one. The blocks of the file system headers, of
/// their code and of the bad-block list are noted, so WriteRDB never puts
/// a PartitionBlock over them. `change_num` is the unit's TD_CHANGENUM,
/// which says later whether the medium is still this one.
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
/// `CloseRDB`, `NextPartition`, `InitRDB`, `WriteRDB`, `NextGPTPartition`
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
        handle.device = copyName(sys, device) orelse break :fail rdb.RDBERR_NOMEM;
        handle.unit = unit;
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
        handle.public.change_num = _handle.changeNum(handle);

        const buffer = sys.AllocVec(geometry.sector_size, geometry.buf_mem_type | exec.MEMF_CLEAR) orelse
            break :fail rdb.RDBERR_NOMEM;
        handle.buffer = @ptrCast(buffer);
        const read = _handle.readTable(handle);
        if (read != rdb.RDBERR_OK) break :fail read;
        // A block that cannot be read is no table, so a medium that went
        // while they were read would look blank.
        if (_handle.changed(handle)) break :fail rdb.RDBERR_CHANGED;
        return &handle.public;
    };
    _handle.destroy(handle);
    reason.* = failed;
    return null;
}

/// A copy of a C string, or null for no memory.
fn copyName(sys: *ExecBase, name: [*:0]const u8) ?[*:0]u8 {
    var length: usize = 0;
    while (name[length] != 0) length += 1;
    const memory = sys.AllocVec(length + 1, exec.MEMF_CLEAR) orelse return null;
    const copy: [*]u8 = @ptrCast(memory);
    @memcpy(copy[0..length], name[0..length]);
    return @ptrCast(copy);
}

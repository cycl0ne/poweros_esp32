// SPDX-License-Identifier: MIT
//! What every call shares: the handle behind the program's RDBHandle, the
//! one block it reads and writes through, and the reading of a disk's
//! chains.
//!
//! A handle is one allocation: the RDBHandle the program sees first, then
//! the open unit's port and request, the block buffer, and two maps of the
//! blocks at the start of the disk - those the library must not write
//! over (the chains it does not manage), and those the partition chain on
//! the disk is in, which WriteRDB keeps clear of while it can so that the
//! old table stays whole until the new RigidDiskBlock replaces it.
//!
//! Every transfer is a whole block of the medium through the buffer, in
//! the memory the medium asks for: a structure is the first 256 bytes of
//! its block, and the rest is written as zeroes.

const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const trackdisk = sdk.devices.trackdisk;
const hardblocks = sdk.dos.hardblocks;
const ExecBase = sdk.interface.exec.ExecBase;
const RDBBase = @import("../rdb_base.zig").RDBBase;

/// The blocks the maps cover: an RDB area reaching past them is used only
/// up to here.
pub const mapped_blocks = 256;

/// The most blocks a chain is followed through before it counts as a ring.
const max_chain = mapped_blocks;

/// A set of block numbers below `mapped_blocks`.
pub const BlockMap = extern struct {
    words: [mapped_blocks / 32]u32 = @splat(0),

    pub fn has(map: *const BlockMap, block: u32) bool {
        if (block >= mapped_blocks) return false;
        return map.words[block / 32] & (@as(u32, 1) << @intCast(block % 32)) != 0;
    }

    pub fn add(map: *BlockMap, block: u32) void {
        if (block >= mapped_blocks) return;
        map.words[block / 32] |= @as(u32, 1) << @intCast(block % 32);
    }
};

/// The handle behind an RDBHandle.
pub const Handle = extern struct {
    public: rdb.RDBHandle = .{},
    sys: *ExecBase,
    port: ?*exec.MsgPort = null,
    io: ?*exec.IOStdReq = null,
    /// Whether `io` has the unit open.
    unit_open: bool = false,
    /// Whether `public.rdb` is a table WriteRDB may write: one read from
    /// the disk, or one InitRDB made.
    has_table: bool = false,
    /// One block of the medium.
    buffer: ?[*]u8 = null,
    /// Blocks no PartitionBlock may go in: the chains of file system
    /// headers, their code and bad blocks.
    kept: BlockMap = .{},
    /// The blocks the partition chain on the disk is in.
    on_disk: BlockMap = .{},
};

pub fn handleOf(handle: *rdb.RDBHandle) *Handle {
    return @fieldParentPtr("public", handle);
}

/// The bytes of one block: the medium's own.
pub fn blockBytes(handle: *const Handle) u32 {
    return handle.public.geometry.sector_size;
}

/// A handle with nothing open yet, or null for no memory.
pub fn create(base: *RDBBase) ?*Handle {
    const sys = base.sys_base;
    const memory = sys.AllocVec(@sizeOf(Handle), exec.MEMF_CLEAR) orelse return null;
    const handle: *Handle = @ptrCast(@alignCast(memory));
    handle.* = .{ .sys = sys };
    handle.public.partitions.init(.unknown);
    return handle;
}

/// Everything a handle holds let go of, and the handle freed: what Open
/// got as far as making, and all of it after.
pub fn destroy(handle: *Handle) void {
    const sys = handle.sys;
    freePartitions(handle);
    if (handle.io) |io| {
        if (handle.unit_open) sys.CloseDevice(&io.req);
        sys.DeleteIORequest(&io.req);
    }
    sys.DeleteMsgPort(handle.port);
    sys.FreeVec(handle.buffer);
    sys.FreeVec(handle);
}

/// Every partition node taken off the list and freed.
pub fn freePartitions(handle: *Handle) void {
    const sys = handle.sys;
    while (sys.RemHead(&handle.public.partitions)) |node| sys.FreeVec(node);
}

/// A new partition node holding `block`, at the end of the list; null for
/// no memory.
pub fn appendPartition(handle: *Handle, at: u32, block: *const hardblocks.PartitionBlock) ?*rdb.RDBPartition {
    const sys = handle.sys;
    const memory = sys.AllocVec(@sizeOf(rdb.RDBPartition), exec.MEMF_CLEAR) orelse return null;
    const part: *rdb.RDBPartition = @ptrCast(@alignCast(memory));
    part.* = .{ .at = at, .block = block.* };
    // A name runs to the end of its field at the most.
    part.block.drive_name[part.block.drive_name.len - 1] = 0;
    part.node.name = rdb.partitionName(part);
    sys.AddTail(&handle.public.partitions, &part.node);
    return part;
}

// --- the medium ---------------------------------------------------------------

/// One command to the unit; whether it was done.
fn command(handle: *Handle, code: u16, block: u32, data: ?*anyopaque) bool {
    const io = handle.io orelse return false;
    const bytes = blockBytes(handle);
    io.req.command = code;
    io.offset = @as(u64, block) * bytes;
    io.length = bytes;
    io.data = data;
    io.actual = 0;
    return handle.sys.DoIO(&io.req) == 0;
}

/// A block's structure read into `into`; whether the block could be read.
pub fn readBlock(handle: *Handle, block: u32, into: anytype) bool {
    const buffer = handle.buffer orelse return false;
    if (!command(handle, exec.CMD_READ, block, buffer)) return false;
    const bytes: [*]u8 = @ptrCast(into);
    @memcpy(bytes[0..@sizeOf(@TypeOf(into.*))], buffer[0..@sizeOf(@TypeOf(into.*))]);
    return true;
}

/// A structure written as the start of a block, zeroes after it; the
/// block erased first on a medium that wants it. Whether it was done.
pub fn writeBlock(handle: *Handle, block: u32, from: anytype) bool {
    const buffer = handle.buffer orelse return false;
    const size = @sizeOf(@TypeOf(from.*));
    @memset(buffer[0..blockBytes(handle)], 0);
    const bytes: [*]const u8 = @ptrCast(from);
    @memcpy(buffer[0..size], bytes[0..size]);
    if (handle.public.geometry.erase_size != 0 and !command(handle, trackdisk.TDCMD_ERASE, block, null)) return false;
    return command(handle, exec.CMD_WRITE, block, buffer);
}

// --- reading the table ----------------------------------------------------------

/// The disk's table read into the handle: the RigidDiskBlock in the first
/// blocks, the partitions on its chain, and the blocks of the chains the
/// library leaves alone. Answers RDBERR_OK or RDBERR_NOMEM; a disk with no
/// table, or a broken one, is said in the handle's flags.
pub fn readTable(handle: *Handle) i32 {
    const public = &handle.public;
    const geometry = &public.geometry;
    var block: u32 = 0;
    while (block < hardblocks.RDB_LOCATION_LIMIT and block < geometry.total_sectors) : (block += 1) {
        var found: hardblocks.RigidDiskBlock = undefined;
        if (!readBlock(handle, block, &found)) continue;
        if (!hardblocks.sound(&found, hardblocks.IDNAME_RIGIDDISK)) continue;
        // The block numbers in it count another size of block.
        if (found.block_bytes != geometry.sector_size) {
            public.flags |= rdb.RDBF_FOREIGN;
            return rdb.RDBERR_OK;
        }
        public.rdb = found;
        public.block = block;
        public.flags |= rdb.RDBF_FOUND;
        handle.has_table = true;
        break;
    } else return rdb.RDBERR_OK;

    var next = public.rdb.partition_list;
    var seen: u32 = 0;
    while (next != hardblocks.end_of_list) : (seen += 1) {
        var part: hardblocks.PartitionBlock = undefined;
        if (seen == max_chain or handle.on_disk.has(next) or !readBlock(handle, next, &part) or
            !hardblocks.sound(&part, hardblocks.IDNAME_PARTITION))
        {
            public.flags |= rdb.RDBF_DAMAGED;
            break;
        }
        _ = appendPartition(handle, next, &part) orelse return rdb.RDBERR_NOMEM;
        handle.on_disk.add(next);
        next = part.next;
    }

    keepFileSystems(handle);
    keepChain(handle, public.rdb.bad_block_list, hardblocks.IDNAME_BADBLOCK);
    keepChain(handle, public.rdb.drive_init, hardblocks.IDNAME_LOADSEG);
    return rdb.RDBERR_OK;
}

/// The file system headers' blocks and their code's, kept.
fn keepFileSystems(handle: *Handle) void {
    var next = handle.public.rdb.file_sys_header_list;
    var seen: u32 = 0;
    while (next != hardblocks.end_of_list and seen < max_chain and !handle.kept.has(next)) : (seen += 1) {
        var header: hardblocks.FileSysHeaderBlock = undefined;
        if (!readBlock(handle, next, &header)) return;
        if (!hardblocks.sound(&header, hardblocks.IDNAME_FILESYSHEADER)) return;
        handle.kept.add(next);
        keepChain(handle, @bitCast(header.seg_list_blocks), hardblocks.IDNAME_LOADSEG);
        next = header.next;
    }
}

/// A chain of blocks that start with `id` and a next field (LoadSegBlock
/// and BadBlockBlock have the same head), kept. Their checksums cover the
/// data after the head, so the identifier is what is checked.
fn keepChain(handle: *Handle, first: u32, id: u32) void {
    var next = first;
    var seen: u32 = 0;
    while (next != hardblocks.end_of_list and seen < max_chain and !handle.kept.has(next)) : (seen += 1) {
        var head: hardblocks.LoadSegBlock = undefined;
        if (!readBlock(handle, next, &head)) return;
        if (head.id != id) return;
        handle.kept.add(next);
        next = head.next;
    }
}

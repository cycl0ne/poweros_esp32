// SPDX-License-Identifier: MIT
//! What every call shares: the handle behind the program's RDBHandle, the
//! one block it reads and writes through, and the reading of a disk's
//! chains.
//!
//! A handle is one allocation: the RDBHandle the program sees first, then
//! the open unit's port and request, the block buffer, a copy of the
//! device's name for the nodes MountPartition makes, and four maps of
//! the blocks at the start of the disk - those the library must not write
//! over (the chains it does not manage), those the table's file systems'
//! code is in, those the partition chain on the disk is in, and those a
//! RigidDiskBlock is in. WriteRDB keeps clear of the disk's table while it
//! can, so that the old one stays whole until the new RigidDiskBlock
//! replaces it.
//!
//! The table's file systems are nodes of their own (`FileSys`): the
//! FileSysHeaderBlock and what its chain of LoadSegBlocks measures, read
//! at OpenRDB without the code itself, which is read from the disk when
//! MountPartition wants it. One AddFileSystem made holds its code in
//! memory until WriteRDB has put it on the disk.
//!
//! Every transfer is a whole block of the medium through the buffer, in
//! the memory the medium asks for: a structure is the first 256 bytes of
//! its block, and the rest is written as zeroes; a LoadSegBlock fills it.

const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const trackdisk = sdk.devices.trackdisk;
const hardblocks = sdk.dos.hardblocks;
const loadfile = sdk.dos.loadfile;
const ExecBase = sdk.interface.exec.ExecBase;
const RDBBase = @import("../rdb_base.zig").RDBBase;

/// The blocks the maps cover: an RDB area reaching past them is used only
/// up to here.
pub const mapped_blocks = 256;

/// The most blocks a chain is followed through before it counts as a ring.
const max_chain = mapped_blocks;

/// No block: a BlockMap's `lowest` when the map has none.
pub const no_block = hardblocks.end_of_list;

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

    /// The lowest block in the map, or `no_block`.
    pub fn lowest(map: *const BlockMap) u32 {
        var block: u32 = 0;
        while (block < mapped_blocks) : (block += 1) {
            if (map.has(block)) return block;
        }
        return no_block;
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
    /// The device's name as OpenRDB was given it, and its unit: what a
    /// node MountPartition makes opens.
    device: ?[*:0]u8 = null,
    unit: u32 = 0,
    /// Whether `public.rdb` is a table WriteRDB may write: one read from
    /// the disk, or one InitRDB made.
    has_table: bool = false,
    /// One block of the medium.
    buffer: ?[*]u8 = null,
    /// Blocks no PartitionBlock may go in and nothing is written over:
    /// the chains of bad blocks and of the drive's init code.
    kept: BlockMap = .{},
    /// The blocks the table's file systems are in on the disk, headers
    /// and code: no PartitionBlock goes in one.
    stored: BlockMap = .{},
    /// The blocks the partition chain on the disk is in.
    on_disk: BlockMap = .{},
    /// The first FileSysHeaderBlock of the chain on the disk, or
    /// `end_of_list`: WriteRDB reads the chain to keep clear of its
    /// blocks.
    file_sys_list: u32 = hardblocks.end_of_list,
    /// The blocks of the first RDB_LOCATION_LIMIT that hold a sound
    /// RigidDiskBlock, for this block size or another: a reader takes the
    /// lowest, and WriteRDB leaves only its own.
    tables: BlockMap = .{},
};

pub fn handleOf(handle: *rdb.RDBHandle) *Handle {
    return @fieldParentPtr("public", handle);
}

/// The node behind an RDBFileSystem.
pub const FileSys = extern struct {
    public: rdb.RDBFileSystem = .{},
    /// The code AddFileSystem was given, a copy, until WriteRDB has put
    /// it on the disk; null for code that is there.
    image: ?[*]u8 = null,
};

pub fn fileSysOf(file_system: *rdb.RDBFileSystem) *FileSys {
    return @fieldParentPtr("public", file_system);
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
    handle.public.file_systems.init(.unknown);
    return handle;
}

/// Everything a handle holds let go of, and the handle freed: what Open
/// got as far as making, and all of it after.
pub fn destroy(handle: *Handle) void {
    const sys = handle.sys;
    freePartitions(handle);
    freeFileSystems(handle);
    if (handle.io) |io| {
        if (handle.unit_open) sys.CloseDevice(&io.req);
        sys.DeleteIORequest(&io.req);
    }
    sys.DeleteMsgPort(handle.port);
    sys.FreeVec(handle.buffer);
    sys.FreeVec(handle.device);
    sys.FreeVec(handle);
}

/// Every partition node taken off the list and freed.
pub fn freePartitions(handle: *Handle) void {
    const sys = handle.sys;
    while (sys.RemHead(&handle.public.partitions)) |node| sys.FreeVec(node);
}

/// Every file system node taken off the list and freed, with any code it
/// held.
pub fn freeFileSystems(handle: *Handle) void {
    const sys = handle.sys;
    while (sys.RemHead(&handle.public.file_systems)) |node| freeFileSys(sys, @fieldParentPtr("node", node));
}

/// One file system node freed, off its list already.
pub fn freeFileSys(sys: *ExecBase, file_system: *rdb.RDBFileSystem) void {
    const node = fileSysOf(file_system);
    sys.FreeVec(node.image);
    sys.FreeVec(node);
}

/// A new file system node at the end of the list, holding `header`; null
/// for no memory.
pub fn appendFileSys(handle: *Handle, at: u32, header: *const hardblocks.FileSysHeaderBlock) ?*FileSys {
    const sys = handle.sys;
    const memory = sys.AllocVec(@sizeOf(FileSys), exec.MEMF_CLEAR) orelse return null;
    const node: *FileSys = @ptrCast(@alignCast(memory));
    node.* = .{ .public = .{ .at = at, .header = header.* } };
    sys.AddTail(&handle.public.file_systems, &node.public.node);
    return node;
}

/// The handler a load file holds, by its ROM tag: its name and version,
/// or null for code that is not a handler's load file for this machine.
pub fn handlerIn(code: []const u8) ?loadfile.HandlerTag {
    var bytes = loadfile.Bytes{ .data = code };
    const source = bytes.source();
    const found = loadfile.findResident(source) orelse return null;
    var tag: loadfile.HandlerTag = .{};
    if (!loadfile.readHandler(source, found, &tag)) return null;
    return tag;
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

/// A whole block read into the buffer: its bytes, until the next
/// transfer, or null when it could not be read.
pub fn readWhole(handle: *Handle, block: u32) ?[]u8 {
    const buffer = handle.buffer orelse return null;
    if (!command(handle, exec.CMD_READ, block, buffer)) return null;
    return buffer[0..blockBytes(handle)];
}

/// A structure written as the start of a block, zeroes after it; the
/// block erased first on a medium that wants it. Whether it was done.
pub fn writeBlock(handle: *Handle, block: u32, from: anytype) bool {
    const buffer = handle.buffer orelse return false;
    const size = @sizeOf(@TypeOf(from.*));
    @memset(buffer[0..blockBytes(handle)], 0);
    const bytes: [*]const u8 = @ptrCast(from);
    @memcpy(buffer[0..size], bytes[0..size]);
    return writeBuffer(handle, block);
}

/// The buffer, as it is, written to a block, erased first on a medium
/// that wants it. Whether it was done.
pub fn writeBuffer(handle: *Handle, block: u32) bool {
    const buffer = handle.buffer orelse return false;
    if (handle.public.geometry.erase_size != 0 and !command(handle, trackdisk.TDCMD_ERASE, block, null)) return false;
    return command(handle, exec.CMD_WRITE, block, buffer);
}

/// A block wiped: erased on a medium that erases, written with zeroes on
/// any other. Whether it was done.
pub fn clearBlock(handle: *Handle, block: u32) bool {
    const buffer = handle.buffer orelse return false;
    if (handle.public.geometry.erase_size != 0) return command(handle, trackdisk.TDCMD_ERASE, block, null);
    @memset(buffer[0..blockBytes(handle)], 0);
    return command(handle, exec.CMD_WRITE, block, buffer);
}

/// TD_CHANGENUM: how often the unit's medium has changed, or 0 from a
/// device that does not count.
pub fn changeNum(handle: *Handle) u32 {
    const io = handle.io orelse return 0;
    io.req.command = trackdisk.TD_CHANGENUM;
    io.offset = 0;
    io.length = 0;
    io.data = null;
    io.actual = 0;
    if (handle.sys.DoIO(&io.req) != 0) return 0;
    return @truncate(io.actual);
}

/// Whether the medium in the unit is another than the table was read
/// from.
pub fn changed(handle: *Handle) bool {
    return changeNum(handle) != handle.public.change_num;
}

/// CMD_UPDATE: what the device still holds written out to the medium.
/// Whether it was; a device that holds nothing back and does not know
/// the command has nothing to write.
pub fn update(handle: *Handle) bool {
    const io = handle.io orelse return false;
    io.req.command = exec.CMD_UPDATE;
    io.offset = 0;
    io.length = 0;
    io.data = null;
    io.actual = 0;
    const err = handle.sys.DoIO(&io.req);
    return err == 0 or err == exec.IOERR_NOCMD;
}

// --- reading the table ----------------------------------------------------------

/// The disk's table read into the handle: the lowest sound RigidDiskBlock
/// in the first blocks, as every reader takes it, the partitions on its
/// chain, and the blocks of the chains the library leaves alone; every
/// other sound RigidDiskBlock there noted. Answers RDBERR_OK or
/// RDBERR_NOMEM; a disk with no table, or a broken one, is said in the
/// handle's flags.
pub fn readTable(handle: *Handle) i32 {
    const public = &handle.public;
    const geometry = &public.geometry;
    var block: u32 = 0;
    while (block < hardblocks.RDB_LOCATION_LIMIT and block < geometry.total_sectors) : (block += 1) {
        var found: hardblocks.RigidDiskBlock = undefined;
        if (!readBlock(handle, block, &found)) continue;
        if (!hardblocks.sound(&found, hardblocks.IDNAME_RIGIDDISK)) continue;
        const first = handle.tables.lowest() == no_block;
        handle.tables.add(block);
        if (!first) continue;
        // The block numbers in it count another size of block.
        if (found.block_bytes != geometry.sector_size) {
            public.flags |= rdb.RDBF_FOREIGN;
            continue;
        }
        public.rdb = found;
        public.block = block;
        public.flags |= rdb.RDBF_FOUND;
        handle.has_table = true;
    }
    if (!handle.has_table) return rdb.RDBERR_OK;
    handle.file_sys_list = public.rdb.file_sys_header_list;

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

    if (readFileSystems(handle) != rdb.RDBERR_OK) return rdb.RDBERR_NOMEM;
    keepChain(handle, public.rdb.bad_block_list, hardblocks.IDNAME_BADBLOCK);
    keepChain(handle, public.rdb.drive_init, hardblocks.IDNAME_LOADSEG);
    return rdb.RDBERR_OK;
}

/// The most file systems a table's chain is followed for.
pub const max_file_systems = 16;

/// The most blocks one file system's code is followed through: a chain
/// longer than this is taken for a ring.
pub const max_code_blocks = 1 << 16;

/// A node for every sound FileSysHeaderBlock on the table's chain, with
/// its code measured, and their blocks noted. A chain that breaks marks
/// the table damaged, and a header whose code breaks is left out.
/// Answers RDBERR_OK or RDBERR_NOMEM.
fn readFileSystems(handle: *Handle) i32 {
    var next = handle.public.rdb.file_sys_header_list;
    var seen: u32 = 0;
    while (next != hardblocks.end_of_list) : (seen += 1) {
        var header: hardblocks.FileSysHeaderBlock = undefined;
        if (seen == max_file_systems or !readBlock(handle, next, &header) or
            !hardblocks.sound(&header, hardblocks.IDNAME_FILESYSHEADER))
        {
            handle.public.flags |= rdb.RDBF_DAMAGED;
            return rdb.RDBERR_OK;
        }
        const at = next;
        next = header.next;
        var size: u32 = 0;
        var blocks: u32 = 0;
        if (!measureCode(handle, @bitCast(header.seg_list_blocks), &size, &blocks)) {
            handle.public.flags |= rdb.RDBF_DAMAGED;
            continue;
        }
        const node = appendFileSys(handle, at, &header) orelse return rdb.RDBERR_NOMEM;
        node.public.size = size;
        node.public.blocks = blocks;
        handle.stored.add(at);
    }
    return rdb.RDBERR_OK;
}

/// The bytes and blocks of a chain of LoadSegBlocks, its blocks noted in
/// `stored`; false for an empty chain or one that breaks.
fn measureCode(handle: *Handle, first: u32, size: *u32, blocks: *u32) bool {
    var next = first;
    size.* = 0;
    blocks.* = 0;
    while (next != hardblocks.end_of_list) {
        if (blocks.* == max_code_blocks or next >= handle.public.geometry.total_sectors) return false;
        const block = readWhole(handle, next) orelse return false;
        const data = hardblocks.loadSegData(block) orelse return false;
        handle.stored.add(next);
        size.* += @intCast(data.len);
        blocks.* += 1;
        next = nextOf(block);
    }
    return blocks.* != 0;
}

/// A LoadSegBlock's next block, from its bytes.
pub fn nextOf(block: []const u8) u32 {
    const at = @offsetOf(hardblocks.LoadSegBlock, "next");
    return @as(u32, block[at]) | @as(u32, block[at + 1]) << 8 | @as(u32, block[at + 2]) << 16 | @as(u32, block[at + 3]) << 24;
}

/// A file system's code into `into`, as far as it goes: from the copy
/// AddFileSystem made, or read from the disk's chain. The bytes put
/// there, or null when the chain breaks before `into` is full.
pub fn readCode(handle: *Handle, file_system: *rdb.RDBFileSystem, into: []u8) ?u32 {
    if (fileSysOf(file_system).image) |image| {
        const length = @min(into.len, file_system.size);
        @memcpy(into[0..length], image[0..length]);
        return @intCast(length);
    }
    var next: u32 = @bitCast(file_system.header.seg_list_blocks);
    var done: u32 = 0;
    var seen: u32 = 0;
    while (done < into.len and next != hardblocks.end_of_list) : (seen += 1) {
        if (seen == max_code_blocks) return null;
        const block = readWhole(handle, next) orelse return null;
        const data = hardblocks.loadSegData(block) orelse return null;
        const length = @min(data.len, into.len - done);
        @memcpy(into[done..][0..length], data[0..length]);
        done += @intCast(length);
        next = nextOf(block);
    }
    return if (done == into.len) done else null;
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

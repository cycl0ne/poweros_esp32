// SPDX-License-Identifier: MIT
//! WriteRDB: a handle's table checked and put on the disk.
//!
//! **Where the blocks go.** Every reader of a disk takes the lowest sound
//! RigidDiskBlock of the first RDB_LOCATION_LIMIT blocks, and follows its
//! chains. The new table is put down beside the old one: its file
//! systems' headers and new code, its PartitionBlocks and its
//! RigidDiskBlock go in blocks the old table is not in, and only then are
//! the old RigidDiskBlock and any other one wiped. Whichever of the two
//! is lower, a reader finds a whole table at every point: the old one
//! until the new is written below it or the old is wiped above it, the
//! new one after. Where the table's area has no block to spare for that,
//! the RigidDiskBlock is written over the old one. A map of the blocks
//! (area.zig) says which are free, which are the old table's and which
//! stay as they are.
//!
//! **Code.** A file system whose code is on the disk keeps its chain of
//! LoadSegBlocks where it is, and gets a new header that points at it;
//! code AddFileSystem gave is written as a new chain. The headers are
//! new every time, since each one points at the next. Code that does not
//! fit in the table's area goes after it, up to the first partition, and
//! the area grows over it.

const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const hardblocks = sdk.dos.hardblocks;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");
const _partition = @import("../partition/_partition.zig");
const Area = @import("area.zig").Area;

const Handle = _handle.Handle;
const no_block = _handle.no_block;

/// Checks a handle's table and writes it to the disk: the code of its
/// file systems, a FileSysHeaderBlock per file system, a PartitionBlock
/// per partition, then the RigidDiskBlock.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteRDB(base: *RDBBase, handle: *rdb.RDBHandle) i32
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `handle`: from OpenRDB, with a table (RDBF_FOUND, or after InitRDB).
///
/// RESULT:
/// RDBERR_OK when all of it is on the disk. Before anything is written:
/// RDBERR_NORDB for a handle with no table; RDBERR_BLOCKSIZE for a medium
/// whose erase unit is larger than its blocks, where erasing one block
/// would take its neighbours with it; RDBERR_CHANGED when the medium in
/// the unit is not the one the table was read from; RDBERR_NAME for a
/// partition whose name is empty, too long, holds a colon or a slash, or
/// is another's; RDBERR_RANGE for one whose cylinders are outside the
/// table's usable ones, the wrong way round or another's; RDBERR_FULL for
/// more partitions than the table's own blocks hold, more than 16 file
/// systems, or code that does not fit even with the area grown up to the
/// first partition; RDBERR_NOMEM; RDBERR_IO when a block of the disk's
/// chain of file systems cannot be read. RDBERR_IO when the device
/// refused a write, part of the way through.
///
/// BEHAVIOR:
/// Every partition is checked first, as AddPartition checks a new one,
/// since the program may have changed any of them. Each then gets a
/// block in the table's own area (`rdb_blocks_lo` to `rdb_blocks_hi`),
/// never one of the code the table keeps or of the bad-block list, and so
/// does the RigidDiskBlock, in one of the first RDB_LOCATION_LIMIT
/// blocks. Each file system gets a block for its header, and code that
/// AddFileSystem gave a LoadSegBlock per piece: in the area, or past it
/// up to the first partition's cylinder (on a table with no partition,
/// up to its last cylinder). Blocks the disk's table is not in are taken
/// first. Where the code reaches past the area, `rdb_blocks_hi` grows to
/// the end of the cylinder it reaches into and `lo_cylinder` to the next
/// one; the area never shrinks.
///
/// The new code is written first, as chains of LoadSegBlocks, then the
/// FileSysHeaderBlocks in the list's order, chained the same way, then
/// the PartitionBlocks in the list's order, chained the same way, each
/// with its checksum, then the RigidDiskBlock pointing at the first of
/// each; then every other RigidDiskBlock in the first blocks is wiped,
/// the one the disk's readers took until now last. A reader takes the
/// lowest sound RigidDiskBlock, so whichever of the old and the new is
/// lower, the disk holds a whole table at every point of the write: the
/// old one until the new replaces it, the new one after. A medium that
/// wants erasing has each block erased before it is written, and a wiped
/// block erased; on any other a wiped block is written with zeroes.
/// CMD_UPDATE ends it, so a device that holds writes back has them on the
/// medium when the call returns.
///
/// Afterwards `block` is the RigidDiskBlock's, each partition's and each
/// file system's `at` is its block, a file system's `blocks` counts its
/// code's, the copies AddFileSystem made are freed, RDBF_FOUND is set and
/// RDBF_CHANGED, RDBF_DAMAGED and RDBF_FOREIGN are cleared.
///
/// Nothing but the table's blocks is written: what is on a partition's
/// cylinders stays, whatever the table now says of them.
///
/// CONTEXT:
/// - Waits: yes, on the device.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the task that opened the handle.
///
/// OWNERSHIP:
/// The handle stays the caller's.
///
/// NOTES:
/// A drive mounted from a partition keeps the cylinders it was mounted
/// with until the system starts again: changing a partition's cylinders
/// or file system under its drive leaves the drive on the old ones.
/// Inhibit the drive first, and restart once the table is written.
///
/// After RDBERR_IO the handle no longer says what the disk holds: close
/// it, and open the unit again to see.
///
/// BUGS:
/// Where the table's area has no block to spare, the RigidDiskBlock is
/// written over the old one, and on a medium that erases, a cut between
/// that block's erase and its write leaves the disk without a table. A
/// write that fails after the first PartitionBlock that had to reuse a
/// block of the old chain can leave the old table pointing at a new
/// block; so can new code that had to go in the old table's blocks. Code
/// that goes past the area is written over the first blocks of a
/// partition that the old table had there.
///
/// SEE ALSO:
/// `OpenRDB`, `InitRDB`, `AddPartition`, `RemPartition`, `MountPartition`
///
/// EXAMPLES:
/// ```zig
/// const err = rb.WriteRDB(handle);
/// if (err != rdb.RDBERR_OK) _ = Printf(dl, "not written (%ld)\n", .{err});
/// ```
pub fn WriteRDB(_: *RDBBase, handle: *rdb.RDBHandle) i32 {
    const private = _handle.handleOf(handle);
    if (!private.has_table) return rdb.RDBERR_NORDB;
    const geometry = &handle.geometry;
    if (geometry.erase_size != 0 and geometry.sector_size % geometry.erase_size != 0) return rdb.RDBERR_BLOCKSIZE;
    if (_handle.changed(private)) return rdb.RDBERR_CHANGED;

    var walk = _partition.Partitions.of(handle);
    var partitions: u32 = 0;
    while (walk.next()) |part| : (partitions += 1) {
        const name = _partition.driveName(part);
        if (!_partition.validName(name) or _partition.named(handle, name, part) != null) return rdb.RDBERR_NAME;
        const env = &part.block.environment;
        if (!_partition.rangeFree(handle, env.low_cyl, env.high_cyl, part)) return rdb.RDBERR_RANGE;
    }
    if (partitions > _partition.blocksFor(private)) return rdb.RDBERR_FULL;
    var file_systems: u32 = 0;
    var code_blocks: u32 = 0;
    var fs_walk = FileSystems.of(handle);
    while (fs_walk.next()) |file_system| : (file_systems += 1) code_blocks += newBlocks(private, file_system);
    if (file_systems > _handle.max_file_systems) return rdb.RDBERR_FULL;

    var err: i32 = rdb.RDBERR_OK;
    var map = Area.make(private, &err) orelse return err;
    defer map.free();
    const code_memory = if (code_blocks == 0) null else private.sys.AllocVec(code_blocks * @sizeOf(u32), 0) orelse return rdb.RDBERR_NOMEM;
    defer private.sys.FreeVec(code_memory);
    var layout: Layout = .{ .code = if (code_memory) |memory| @as([*]u32, @ptrCast(@alignCast(memory)))[0..code_blocks] else &.{} };

    // The RigidDiskBlock a reader takes now, which stays until the new
    // table is down: nothing else goes in its block.
    const current = private.tables.lowest();
    map.hold(current);
    if (!lay(&map, handle, current, true, partitions, &layout)) {
        map.reset();
        if (current == no_block or !lay(&map, handle, current, false, partitions, &layout)) return rdb.RDBERR_FULL;
    }

    // The new code first, then the headers that point at it, then the
    // partitions: none of it is reached from the disk's table.
    var piece: u32 = 0;
    fs_walk = FileSystems.of(handle);
    while (fs_walk.next()) |file_system| {
        const image = _handle.fileSysOf(file_system).image orelse continue;
        const blocks = newBlocks(private, file_system);
        if (!writeCode(private, image[0..file_system.size], layout.code[piece..][0..blocks])) return rdb.RDBERR_IO;
        file_system.header.seg_list_blocks = @bitCast(layout.code[piece]);
        piece += blocks;
    }
    fs_walk = FileSystems.of(handle);
    var index: u32 = 0;
    while (fs_walk.next()) |file_system| : (index += 1) {
        const header = &file_system.header;
        header.id = hardblocks.IDNAME_FILESYSHEADER;
        header.summed_longs = @sizeOf(hardblocks.FileSysHeaderBlock) / 4;
        header.next = if (index + 1 < file_systems) layout.headers[index + 1] else hardblocks.end_of_list;
        header.checksum = hardblocks.checksumOf(header);
        if (!_handle.writeBlock(private, layout.headers[index], header)) return rdb.RDBERR_IO;
    }

    var on_disk: _handle.BlockMap = .{};
    walk = _partition.Partitions.of(handle);
    index = 0;
    while (walk.next()) |part| : (index += 1) {
        const block = &part.block;
        block.id = hardblocks.IDNAME_PARTITION;
        block.summed_longs = @sizeOf(hardblocks.PartitionBlock) / 4;
        block.next = if (index + 1 < partitions) layout.parts[index + 1] else hardblocks.end_of_list;
        block.drive_name[block.drive_name.len - 1] = 0;
        block.checksum = hardblocks.checksumOf(block);
        if (!_handle.writeBlock(private, layout.parts[index], block)) return rdb.RDBERR_IO;
        part.at = layout.parts[index];
        on_disk.add(layout.parts[index]);
    }

    const table = &handle.rdb;
    table.id = hardblocks.IDNAME_RIGIDDISK;
    table.summed_longs = @sizeOf(hardblocks.RigidDiskBlock) / 4;
    table.block_bytes = geometry.sector_size;
    table.partition_list = if (partitions != 0) layout.parts[0] else hardblocks.end_of_list;
    table.file_sys_header_list = if (file_systems != 0) layout.headers[0] else hardblocks.end_of_list;
    grow(table, map.used());
    table.checksum = hardblocks.checksumOf(table);
    if (!_handle.writeBlock(private, layout.table_block, table)) return rdb.RDBERR_IO;

    // Every other RigidDiskBlock wiped, the one readers took until now
    // last: one between it and the new one would be taken in between.
    var other: u32 = 0;
    while (other < hardblocks.RDB_LOCATION_LIMIT) : (other += 1) {
        if (!private.tables.has(other) or other == current or other == layout.table_block or map.taken(other)) continue;
        if (!_handle.clearBlock(private, other)) return rdb.RDBERR_IO;
    }
    if (current != no_block and current != layout.table_block and !_handle.clearBlock(private, current)) return rdb.RDBERR_IO;
    if (!_handle.update(private)) return rdb.RDBERR_IO;

    // What the handle says of the disk, now the disk holds the new table.
    var stored: _handle.BlockMap = .{};
    var block: u32 = 0;
    while (block < _handle.mapped_blocks) : (block += 1) {
        if (map.isCode(block)) stored.add(block);
    }
    for (layout.code) |code_block| stored.add(code_block);
    fs_walk = FileSystems.of(handle);
    index = 0;
    while (fs_walk.next()) |file_system| : (index += 1) {
        file_system.at = layout.headers[index];
        stored.add(file_system.at);
        const node = _handle.fileSysOf(file_system);
        if (node.image) |image| {
            file_system.blocks = newBlocks(private, file_system);
            private.sys.FreeVec(image);
            node.image = null;
        }
    }
    handle.block = layout.table_block;
    private.tables = .{};
    private.tables.add(layout.table_block);
    private.on_disk = on_disk;
    private.stored = stored;
    private.file_sys_list = table.file_sys_header_list;
    handle.flags |= rdb.RDBF_FOUND;
    handle.flags &= ~(rdb.RDBF_CHANGED | rdb.RDBF_DAMAGED | rdb.RDBF_FOREIGN);
    return rdb.RDBERR_OK;
}

/// Where each block of the new table goes.
const Layout = struct {
    /// The RigidDiskBlock's.
    table_block: u32 = no_block,
    /// One per partition, in list order.
    parts: [_handle.mapped_blocks]u32 = undefined,
    /// One header per file system, in list order.
    headers: [_handle.max_file_systems]u32 = undefined,
    /// The new code's LoadSegBlocks, the file systems' in list order and
    /// each one's in chain order.
    code: []u32,
};

/// The blocks of the new table taken in the map: the RigidDiskBlock's -
/// a fresh one of the first blocks with `fresh`, the disk's own without -
/// then a block of the table's area per partition, then a block per file
/// system header and per LoadSegBlock of new code, in the area or after
/// it up to the first partition. Free blocks are taken before the disk's
/// table's. Whether all of it found room.
fn lay(map: *Area, handle: *rdb.RDBHandle, current: u32, fresh: bool, partitions: u32, layout: *Layout) bool {
    const private = _handle.handleOf(handle);
    layout.table_block = if (fresh) map.take(@min(map.end, hardblocks.RDB_LOCATION_LIMIT), false) else current;
    if (layout.table_block == no_block) return false;
    const partition_end = @min(map.end, _handle.mapped_blocks);
    for (layout.parts[0..partitions]) |*part| {
        part.* = map.take(partition_end, true);
        if (part.* == no_block) return false;
    }
    var walk = FileSystems.of(handle);
    var index: usize = 0;
    var piece: usize = 0;
    while (walk.next()) |file_system| : (index += 1) {
        layout.headers[index] = map.take(map.grow_to, true);
        if (layout.headers[index] == no_block) return false;
        for (layout.code[piece..][0..newBlocks(private, file_system)]) |*code_block| {
            code_block.* = map.take(map.grow_to, true);
            if (code_block.* == no_block) return false;
        }
        piece += newBlocks(private, file_system);
    }
    return true;
}

/// How many LoadSegBlocks a file system's code takes that WriteRDB has
/// to write: none for code on the disk already.
fn newBlocks(handle: *Handle, file_system: *rdb.RDBFileSystem) u32 {
    if (_handle.fileSysOf(file_system).image == null) return 0;
    const room = hardblocks.loadSegRoom(_handle.blockBytes(handle));
    return (file_system.size + room - 1) / room;
}

/// A file system's code written as a chain of LoadSegBlocks into
/// `blocks`, in order. Whether it was.
fn writeCode(handle: *Handle, code: []const u8, blocks: []const u32) bool {
    const buffer = handle.buffer orelse return false;
    const bytes = _handle.blockBytes(handle);
    const room = hardblocks.loadSegRoom(bytes);
    for (blocks, 0..) |block, index| {
        const from = index * room;
        const piece = code[from..@min(from + room, code.len)];
        const next = if (index + 1 < blocks.len) blocks[index + 1] else hardblocks.end_of_list;
        hardblocks.makeLoadSeg(buffer[0..bytes], piece, next);
        if (!_handle.writeBuffer(handle, block)) return false;
    }
    return true;
}

/// The table's area grown to end past `used`, at the end of a cylinder,
/// and the usable cylinders starting after it; a table whose area holds
/// it already unchanged.
fn grow(table: *hardblocks.RigidDiskBlock, used: u32) void {
    if (used <= table.rdb_blocks_hi + 1) return;
    if (table.cyl_blocks == 0) {
        table.rdb_blocks_hi = used - 1;
        return;
    }
    const cylinders = (used + table.cyl_blocks - 1) / table.cyl_blocks;
    table.lo_cylinder = @max(table.lo_cylinder, cylinders);
    table.rdb_blocks_hi = @intCast(@min(@as(u64, table.lo_cylinder) * table.cyl_blocks, 0xFFFF_FFFF) - 1);
}

/// A walk along the handle's file systems.
const FileSystems = struct {
    node: ?*exec.Node,

    fn of(handle: *rdb.RDBHandle) FileSystems {
        return .{ .node = handle.file_systems.first() };
    }

    fn next(walk: *FileSystems) ?*rdb.RDBFileSystem {
        const node = walk.node orelse return null;
        walk.node = node.next();
        return @fieldParentPtr("node", node);
    }
};

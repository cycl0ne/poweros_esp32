// SPDX-License-Identifier: MIT
//! Where WriteRDB puts the new table's blocks: a map of the start of the
//! disk, a byte per block, made for one write.
//!
//! Each block of the map is free; the disk's table's (`old`: its
//! partition chain and its file systems' headers and code), taken only
//! when nothing free is left; one that stays as it is
//! (`keep`: below the table's area, or on a chain the library leaves
//! alone); the code of a file system on the disk that the new table keeps
//! (`code`, which stays where it is); or taken for the new table, from a
//! free block or an old one. Taking the free blocks first keeps the old
//! table whole while the new one is written beside it. The RigidDiskBlock
//! a reader takes now is held by WriteRDB, so nothing goes in it; any
//! other one in the first blocks is free, since no reader takes it while
//! that one is there, and it is wiped once the new table is down.
//!
//! The map covers the table's area and the blocks after it up to the
//! first partition (`grow_to`): the code of a file system that does not
//! fit in the area goes there, and the area grows over it. The disk's
//! chain of file systems is read to fill the map in, so blocks past the
//! 256 the handle's own maps cover are known too.

const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const hardblocks = sdk.dos.hardblocks;
const _handle = @import("../handle/_handle.zig");

const Handle = _handle.Handle;
const no_block = _handle.no_block;

/// The most blocks the map covers: the area does not grow past them.
pub const max_area_blocks = 1 << 14;

pub const State = enum(u8) { free, old, keep, code, taken_free, taken_old };

pub const Area = struct {
    handle: *Handle,
    states: []State,
    /// The table's area: `low` to `end`, rdb_blocks_lo to past
    /// rdb_blocks_hi, as far as the map covers it.
    low: u32,
    end: u32,
    /// The first block a file system's code may not go in: the first
    /// partition's, or the last cylinder's on a table with none.
    grow_to: u32,

    /// The map of the handle's disk, or null for no memory or a chain of
    /// the disk that cannot be read (in `err`: RDBERR_NOMEM, RDBERR_IO).
    pub fn make(handle: *Handle, err: *i32) ?Area {
        const sys = handle.sys;
        const table = &handle.public.rdb;
        const total: u32 = @intCast(@min(handle.public.geometry.total_sectors, max_area_blocks));
        const end: u32 = @intCast(@min(@as(u64, table.rdb_blocks_hi) + 1, total));
        const grow_to: u32 = @intCast(@min(firstPartitionBlock(handle), total));
        const size = @max(end, grow_to);
        const memory = sys.AllocVec(@max(size, 1), exec.MEMF_CLEAR) orelse {
            err.* = rdb.RDBERR_NOMEM;
            return null;
        };
        const states: [*]State = @ptrCast(memory);
        var area: Area = .{
            .handle = handle,
            .states = states[0..size],
            .low = @min(table.rdb_blocks_lo, end),
            .end = end,
            .grow_to = grow_to,
        };
        var block: u32 = 0;
        while (block < size) : (block += 1) {
            if (block < area.low or handle.kept.has(block)) {
                area.states[block] = .keep;
            } else if (handle.on_disk.has(block)) {
                area.states[block] = .old;
            }
        }
        if (!area.markFileSystems()) {
            area.free();
            err.* = rdb.RDBERR_IO;
            return null;
        }
        return area;
    }

    pub fn free(area: *Area) void {
        area.handle.sys.FreeVec(area.states.ptr);
    }

    /// The disk's file systems marked: each header old, and its code old
    /// as well unless the handle keeps the file system as it is. False
    /// when a block of the chain cannot be read.
    fn markFileSystems(area: *Area) bool {
        const handle = area.handle;
        var next = handle.file_sys_list;
        var seen: u32 = 0;
        while (next != hardblocks.end_of_list and seen < _handle.max_file_systems) : (seen += 1) {
            var header: hardblocks.FileSysHeaderBlock = undefined;
            if (!_handle.readBlock(handle, next, &header)) return false;
            if (!hardblocks.sound(&header, hardblocks.IDNAME_FILESYSHEADER)) return true;
            area.mark(next, .old);
            const state: State = if (keptAt(handle, next) != null) .code else .old;
            if (!area.markCode(@bitCast(header.seg_list_blocks), state)) return false;
            next = header.next;
        }
        return true;
    }

    /// A chain of LoadSegBlocks marked, as far as it is sound. False when
    /// a block of it cannot be read.
    fn markCode(area: *Area, first: u32, state: State) bool {
        const handle = area.handle;
        var next = first;
        var seen: u32 = 0;
        while (next != hardblocks.end_of_list and seen < _handle.max_code_blocks) : (seen += 1) {
            if (next >= handle.public.geometry.total_sectors) return true;
            // A block met before is a ring, or another chain's.
            if (next < area.states.len and area.states[next] == state) return true;
            const block = _handle.readWhole(handle, next) orelse return false;
            if (hardblocks.loadSegData(block) == null) return true;
            area.mark(next, state);
            next = _handle.nextOf(block);
        }
        return true;
    }

    /// A block's state set, where the map covers it and leaves it to be
    /// changed: a block to keep stays kept.
    fn mark(area: *Area, block: u32, state: State) void {
        if (block >= area.states.len or area.states[block] == .keep) return;
        area.states[block] = state;
    }

    /// The lowest block from `low` to `to` that is free - or, with
    /// `old_too` and none free, the disk's table's - taken; `no_block`
    /// for none.
    pub fn take(area: *Area, to: u32, old_too: bool) u32 {
        const limit = @min(to, @as(u32, @intCast(area.states.len)));
        for ([_]State{ .free, .old }) |wanted| {
            if (wanted == .old and !old_too) break;
            var block = area.low;
            while (block < limit) : (block += 1) {
                if (area.states[block] != wanted) continue;
                area.states[block] = if (wanted == .free) .taken_free else .taken_old;
                return block;
            }
        }
        return no_block;
    }

    /// A particular block taken: false for one that is not free or old.
    pub fn takeBlock(area: *Area, block: u32) bool {
        if (block >= area.states.len) return false;
        area.states[block] = switch (area.states[block]) {
            .free => .taken_free,
            .old => .taken_old,
            else => return false,
        };
        return true;
    }

    /// A block no part of the new table may go in, where the map covers
    /// it.
    pub fn hold(area: *Area, block: u32) void {
        if (block < area.states.len) area.states[block] = .keep;
    }

    /// Whether a block was taken for the new table.
    pub fn taken(area: *const Area, block: u32) bool {
        if (block >= area.states.len) return false;
        return area.states[block] == .taken_free or area.states[block] == .taken_old;
    }

    /// Every block taken given back, as it was before.
    pub fn reset(area: *Area) void {
        for (area.states) |*state| {
            state.* = switch (state.*) {
                .taken_free => .free,
                .taken_old => .old,
                else => state.*,
            };
        }
    }

    /// One past the highest block taken or kept as code: where the area
    /// has to end for the new table.
    pub fn used(area: *const Area) u32 {
        var block: u32 = @intCast(area.states.len);
        while (block > 0) : (block -= 1) {
            switch (area.states[block - 1]) {
                .taken_free, .taken_old, .code => return block,
                else => {},
            }
        }
        return 0;
    }

    /// Whether a block holds code the new table keeps.
    pub fn isCode(area: *const Area, block: u32) bool {
        return block < area.states.len and area.states[block] == .code;
    }
};

/// The file system the handle keeps as the disk has it, by the block its
/// header is in: one on the list whose code is not a new copy.
pub fn keptAt(handle: *Handle, at: u32) ?*rdb.RDBFileSystem {
    var node = handle.public.file_systems.first();
    while (node) |it| : (node = it.next()) {
        const file_system: *rdb.RDBFileSystem = @fieldParentPtr("node", it);
        if (file_system.at == at and _handle.fileSysOf(file_system).image == null) return file_system;
    }
    return null;
}

/// The first block of the lowest partition on the handle's list, or of
/// the table's last cylinder when it has none: what the table's area may
/// grow to.
fn firstPartitionBlock(handle: *Handle) u64 {
    const table = &handle.public.rdb;
    var lowest: u64 = @as(u64, table.hi_cylinder) * table.cyl_blocks;
    var node = handle.public.partitions.first();
    while (node) |it| : (node = it.next()) {
        const part: *rdb.RDBPartition = @fieldParentPtr("node", it);
        lowest = @min(lowest, @as(u64, part.block.environment.low_cyl) * table.cyl_blocks);
    }
    return lowest;
}

// SPDX-License-Identifier: MIT
//! What the GPT calls share: the GPT read into the handle at OpenRDB, the
//! nodes of its partitions, the window onto its container, the checks a
//! partition's blocks go through, and new GUIDs.
//!
//! **Reading.** A disk whose first block is a protective MBR, or whose
//! second begins with a GPT header's signature, holds a GPT. The header
//! in block 1 and the entries it names are taken when both are sound, and
//! otherwise the copy in the disk's last block (`sdk.dos.gpt` says what
//! sound is); a GPT neither of whose copies is sound marks the handle
//! RDBF_GPTDAMAGED. The entries are read a block at a time, twice: once
//! for their crc32, then for a GPTPartition per used one, in the order of
//! the entries, whose blocks are checked against the others'. The first
//! container among them is the window the table is read through.
//!
//! **The window.** The container's first block is the handle's `window`
//! and `container`, and `geometry` counts the container's blocks, so the
//! RigidDiskBlock calls find, make and write a table inside it as they
//! would on a disk of that size; `disk_blocks` keeps the whole disk's.

const builtin = @import("builtin");
const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const gpt = sdk.dos.gpt;
const hardblocks = sdk.dos.hardblocks;
const _handle = @import("../handle/_handle.zig");

const Handle = _handle.Handle;

// --- reading ------------------------------------------------------------------

/// The disk's GPT read into the handle, when it has one, and the window
/// set on its first container. Answers RDBERR_OK or RDBERR_NOMEM; a GPT
/// that cannot be read, or none, is said in the handle's flags.
pub fn readGpt(handle: *Handle) i32 {
    const public = &handle.public;
    const blocks = public.disk_blocks;
    if (blocks < 4) return rdb.RDBERR_OK;
    const first = _handle.readAt(handle, 0) orelse return rdb.RDBERR_OK;
    const protective = gpt.protective(first);
    const second = _handle.readAt(handle, gpt.header_block) orelse return rdb.RDBERR_OK;
    if (!protective and !gpt.signed(second)) return rdb.RDBERR_OK;
    public.flags |= rdb.RDBF_GPT;
    handle.gpt_on_disk = true;

    for ([_]u64{ gpt.header_block, blocks - 1 }) |at| {
        const header = soundHeader(handle, at) orelse continue;
        public.gpt_header = header;
        switch (readEntries(handle)) {
            .sound => {},
            .unsound => {
                freeGptPartitions(handle);
                continue;
            },
            .no_memory => return rdb.RDBERR_NOMEM,
        }
        // The copy at the end is what is on the disk until WriteGPT puts
        // the first one back.
        if (at != gpt.header_block) public.flags |= rdb.RDBF_GPTCHANGED;
        var walk = Partitions.of(public);
        while (walk.next()) |part| {
            if (!gpt.isContainer(&part.entry)) continue;
            setWindow(handle, &part.entry);
            break;
        }
        return rdb.RDBERR_OK;
    }
    public.gpt_header = .{};
    public.flags |= rdb.RDBF_GPTDAMAGED;
    return rdb.RDBERR_OK;
}

/// The header in block `at` when it is sound and the crc32 of the
/// entries it names agrees, the entries read a block at a time.
fn soundHeader(handle: *Handle, at: u64) ?gpt.Header {
    const block = _handle.readAt(handle, at) orelse return null;
    const header = gpt.readHeader(block, at, handle.public.disk_blocks) orelse return null;
    var crc = gpt.EntriesCrc.of(&header);
    const count = gpt.entriesBlocks(&header, _handle.blockBytes(handle));
    var done: u64 = 0;
    while (done < count) : (done += 1) {
        const piece = _handle.readAt(handle, header.partition_entry_lba + done) orelse return null;
        crc.add(piece);
    }
    if (crc.end() != header.partition_entry_array_crc32) return null;
    return header;
}

const Entries = enum { sound, unsound, no_memory };

/// A node for every used entry of the handle's `gpt_header`, the entries
/// read a block at a time: `unsound` when one lies outside the usable
/// blocks, the wrong way round, or shares a block with another, or a
/// block cannot be read.
fn readEntries(handle: *Handle) Entries {
    const header = &handle.public.gpt_header;
    const per = gpt.entriesPerBlock(header, _handle.blockBytes(handle));
    const count = gpt.entriesBlocks(header, _handle.blockBytes(handle));
    var done: u64 = 0;
    var number: u32 = 1;
    while (done < count) : (done += 1) {
        const piece = _handle.readAt(handle, header.partition_entry_lba + done) orelse return .unsound;
        var slot: u32 = 0;
        while (slot < per and number <= header.number_of_partition_entries) : ({
            slot += 1;
            number += 1;
        }) {
            const entry = gpt.entryAt(header, piece, slot);
            if (!gpt.used(&entry)) continue;
            _ = appendGptPartition(handle, number, &entry) orelse return .no_memory;
        }
    }
    var walk = Partitions.of(&handle.public);
    while (walk.next()) |part| {
        if (!blocksFree(&handle.public, part.entry.starting_lba, part.entry.ending_lba, part)) return .unsound;
    }
    return .sound;
}

// --- the nodes ----------------------------------------------------------------

/// A new node for entry `number` (from 1), in its place on the list - the
/// list is in the order of the entries; null for no memory.
pub fn appendGptPartition(handle: *Handle, number: u32, entry: *const gpt.Entry) ?*rdb.GPTPartition {
    const sys = handle.sys;
    const memory = sys.AllocVec(@sizeOf(rdb.GPTPartition), exec.MEMF_CLEAR) orelse return null;
    const part: *rdb.GPTPartition = @ptrCast(@alignCast(memory));
    part.* = .{ .number = number, .entry = entry.* };
    var before: ?*exec.Node = null;
    var walk = Partitions.of(&handle.public);
    while (walk.next()) |other| {
        if (other.number > number) break;
        before = &other.node;
    }
    sys.Insert(&handle.public.gpt_partitions, &part.node, before);
    return part;
}

/// Every GPT partition node taken off the list and freed.
pub fn freeGptPartitions(handle: *Handle) void {
    const sys = handle.sys;
    while (sys.RemHead(&handle.public.gpt_partitions)) |node| sys.FreeVec(node);
}

/// The GPT partitions on the handle's list, in order.
pub const Partitions = struct {
    node: ?*exec.Node,

    pub fn of(handle: *rdb.RDBHandle) Partitions {
        return .{ .node = handle.gpt_partitions.first() };
    }

    pub fn next(walk: *Partitions) ?*rdb.GPTPartition {
        const node = walk.node orelse return null;
        walk.node = node.next();
        return @fieldParentPtr("node", node);
    }
};

/// Whether the handle's list has a container.
pub fn hasContainer(handle: *rdb.RDBHandle) bool {
    var walk = Partitions.of(handle);
    while (walk.next()) |part| {
        if (gpt.isContainer(&part.entry)) return true;
    }
    return false;
}

/// The lowest entry number no node has, or null when every entry the
/// GPT has room for is used.
pub fn freeNumber(handle: *rdb.RDBHandle) ?u32 {
    var number: u32 = 1;
    var walk = Partitions.of(handle);
    while (walk.next()) |part| {
        if (part.number != number) break;
        number += 1;
    }
    if (number > handle.gpt_header.number_of_partition_entries) return null;
    return number;
}

// --- blocks ---------------------------------------------------------------------

/// Whether blocks `first` to `last` may be a GPT partition's: the right
/// way round, inside the usable blocks, and none of them another
/// partition's (other than `except`).
pub fn blocksFree(handle: *rdb.RDBHandle, first: u64, last: u64, except: ?*const rdb.GPTPartition) bool {
    const header = &handle.gpt_header;
    if (first > last or first < header.first_usable_lba or last > header.last_usable_lba) return false;
    var walk = Partitions.of(handle);
    while (walk.next()) |part| {
        if (part == except) continue;
        if (first <= part.entry.ending_lba and part.entry.starting_lba <= last) return false;
    }
    return true;
}

pub const Run = struct { first: u64, last: u64 };

/// The longest run of usable blocks no partition has, its start on a
/// multiple of `gpt.alignment_bytes`; the first of them on a tie, null
/// when no aligned block is free.
pub fn largestFree(handle: *rdb.RDBHandle) ?Run {
    const header = &handle.gpt_header;
    const bytes = handle.geometry.sector_size;
    var best: ?Run = null;
    // A free run starts at the first usable block or just past a
    // partition, and ends before the nearest partition above it.
    var start: u64 = header.first_usable_lba;
    var walk = Partitions.of(handle);
    while (true) {
        const first = gpt.alignUp(start, bytes);
        if (first <= header.last_usable_lba and !inside(handle, first)) {
            var last = header.last_usable_lba;
            var others = Partitions.of(handle);
            while (others.next()) |part| {
                if (part.entry.starting_lba > first and part.entry.starting_lba - 1 < last) last = part.entry.starting_lba - 1;
            }
            if (best == null or last - first > best.?.last - best.?.first) best = .{ .first = first, .last = last };
        }
        const part = walk.next() orelse break;
        start = part.entry.ending_lba + 1;
    }
    return best;
}

/// Whether a block is one of a partition's.
fn inside(handle: *rdb.RDBHandle, block: u64) bool {
    var walk = Partitions.of(handle);
    while (walk.next()) |part| {
        if (part.entry.starting_lba <= block and block <= part.entry.ending_lba) return true;
    }
    return false;
}

// --- the window -----------------------------------------------------------------

/// The table read and written inside a container from now on: its first
/// block is the window, and `geometry` counts its blocks.
pub fn setWindow(handle: *Handle, entry: *const gpt.Entry) void {
    const public = &handle.public;
    const blocks = entry.ending_lba - entry.starting_lba + 1;
    handle.window = entry.starting_lba;
    public.container = entry.starting_lba;
    public.geometry.total_sectors = blocks;
    public.geometry.cylinders = cylindersOf(&public.geometry, blocks);
    public.flags |= rdb.RDBF_CONTAINER;
}

/// The table over the whole disk again: no window, and `geometry` the
/// disk's.
pub fn clearWindow(handle: *Handle) void {
    const public = &handle.public;
    handle.window = 0;
    public.container = 0;
    public.geometry.total_sectors = public.disk_blocks;
    public.geometry.cylinders = cylindersOf(&public.geometry, public.disk_blocks);
    public.flags &= ~rdb.RDBF_CONTAINER;
}

fn cylindersOf(geometry: *const sdk.devices.trackdisk.DriveGeometry, blocks: u64) u32 {
    const per = @max(geometry.cyl_sectors, 1);
    return @intCast(@min(blocks / per, 0xFFFF_FFFF));
}

/// The RigidDiskBlock table taken out of the handle: its partitions and
/// file systems freed and the disk's blocks it noted forgotten, so the
/// handle has no table until InitRDB makes one.
pub fn dropTable(handle: *Handle) void {
    const public = &handle.public;
    _handle.freePartitions(handle);
    _handle.freeFileSystems(handle);
    handle.has_table = false;
    handle.kept = .{};
    handle.stored = .{};
    handle.on_disk = .{};
    handle.tables = .{};
    handle.file_sys_list = hardblocks.end_of_list;
    public.rdb = .{};
    public.block = 0;
    public.flags &= ~(rdb.RDBF_FOUND | rdb.RDBF_DAMAGED | rdb.RDBF_FOREIGN);
    public.flags |= rdb.RDBF_CHANGED;
}

// --- GUIDs ----------------------------------------------------------------------

/// A new random GUID, for a disk or a partition. The host tests get one
/// from a count.
pub fn newGuid(handle: *Handle) gpt.Guid {
    var guid: gpt.Guid = undefined;
    if (builtin.is_test) {
        handle.guids_made += 1;
        for (&guid, 0..) |*byte, index| byte.* = @truncate(handle.guids_made *% 37 +% index);
    } else {
        sdk.hardware.rng.fill(&guid);
    }
    gpt.markRandom(&guid);
    return guid;
}

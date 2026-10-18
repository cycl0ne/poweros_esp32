// SPDX-License-Identifier: MPL-2.0
//! Which blocks of a posfs volume are free, and handing them out.
//!
//! **The bitmap** has a bit a block, 1 for used, in groups of a block's
//! bits (32768 blocks a group at 4 KiB). Each group's bits are a block of
//! their own, or - when they are few, as on a small volume - the data of
//! their item in the space tree; the item (`Bmap`) says where, how many
//! are free, and the bits' crc. The space tree is a tree like the object
//! tree, with one item a group, and it never changes shape.
//!
//! **What may be given out** is a block whose bit is clear and that no
//! one holds. A block is held (`h`, a second set of bits beside a loaded
//! group's) while it is:
//!
//! - in flight: a journal block, or data written for a file not yet
//!   committed - nothing durable names it, so its bit stays clear;
//! - freed in this interval or the one before (`f0`, `f1`): the newest
//!   checkpoint, or the one before it that mount falls back to, may still
//!   name it. A freed block comes back after the second checkpoint.
//!
//! **A checkpoint writes the bitmap** without asking for blocks it then has
//! to write the bitmap for: every new home for a bitmap block or a space
//! tree node comes from groups that are being written anyway, counted
//! before one is taken (`writeSpace`). The homes they leave are freed after
//! the checkpoint is durable, as the next interval's frees; a mount works
//! the same set out again from the previous checkpoint's space tree, so a
//! cut between the two loses nothing.
//!
//! **A pin** (`pin`, while a check reads the newest checkpoint over
//! several packets) keeps every block that checkpoint names from being
//! handed out: the frees that would come back go on being held until
//! `unpin`.
//!
//! **On flash** a block must be erased before it is written. `erased` has
//! a bit for each block known to be erased since it was last written, and
//! `volume.prepare` erases a block that is not. After a mount that was not
//! clean no block reading as erased is trusted to be.

const sdk = @import("sdk");
const posfs = sdk.dos.posfs;
const layout = posfs.layout;
const volume = @import("volume.zig");
const btree = @import("btree.zig");
const snapshots = @import("snapshots.zig");
const Volume = volume.Volume;
const Error = volume.Error;

/// A run of blocks.
pub const Run = struct { start: u64, count: u64 };

/// A list of runs that grows as needed.
pub const Runs = struct {
    items: []Run = &.{},
    len: usize = 0,

    pub fn append(runs: *Runs, vol: *Volume, run: Run) Error!void {
        if (runs.len > 0) {
            const last = &runs.items[runs.len - 1];
            if (last.start + last.count == run.start) {
                last.count += run.count;
                return;
            }
        }
        if (runs.len == runs.items.len) {
            const grown = try vol.allocSlice(Run, if (runs.items.len == 0) 16 else runs.items.len * 2);
            @memcpy(grown[0..runs.len], runs.items[0..runs.len]);
            vol.freeSlice(Run, runs.items);
            runs.items = grown;
        }
        runs.items[runs.len] = run;
        runs.len += 1;
    }

    pub fn slice(runs: *const Runs) []const Run {
        return runs.items[0..runs.len];
    }

    pub fn clear(runs: *Runs) void {
        runs.len = 0;
    }

    pub fn deinit(runs: *Runs, vol: *Volume) void {
        vol.freeSlice(Run, runs.items);
        runs.* = .{};
    }

    pub fn total(runs: *const Runs) u64 {
        var sum: u64 = 0;
        for (runs.slice()) |run| sum += run.count;
        return sum;
    }
};

pub const Group = struct {
    /// Where its bits are on the medium (0 for none, or in its item), the
    /// generation they were written in, and their crc.
    block: u64 = 0,
    gen: u64 = 0,
    crc: u32 = 0,
    /// Its blocks with a clear bit, held ones among them.
    free: u32 = 0,
    holds: u32 = 0,
    /// The blocks it covers.
    blocks: u32 = 0,
    /// Its bits, when loaded; the held ones, when any are.
    w: []u8 = &.{},
    h: []u8 = &.{},
    /// Its bits are its item's data.
    in_item: bool = false,
    /// Changed since the last checkpoint.
    dirty: bool = false,
};

pub const Space = struct {
    groups: []Group = &.{},
    group_blocks: u64 = 0,
    /// Where the next search for free blocks starts.
    cursor: u64 = 0,
    free_total: u64 = 0,
    holds_total: u64 = 0,
    /// Blocks promised to writes not yet committed.
    promised: u64 = 0,
    /// What only deletes and checkpoints may take.
    reserve: u64 = 0,
    /// Freed in this interval and the one before.
    f0: Runs = .{},
    f1: Runs = .{},
    /// Homes of the space tree's nodes and bitmaps that this checkpoint
    /// replaces, freed once it is durable.
    replaced: Runs = .{},
    /// Homes taken for this checkpoint's space metadata, handed out one by
    /// one.
    pool: Runs = .{},
    /// While pinned: the frees that came back since, still held.
    pinned: Runs = .{},
    pin: bool = false,
    /// flash: a bit per block known to be erased.
    erased: []u8 = &.{},
    /// Groups with bits in memory, of their own block.
    loaded: u32 = 0,
};

/// How many groups keep their bits in memory before a clean one is let go.
const max_loaded: u32 = 64;

// --- bits --------------------------------------------------------------------------

fn bit(bits: []const u8, at: u64) bool {
    if (bits.len == 0) return false;
    const index: usize = @intCast(at);
    return bits[index / 8] & (@as(u8, 1) << @intCast(index % 8)) != 0;
}

fn setBit(bits: []u8, at: u64, on: bool) void {
    const index: usize = @intCast(at);
    const mask = @as(u8, 1) << @intCast(index % 8);
    if (on) bits[index / 8] |= mask else bits[index / 8] &= ~mask;
}

/// The bytes a group's bits take.
fn groupBytes(group: *const Group) usize {
    return (@as(usize, group.blocks) + 7) / 8;
}

pub fn isErased(vol: *Volume, addr: u64) bool {
    return bit(vol.space.erased, addr);
}

pub fn setErased(vol: *Volume, addr: u64, on: bool) void {
    if (vol.space.erased.len == 0) return;
    setBit(vol.space.erased, addr, on);
}

/// The blocks that are not the pool's: the labels and the rings.
pub fn fixedBlock(vol: *const Volume, addr: u64) bool {
    const count = vol.block_count;
    return addr == 0 or addr >= count - 1 - layout.ring_blocks or addr <= layout.ring_blocks;
}

/// The blocks a group's bits stay inside an item for.
pub fn inItem(vol: *const Volume, blocks: u32) bool {
    return (blocks + 7) / 8 + @sizeOf(layout.Bmap) <= layout.itemMax(vol.block_size);
}

pub fn bmapKey(group: usize) layout.Key {
    return .{ .oid = 0, .kind = @intFromEnum(layout.Kind.bmap), .offset = group };
}

// --- setting up -----------------------------------------------------------------------

/// The groups of a volume of `vol.block_count` blocks, none loaded.
fn makeGroups(vol: *Volume) Error!void {
    const space = &vol.space;
    space.group_blocks = layout.groupBlocks(vol.block_size);
    const count: usize = @intCast((vol.block_count + space.group_blocks - 1) / space.group_blocks);
    space.groups = try vol.allocSlice(Group, count);
    for (space.groups, 0..) |*group, index| {
        const first = @as(u64, index) * space.group_blocks;
        const left = vol.block_count - first;
        group.* = .{ .blocks = @intCast(if (left < space.group_blocks) left else space.group_blocks) };
        group.in_item = inItem(vol, group.blocks);
    }
    if (vol.erase_size != 0) space.erased = try vol.alloc(@intCast((vol.block_count + 7) / 8));
    const pool = vol.block_count - 2 - 2 * layout.ring_blocks;
    space.reserve = @max(8, @min(64, pool / 32));
}

pub fn release(vol: *Volume) void {
    const space = &vol.space;
    for (space.groups) |*group| {
        vol.free(group.w);
        vol.free(group.h);
    }
    vol.freeSlice(Group, space.groups);
    space.f0.deinit(vol);
    space.f1.deinit(vol);
    space.replaced.deinit(vol);
    space.pool.deinit(vol);
    space.pinned.deinit(vol);
    vol.free(space.erased);
    space.* = .{};
}

/// The space of a new volume: everything free but the labels and the
/// rings, every group to be written at the first checkpoint.
pub fn format(vol: *Volume) Error!void {
    try makeGroups(vol);
    const space = &vol.space;
    for (space.groups) |*group| {
        group.w = try vol.alloc(if (group.in_item) groupBytes(group) else vol.block_size);
        if (!group.in_item) space.loaded += 1;
        group.free = group.blocks;
        group.dirty = true;
        space.free_total += group.blocks;
    }
    var addr: u64 = 0;
    while (addr < vol.block_count) : (addr += 1) {
        if (fixedBlock(vol, addr)) markUsed(vol, addr);
    }
    space.cursor = layout.ring_blocks + 1;
    // The space tree: an item a group, in a tree written at the first
    // checkpoint.
    try btree.create(vol, &vol.space_tree);
    for (space.groups, 0..) |*group, index| {
        // Built in the block for file data, which nothing reads while a
        // volume is made; an item is never larger than a block.
        const data = itemOf(group, vol.bounce);
        try btree.insert(vol, &vol.space_tree, bmapKey(index), data);
    }
}

/// The bytes of a group's item.
fn itemLen(group: *const Group) usize {
    return @sizeOf(layout.Bmap) + if (group.in_item) groupBytes(group) else 0;
}

/// A group's item: its Bmap, and its bits when they live there.
fn itemOf(group: *const Group, into: []u8) []const u8 {
    const bmap: layout.Bmap = .{ .block = group.block, .gen = group.gen, .free = group.free, .crc = group.crc };
    @memcpy(into[0..@sizeOf(layout.Bmap)], layout.bytesOf(&bmap));
    var len: usize = @sizeOf(layout.Bmap);
    if (group.in_item) {
        const bytes = groupBytes(group);
        @memcpy(into[len..][0..bytes], group.w[0..bytes]);
        len += bytes;
    }
    return into[0..len];
}

/// The space of the checkpoint mounted: the groups from the space tree,
/// and the homes the checkpoint before it left freed again.
pub fn load(vol: *Volume, slot: *const layout.CheckpointSlot) Error!void {
    try makeGroups(vol);
    const space = &vol.space;
    var key = bmapKey(0);
    var seen: usize = 0;
    while (try btree.seek(vol, &vol.space_tree, key)) |item| {
        if (item.key.kind != @intFromEnum(layout.Kind.bmap) or item.key.oid != 0) return error.Corrupt;
        if (item.key.offset >= space.groups.len or item.data.len < @sizeOf(layout.Bmap)) return error.Corrupt;
        const index: usize = @intCast(item.key.offset);
        const group = &space.groups[index];
        var bmap: layout.Bmap = undefined;
        @memcpy(layout.bytesOfMut(&bmap), item.data[0..@sizeOf(layout.Bmap)]);
        group.block = bmap.block;
        group.gen = bmap.gen;
        group.crc = bmap.crc;
        group.free = bmap.free;
        if (group.free > group.blocks) return error.Corrupt;
        if (group.in_item) {
            const bytes = groupBytes(group);
            if (item.data.len != @sizeOf(layout.Bmap) + bytes) return error.Corrupt;
            const bits = item.data[@sizeOf(layout.Bmap)..];
            if (layout.crcSeeded(&vol.uuid, bits) != group.crc) return error.Corrupt;
            group.w = try vol.alloc(bytes);
            @memcpy(group.w, bits);
        } else if (group.block == 0 or group.block >= vol.block_count) return error.Corrupt;
        space.free_total += group.free;
        seen += 1;
        key = btree.successor(item.key);
    }
    if (seen != space.groups.len) return error.Corrupt;
    space.cursor = slot.alloc_cursor;
    if (space.cursor >= vol.block_count) space.cursor = 0;
    try freeReplaced(vol, slot);
}

/// The metadata of the previous checkpoint's space tree that this one's
/// replaced: freed, as they would have been once this checkpoint was
/// durable.
fn freeReplaced(vol: *Volume, slot: *const layout.CheckpointSlot) Error!void {
    var replaced: Runs = .{};
    defer replaced.deinit(vol);
    try replacedBy(vol, slot, &replaced);
    for (replaced.slice()) |run| {
        var addr = run.start;
        while (addr < run.start + run.count) : (addr += 1) {
            if (isUsed(vol, addr)) try freeNow(vol, addr, 1);
        }
    }
}

/// The blocks of the previous checkpoint's space tree and bitmaps that
/// `slot`'s no longer name, sorted, into `into`. A damaged previous tree
/// gives none: it costs the few blocks it held, not the mount.
pub fn replacedBy(vol: *Volume, slot: *const layout.CheckpointSlot, into: *Runs) Error!void {
    if (slot.prev_space_root == 0) return;
    var current: Runs = .{};
    defer current.deinit(vol);
    var before: Runs = .{};
    defer before.deinit(vol);
    try metadataOf(vol, slot.space_root, slot.space_gen, &current);
    metadataOf(vol, slot.prev_space_root, slot.prev_space_gen, &before) catch |err| switch (err) {
        error.Corrupt, error.Io => return,
        else => return err,
    };
    sortRuns(current.items[0..current.len]);
    sortRuns(before.items[0..before.len]);
    // A run of the list may be several blocks: each is looked at.
    for (before.slice()) |run| {
        var addr = run.start;
        while (addr < run.start + run.count) : (addr += 1) {
            if (!containsBlock(current.slice(), addr)) try into.append(vol, .{ .start = addr, .count = 1 });
        }
    }
}

/// Every block a space tree's nodes and bitmaps take, a run each.
fn metadataOf(vol: *Volume, root: u64, gen: u64, into: *Runs) Error!void {
    var refs: [volume.max_height]u64 = undefined;
    var gens: [volume.max_height]u64 = undefined;
    var next: [volume.max_height]u32 = undefined;
    var depth: u32 = 0;
    const tree: btree.Tree = .{ .id = layout.tree_space };
    refs[0] = root;
    gens[0] = gen;
    next[0] = 0;
    try into.append(vol, .{ .start = root, .count = 1 });
    while (true) {
        const block = try btree.nodeAt(vol, &tree, refs[depth], gens[depth]);
        const header = btree.header(block);
        if (header.level == 0) {
            for (btree.leafEntries(block)) |entry| {
                const data = btree.itemData(block, entry);
                if (data.len < @sizeOf(layout.Bmap)) return error.Corrupt;
                const home = layout.getU64(data, 0);
                if (home != 0) try into.append(vol, .{ .start = home, .count = 1 });
            }
        } else {
            const entries = btree.innerEntries(block);
            if (next[depth] < entries.len) {
                const entry = entries[next[depth]];
                next[depth] += 1;
                if (depth + 1 >= volume.max_height) return error.Corrupt;
                try into.append(vol, .{ .start = entry.child, .count = 1 });
                depth += 1;
                refs[depth] = entry.child;
                gens[depth] = entry.child_gen;
                next[depth] = 0;
                continue;
            }
        }
        if (depth == 0) return;
        depth -= 1;
    }
}

fn sortRuns(runs: []Run) void {
    // Shell sort: no recursion, no library, and the lists are short.
    var gap = runs.len / 2;
    while (gap > 0) : (gap /= 2) {
        var at = gap;
        while (at < runs.len) : (at += 1) {
            const moving = runs[at];
            var to = at;
            while (to >= gap and runs[to - gap].start > moving.start) : (to -= gap) runs[to] = runs[to - gap];
            runs[to] = moving;
        }
    }
}

/// Whether a block is in one of a sorted list's runs.
pub fn containsBlock(sorted: []const Run, addr: u64) bool {
    var low: usize = 0;
    var high: usize = sorted.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (sorted[middle].start + sorted[middle].count <= addr) low = middle + 1 else high = middle;
    }
    return low < sorted.len and sorted[low].start <= addr;
}

// --- groups in memory -------------------------------------------------------------------

/// A group's bits, read in if they are not yet.
fn loadGroup(vol: *Volume, index: usize) Error!*Group {
    const space = &vol.space;
    const group = &space.groups[index];
    if (group.w.len != 0) return group;
    if (space.loaded >= max_loaded) letGo(vol);
    const bits = try vol.alloc(vol.block_size);
    errdefer vol.free(bits);
    try vol.readBlocks(group.block, bits);
    if (layout.crcSeeded(&vol.uuid, bits) != group.crc) return error.Corrupt;
    group.w = bits;
    space.loaded += 1;
    return group;
}

/// A clean group with nothing held let go of, to make room for another.
fn letGo(vol: *Volume) void {
    const space = &vol.space;
    for (space.groups) |*group| {
        if (group.in_item or group.dirty or group.holds != 0 or group.w.len == 0) continue;
        vol.free(group.w);
        group.w = &.{};
        vol.free(group.h);
        group.h = &.{};
        space.loaded -= 1;
        return;
    }
}

fn groupOf(vol: *const Volume, addr: u64) usize {
    return @intCast(addr / vol.space.group_blocks);
}

/// Whether block `addr`'s bit is set.
pub fn isUsed(vol: *Volume, addr: u64) bool {
    const index = groupOf(vol, addr);
    const group = loadGroup(vol, index) catch return true;
    return bit(group.w, addr - @as(u64, index) * vol.space.group_blocks);
}

fn markUsed(vol: *Volume, addr: u64) void {
    const space = &vol.space;
    const index = groupOf(vol, addr);
    const group = &space.groups[index];
    const at = addr - @as(u64, index) * space.group_blocks;
    if (bit(group.w, at)) return;
    setBit(group.w, at, true);
    group.free -= 1;
    space.free_total -= 1;
    group.dirty = true;
}

/// A block's bit cleared (the group is loaded).
fn markFree(vol: *Volume, addr: u64) void {
    const space = &vol.space;
    const index = groupOf(vol, addr);
    const group = &space.groups[index];
    const at = addr - @as(u64, index) * space.group_blocks;
    if (!bit(group.w, at)) return;
    setBit(group.w, at, false);
    group.free += 1;
    space.free_total += 1;
    group.dirty = true;
}

fn setHeld(vol: *Volume, addr: u64, on: bool) Error!void {
    const space = &vol.space;
    const index = groupOf(vol, addr);
    const group = &space.groups[index];
    const at = addr - @as(u64, index) * space.group_blocks;
    if (group.h.len == 0) {
        if (!on) return;
        group.h = try vol.alloc(groupBytes(group));
    }
    if (bit(group.h, at) == on) return;
    setBit(group.h, at, on);
    if (on) {
        group.holds += 1;
        space.holds_total += 1;
    } else {
        group.holds -= 1;
        space.holds_total -= 1;
    }
}

/// Whether block `addr` may be handed out.
fn allocatable(vol: *Volume, group: *const Group, index: usize, addr: u64) bool {
    const at = addr - @as(u64, index) * vol.space.group_blocks;
    return !bit(group.w, at) and !bit(group.h, at);
}

// --- handing out ---------------------------------------------------------------------------

/// What a block handed out becomes: used (the tree names it now) or held
/// (in flight, named by nothing durable yet).
pub const Mode = enum { used, held };

/// Free blocks that may be handed out, the reserve not counted.
pub fn available(vol: *const Volume) u64 {
    const space = &vol.space;
    const out = space.holds_total + space.promised + space.reserve;
    return if (space.free_total > out) space.free_total - out else 0;
}

/// Blocks that may be handed out, the reserve counted: what a delete or a
/// checkpoint may still have.
pub fn availableAll(vol: *const Volume) u64 {
    const space = &vol.space;
    const out = space.holds_total + space.promised;
    return if (space.free_total > out) space.free_total - out else 0;
}

/// Up to `want` free blocks in one run, found from the cursor on. Only a
/// `privileged` caller (a checkpoint, a delete) reaches into the reserve.
pub fn alloc(vol: *Volume, want: u64, mode: Mode, privileged: bool) Error!Run {
    if (vol.read_only or vol.failed) return error.ReadOnly;
    const room = if (privileged) availableAll(vol) else available(vol);
    if (room == 0 or want == 0) return error.DiskFull;
    const space = &vol.space;
    const limit = if (want < room) want else room;
    var index = groupOf(vol, space.cursor);
    var start_at = space.cursor - @as(u64, index) * space.group_blocks;
    var tried: usize = 0;
    while (tried <= space.groups.len) : (tried += 1) {
        const group = &space.groups[index];
        if (group.free > group.holds) {
            const loaded = try loadGroup(vol, index);
            const base = @as(u64, index) * space.group_blocks;
            var at = start_at;
            while (at < loaded.blocks) : (at += 1) {
                if (!allocatable(vol, loaded, index, base + at)) continue;
                var count: u64 = 1;
                while (count < limit and at + count < loaded.blocks and allocatable(vol, loaded, index, base + at + count)) count += 1;
                const run: Run = .{ .start = base + at, .count = count };
                try take(vol, run, mode);
                space.cursor = run.start + run.count;
                if (space.cursor >= vol.block_count) space.cursor = 0;
                return run;
            }
        }
        index += 1;
        if (index == space.groups.len) index = 0;
        start_at = 0;
    }
    return error.DiskFull;
}

fn take(vol: *Volume, run: Run, mode: Mode) Error!void {
    var addr = run.start;
    while (addr < run.start + run.count) : (addr += 1) {
        switch (mode) {
            .used => markUsed(vol, addr),
            .held => try setHeld(vol, addr, true),
        }
    }
}

/// One block for a node of `tree`, at a checkpoint: an object tree's from
/// anywhere, a space tree's from the homes counted out for it.
pub fn nodeHome(vol: *Volume, tree: u32) Error!u64 {
    if (tree == layout.tree_space) return popPool(vol);
    const run = try alloc(vol, 1, .used, true);
    return run.start;
}

fn popPool(vol: *Volume) Error!u64 {
    const pool = &vol.space.pool;
    if (pool.len == 0) return error.Corrupt;
    const run = &pool.items[pool.len - 1];
    const addr = run.start;
    run.start += 1;
    run.count -= 1;
    if (run.count == 0) pool.len -= 1;
    return addr;
}

/// A node's old home given up, now that a copy of it is being changed. A
/// space tree node's is freed once this checkpoint is durable.
pub fn dropNode(vol: *Volume, tree: u32, addr: u64, gen: u64) Error!void {
    if (tree == layout.tree_space) return vol.space.replaced.append(vol, .{ .start = addr, .count = 1 });
    try dropRun(vol, addr, gen, 1);
}

/// Blocks the live tree no longer names, born in generation `birth`:
/// held for two checkpoints and then free - or, when a snapshot still
/// names them, kept on the live deadlist.
pub fn dropRun(vol: *Volume, start: u64, birth: u64, count: u64) Error!void {
    if (snapshots.holds(vol, birth)) return snapshots.kill(vol, start, birth, count);
    try freeNow(vol, start, count);
}

/// Blocks no checkpoint will name once this interval ends: bits cleared,
/// held until two checkpoints have passed.
pub fn freeNow(vol: *Volume, start: u64, count: u64) Error!void {
    if (start >= vol.block_count or count > vol.block_count - start) return error.Corrupt;
    var addr = start;
    while (addr < start + count) : (addr += 1) {
        _ = try loadGroup(vol, groupOf(vol, addr));
        markFree(vol, addr);
        try setHeld(vol, addr, true);
    }
    try vol.space.f0.append(vol, .{ .start = start, .count = count });
}

/// In-flight blocks named by the tree now: a file's data at its commit.
pub fn commitHeld(vol: *Volume, start: u64, count: u64) Error!void {
    var addr = start;
    while (addr < start + count) : (addr += 1) {
        _ = try loadGroup(vol, groupOf(vol, addr));
        try setHeld(vol, addr, false);
        markUsed(vol, addr);
    }
}

/// In-flight blocks no longer needed.
pub fn releaseHeld(vol: *Volume, start: u64, count: u64) Error!void {
    var addr = start;
    while (addr < start + count) : (addr += 1) try setHeld(vol, addr, false);
}

/// Blocks something durable may name that are not to be handed out:
/// what replay finds the journal names, before it is replayed.
pub fn claim(vol: *Volume, start: u64, count: u64) Error!void {
    if (start >= vol.block_count or count > vol.block_count - start) return error.Corrupt;
    var addr = start;
    while (addr < start + count) : (addr += 1) {
        _ = try loadGroup(vol, groupOf(vol, addr));
        try setHeld(vol, addr, true);
    }
}

/// Blocks a commit puts in the tree that replay found claimed, or that
/// are free: used now.
pub fn useClaimed(vol: *Volume, start: u64, count: u64) Error!void {
    if (start >= vol.block_count or count > vol.block_count - start) return error.Corrupt;
    var addr = start;
    while (addr < start + count) : (addr += 1) {
        _ = try loadGroup(vol, groupOf(vol, addr));
        try setHeld(vol, addr, false);
        markUsed(vol, addr);
    }
}

// --- checkpoints ---------------------------------------------------------------------------

/// The space tree and the bitmaps written for this checkpoint, every home
/// they need counted out first from groups already being written.
pub fn writeSpace(vol: *Volume) Error!void {
    const space = &vol.space;
    // Each dirty group's item is touched first, so the space tree's nodes
    // that change are known before a home is counted.
    for (space.groups, 0..) |*group, index| {
        if (group.dirty) _ = try btree.modify(vol, &vol.space_tree, bmapKey(index));
    }
    space.pool.clear();
    var taken: u64 = 0;
    var start: usize = groupOf(vol, space.cursor);
    while (true) {
        const need = homesNeeded(vol);
        if (taken >= need) break;
        // From the groups being written anyway, first.
        var found = false;
        var looked: usize = 0;
        while (looked < space.groups.len and taken < need) : (looked += 1) {
            const index = (start + looked) % space.groups.len;
            const group = &space.groups[index];
            if (!group.dirty or group.free <= group.holds) continue;
            taken += try takeHomes(vol, index, need - taken);
            found = true;
        }
        if (taken >= need) break;
        // Then one more group, which is then written too.
        var added = false;
        looked = 0;
        while (looked < space.groups.len) : (looked += 1) {
            const index = (start + looked) % space.groups.len;
            const group = &space.groups[index];
            if (group.dirty or group.free <= group.holds) continue;
            group.dirty = true;
            _ = try btree.modify(vol, &vol.space_tree, bmapKey(index));
            start = index;
            added = true;
            break;
        }
        if (!added and !found) return error.DiskFull;
    }
    // The bitmaps, then their items, then the tree.
    for (space.groups, 0..) |*group, index| {
        if (!group.dirty) continue;
        if (!group.in_item) {
            const home = try popPool(vol);
            try vol.writeBlocks(home, group.w);
            if (group.block != 0) try space.replaced.append(vol, .{ .start = group.block, .count = 1 });
            group.block = home;
            group.crc = layout.crcSeeded(&vol.uuid, group.w);
        } else group.crc = layout.crcSeeded(&vol.uuid, group.w[0..groupBytes(group)]);
        group.gen = vol.gen;
        const target = (try btree.modify(vol, &vol.space_tree, bmapKey(index))) orelse return error.Corrupt;
        if (target.len != itemLen(group)) return error.Corrupt;
        _ = itemOf(group, target);
    }
    try btree.flush(vol, &vol.space_tree);
    if (space.pool.len != 0) return error.Corrupt;
    for (space.groups) |*group| group.dirty = false;
}

/// Homes the space metadata needs now: a block for each dirty group's
/// bits that are not in an item, and one for each space tree node being
/// changed.
fn homesNeeded(vol: *Volume) u64 {
    var count: u64 = btree.dirtyNodes(vol, &vol.space_tree);
    for (vol.space.groups) |*group| {
        if (group.dirty and !group.in_item) count += 1;
    }
    return count;
}

/// Up to `want` homes from group `index` into the pool.
fn takeHomes(vol: *Volume, index: usize, want: u64) Error!u64 {
    const space = &vol.space;
    const group = try loadGroup(vol, index);
    const base = @as(u64, index) * space.group_blocks;
    var got: u64 = 0;
    var at: u64 = 0;
    while (at < group.blocks and got < want) : (at += 1) {
        if (!allocatable(vol, group, index, base + at)) continue;
        markUsed(vol, base + at);
        try space.pool.append(vol, .{ .start = base + at, .count = 1 });
        got += 1;
    }
    return got;
}

/// What a checkpoint's being durable lets go: the frees of the interval
/// before last become free, this interval's wait one more, and the space
/// metadata this checkpoint replaced is freed in the next.
pub fn afterCheckpoint(vol: *Volume) Error!void {
    const space = &vol.space;
    for (space.f1.slice()) |run| {
        if (space.pin) try space.pinned.append(vol, run) else try releaseHeld(vol, run.start, run.count);
    }
    const older = space.f1;
    space.f1 = space.f0;
    space.f0 = older;
    space.f0.clear();
    for (space.replaced.slice()) |run| try freeNow(vol, run.start, run.count);
    space.replaced.clear();
}

/// The newest checkpoint's blocks kept from being handed out, however
/// many checkpoints follow, until `unpin`.
pub fn pin(vol: *Volume) void {
    vol.space.pin = true;
}

/// The pin let go: what it held is free again.
pub fn unpin(vol: *Volume) Error!void {
    const space = &vol.space;
    space.pin = false;
    for (space.pinned.slice()) |run| try releaseHeld(vol, run.start, run.count);
    space.pinned.clear();
}

/// Every group's bits as they are now, and the free count the groups give.
pub fn countFree(vol: *Volume) Error!u64 {
    var free: u64 = 0;
    for (0..vol.space.groups.len) |index| {
        const loaded = try loadGroup(vol, index);
        var count: u32 = 0;
        for (0..loaded.blocks) |at| {
            if (!bit(loaded.w, at)) count += 1;
        }
        if (count != loaded.free) return error.Corrupt;
        free += count;
    }
    return free;
}

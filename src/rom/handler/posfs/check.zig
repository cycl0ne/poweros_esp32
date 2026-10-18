// SPDX-License-Identifier: MPL-2.0
//! The check: whether a posfs volume is what it should be.
//!
//! **The trees**: every node reads and checks out, keys are in order in
//! each node and between a node and its neighbours (an inner node's key is
//! at or below everything under its child and above everything under the
//! child before), every leaf is at the same depth, and a child is never
//! newer than its parent.
//!
//! **The space**: the blocks the volume names - the trees' nodes, the
//! files' data, the bitmaps, the volume table, the deadlists - are each
//! named once, and are exactly the blocks the bitmap marks used. A block
//! marked used that nothing names is lost space; one named that is not
//! marked could be given out twice.
//!
//! **The objects** (`objects.visitItem`, `objects.checkInode`): every
//! name points at an object that is there, every object but the root has
//! the names its link count says, a directory's count of entries is right,
//! and a file's extents lie inside it and do not overlap. Recycled is
//! there exactly when the volume table says it is on, each object in it
//! has its origin and its number in the queue, and the totals are what it
//! holds; an object with no name is an orphan with its orphan item.
//!
//! **The snapshots** (`snapshots.Checker`): their table is in order, every
//! node and block of data a snapshot holds and no live tree names is named
//! too, and each of those is on exactly one deadlist, whose blocks are
//! named and whose entries no live tree names.
//!
//! **The data**, when asked for: every block of every file read, and
//! checked against its crc where it has one; a compressed chunk checked
//! against its crc and decoded.
//!
//! **What is checked** is a view. `live` is the volume as it is in
//! memory, nodes not yet written included - what the tests check after
//! every step. `durable` is the newest checkpoint as it is on the medium -
//! what C:PosFS checks, in slices of a packet each while the volume goes
//! on changing. A durable check pins its checkpoint (`space.pin`), so
//! nothing it names is handed out before the check ends, and reads only
//! what that checkpoint names: the trees by the roots in its slot, the
//! bitmaps by its space tree. The bits it compares are the ones the
//! checkpoint wrote, which still mark the space metadata it replaced of
//! the checkpoint before; those blocks count as named.
//!
//! The work is a list of phases taken a step at a time (`Check.run`): a
//! node of a tree, an object, a group's bits, or a few blocks of data. A
//! slice ends after the step that reaches its time.

const sdk = @import("sdk");
const posfs = sdk.dos.posfs;
const layout = posfs.layout;
const volume = @import("volume.zig");
const btree = @import("btree.zig");
const space = @import("space.zig");
const objects = @import("objects.zig");
const snapshots = @import("snapshots.zig");
const compress = @import("compress.zig");
const checkpoint = @import("checkpoint.zig");
const Volume = volume.Volume;
const Error = volume.Error;
const Key = layout.Key;

pub const Report = struct {
    errors: u32 = 0,
    nodes: u64 = 0,
    items: u64 = 0,
    named: u64 = 0,
    /// The first thing found wrong.
    message: []const u8 = "",
    /// Where it was: the block or the object.
    where: u64 = 0,
    /// Told of every fault, for a caller that lists them all.
    each: ?*const fn (context: ?*anyopaque, message: []const u8, where: u64) void = null,
    context: ?*anyopaque = null,

    pub fn fail(report: *Report, message: []const u8, where: u64) void {
        if (report.errors == 0) {
            report.message = message;
            report.where = where;
        }
        report.errors += 1;
        if (report.each) |call| call(report.context, message, where);
    }
};

/// The blocks found named, a bit each.
pub const Named = struct {
    bits: []u8 = &.{},

    pub fn init(vol: *Volume) Error!Named {
        const bits = try vol.alloc(@intCast((vol.block_count + 7) / 8));
        @memset(bits, 0);
        return .{ .bits = bits };
    }

    pub fn deinit(named: *Named, vol: *Volume) void {
        vol.free(named.bits);
        named.bits = &.{};
    }

    pub fn has(named: *const Named, addr: u64) bool {
        const index: usize = @intCast(addr);
        return named.bits[index / 8] & (@as(u8, 1) << @intCast(index % 8)) != 0;
    }

    /// `count` blocks from `start` named; a fault for one named before or
    /// outside the volume.
    pub fn mark(named: *Named, vol: *const Volume, report: *Report, start: u64, count: u64) void {
        if (start >= vol.block_count or count > vol.block_count - start) {
            report.fail("a block outside the volume is named", start);
            return;
        }
        var addr = start;
        while (addr < start + count) : (addr += 1) {
            const index: usize = @intCast(addr);
            const mask = @as(u8, 1) << @intCast(index % 8);
            if (named.bits[index / 8] & mask != 0) {
                report.fail("a block is named twice", addr);
                continue;
            }
            named.bits[index / 8] |= mask;
            report.named += 1;
        }
    }
};

/// A tree walked a node at a time: each node checked, each clean node's
/// block named, and `visit` called for each item of a leaf.
pub const TreeWalk = struct {
    const max = volume.max_height;

    tree: btree.Tree,
    refs: [max]u64 = undefined,
    gens: [max]u64 = undefined,
    next: [max]u32 = undefined,
    // The bounds a node's keys must keep to: at or above `low`, below `high`.
    lows: [max]Key = undefined,
    highs: [max]?Key = undefined,
    depth: u32 = 0,
    leaf_depth: ?u32 = null,
    previous: ?Key = null,

    pub fn init(tree: btree.Tree) TreeWalk {
        var walk: TreeWalk = .{ .tree = tree };
        walk.refs[0] = tree.root;
        walk.gens[0] = tree.root_gen;
        walk.next[0] = 0;
        walk.lows[0] = layout.key_min;
        walk.highs[0] = null;
        return walk;
    }

    /// One node, or one more child of an inner node: false once the whole
    /// tree is walked.
    pub fn step(
        walk: *TreeWalk,
        vol: *Volume,
        named: ?*Named,
        report: *Report,
        context: anytype,
        comptime visit: ?fn (@TypeOf(context), *Volume, Key, []const u8, *Report) Error!void,
    ) Error!bool {
        const depth = walk.depth;
        const block = btree.nodeAt(vol, &walk.tree, walk.refs[depth], walk.gens[depth]) catch |err| switch (err) {
            error.Corrupt, error.Io => {
                report.fail("a node does not read", walk.refs[depth]);
                return walk.up();
            },
            else => return err,
        };
        const header = btree.header(block);
        if (walk.next[depth] == 0) {
            report.nodes += 1;
            if (walk.refs[depth] & volume.dirty_bit == 0) {
                if (named) |set| set.mark(vol, report, walk.refs[depth], 1);
            }
            if (header.level != walk.tree.height - 1 - depth) report.fail("a node is at the wrong level", walk.refs[depth]);
        }
        if (header.level == 0) {
            if (walk.leaf_depth) |seen| {
                if (seen != depth) report.fail("leaves at different depths", walk.refs[depth]);
            } else walk.leaf_depth = depth;
            for (btree.leafEntries(block)) |entry| {
                report.items += 1;
                if (walk.previous) |before| {
                    if (!before.lessThan(entry.key)) report.fail("keys out of order", walk.refs[depth]);
                }
                if (entry.key.lessThan(walk.lows[depth]) and depth > 0) report.fail("a key below its node's bound", walk.refs[depth]);
                if (walk.highs[depth]) |high| {
                    if (!entry.key.lessThan(high)) report.fail("a key above its node's bound", walk.refs[depth]);
                }
                walk.previous = entry.key;
                if (visit) |call| try call(context, vol, entry.key, btree.itemData(block, entry), report);
            }
            return walk.up();
        }
        const entries = btree.innerEntries(block);
        if (walk.next[depth] >= entries.len) return walk.up();
        const at = walk.next[depth];
        const entry = entries[at];
        walk.next[depth] += 1;
        if (at > 0 and !entries[at - 1].key.lessThan(entry.key)) report.fail("inner keys out of order", walk.refs[depth]);
        if (entry.child & volume.dirty_bit == 0 and walk.refs[depth] & volume.dirty_bit == 0 and entry.child_gen > header.gen) {
            report.fail("a child newer than its parent", entry.child);
        }
        if (depth + 1 >= max) {
            report.fail("the tree is too deep", walk.refs[depth]);
            return false;
        }
        const low = if (at == 0) walk.lows[depth] else entry.key;
        const high = if (at + 1 < entries.len) entries[at + 1].key else walk.highs[depth];
        walk.depth += 1;
        walk.refs[walk.depth] = entry.child;
        walk.gens[walk.depth] = entry.child_gen;
        walk.next[walk.depth] = 0;
        walk.lows[walk.depth] = low;
        walk.highs[walk.depth] = high;
        return true;
    }

    fn up(walk: *TreeWalk) bool {
        if (walk.depth == 0) return false;
        walk.depth -= 1;
        return true;
    }
};

/// A whole tree walked at once.
pub fn walkTree(
    vol: *Volume,
    tree: *const btree.Tree,
    named: ?*Named,
    report: *Report,
    context: anytype,
    comptime visit: ?fn (@TypeOf(context), *Volume, Key, []const u8, *Report) Error!void,
) Error!void {
    var walk = TreeWalk.init(tree.*);
    while (try walk.step(vol, named, report, context, visit)) {}
}

pub const View = enum { live, durable };

const Phase = enum { fixed, space, replaced, voltab, objects, names, snapshots, bitmap, data, done };

/// A check under way: what it looks at, how far it has come, and what it
/// has found.
pub const Check = struct {
    view: View,
    /// The checkpoint a durable check reads.
    slot: layout.CheckpointSlot,
    obj: btree.Tree,
    space_tree: btree.Tree,
    voltab: u64,
    data: bool,
    phase: Phase = .fixed,
    named: Named = .{},
    report: Report = .{},
    walk: TreeWalk = undefined,
    objects: objects.Walk = undefined,
    /// The names pass: the next inode and the next name count.
    key: Key = layout.key_min,
    index: usize = 0,
    /// The bitmap pass: the next group, and the free blocks counted.
    group: usize = 0,
    free: u64 = 0,
    /// The space metadata of the checkpoint before that this one replaced.
    replaced: space.Runs = .{},
    /// The data pass: the next extent, how many of its blocks are done,
    /// and its crcs.
    data_key: Key = layout.key_min,
    data_done: u64 = 0,
    data_blocks: u64 = 0,
    crcs: [layout.max_csums]u32 = undefined,
    /// A block of the medium read for the bitmap and the data passes.
    buffer: []u8 = &.{},
    /// The snapshots pass.
    snapshot_check: snapshots.Checker = .{},

    /// A check of the volume as `view` has it, the data too with `data`.
    /// A durable check pins the newest checkpoint until `end`.
    pub fn begin(c: *Check, vol: *Volume, view: View, data: bool) Error!void {
        const slot = vol.durable;
        c.* = .{
            .view = view,
            .slot = slot,
            .obj = if (view == .live) vol.obj else .{ .id = layout.tree_object, .root = slot.obj_root, .root_gen = slot.obj_gen, .height = slot.obj_height },
            .space_tree = if (view == .live) vol.space_tree else .{ .id = layout.tree_space, .root = slot.space_root, .root_gen = slot.space_gen, .height = slot.space_height },
            .voltab = slot.voltab,
            .data = data,
        };
        c.named = try Named.init(vol);
        errdefer c.named.deinit(vol);
        c.buffer = try vol.alloc(vol.block_size);
        c.objects = .{ .vol = vol, .named = &c.named };
        c.walk = TreeWalk.init(c.space_tree);
        if (view == .durable) space.pin(vol);
    }

    /// What the check holds given back, and the pin let go.
    pub fn end(c: *Check, vol: *Volume) Error!void {
        c.objects.deinit(vol);
        c.snapshot_check.end(vol);
        c.replaced.deinit(vol);
        c.named.deinit(vol);
        vol.free(c.buffer);
        c.buffer = &.{};
        if (c.view == .durable and vol.space.pin) try space.unpin(vol);
    }

    pub fn done(c: *const Check) bool {
        return c.phase == .done;
    }

    /// Objects and data blocks looked at so far.
    pub fn objectsSeen(c: *const Check) u64 {
        return c.objects.seen;
    }

    pub fn dataBlocks(c: *const Check) u64 {
        return c.data_blocks;
    }

    /// Steps until the check is done, or - with `until` - until the
    /// volume's clock reaches it: true when done.
    pub fn run(c: *Check, vol: *Volume, until: ?u64) Error!bool {
        while (c.phase != .done) {
            try c.step(vol);
            if (until) |limit| {
                if (vol.now() >= limit) break;
            }
        }
        return c.phase == .done;
    }

    fn step(c: *Check, vol: *Volume) Error!void {
        const report = &c.report;
        switch (c.phase) {
            .fixed => {
                // The labels and the rings.
                const ends = layout.ring_blocks + 1;
                c.named.mark(vol, report, 0, ends);
                c.named.mark(vol, report, vol.block_count - ends, ends);
                c.phase = .space;
            },
            .space => {
                if (!try c.walk.step(vol, &c.named, report, c, spaceItem)) c.phase = .replaced;
            },
            .replaced => {
                if (c.view == .durable) {
                    try space.replacedBy(vol, &c.slot, &c.replaced);
                    for (c.replaced.slice()) |piece| c.named.mark(vol, report, piece.start, piece.count);
                }
                c.phase = .voltab;
            },
            .voltab => {
                // A changed table's new home is taken only at the
                // checkpoint.
                if (c.voltab != 0) c.named.mark(vol, report, c.voltab, layout.voltabBlocks(vol.block_size));
                c.objects.recycled_on = try c.voltabFlags(vol) & layout.VT_RECYCLED != 0;
                c.walk = TreeWalk.init(c.obj);
                c.phase = .objects;
            },
            .objects => {
                if (try c.walk.step(vol, &c.named, report, &c.objects, objects.visitItem)) return;
                try c.objects.settle(report);
                c.key = objects.inodeKey(0);
                c.index = 0;
                c.phase = .names;
            },
            .names => {
                if (try objects.checkInode(&c.objects, &c.obj, &c.key, &c.index, report)) return;
                c.phase = .snapshots;
                c.snapshot_check.begin(vol, if (c.view == .durable) &c.slot else null) catch |err| switch (err) {
                    error.Io, error.Corrupt => {
                        report.fail("the volume table does not read", c.voltab);
                        c.phase = .bitmap;
                    },
                    else => return err,
                };
            },
            .snapshots => {
                if (try c.snapshot_check.step(vol, &c.named, report)) return;
                c.snapshot_check.end(vol);
                c.phase = .bitmap;
            },
            .bitmap => {
                if (c.group < vol.space.groups.len) {
                    try c.compareGroup(vol);
                    c.group += 1;
                    return;
                }
                const free = if (c.view == .live) vol.space.free_total else c.slot.free_blocks;
                if (c.free != free) report.fail("the free count is off", c.free);
                c.phase = if (c.data) .data else .done;
            },
            .data => if (!try c.dataStep(vol)) {
                c.phase = .done;
            },
            .done => {},
        }
    }

    /// The switches of the volume table checked with the trees: the one in
    /// memory, or the one the checkpoint wrote.
    fn voltabFlags(c: *Check, vol: *Volume) Error!u32 {
        if (c.view == .live) return vol.voltab.flags;
        const bytes = try vol.alloc(layout.voltab_size);
        defer vol.free(bytes);
        const table: *layout.VolTab = @ptrCast(@alignCast(bytes.ptr));
        checkpoint.loadVoltab(vol, &c.slot, table) catch |err| switch (err) {
            error.Io, error.Corrupt => {
                c.report.fail("the volume table does not read", c.voltab);
                return vol.voltab.flags;
            },
            else => return err,
        };
        return table.flags;
    }

    /// One group's bits against the blocks named.
    fn compareGroup(c: *Check, vol: *Volume) Error!void {
        const report = &c.report;
        const index = c.group;
        const per_group = layout.groupBlocks(vol.block_size);
        const first = @as(u64, index) * per_group;
        const left = vol.block_count - first;
        const blocks: u32 = @intCast(if (left < per_group) left else per_group);
        var bits: []const u8 = &.{};
        var listed: u32 = 0;
        if (c.view == .durable) {
            const item = try btree.find(vol, &c.space_tree, space.bmapKey(index)) orelse {
                report.fail("a group has no item", index);
                return;
            };
            if (item.len < @sizeOf(layout.Bmap)) return;
            var bmap: layout.Bmap = undefined;
            @memcpy(layout.bytesOfMut(&bmap), item[0..@sizeOf(layout.Bmap)]);
            listed = bmap.free;
            if (space.inItem(vol, blocks)) {
                const bytes = (blocks + 7) / 8;
                if (item.len != @sizeOf(layout.Bmap) + bytes) {
                    report.fail("a group's item is short", index);
                    return;
                }
                @memcpy(c.buffer[0..bytes], item[@sizeOf(layout.Bmap)..]);
                bits = c.buffer[0..bytes];
            } else {
                if (bmap.block == 0 or bmap.block >= vol.block_count) {
                    report.fail("a group's bits are nowhere", index);
                    return;
                }
                vol.readBlocks(bmap.block, c.buffer) catch |err| switch (err) {
                    error.Io, error.Corrupt => {
                        report.fail("a group's bits do not read", bmap.block);
                        return;
                    },
                    else => return err,
                };
                bits = c.buffer;
            }
            if (layout.crcSeeded(&vol.uuid, bits) != bmap.crc) {
                report.fail("a group's bits are not what was written", index);
                return;
            }
        }
        var free: u32 = 0;
        var at: u32 = 0;
        while (at < blocks) : (at += 1) {
            const addr = first + at;
            const used = if (c.view == .live) space.isUsed(vol, addr) else bits[at / 8] & (@as(u8, 1) << @intCast(at % 8)) != 0;
            if (!used) free += 1;
            const is_named = c.named.has(addr);
            // The space metadata replaced is named, and may be marked
            // either way.
            if (is_named and !used and !space.containsBlock(c.replaced.slice(), addr)) report.fail("a block named is marked free", addr);
            if (!is_named and used) report.fail("a block marked used is named by nothing", addr);
        }
        if (c.view == .durable and free != listed) report.fail("a group's free count is off", index);
        if (c.view == .live and free != vol.space.groups[index].free) report.fail("a group's free count is off", index);
        c.free += free;
    }

    /// Blocks of one extent read and checked: false when no extent is
    /// left.
    fn dataStep(c: *Check, vol: *Volume) Error!bool {
        const report = &c.report;
        const kind_extent = @intFromEnum(layout.Kind.extent);
        const item = try btree.seek(vol, &c.obj, c.data_key) orelse return false;
        const oid = item.key.oid;
        if (item.key.kind != kind_extent) {
            c.data_key = if (item.key.kind < kind_extent) .{ .oid = oid, .kind = kind_extent } else .{ .oid = oid + 1 };
            return true;
        }
        const offset = item.key.offset;
        var extent: layout.Extent = undefined;
        if (item.data.len != @sizeOf(layout.Extent)) {
            c.data_key = btree.successor(item.key);
            return true;
        }
        @memcpy(layout.bytesOfMut(&extent), item.data);
        if (extent.block >= vol.block_count or extent.blocks > vol.block_count - extent.block) {
            c.data_key = btree.successor(item.key);
            return true;
        }
        if (extent.compressed()) {
            // Read anew, not from the chunk last decoded.
            compress.forget(vol, extent.block, extent.blocks);
            const stored: compress.Stored = .{ .block = extent.block, .blocks = extent.blocks, .stored = extent.stored, .crc = extent.crc };
            if (compress.read(vol, stored, @intCast(extent.length))) |_| {} else |err| switch (err) {
                error.BadChecksum => report.fail("a compressed chunk is not what was written", oid),
                error.Corrupt => report.fail("a compressed chunk does not decode", oid),
                error.Io => report.fail("a file's data does not read", oid),
                else => return err,
            }
            c.data_blocks += extent.blocks;
            c.data_key = btree.successor(item.key);
            return true;
        }
        const checksummed = extent.checksummed();
        if (checksummed and c.data_done == 0) {
            const data = try btree.find(vol, &c.obj, .{ .oid = oid, .kind = @intFromEnum(layout.Kind.csum), .offset = offset }) orelse {
                report.fail("a checksummed extent has no crcs", oid);
                c.data_key = btree.successor(item.key);
                return true;
            };
            if (extent.blocks > c.crcs.len or data.len != @as(usize, extent.blocks) * 4) {
                report.fail("a checksummed extent's crcs do not fit it", oid);
                c.data_key = btree.successor(item.key);
                return true;
            }
            @memcpy(@as([*]u8, @ptrCast(&c.crcs))[0..data.len], data);
        }
        // About 64 KiB a step.
        const per_step: u64 = @max(1, layout.chunk_size / vol.block_size);
        const count = @min(per_step, extent.blocks - c.data_done);
        var each: u64 = 0;
        while (each < count) : (each += 1) {
            const index = c.data_done + each;
            const block = extent.block + index;
            var bytes: []const u8 = c.buffer;
            if (vol.map != null) {
                bytes = vol.mappedView(block);
            } else vol.readBlocks(block, c.buffer) catch |err| switch (err) {
                error.Io, error.Corrupt => {
                    report.fail("a file's data does not read", oid);
                    continue;
                },
                else => return err,
            };
            if (checksummed and layout.crcSeeded(&vol.uuid, bytes) != c.crcs[@intCast(index)]) report.fail("a block of a file's data is not what was written", block);
        }
        c.data_done += count;
        c.data_blocks += count;
        if (c.data_done >= extent.blocks) {
            c.data_done = 0;
            c.data_key = btree.successor(item.key);
        }
        return true;
    }
};

fn spaceItem(c: *Check, vol: *Volume, key: Key, data: []const u8, report: *Report) Error!void {
    if (key.kind != @intFromEnum(layout.Kind.bmap)) return report.fail("a space tree item that is no group", key.offset);
    if (data.len < @sizeOf(layout.Bmap)) return report.fail("a group's item is short", key.offset);
    if (key.offset >= vol.space.groups.len) return report.fail("a group past the volume's end", key.offset);
    const per_group = layout.groupBlocks(vol.block_size);
    const left = vol.block_count - key.offset * per_group;
    const blocks: u32 = @intCast(if (left < per_group) left else per_group);
    if (space.inItem(vol, blocks)) return;
    const home = layout.getU64(data, 0);
    if (home != 0) c.named.mark(vol, report, home, 1);
}

/// The volume as it is in memory checked, whole.
pub fn check(vol: *Volume, report: *Report) Error!void {
    _ = try checkWhole(vol, false, report);
}

/// What a whole check looked at.
pub const Totals = struct { objects: u64, data_blocks: u64 };

/// The volume as it is in memory checked, whole, its data too with
/// `data`. `report` comes in with the caller's `each`, and goes out
/// filled.
pub fn checkWhole(vol: *Volume, data: bool, report: *Report) Error!Totals {
    var c: Check = undefined;
    try c.begin(vol, .live, data);
    defer c.end(vol) catch {};
    c.report.each = report.each;
    c.report.context = report.context;
    _ = try c.run(vol, null);
    report.* = c.report;
    return .{ .objects = c.objectsSeen(), .data_blocks = c.dataBlocks() };
}

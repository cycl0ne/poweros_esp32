// SPDX-License-Identifier: MPL-2.0
//! Snapshots: the object tree kept as it was at a checkpoint, read under
//! `.snapshots/<name>/`.
//!
//! **A snapshot is a root.** A checkpoint writes the object tree, and the
//! snapshot takes the root it ended with, its generation and its height
//! (`make` asks the next checkpoint for one); nothing is copied. The tree
//! is changed by copying, so the snapshot's nodes and data stay as they
//! are for as long as something holds them.
//!
//! **What holds a block** is decided by when it was born. Every node says
//! the generation it was written in, every extent the one it entered the
//! tree in, and a snapshot holds everything born at or before its own
//! generation that was in the live tree then. So when the live tree lets
//! go of a block (`space.dropRun`), the newest snapshot holds it if it was
//! born at or before that snapshot (`holds`), and no snapshot does
//! otherwise: such a block is freed, and a held one goes on a deadlist
//! (`kill`) and stays used.
//!
//! **The deadlists.** Each snapshot keeps the blocks the live tree let go
//! of while it was the newest - the newest one's list is the volume
//! table's `live_dead` until another is made - as a chain of blocks of
//! (start, birth, count) entries, the newest block first, written at the
//! checkpoints (`flush`); between two the entries wait in memory. A chain's
//! first block is taken up into a new one while it has room, the old one
//! freed, so no block is written twice.
//!
//! **Deleting a snapshot** (`delete`) goes through its list: an entry the
//! snapshot before it holds too - born at or before that one - moves to
//! that one's list, any other is freed, and then the list's own blocks.
//! **A rollback** (`rollback`) makes the newest snapshot's root the live
//! tree's again: what the live tree holds beyond it - the nodes and
//! extents born after it - is freed, found by walking only the parts of
//! the tree newer than the snapshot, and the newest's list is let go, its
//! blocks the live tree's again. Each is done whole within its packet and
//! committed by two checkpoints, so a cut leaves it done or not begun.
//!
//! **The check** (`Checker`) walks the snapshots' trees where they are
//! their own - a node another tree named is shared, and so is all below
//! it - and finds every block only the snapshots hold on exactly one list,
//! and every block a list names held by a snapshot and by no live tree.

const sdk = @import("sdk");
const dos = sdk.dos;
const posfs = dos.posfs;
const layout = posfs.layout;
const fold = posfs.fold;
const volume = @import("volume.zig");
const btree = @import("btree.zig");
const space = @import("space.zig");
const checkpoint = @import("checkpoint.zig");
const objects = @import("objects.zig");
const check = @import("check.zig");
const Volume = volume.Volume;
const Error = volume.Error;
const Snapshot = layout.Snapshot;
const DeadList = layout.DeadList;
const DeadEntry = layout.DeadEntry;
const DeadHeader = layout.DeadHeader;
const header_size = layout.node_header_size;
const max_height = volume.max_height;
const kind_extent: u32 = @intFromEnum(layout.Kind.extent);

/// The id `.snapshots` goes by as a lock's object: no tree holds it, and
/// the trees' own ids are others.
pub const dir_oid: u64 = 4;

/// A deadlist entry waiting for the next checkpoint, and the list it goes
/// on: 0 for the newest snapshot's (the volume table's `live_dead`), else
/// the id of the snapshot whose list it is.
pub const Waiting = struct { list: u32, entry: DeadEntry };

/// What the snapshots keep in memory between checkpoints.
pub const State = struct {
    waiting: []Waiting = &.{},
    len: usize = 0,
    /// A snapshot the next checkpoint makes, and its name and time.
    wanted: bool = false,
    name: [posfs.max_snapshot_name]u8 = undefined,
    name_len: u32 = 0,
    created: u64 = 0,
};

pub fn release(vol: *Volume) void {
    vol.freeSlice(Waiting, vol.snapshots.waiting);
    vol.snapshots = .{};
}

/// The volume's snapshots, the oldest first.
pub fn all(vol: *const Volume) []Snapshot {
    return vol.voltab.snapshots[0..vol.voltab.snapshot_count];
}

/// The snapshot with `id`.
pub fn byId(vol: *const Volume, id: u32) ?*Snapshot {
    for (all(vol)) |*snapshot| {
        if (snapshot.id == id) return snapshot;
    }
    return null;
}

/// Where the snapshot named `name` (UTF-8, compared without case) is in
/// the table.
pub fn find(vol: *const Volume, name: []const u8) ?usize {
    for (all(vol), 0..) |*snapshot, index| {
        if (fold.same(nameOf(snapshot), name)) return index;
    }
    return null;
}

/// Where the snapshot dos names `dos_name` is: by the name, or by the
/// stand-in dos is shown for it.
pub fn findDos(vol: *const Volume, dos_name: []const u8) ?usize {
    var buffer: [posfs.max_name]u8 = undefined;
    if (fold.fromDos(dos_name, &buffer)) |name| {
        if (find(vol, name)) |index| return index;
    }
    var shown: [posfs.max_name]u8 = undefined;
    for (all(vol), 0..) |*snapshot, index| {
        if (fold.sameLatin1(fold.toDos(nameOf(snapshot), &shown), dos_name)) return index;
    }
    return null;
}

pub fn nameOf(snapshot: *const Snapshot) []const u8 {
    const len = if (snapshot.name_len > snapshot.name.len) snapshot.name.len else snapshot.name_len;
    return snapshot.name[0..len];
}

/// A snapshot's tree, for reading.
pub fn treeOf(snapshot: *const Snapshot) btree.Tree {
    return .{ .id = layout.tree_object, .root = snapshot.root, .root_gen = snapshot.root_gen, .height = snapshot.height };
}

/// The blocks the snapshots hold that the live tree does not: what their
/// lists name, and what waits to go on them.
pub fn heldBlocks(vol: *const Volume) u64 {
    var total: u64 = vol.voltab.live_dead.count;
    for (all(vol)) |*snapshot| total += snapshot.dead.count;
    for (vol.snapshots.waiting[0..vol.snapshots.len]) |waiting| total += waiting.entry.count;
    return total;
}

// --- what the live tree lets go of ----------------------------------------------------

/// Whether a snapshot names a block born in generation `birth` that the
/// live tree lets go of: the newest does, if it was made then or after.
pub fn holds(vol: *const Volume, birth: u64) bool {
    const count = vol.voltab.snapshot_count;
    if (count == 0) return false;
    return birth <= vol.voltab.snapshots[count - 1].gen;
}

/// Blocks the live tree let go of that the newest snapshot names: onto
/// its list, still used.
pub fn kill(vol: *Volume, start: u64, birth: u64, count: u64) Error!void {
    try wait(vol, 0, .{ .start = start, .birth = birth, .count = count });
}

/// An entry for list `list`, waiting for the next checkpoint: joined to
/// the one before when it goes on where that one ends.
fn wait(vol: *Volume, list: u32, entry: DeadEntry) Error!void {
    const st = &vol.snapshots;
    if (st.len > 0) {
        const last = &st.waiting[st.len - 1];
        if (last.list == list and last.entry.birth == entry.birth and last.entry.start + last.entry.count == entry.start) {
            last.entry.count += entry.count;
            return;
        }
    }
    if (st.len == st.waiting.len) {
        const grown = try vol.allocSlice(Waiting, if (st.waiting.len == 0) 32 else st.waiting.len * 2);
        @memcpy(grown[0..st.len], st.waiting[0..st.len]);
        vol.freeSlice(Waiting, st.waiting);
        st.waiting = grown;
    }
    st.waiting[st.len] = .{ .list = list, .entry = entry };
    st.len += 1;
}

/// The list `id` stands for: 0 the newest snapshot's, else the snapshot's
/// with that id.
fn listOf(vol: *Volume, id: u32) Error!*DeadList {
    if (id == 0) return &vol.voltab.live_dead;
    const snapshot = byId(vol, id) orelse return error.Corrupt;
    return &snapshot.dead;
}

// --- a deadlist's blocks ------------------------------------------------------------------

fn deadHeader(block: []u8) *DeadHeader {
    return @ptrCast(@alignCast(block.ptr + header_size));
}

fn entriesOf(block: []u8) [*]DeadEntry {
    return @ptrCast(@alignCast(block.ptr + header_size + @sizeOf(DeadHeader)));
}

/// The deadlist block at `addr`, written in generation `gen`, read and
/// checked into `into`: its entries. What comes after it is in its
/// `deadHeader`.
fn readDead(vol: *Volume, addr: u64, gen: u64, into: []u8) Error![]DeadEntry {
    const block = try vol.nodeView(addr, gen, layout.tree_deadlist);
    @memcpy(into, block);
    return entriesOf(into)[0..volume.headerOf(into).count];
}

/// `count` entries in `block` written to a new home in front of `next`:
/// the home.
fn writeDead(vol: *Volume, block: []u8, count: u32, next: u64, next_gen: u64) Error!u64 {
    const addr = try space.nodeHome(vol, layout.tree_deadlist);
    volume.headerOfMut(block).* = .{ .gen = vol.gen, .tree = layout.tree_deadlist, .count = count };
    deadHeader(block).* = .{ .next = next, .next_gen = next_gen };
    try vol.writeNode(addr, block);
    return addr;
}

/// The waiting entries of list `id` written onto its chain: into a new
/// copy of its first block while that has room, into new blocks in front
/// of it once it has not.
fn appendTo(vol: *Volume, id: u32) Error!void {
    const st = &vol.snapshots;
    const dead = try listOf(vol, id);
    const per_block = layout.deadEntries(vol.block_size);
    const block = try vol.alloc(vol.block_size);
    defer vol.free(block);
    @memset(block, 0);
    var count: u32 = 0;
    var next = dead.head;
    var next_gen = dead.head_gen;
    if (dead.head != 0) {
        const old = try readDead(vol, dead.head, dead.head_gen, block);
        if (old.len < per_block) {
            count = @intCast(old.len);
            const behind = deadHeader(block).*;
            next = behind.next;
            next_gen = behind.next_gen;
            try space.freeNow(vol, dead.head, 1);
        } else @memset(block, 0);
    }
    for (st.waiting[0..st.len]) |waiting| {
        if (waiting.list != id) continue;
        if (count == per_block) {
            next = try writeDead(vol, block, count, next, next_gen);
            next_gen = vol.gen;
            @memset(block, 0);
            count = 0;
        }
        entriesOf(block)[count] = waiting.entry;
        count += 1;
        dead.count += waiting.entry.count;
    }
    dead.head = try writeDead(vol, block, count, next, next_gen);
    dead.head_gen = vol.gen;
    vol.voltab_dirty = true;
}

/// A list's blocks freed - not what it names - from `list.head` on.
fn freeChain(vol: *Volume, list: DeadList, block: []u8) Error!void {
    var addr = list.head;
    var gen = list.head_gen;
    var steps: u64 = 0;
    while (addr != 0) : (steps += 1) {
        if (steps > vol.block_count) return error.Corrupt;
        _ = try readDead(vol, addr, gen, block);
        const behind = deadHeader(block).*;
        try space.freeNow(vol, addr, 1);
        addr = behind.next;
        gen = behind.next_gen;
    }
}

// --- at a checkpoint ------------------------------------------------------------------------

/// What a checkpoint does once it has written the object tree: the waiting
/// entries onto their lists, and the snapshot asked for made of the tree
/// just written - the newest one's list becomes the one before's, and the
/// new one's starts empty.
pub fn flush(vol: *Volume) Error!void {
    const st = &vol.snapshots;
    var index: usize = 0;
    while (index < st.len) : (index += 1) {
        const id = st.waiting[index].list;
        var earlier = false;
        for (st.waiting[0..index]) |before| {
            if (before.list == id) earlier = true;
        }
        if (!earlier) try appendTo(vol, id);
    }
    st.len = 0;
    if (!st.wanted) return;
    st.wanted = false;
    const table = vol.voltab;
    if (table.snapshot_count >= posfs.max_snapshots) return error.Corrupt;
    if (table.snapshot_count > 0) table.snapshots[table.snapshot_count - 1].dead = table.live_dead;
    table.live_dead = .{};
    const made = &table.snapshots[table.snapshot_count];
    made.* = .{
        .id = table.next_snapshot_id,
        .gen = vol.gen,
        .root = vol.obj.root,
        .root_gen = vol.obj.root_gen,
        .height = vol.obj.height,
        .name_len = st.name_len,
        .created = st.created,
    };
    @memcpy(made.name[0..st.name_len], st.name[0..st.name_len]);
    table.next_snapshot_id += 1;
    table.snapshot_count += 1;
    table.ro_compat |= layout.RO_COMPAT_SNAPSHOTS;
    vol.voltab_dirty = true;
}

pub fn afterCheckpoint(vol: *Volume) Error!void {
    _ = vol;
}

/// The snapshots of the volume table just read, looked over, so that what
/// follows from them cannot go wrong.
pub fn load(vol: *Volume) Error!void {
    vol.snapshots.len = 0;
    vol.snapshots.wanted = false;
    const table = vol.voltab;
    var before: u64 = 0;
    for (all(vol)) |*snapshot| {
        if (snapshot.gen <= before or snapshot.gen > vol.durable.gen) return error.Corrupt;
        if (snapshot.id == 0 or snapshot.id >= table.next_snapshot_id) return error.Corrupt;
        if (snapshot.root == 0 or snapshot.root >= vol.block_count) return error.Corrupt;
        if (snapshot.height == 0 or snapshot.height > max_height) return error.Corrupt;
        if (snapshot.name_len == 0 or snapshot.name_len > posfs.max_snapshot_name) return error.Corrupt;
        if (snapshot.dead.head >= vol.block_count) return error.Corrupt;
        before = snapshot.gen;
    }
    if (table.live_dead.head >= vol.block_count) return error.Corrupt;
    if (table.snapshot_count == 0 and table.live_dead.head != 0) return error.Corrupt;
}

// --- making, deleting, rolling back --------------------------------------------------------

/// A snapshot of the object tree as it is committed now, named `name`
/// (UTF-8): the next checkpoint makes it, one more makes it durable. What
/// open files have not committed is not in it.
pub fn make(vol: *Volume, name: []const u8) Error!void {
    if (vol.read_only or vol.failed) return error.ReadOnly;
    if (name.len == 0 or name.len > posfs.max_snapshot_name or !fold.acceptable(name)) return error.BadName;
    for (name) |byte| {
        if (byte < 0x20) return error.BadName;
    }
    if (find(vol, name) != null) return error.Exists;
    if (vol.voltab.snapshot_count >= posfs.max_snapshots) return error.DiskFull;
    const st = &vol.snapshots;
    @memcpy(st.name[0..name.len], name);
    st.name_len = @intCast(name.len);
    st.created = vol.now();
    st.wanted = true;
    errdefer st.wanted = false;
    try checkpoint.write(vol, 0);
    try checkpoint.write(vol, 0);
}

/// The snapshot at `index` deleted: of what its list names, what the
/// snapshot before holds too moved onto that one's list and the rest
/// freed, and the list's own blocks freed; committed by two checkpoints.
/// The caller has seen that nothing is in use in it.
pub fn delete(vol: *Volume, index: usize) Error!void {
    if (vol.read_only or vol.failed) return error.ReadOnly;
    const table = vol.voltab;
    const count = table.snapshot_count;
    if (index >= count) return error.NotFound;
    const doomed = table.snapshots[index];
    // What the snapshot before holds too stays held.
    const keep: ?u64 = if (index > 0) table.snapshots[index - 1].gen else null;
    var gone: DeadList = doomed.dead;
    var target: u32 = if (index > 0) table.snapshots[index - 1].id else 0;
    var list = doomed.id;
    if (index + 1 == count) {
        // The newest: its list is the live one, which the list of the one
        // before becomes - entries waiting for that one with it.
        gone = table.live_dead;
        list = 0;
        target = 0;
        if (index > 0) {
            const before = &table.snapshots[index - 1];
            table.live_dead = before.dead;
            before.dead = .{};
            for (vol.snapshots.waiting[0..vol.snapshots.len]) |*waiting| {
                if (waiting.list == before.id) waiting.list = 0;
            }
        } else table.live_dead = .{};
    }
    try sortWaiting(vol, list, keep, target);
    try sortChain(vol, gone, keep, target);
    var at = index;
    while (at + 1 < count) : (at += 1) table.snapshots[at] = table.snapshots[at + 1];
    table.snapshots[count - 1] = .{};
    table.snapshot_count -= 1;
    if (table.snapshot_count == 0) table.ro_compat &= ~layout.RO_COMPAT_SNAPSHOTS;
    vol.voltab_dirty = true;
    try checkpoint.write(vol, 0);
    try checkpoint.write(vol, 0);
}

/// Whether an entry is held by a snapshot made in generation `keep`.
fn kept(entry: DeadEntry, keep: ?u64) bool {
    const gen = keep orelse return false;
    return entry.birth <= gen;
}

/// The entries waiting for list `list` sorted: those `keep` holds onto
/// list `target`, the others freed.
fn sortWaiting(vol: *Volume, list: u32, keep: ?u64, target: u32) Error!void {
    const st = &vol.snapshots;
    var left: usize = 0;
    for (st.waiting[0..st.len]) |waiting| {
        var moved = waiting;
        if (waiting.list == list) {
            if (!kept(waiting.entry, keep)) {
                try space.freeNow(vol, waiting.entry.start, waiting.entry.count);
                continue;
            }
            moved.list = target;
        }
        st.waiting[left] = moved;
        left += 1;
    }
    st.len = left;
}

/// A list's entries sorted as `sortWaiting` sorts them - the kept ones
/// waiting for `target`'s list - and its blocks freed.
fn sortChain(vol: *Volume, list: DeadList, keep: ?u64, target: u32) Error!void {
    const block = try vol.alloc(vol.block_size);
    defer vol.free(block);
    var addr = list.head;
    var gen = list.head_gen;
    var steps: u64 = 0;
    while (addr != 0) : (steps += 1) {
        if (steps > vol.block_count) return error.Corrupt;
        for (try readDead(vol, addr, gen, block)) |entry| {
            if (kept(entry, keep)) {
                try wait(vol, target, entry);
            } else try space.freeNow(vol, entry.start, entry.count);
        }
        const behind = deadHeader(block).*;
        try space.freeNow(vol, addr, 1);
        addr = behind.next;
        gen = behind.next_gen;
    }
}

/// The volume put back to the snapshot at `index`, which must be the
/// newest (Exists when a newer one is there): its root becomes the live
/// tree's, what the live tree holds beyond it is freed, and its list's
/// blocks are the live tree's again. Recycled is on when the snapshot has
/// it. Committed by two checkpoints; the caller has seen that nothing on
/// the volume is in use.
pub fn rollback(vol: *Volume, index: usize) Error!void {
    if (vol.read_only or vol.failed) return error.ReadOnly;
    const table = vol.voltab;
    if (index >= table.snapshot_count) return error.NotFound;
    if (index + 1 != table.snapshot_count) return error.Exists;
    // The live tree all on the medium first, and nothing waiting.
    try checkpoint.write(vol, 0);
    const target = table.snapshots[index];
    try freeNewer(vol, vol.obj, target.gen);
    const block = try vol.alloc(vol.block_size);
    defer vol.free(block);
    try freeChain(vol, table.live_dead, block);
    table.live_dead = .{};
    btree.reset(&vol.obj, target.root, target.root_gen, target.height);
    if (try objects.inode(vol, posfs.recycled_oid) != null) {
        table.flags |= layout.VT_RECYCLED;
        table.compat |= layout.COMPAT_RECYCLED;
    } else {
        table.flags &= ~layout.VT_RECYCLED;
        table.compat &= ~layout.COMPAT_RECYCLED;
    }
    vol.voltab_dirty = true;
    try checkpoint.write(vol, 0);
    try checkpoint.write(vol, 0);
}

/// What `tree`, all on the medium, holds that was born after generation
/// `gen` freed: its nodes written after it and their extents that came
/// after it. A child no newer is shared with the tree as it was then, and
/// not read.
fn freeNewer(vol: *Volume, tree: btree.Tree, gen: u64) Error!void {
    if (tree.root_gen <= gen) return;
    var refs: [max_height]u64 = undefined;
    var gens: [max_height]u64 = undefined;
    var next: [max_height]u32 = undefined;
    var depth: u32 = 0;
    refs[0] = tree.root;
    gens[0] = tree.root_gen;
    next[0] = 0;
    const leaf = try vol.alloc(vol.block_size);
    defer vol.free(leaf);
    while (true) {
        const block = try btree.nodeAt(vol, &tree, refs[depth], gens[depth]);
        if (btree.header(block).level == 0) {
            // Freeing reads the bitmaps, which may take the node's place.
            @memcpy(leaf, block);
            for (btree.leafEntries(leaf)) |entry| {
                if (entry.key.kind != kind_extent) continue;
                const extent = try extentOf(btree.itemData(leaf, entry));
                if (extent.birth > gen) try space.freeNow(vol, extent.block, extent.blocks);
            }
        } else {
            const entries = btree.innerEntries(block);
            var down = false;
            while (next[depth] < entries.len) {
                const entry = entries[next[depth]];
                next[depth] += 1;
                if (entry.child_gen <= gen) continue;
                if (depth + 1 >= max_height) return error.Corrupt;
                depth += 1;
                refs[depth] = entry.child;
                gens[depth] = entry.child_gen;
                next[depth] = 0;
                down = true;
                break;
            }
            if (down) continue;
        }
        // Its children done: the node itself.
        try space.freeNow(vol, refs[depth], 1);
        if (depth == 0) return;
        depth -= 1;
    }
}

fn extentOf(data: []const u8) Error!layout.Extent {
    if (data.len != @sizeOf(layout.Extent)) return error.Corrupt;
    var extent: layout.Extent = undefined;
    @memcpy(layout.bytesOfMut(&extent), data);
    return extent;
}

// --- the check ---------------------------------------------------------------------------------

/// The snapshots checked a step at a time, after the live trees: the
/// table, the lists' blocks, every snapshot's own nodes and data, and
/// that each block only the snapshots hold is on one list.
pub const Checker = struct {
    const Stage = enum { table, name_lists, waiting_live, trees, take_lists, take_waiting, leftover, done };

    stage: Stage = .table,
    /// The table checked, and a durable check's own copy of it.
    table: *const layout.VolTab = undefined,
    copy: []u8 = &.{},
    /// The entries not on their lists yet (a live check's).
    waiting: []const Waiting = &.{},
    /// The blocks only the snapshots hold, each cleared when a list names
    /// it.
    only: check.Named = .{},
    block: []u8 = &.{},
    /// The list walked (0: the newest's, n: the n-th snapshot's), its next
    /// block, and what its entries add up to.
    list: u32 = 0,
    addr: u64 = 0,
    gen: u64 = 0,
    steps: u64 = 0,
    total: u64 = 0,
    /// The snapshot whose tree is walked, and where the walk is.
    index: u32 = 0,
    depth: u32 = 0,
    walking: bool = false,
    refs: [max_height]u64 = undefined,
    gens: [max_height]u64 = undefined,
    next: [max_height]u32 = undefined,

    /// A check of the snapshots in the volume table `slot` names (null:
    /// the one in memory, with the entries waiting).
    pub fn begin(checker: *Checker, vol: *Volume, slot: ?*const layout.CheckpointSlot) Error!void {
        checker.* = .{};
        errdefer checker.end(vol);
        checker.only = try check.Named.init(vol);
        checker.block = try vol.alloc(vol.block_size);
        if (slot) |durable| {
            checker.copy = try vol.alloc(layout.voltab_size);
            const table: *layout.VolTab = @ptrCast(@alignCast(checker.copy.ptr));
            try checkpoint.loadVoltab(vol, durable, table);
            checker.table = table;
        } else {
            checker.table = vol.voltab;
            checker.waiting = vol.snapshots.waiting[0..vol.snapshots.len];
        }
    }

    pub fn end(checker: *Checker, vol: *Volume) void {
        checker.only.deinit(vol);
        vol.free(checker.block);
        checker.block = &.{};
        vol.free(checker.copy);
        checker.copy = &.{};
    }

    /// One step: false once the check is done.
    pub fn step(checker: *Checker, vol: *Volume, named: *check.Named, report: *check.Report) Error!bool {
        switch (checker.stage) {
            .table => {
                checker.checkTable(report);
                checker.startList(0);
                checker.stage = .name_lists;
            },
            .name_lists => if (!try checker.listStep(vol, named, report)) {
                checker.stage = .waiting_live;
            },
            .waiting_live => {
                for (checker.waiting) |each| notLive(vol, each.entry, named, report);
                checker.index = 0;
                checker.walking = false;
                checker.stage = .trees;
            },
            .trees => if (!try checker.treeStep(vol, named, report)) {
                checker.startList(0);
                checker.stage = .take_lists;
            },
            .take_lists => if (!try checker.listStep(vol, null, report)) {
                checker.stage = .take_waiting;
            },
            .take_waiting => {
                for (checker.waiting) |each| checker.take(vol, each.entry, report);
                checker.stage = .leftover;
            },
            .leftover => {
                for (checker.only.bits, 0..) |byte, at| {
                    if (byte == 0) continue;
                    report.fail("a block only a snapshot holds is on no deadlist", at * 8 + @ctz(byte));
                    break;
                }
                checker.stage = .done;
            },
            .done => {},
        }
        return checker.stage != .done;
    }

    fn snapshotsOf(checker: *const Checker) []const Snapshot {
        const table = checker.table;
        const count = if (table.snapshot_count > posfs.max_snapshots) posfs.max_snapshots else table.snapshot_count;
        return table.snapshots[0..count];
    }

    fn checkTable(checker: *Checker, report: *check.Report) void {
        const table = checker.table;
        if (table.snapshot_count > posfs.max_snapshots) report.fail("too many snapshots", table.snapshot_count);
        const snapshots = checker.snapshotsOf();
        var before: u64 = 0;
        for (snapshots, 0..) |*snapshot, index| {
            if (snapshot.gen <= before) report.fail("snapshots out of order", snapshot.id);
            before = snapshot.gen;
            if (snapshot.id == 0 or snapshot.id >= table.next_snapshot_id) report.fail("a snapshot's id is wrong", snapshot.id);
            if (snapshot.name_len == 0 or snapshot.name_len > posfs.max_snapshot_name) report.fail("a snapshot's name is wrong", snapshot.id);
            for (snapshots[0..index]) |*earlier| {
                if (earlier.id == snapshot.id) report.fail("two snapshots with one id", snapshot.id);
                if (fold.same(nameOf(earlier), nameOf(snapshot))) report.fail("two snapshots with one name", snapshot.id);
            }
        }
        if (snapshots.len == 0 and (table.live_dead.head != 0 or checker.waiting.len != 0)) report.fail("a deadlist with no snapshot", table.live_dead.head);
        if (snapshots.len > 0 and table.ro_compat & layout.RO_COMPAT_SNAPSHOTS == 0) report.fail("snapshots the feature mask leaves out", snapshots.len);
    }

    /// The list `n` stands for, or null past the last.
    fn listAt(checker: *const Checker, n: u32) ?*const DeadList {
        if (n == 0) return &checker.table.live_dead;
        const snapshots = checker.snapshotsOf();
        if (n > snapshots.len) return null;
        return &snapshots[n - 1].dead;
    }

    fn startList(checker: *Checker, n: u32) void {
        checker.list = n;
        checker.steps = 0;
        checker.total = 0;
        checker.addr = 0;
        if (checker.listAt(n)) |list| {
            checker.addr = list.head;
            checker.gen = list.head_gen;
        }
    }

    /// One block of a list: with `named`, the block named there and its
    /// entries checked against it; without, its entries taken out of
    /// `only`. False once every list is done.
    fn listStep(checker: *Checker, vol: *Volume, named: ?*check.Named, report: *check.Report) Error!bool {
        const list = checker.listAt(checker.list) orelse return false;
        if (checker.addr != 0 and checker.steps > vol.block_count) {
            report.fail("a deadlist goes round", list.head);
            checker.addr = 0;
            checker.total = list.count;
        }
        if (checker.addr == 0) {
            if (named != null and checker.total != list.count) report.fail("a deadlist's count is off", list.head);
            checker.startList(checker.list + 1);
            return checker.listAt(checker.list) != null;
        }
        checker.steps += 1;
        const entries = readDead(vol, checker.addr, checker.gen, checker.block) catch |err| switch (err) {
            error.Corrupt, error.Io => {
                if (named != null) report.fail("a deadlist block does not read", checker.addr);
                checker.addr = 0;
                checker.total = list.count;
                return true;
            },
            else => return err,
        };
        if (named) |set| set.mark(vol, report, checker.addr, 1);
        for (entries) |entry| {
            checker.total += entry.count;
            if (named) |set| notLive(vol, entry, set, report) else checker.take(vol, entry, report);
        }
        const behind = deadHeader(checker.block).*;
        checker.addr = behind.next;
        checker.gen = behind.next_gen;
        return true;
    }

    /// An entry's blocks out of `only`: each must be there.
    fn take(checker: *Checker, vol: *const Volume, entry: DeadEntry, report: *check.Report) void {
        if (!inVolume(vol, entry)) return;
        var addr = entry.start;
        while (addr < entry.start + entry.count) : (addr += 1) {
            if (!checker.only.has(addr)) {
                report.fail("a deadlist names a block no snapshot holds alone", addr);
                return;
            }
            setBit(&checker.only, addr, false);
        }
    }

    /// One node of a snapshot's tree, or the step to the next snapshot:
    /// false once every tree is walked.
    fn treeStep(checker: *Checker, vol: *Volume, named: *check.Named, report: *check.Report) Error!bool {
        const snapshots = checker.snapshotsOf();
        if (!checker.walking) {
            if (checker.index >= snapshots.len) return false;
            const snapshot = &snapshots[checker.index];
            if (snapshot.root == 0 or snapshot.root >= vol.block_count or snapshot.height == 0 or snapshot.height > max_height) {
                report.fail("a snapshot's root is wrong", snapshot.id);
                checker.index += 1;
                return true;
            }
            // A root named already is another tree's: so is all below it.
            if (named.has(snapshot.root)) {
                checker.index += 1;
                return true;
            }
            checker.own(vol, named, report, snapshot.root);
            checker.depth = 0;
            checker.refs[0] = snapshot.root;
            checker.gens[0] = snapshot.root_gen;
            checker.next[0] = 0;
            checker.walking = true;
            return true;
        }
        const tree = treeOf(&snapshots[checker.index]);
        const depth = checker.depth;
        const block = btree.nodeAt(vol, &tree, checker.refs[depth], checker.gens[depth]) catch |err| switch (err) {
            error.Corrupt, error.Io => {
                report.fail("a snapshot's node does not read", checker.refs[depth]);
                checker.up();
                return true;
            },
            else => return err,
        };
        const header = btree.header(block);
        if (checker.next[depth] == 0) {
            report.nodes += 1;
            if (header.level + depth + 1 != tree.height) report.fail("a snapshot's node is at the wrong level", checker.refs[depth]);
        }
        if (header.level == 0) {
            for (btree.leafEntries(block)) |entry| {
                if (entry.key.kind != kind_extent) continue;
                const extent = extentOf(btree.itemData(block, entry)) catch {
                    report.fail("a snapshot's extent is short", entry.key.oid);
                    continue;
                };
                if (extent.block >= vol.block_count or extent.blocks > vol.block_count - extent.block) {
                    report.fail("a snapshot's extent is outside the volume", entry.key.oid);
                    continue;
                }
                var addr = extent.block;
                while (addr < extent.block + extent.blocks) : (addr += 1) {
                    if (!named.has(addr)) checker.own(vol, named, report, addr);
                }
            }
            checker.up();
            return true;
        }
        const entries = btree.innerEntries(block);
        while (checker.next[depth] < entries.len) {
            const entry = entries[checker.next[depth]];
            checker.next[depth] += 1;
            if (entry.child >= vol.block_count) {
                report.fail("a snapshot's node is outside the volume", entry.child);
                continue;
            }
            if (named.has(entry.child)) continue;
            if (entry.child_gen > header.gen) report.fail("a child newer than its parent", entry.child);
            if (depth + 1 >= max_height) {
                report.fail("a snapshot's tree is too deep", entry.child);
                continue;
            }
            checker.own(vol, named, report, entry.child);
            checker.depth += 1;
            checker.refs[checker.depth] = entry.child;
            checker.gens[checker.depth] = entry.child_gen;
            checker.next[checker.depth] = 0;
            return true;
        }
        checker.up();
        return true;
    }

    fn up(checker: *Checker) void {
        if (checker.depth == 0) {
            checker.walking = false;
            checker.index += 1;
        } else checker.depth -= 1;
    }

    /// A block only the snapshots name: named, and set in `only`.
    fn own(checker: *Checker, vol: *const Volume, named: *check.Named, report: *check.Report, addr: u64) void {
        named.mark(vol, report, addr, 1);
        setBit(&checker.only, addr, true);
    }
};

fn inVolume(vol: *const Volume, entry: DeadEntry) bool {
    return entry.count != 0 and entry.start < vol.block_count and entry.count <= vol.block_count - entry.start;
}

/// A list's entry: inside the volume, and none of its blocks named by the
/// live trees.
fn notLive(vol: *const Volume, entry: DeadEntry, named: *const check.Named, report: *check.Report) void {
    if (!inVolume(vol, entry)) {
        report.fail("a deadlist entry outside the volume", entry.start);
        return;
    }
    var addr = entry.start;
    while (addr < entry.start + entry.count) : (addr += 1) {
        if (named.has(addr)) {
            report.fail("a block on a deadlist is named by the live tree", addr);
            return;
        }
    }
}

fn setBit(set: *check.Named, addr: u64, on: bool) void {
    const index: usize = @intCast(addr);
    const mask = @as(u8, 1) << @intCast(index % 8);
    if (on) set.bits[index / 8] |= mask else set.bits[index / 8] &= ~mask;
}

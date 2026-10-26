// SPDX-License-Identifier: MPL-2.0
//! posfs's objects: inodes and their items, the records that change
//! them, and replay.
//!
//! **Every change is a record.** A packet that changes the volume builds
//! its record, appends it to the journal and applies it (`apply`): the
//! same code that replay runs on the records it finds after the
//! checkpoint it mounted. The record reaches the medium with the others
//! of its moment (`journal.flush`), and always before a checkpoint that
//! holds what it changed. A record carries everything its
//! change needs - oids, positions, times - so applying it reads neither
//! the clock nor file data, and gives the same tree every time. What it
//! depends on is checked again as it is applied (the object is there, the
//! name is free, a directory does not move into itself), so a journal that
//! does not fit its checkpoint stops replay instead of damaging the tree.
//!
//! **Replay** runs in two passes over the records after the checkpoint.
//! The first holds every block they need - the journal's own, and the
//! data blocks their commits name - so nothing the second does can give
//! one out; the second applies them, in order. A volume that replayed
//! anything writes a checkpoint before its first answer.

const sdk = @import("sdk");
const dos = sdk.dos;
const posfs = dos.posfs;
const layout = posfs.layout;
const fold = posfs.fold;
const volume = @import("volume.zig");
const btree = @import("btree.zig");
const space = @import("space.zig");
const journal = @import("journal.zig");
const checkpoint = @import("checkpoint.zig");
const dirs = @import("dirs.zig");
const files = @import("files.zig");
const recycled = @import("recycled.zig");
const check = @import("check.zig");
const Volume = volume.Volume;
const Error = volume.Error;
const Key = layout.Key;
const Inode = layout.Inode;

pub fn inodeKey(oid: u64) Key {
    return .{ .oid = oid, .kind = @intFromEnum(layout.Kind.inode) };
}

fn commentKey(oid: u64) Key {
    return .{ .oid = oid, .kind = @intFromEnum(layout.Kind.comment) };
}

fn linkKey(oid: u64, piece: u64) Key {
    return .{ .oid = oid, .kind = @intFromEnum(layout.Kind.link_target), .offset = piece };
}

pub fn isDir(entry_type: i32) bool {
    return entry_type == dos.ST_USERDIR or entry_type == dos.ST_ROOT;
}

// --- inodes --------------------------------------------------------------------------

/// An object's inode, copied out; null when there is none.
pub fn inode(vol: *Volume, oid: u64) Error!?Inode {
    return inodeIn(vol, &vol.obj, oid);
}

/// An object's inode in `tree` - the live tree or a snapshot's.
pub fn inodeIn(vol: *Volume, tree: *const btree.Tree, oid: u64) Error!?Inode {
    const data = try btree.find(vol, tree, inodeKey(oid)) orelse return null;
    if (data.len != @sizeOf(Inode)) return error.Corrupt;
    var node: Inode = undefined;
    @memcpy(layout.bytesOfMut(&node), data);
    return node;
}

/// An object's inode, which must be there.
pub fn needInode(vol: *Volume, oid: u64) Error!Inode {
    return try inode(vol, oid) orelse error.NotFound;
}

/// An object's inode written back.
pub fn putInode(vol: *Volume, oid: u64, node: *const Inode) Error!void {
    const target = try btree.modify(vol, &vol.obj, inodeKey(oid)) orelse return error.Corrupt;
    if (target.len != @sizeOf(Inode)) return error.Corrupt;
    @memcpy(target, layout.bytesOf(node));
}

/// An object's comment, copied into `into`.
pub fn comment(vol: *Volume, oid: u64, into: []u8) Error![]const u8 {
    return commentIn(vol, &vol.obj, oid, into);
}

pub fn commentIn(vol: *Volume, tree: *const btree.Tree, oid: u64, into: []u8) Error![]const u8 {
    const data = try btree.find(vol, tree, commentKey(oid)) orelse return into[0..0];
    if (data.len > posfs.max_comment or data.len > into.len) return error.Corrupt;
    @memcpy(into[0..data.len], data);
    return into[0..data.len];
}

/// A soft link's target, copied into `into`; its length, which may be
/// more than `into` holds.
pub fn linkTarget(vol: *Volume, oid: u64, into: []u8) Error!usize {
    return linkTargetIn(vol, &vol.obj, oid, into);
}

pub fn linkTargetIn(vol: *Volume, tree: *const btree.Tree, oid: u64, into: []u8) Error!usize {
    var len: usize = 0;
    var key = linkKey(oid, 0);
    while (try btree.seek(vol, tree, key)) |item| {
        if (item.key.oid != oid or item.key.kind != @intFromEnum(layout.Kind.link_target)) break;
        if (item.key.offset != len) return error.Corrupt;
        if (len < into.len) {
            const take = @min(item.data.len, into.len - len);
            @memcpy(into[len..][0..take], item.data[0..take]);
        }
        len += item.data.len;
        key = btree.successor(item.key);
    }
    return len;
}

/// The root of a new volume.
pub fn formatRoot(vol: *Volume) Error!void {
    const time = vol.now();
    const root: Inode = .{
        .entry_type = dos.ST_ROOT,
        .fold = layout.fold_1,
        .parent = posfs.root_oid,
        .mtime = time,
        .ctime = time,
        .btime = time,
    };
    try btree.insert(vol, &vol.obj, inodeKey(posfs.root_oid), layout.bytesOf(&root));
}

/// A directory changed by a name coming or going: dated, its archive bit
/// cleared, its count of entries moved by `delta`.
pub fn touchDir(vol: *Volume, dir: u64, time: u64, delta: i2) Error!void {
    var node = try inode(vol, dir) orelse return error.Corrupt;
    if (!isDir(node.entry_type)) return error.Corrupt;
    switch (delta) {
        1 => node.entries += 1,
        -1 => {
            if (node.entries == 0) return error.Corrupt;
            node.entries -= 1;
        },
        else => {},
    }
    node.mtime = time;
    node.ctime = time;
    node.protection &= ~dos.FIBF_ARCHIVE;
    try putInode(vol, dir, &node);
}

// --- changes ---------------------------------------------------------------------------

/// A change made: its record appended to the journal, then applied. It
/// is durable once the journal is next flushed - by the handler shortly
/// after, by ACTION_FLUSH, or by a checkpoint. What the record needs is
/// checked before; a change that fails to apply has its record written
/// all the same and stops all writing, and the next mount replays it.
pub fn change(vol: *Volume, kind: layout.Record, payload: []const u8) Error!void {
    if (vol.read_only or vol.failed) return error.ReadOnly;
    try checkpoint.startSession(vol);
    try journal.append(vol, kind, 0, &.{payload});
    apply(vol, kind, 0, payload) catch |err| {
        journal.flush(vol) catch {};
        vol.failed = true;
        return err;
    };
    if (checkpoint.due(vol)) try checkpoint.write(vol, 0);
}

// --- applying records ----------------------------------------------------------------

/// A record applied to the tree: live, right after it was written, or in
/// replay. `flags` are the record's.
pub fn apply(vol: *Volume, kind: layout.Record, flags: u32, payload: []const u8) Error!void {
    switch (kind) {
        .create => try applyCreate(vol, payload),
        .link => try applyLink(vol, payload),
        .unlink => try applyUnlink(vol, payload),
        .recycle => try recycled.applyRecycle(vol, payload),
        .rename => try applyRename(vol, payload),
        .set_attr => try applySetAttr(vol, payload),
        .commit => try files.applyCommit(vol, flags, payload),
        else => return error.Corrupt,
    }
}

/// A record's fixed part, read from the front of its payload.
pub fn fixed(comptime T: type, payload: []const u8) Error!T {
    if (payload.len < @sizeOf(T)) return error.Corrupt;
    var value: T = undefined;
    @memcpy(layout.bytesOfMut(&value), payload[0..@sizeOf(T)]);
    return value;
}

/// The bytes after a record's fixed part: `len` of them from `at.*`.
fn tail(payload: []const u8, at: *usize, len: usize) Error![]const u8 {
    if (len > payload.len - at.*) return error.Corrupt;
    const bytes = payload[at.*..][0..len];
    at.* += len;
    return bytes;
}

fn checkName(name: []const u8) Error!void {
    if (!fold.acceptable(name)) return error.Corrupt;
}

fn applyCreate(vol: *Volume, payload: []const u8) Error!void {
    const record = try fixed(layout.CreateRecord, payload);
    var at: usize = @sizeOf(layout.CreateRecord);
    const name = try tail(payload, &at, record.name_len);
    const target = try tail(payload, &at, record.link_len);
    try checkName(name);
    if (record.oid < posfs.first_user_oid) return error.Corrupt;
    if (try inode(vol, record.oid) != null) return error.Corrupt;
    if (try dirs.at(vol, record.parent, record.pos) != null) return error.Corrupt;
    if (try dirs.lookup(vol, record.parent, name) != null) return error.Corrupt;
    switch (record.entry_type) {
        dos.ST_FILE, dos.ST_USERDIR => if (target.len != 0) return error.Corrupt,
        dos.ST_SOFTLINK => if (target.len == 0 or target.len > posfs.max_link) return error.Corrupt,
        else => return error.Corrupt,
    }
    const node: Inode = .{
        .entry_type = record.entry_type,
        .protection = record.protection,
        .owner_uid = record.owner_uid,
        .owner_gid = record.owner_gid,
        .fold = if (record.entry_type == dos.ST_USERDIR) record.fold else 0,
        .pos = @intCast(record.pos),
        .parent = record.parent,
        .mtime = record.time,
        .ctime = record.time,
        .btime = record.time,
    };
    if (node.entry_type == dos.ST_USERDIR and node.fold != layout.fold_1) return error.Corrupt;
    try touchDir(vol, record.parent, record.time, 1);
    try btree.insert(vol, &vol.obj, inodeKey(record.oid), layout.bytesOf(&node));
    var piece: usize = 0;
    const most = layout.itemMax(vol.block_size);
    while (piece < target.len) {
        const len = @min(most, target.len - piece);
        try btree.insert(vol, &vol.obj, linkKey(record.oid, piece), target[piece..][0..len]);
        piece += len;
    }
    try dirs.add(vol, record.parent, record.pos, record.oid, record.entry_type, name);
    if (record.oid >= vol.next_oid) vol.next_oid = record.oid + 1;
}

fn applyLink(vol: *Volume, payload: []const u8) Error!void {
    const record = try fixed(layout.LinkRecord, payload);
    var at: usize = @sizeOf(layout.LinkRecord);
    const name = try tail(payload, &at, record.name_len);
    try checkName(name);
    var node = try inode(vol, record.oid) orelse return error.Corrupt;
    if (node.entry_type != dos.ST_FILE or node.nlink == 0xFFFF_FFFF) return error.Corrupt;
    if (try dirs.at(vol, record.parent, record.pos) != null) return error.Corrupt;
    if (try dirs.lookup(vol, record.parent, name) != null) return error.Corrupt;
    try touchDir(vol, record.parent, record.time, 1);
    node.nlink += 1;
    node.ctime = record.time;
    // A file whose own name went while it kept others is in a directory
    // again.
    if (node.parent == 0) {
        node.parent = record.parent;
        node.pos = @intCast(record.pos);
    }
    try putInode(vol, record.oid, &node);
    try dirs.add(vol, record.parent, record.pos, record.oid, node.entry_type, name);
}

fn applyUnlink(vol: *Volume, payload: []const u8) Error!void {
    const record = try fixed(layout.UnlinkRecord, payload);
    if (record.mode != layout.unlink_now and record.mode != layout.unlink_job) return error.Corrupt;
    const entry = try dirs.at(vol, record.parent, record.pos) orelse return error.Corrupt;
    if (entry.oid != record.oid) return error.Corrupt;
    var node = try inode(vol, record.oid) orelse return error.Corrupt;
    if (isDir(node.entry_type) and try dirs.hasEntries(vol, record.oid)) return error.Corrupt;
    try dirs.remove(vol, record.parent, record.pos);
    try touchDir(vol, record.parent, record.time, -1);
    if (node.nlink > 1) {
        node.nlink -= 1;
        node.ctime = record.time;
        if (node.parent == record.parent and node.pos == record.pos) {
            node.parent = 0;
            node.pos = 0;
        }
        try putInode(vol, record.oid, &node);
        return;
    }
    // A delete in Recycled is for good.
    if (record.parent == posfs.recycled_oid) try recycled.forget(vol, record.oid, &node);
    if (record.mode == layout.unlink_job) return recycled.orphan(vol, record.oid, &node, record.time);
    try destroy(vol, record.oid);
}

/// An object with no name left gone, with everything it has.
pub fn destroy(vol: *Volume, oid: u64) Error!void {
    _ = try files.dropFrom(vol, oid, 0);
    _ = try btree.remove(vol, &vol.obj, commentKey(oid));
    // Whatever else is keyed by the object: a link's target, attributes.
    while (try btree.seek(vol, &vol.obj, .{ .oid = oid, .kind = 0 })) |item| {
        if (item.key.oid != oid) break;
        if (item.key.kind == @intFromEnum(layout.Kind.dir_entry)) return error.Corrupt;
        if (!try btree.remove(vol, &vol.obj, item.key)) return error.Corrupt;
    }
}

fn applyRename(vol: *Volume, payload: []const u8) Error!void {
    const record = try fixed(layout.RenameRecord, payload);
    var at: usize = @sizeOf(layout.RenameRecord);
    const name = try tail(payload, &at, record.name_len);
    try checkName(name);
    const entry = try dirs.at(vol, record.from_parent, record.from_pos) orelse return error.Corrupt;
    if (entry.oid != record.oid) return error.Corrupt;
    var node = try inode(vol, record.oid) orelse return error.Corrupt;
    const same_place = record.from_parent == record.to_parent and record.from_pos == record.to_pos;
    if (!same_place and try dirs.at(vol, record.to_parent, record.to_pos) != null) return error.Corrupt;
    if (try dirs.lookup(vol, record.to_parent, name)) |there| {
        if (there.oid != record.oid) return error.Corrupt;
    }
    if (isDir(node.entry_type) and try within(vol, record.to_parent, record.oid)) return error.Corrupt;
    // Into Recycled only a delete goes; out of it is an undelete.
    const leaving = record.from_parent == posfs.recycled_oid;
    if (record.to_parent == posfs.recycled_oid and !leaving) return error.Corrupt;
    if (leaving and record.to_parent != posfs.recycled_oid) try recycled.forget(vol, record.oid, &node);
    try dirs.remove(vol, record.from_parent, record.from_pos);
    try dirs.add(vol, record.to_parent, record.to_pos, record.oid, node.entry_type, name);
    if (record.from_parent == record.to_parent) {
        try touchDir(vol, record.to_parent, record.time, 0);
    } else {
        try touchDir(vol, record.from_parent, record.time, -1);
        try touchDir(vol, record.to_parent, record.time, 1);
    }
    if (node.parent == record.from_parent and node.pos == record.from_pos) {
        node.parent = record.to_parent;
        node.pos = @intCast(record.to_pos);
    }
    node.ctime = record.time;
    try putInode(vol, record.oid, &node);
}

/// Whether directory `dir` is `oid` or inside it.
pub fn within(vol: *Volume, dir: u64, oid: u64) Error!bool {
    var at = dir;
    var steps: u32 = 0;
    while (true) : (steps += 1) {
        if (at == oid) return true;
        if (at == posfs.root_oid) return false;
        if (steps > 65536) return error.Corrupt;
        const node = try inode(vol, at) orelse return error.Corrupt;
        if (!isDir(node.entry_type)) return error.Corrupt;
        at = node.parent;
    }
}

fn applySetAttr(vol: *Volume, payload: []const u8) Error!void {
    const record = try fixed(layout.SetAttrRecord, payload);
    var at: usize = @sizeOf(layout.SetAttrRecord);
    const text = try tail(payload, &at, record.comment_len);
    var node = try inode(vol, record.oid) orelse return error.Corrupt;
    if (record.mask & layout.ATTR_PROTECTION != 0) node.protection = record.protection;
    if (record.mask & layout.ATTR_OWNER != 0) {
        node.owner_uid = record.owner_uid;
        node.owner_gid = record.owner_gid;
    }
    if (record.mask & layout.ATTR_DATE != 0) node.mtime = record.date;
    if (record.mask & layout.ATTR_COMMENT != 0) {
        if (text.len > posfs.max_comment) return error.Corrupt;
        if (text.len == 0) {
            _ = try btree.remove(vol, &vol.obj, commentKey(record.oid));
        } else try btree.put(vol, &vol.obj, commentKey(record.oid), text);
    }
    node.ctime = record.time;
    try putInode(vol, record.oid, &node);
}

// --- replay ----------------------------------------------------------------------------

/// A journal block replay passes through: held, and kept by the
/// journal until checkpoints let it go.
fn sawBlock(scanner: *journal.Scanner, addr: u64, jseq: u64, next: u64) Error!void {
    _ = next;
    const vol = scanner.vol;
    try space.claim(vol, addr, 1);
    try journal.adopt(vol, addr, jseq);
    if (jseq > vol.journal.highest_jseq) vol.journal.highest_jseq = jseq;
}

/// Replay's outcome, for the volume's report.
pub const Replayed = struct { records: u64 = 0, stopped: bool = false };

/// What the journal holds after the checkpoint mounted, applied.
pub fn replay(vol: *Volume) Error!Replayed {
    var result: Replayed = .{};
    if (!vol.unclean) return result;
    const buffer = try vol.alloc(vol.block_size);
    defer vol.free(buffer);
    var assembly: journal.Assembly = .{};
    defer assembly.deinit(vol);

    // The first pass: what the records need, held.
    var scanner = journal.Scanner.init(vol, buffer, &vol.durable);
    scanner.on_block = sawBlock;
    var count: u64 = 0;
    while (try scanner.nextWhole(&assembly)) |record| {
        if (record.kind == .commit) try files.claimCommit(vol, record.payload);
        count += 1;
    }
    if (count == 0) return result;

    // The second: applied.
    scanner = journal.Scanner.init(vol, buffer, &vol.durable);
    var applied: u64 = 0;
    while (applied < count) : (applied += 1) {
        const record = try scanner.nextWhole(&assembly) orelse return error.Corrupt;
        apply(vol, record.kind, record.flags, record.payload) catch |err| switch (err) {
            error.Corrupt => {
                // What it needs is not there: the volume stays as far as
                // replay got, and is not written.
                vol.read_only = true;
                result.stopped = true;
                break;
            },
            else => return err,
        };
        result.records += 1;
    }
    vol.journal.lsn = scanner.lsn;
    if (!vol.read_only) try checkpoint.startSession(vol);
    return result;
}

// --- the check -----------------------------------------------------------------------------

/// A name's count against its object's links, and the type its names
/// give it.
const NameCount = struct { oid: u64, names: u32, entry_type: i32 };

/// An object in Recycled and its number in the queue.
const Queued = struct { oid: u64, rseq: u64 };

/// The object tree's items as the check walks them, and every name's
/// object, counted against the objects afterwards.
pub const Walk = struct {
    vol: *Volume,
    named: *check.Named,
    /// The object whose items the walk is in, and what is known of it.
    oid: u64 = 0,
    node: ?Inode = null,
    entries: u64 = 0,
    data_end: u64 = 0,
    data_blocks: u64 = 0,
    link_len: u64 = 0,
    /// The checksummed extents' blocks, and the crcs the csum items hold.
    csum_wanted: u64 = 0,
    csum_held: u64 = 0,
    /// Every name's object, counted in a second walk; `unique` of them
    /// once settled, an object each.
    names: []NameCount = &.{},
    name_count: usize = 0,
    unique: usize = 0,
    /// The objects walked.
    seen: u64 = 0,
    failed_alloc: bool = false,
    /// Whether the volume table checked with the tree has Recycled on, and
    /// what of it the walk found: its directory, its totals, its queue,
    /// the objects with an origin and what their data takes.
    recycled_on: bool = false,
    saw_recycled: bool = false,
    totals: ?layout.RecycleStats = null,
    queue: []Queued = &.{},
    queue_count: usize = 0,
    origins: []Queued = &.{},
    origin_count: usize = 0,
    recycled_bytes: u64 = 0,
    /// The object walked has an origin.
    has_origin: bool = false,
    /// The orphan items' objects, in order, and how far the inodes have
    /// been matched against them.
    orphans: []u64 = &.{},
    orphan_count: usize = 0,
    orphan_index: usize = 0,

    pub fn deinit(walk: *Walk, vol: *Volume) void {
        vol.freeSlice(NameCount, walk.names);
        walk.names = &.{};
        walk.name_count = 0;
        walk.unique = 0;
        vol.freeSlice(Queued, walk.queue);
        walk.queue = &.{};
        walk.queue_count = 0;
        vol.freeSlice(Queued, walk.origins);
        walk.origins = &.{};
        walk.origin_count = 0;
        vol.freeSlice(u64, walk.orphans);
        walk.orphans = &.{};
        walk.orphan_count = 0;
    }

    /// The walk's end: its last object finished, and the names sorted and
    /// counted by object.
    pub fn settle(walk: *Walk, report: *check.Report) Error!void {
        walk.finishObject(report);
        walk.node = null;
        if (walk.failed_alloc) return error.NoMemory;
        const names = walk.names[0..walk.name_count];
        sortByOid(NameCount, names);
        var unique: usize = 0;
        for (names) |entry| {
            if (unique > 0 and names[unique - 1].oid == entry.oid) {
                names[unique - 1].names += 1;
                if (names[unique - 1].entry_type != entry.entry_type) report.fail("an object's names give it different types", entry.oid);
            } else {
                names[unique] = entry;
                unique += 1;
            }
        }
        walk.unique = unique;

        // Recycled's queue against the objects in it, and its totals.
        if (walk.recycled_on and !walk.saw_recycled) report.fail("Recycled is on but not there", posfs.recycled_oid);
        const queue = walk.queue[0..walk.queue_count];
        sortByOid(Queued, queue);
        const origins = walk.origins[0..walk.origin_count];
        var same = queue.len == origins.len;
        if (same) {
            for (queue, origins) |queued, origin| {
                if (queued.oid != origin.oid or queued.rseq != origin.rseq) same = false;
            }
        }
        if (!same) report.fail("Recycled's queue is not what it holds", posfs.recycled_oid);
        if (walk.totals) |totals| {
            if (totals.count != origins.len or totals.bytes != walk.recycled_bytes) report.fail("Recycled's totals are off", posfs.recycled_oid);
            for (queue) |queued| {
                if (queued.rseq >= totals.next_rseq) report.fail("a number in Recycled's queue not given out yet", queued.oid);
            }
        } else if (walk.saw_recycled) report.fail("Recycled has no totals", posfs.recycled_oid);
        while (walk.orphan_index < walk.orphan_count) : (walk.orphan_index += 1) report.fail("an orphan item of no object", walk.orphans[walk.orphan_index]);
    }

    fn finishObject(walk: *Walk, report: *check.Report) void {
        const node = walk.node orelse return;
        if (isDir(node.entry_type)) {
            if (walk.entries != node.entries) report.fail("a directory's entry count is off", walk.oid);
        } else if (node.entry_type == dos.ST_FILE) {
            if (walk.data_end > node.size and node.flags & layout.INODE_INLINE == 0) report.fail("a file's data lies past its end", walk.oid);
            if (walk.data_blocks != node.blocks) report.fail("a file's block count is off", walk.oid);
        } else if (node.entry_type == dos.ST_SOFTLINK) {
            if (walk.link_len == 0 or walk.link_len > posfs.max_link) report.fail("a soft link's target is no path", walk.oid);
        }
        if (node.entry_type != dos.ST_SOFTLINK and walk.link_len != 0) report.fail("a link target on what is no soft link", walk.oid);
        if (walk.csum_wanted != walk.csum_held) report.fail("a file's crcs do not match its checksummed extents", walk.oid);
        const in_recycled = node.parent == posfs.recycled_oid;
        if (in_recycled != walk.has_origin) report.fail("an object in Recycled has no origin, or one elsewhere has", walk.oid);
        if (in_recycled and isDir(node.entry_type) and walk.entries != 0) report.fail("a directory in Recycled holds names", walk.oid);
    }

    /// `value` put at the end of a list that grows as it must.
    fn append(walk: *Walk, comptime T: type, list: *[]T, count: *usize, value: T) void {
        const vol = walk.vol;
        if (count.* == list.len) {
            const grown = vol.allocSlice(T, if (list.len == 0) 64 else list.len * 2) catch {
                walk.failed_alloc = true;
                return;
            };
            @memcpy(grown[0..count.*], list.*[0..count.*]);
            vol.freeSlice(T, list.*);
            list.* = grown;
        }
        list.*[count.*] = value;
        count.* += 1;
    }
};

pub fn visitItem(walk: *Walk, vol: *Volume, key: Key, data: []const u8, report: *check.Report) Error!void {
    if (key.oid != walk.oid) {
        walk.finishObject(report);
        walk.oid = key.oid;
        walk.node = null;
        walk.entries = 0;
        walk.data_end = 0;
        walk.data_blocks = 0;
        walk.link_len = 0;
        walk.csum_wanted = 0;
        walk.csum_held = 0;
        walk.has_origin = false;
    }
    const kind: layout.Kind = @enumFromInt(key.kind);
    switch (kind) {
        .inode => {
            walk.seen += 1;
            if (data.len != @sizeOf(Inode)) return report.fail("an inode of the wrong size", key.oid);
            var node: Inode = undefined;
            @memcpy(layout.bytesOfMut(&node), data);
            walk.node = node;
            if (key.oid == posfs.recycled_oid) {
                walk.saw_recycled = true;
                if (!walk.recycled_on) report.fail("Recycled is there while it is off", key.oid);
            }
            // The orphan items come before every object they name.
            var listed = false;
            while (walk.orphan_index < walk.orphan_count and walk.orphans[walk.orphan_index] <= key.oid) : (walk.orphan_index += 1) {
                if (walk.orphans[walk.orphan_index] == key.oid) {
                    listed = true;
                } else report.fail("an orphan item of no object", walk.orphans[walk.orphan_index]);
            }
            if (listed != (node.flags & layout.INODE_ORPHAN != 0)) report.fail("an orphan and its item do not go together", key.oid);
        },
        .dir_entry => {
            const node = walk.node orelse return report.fail("a name in a directory that is not there", key.oid);
            if (!isDir(node.entry_type)) return report.fail("a name in a file", key.oid);
            walk.entries += 1;
            if (data.len < @sizeOf(layout.DirEntry)) return report.fail("a name's entry is short", key.oid);
            var head: layout.DirEntry = undefined;
            @memcpy(layout.bytesOfMut(&head), data[0..@sizeOf(layout.DirEntry)]);
            const name = data[@sizeOf(layout.DirEntry)..];
            if (head.name_len != name.len or !fold.acceptable(name)) return report.fail("a name that is no name", key.oid);
            if (fold.bucketOf(fold.hash(name)) != key.offset >> 8 or key.offset & 0xFF >= fold.bucket_slots) report.fail("a name in the wrong place", key.oid);
            walk.append(NameCount, &walk.names, &walk.name_count, .{ .oid = head.oid, .names = 1, .entry_type = head.entry_type });
        },
        .extent => {
            if (data.len != @sizeOf(layout.Extent)) return report.fail("an extent of the wrong size", key.oid);
            var extent: layout.Extent = undefined;
            @memcpy(layout.bytesOfMut(&extent), data);
            if (key.offset < walk.data_end) report.fail("extents overlap", key.oid);
            walk.data_end = key.offset + extent.length;
            walk.data_blocks += extent.blocks;
            if (extent.blocks == 0 or extent.length == 0) report.fail("an empty extent", key.oid);
            if (extent.compressed()) {
                if (key.offset % layout.chunk_size != 0 or extent.length > layout.chunk_size) report.fail("a compressed extent that is no chunk", key.oid);
                if (extent.stored == 0 or extent.stored > @as(u64, extent.blocks) * vol.block_size) report.fail("a compressed extent's bytes do not fit its blocks", key.oid);
            } else {
                if (extent.length > @as(u64, extent.blocks) * vol.block_size) report.fail("an extent longer than its blocks", key.oid);
                if (extent.checksummed()) {
                    if (extent.blocks > layout.csumPerItem(vol.block_size)) report.fail("a checksummed extent longer than its crcs", key.oid);
                    walk.csum_wanted += extent.blocks;
                }
            }
            walk.named.mark(vol, report, extent.block, extent.blocks);
        },
        .inline_data => {
            const node = walk.node orelse return report.fail("data of no object", key.oid);
            if (node.flags & layout.INODE_INLINE == 0 or data.len != node.size) report.fail("inline data that does not fit its file", key.oid);
        },
        .comment => if (data.len > posfs.max_comment) report.fail("a comment too long", key.oid),
        .csum => {
            if (data.len % 4 != 0) report.fail("a csum item of no whole crcs", key.oid);
            walk.csum_held += data.len / 4;
        },
        .link_target => {
            if (key.offset != walk.link_len) report.fail("a soft link's target has a gap", key.oid);
            walk.link_len += data.len;
        },
        .recycle => {
            const node = walk.node orelse return report.fail("an origin of no object", key.oid);
            if (data.len < @sizeOf(layout.Recycle)) return report.fail("an origin that is short", key.oid);
            var head: layout.Recycle = undefined;
            @memcpy(layout.bytesOfMut(&head), data[0..@sizeOf(layout.Recycle)]);
            const name = data[@sizeOf(layout.Recycle)..];
            if (head.name_len != name.len or !fold.acceptable(name)) report.fail("an origin's name is no name", key.oid);
            walk.has_origin = true;
            walk.recycled_bytes += node.blocks << vol.block_shift;
            walk.append(Queued, &walk.origins, &walk.origin_count, .{ .oid = key.oid, .rseq = head.rseq });
        },
        .recycle_stats => {
            if (key.oid != posfs.recycled_oid or data.len != @sizeOf(layout.RecycleStats)) return report.fail("Recycled's totals are no totals", key.oid);
            var totals: layout.RecycleStats = undefined;
            @memcpy(layout.bytesOfMut(&totals), data);
            walk.totals = totals;
        },
        .recycle_queue => {
            if (key.oid != posfs.recycled_oid or data.len != @sizeOf(layout.RecycleQueue)) return report.fail("Recycled's queue has a stray item", key.oid);
            var queued: layout.RecycleQueue = undefined;
            @memcpy(layout.bytesOfMut(&queued), data);
            walk.append(Queued, &walk.queue, &walk.queue_count, .{ .oid = queued.oid, .rseq = key.offset });
        },
        .orphan => {
            if (key.oid != posfs.orphan_oid or data.len != @sizeOf(layout.Orphan)) return report.fail("an orphan item that is none", key.oid);
            walk.append(u64, &walk.orphans, &walk.orphan_count, key.offset);
        },
        else => {},
    }
}

/// The next object of `tree` from `key` on checked against its names and
/// the name it says it has: false when no object is left. `key` and
/// `index` (into the settled names) keep the place.
pub fn checkInode(walk: *Walk, tree: *const btree.Tree, key: *Key, index: *usize, report: *check.Report) Error!bool {
    const vol = walk.vol;
    const names = walk.names[0..walk.unique];
    const item = try btree.seek(vol, tree, key.*) orelse {
        while (index.* < names.len) : (index.* += 1) report.fail("a name of an object that is not there", names[index.*].oid);
        return false;
    };
    const oid = item.key.oid;
    key.* = .{ .oid = oid + 1, .kind = 0 };
    if (item.key.kind != @intFromEnum(layout.Kind.inode) or item.data.len != @sizeOf(Inode)) return true;
    var node: Inode = undefined;
    @memcpy(layout.bytesOfMut(&node), item.data);
    if (oid != posfs.root_oid) {
        if (node.parent != 0) {
            const found = btree.find(vol, tree, dirs.entryKey(node.parent, node.pos)) catch |err| switch (err) {
                error.Corrupt, error.Io => null,
                else => return err,
            };
            var head: layout.DirEntry = .{};
            if (found) |data| {
                if (data.len >= @sizeOf(layout.DirEntry)) @memcpy(layout.bytesOfMut(&head), data[0..@sizeOf(layout.DirEntry)]);
            }
            if (head.oid != oid) report.fail("an object's name is not where it says", oid);
        } else if (node.entry_type != dos.ST_FILE) report.fail("a directory or a link does not say where it is", oid);
    }
    while (index.* < names.len and names[index.*].oid < oid) : (index.* += 1) report.fail("a name of an object that is not there", names[index.*].oid);
    var count: u32 = 0;
    if (index.* < names.len and names[index.*].oid == oid) {
        count = names[index.*].names;
        if (names[index.*].entry_type != node.entry_type) report.fail("a name's type is not its object's", oid);
        index.* += 1;
    }
    if (oid == posfs.root_oid) {
        if (count != 0) report.fail("a name for the root", oid);
    } else if (count != node.nlink) {
        report.fail("an object's link count is off", oid);
    } else if (count == 0 and node.flags & layout.INODE_ORPHAN == 0) report.fail("an object with no name", oid);
    return true;
}

/// Items with an `oid` sorted by it.
fn sortByOid(comptime T: type, items: []T) void {
    var gap = items.len / 2;
    while (gap > 0) : (gap /= 2) {
        var at = gap;
        while (at < items.len) : (at += 1) {
            const moving = items[at];
            var to = at;
            while (to >= gap and items[to - gap].oid > moving.oid) : (to -= gap) items[to] = items[to - gap];
            items[to] = moving;
        }
    }
}

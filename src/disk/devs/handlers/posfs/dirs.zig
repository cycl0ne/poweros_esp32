// SPDX-License-Identifier: MPL-2.0
//! The names in a posfs directory.
//!
//! **A name is an item** of the object tree, keyed by its directory and
//! its position there - `DirEntry` (the object, its type, the name's
//! length) and the name's bytes. The position is the top 24 bits of the
//! crc32 of the folded name, shifted up a byte, and a slot number in the
//! low byte (0 to 254): the names whose hashes meet share a bucket, and
//! a lookup reads that bucket only. A directory's items lie together and
//! in position order, so going through it is a walk along the tree.
//!
//! **Names are UTF-8** here and on the medium. Names from dos are
//! Latin-1 for now: `fromDos` makes one UTF-8, `lookupDos` finds a name
//! by what dos was given for it - the name itself, or its stand-in,
//! found in the run of buckets its tag says.
//!
//! What an entry's name points at is a node's bytes, good until the tree
//! is next touched.

const sdk = @import("sdk");
const dos = sdk.dos;
const posfs = dos.posfs;
const layout = posfs.layout;
const fold = posfs.fold;
const volume = @import("volume.zig");
const btree = @import("btree.zig");
const Volume = volume.Volume;
const Error = volume.Error;
const Key = layout.Key;

pub const Entry = struct {
    pos: u64,
    oid: u64,
    entry_type: i32,
    name: []const u8,
};

const kind_entry: u32 = @intFromEnum(layout.Kind.dir_entry);

pub fn entryKey(dir: u64, pos: u64) Key {
    return .{ .oid = dir, .kind = kind_entry, .offset = pos };
}

/// The entry an item is, or null when it is no entry of `dir`.
fn entryOf(item: btree.Item, dir: u64) Error!?Entry {
    if (item.key.oid != dir or item.key.kind != kind_entry) return null;
    if (item.data.len < @sizeOf(layout.DirEntry)) return error.Corrupt;
    var head: layout.DirEntry = undefined;
    @memcpy(layout.bytesOfMut(&head), item.data[0..@sizeOf(layout.DirEntry)]);
    if (head.name_len == 0 or head.name_len > posfs.max_name) return error.Corrupt;
    if (item.data.len != @sizeOf(layout.DirEntry) + head.name_len) return error.Corrupt;
    return .{
        .pos = item.key.offset,
        .oid = head.oid,
        .entry_type = head.entry_type,
        .name = item.data[@sizeOf(layout.DirEntry)..],
    };
}

/// The bucket a name hashes to.
fn bucketOfName(name: []const u8) u32 {
    return fold.bucketOf(fold.hash(name));
}

/// The entry at `pos`, if there is one.
pub fn at(vol: *Volume, dir: u64, pos: u64) Error!?Entry {
    return atIn(vol, &vol.obj, dir, pos);
}

/// The entry at `pos` in `tree` - the live tree or a snapshot's.
pub fn atIn(vol: *Volume, tree: *const btree.Tree, dir: u64, pos: u64) Error!?Entry {
    const key = entryKey(dir, pos);
    const data = try btree.find(vol, tree, key) orelse return null;
    return try entryOf(.{ .key = key, .data = data }, dir);
}

/// The first entry at `pos` or after it: what ExNext gives next.
pub fn following(vol: *Volume, dir: u64, pos: u64) Error!?Entry {
    return followingIn(vol, &vol.obj, dir, pos);
}

pub fn followingIn(vol: *Volume, tree: *const btree.Tree, dir: u64, pos: u64) Error!?Entry {
    const item = try btree.seek(vol, tree, entryKey(dir, pos)) orelse return null;
    return entryOf(item, dir);
}

/// Whether a directory has names in it.
pub fn hasEntries(vol: *Volume, dir: u64) Error!bool {
    return try following(vol, dir, 0) != null;
}

/// The entry with name `name` (UTF-8), compared without case.
pub fn lookup(vol: *Volume, dir: u64, name: []const u8) Error!?Entry {
    return lookupIn(vol, &vol.obj, dir, name);
}

pub fn lookupIn(vol: *Volume, tree: *const btree.Tree, dir: u64, name: []const u8) Error!?Entry {
    const bucket = bucketOfName(name);
    const last = fold.position(bucket, fold.bucket_slots - 1);
    var key = entryKey(dir, fold.position(bucket, 0));
    while (try btree.seek(vol, tree, key)) |item| {
        if (item.key.offset > last) return null;
        const entry = try entryOf(item, dir) orelse return null;
        if (fold.same(entry.name, name)) return entry;
        key = btree.successor(item.key);
    }
    return null;
}

/// The entry dos names `dos_name`: the name, or the stand-in it was given.
pub fn lookupDos(vol: *Volume, dir: u64, dos_name: []const u8) Error!?Entry {
    return lookupDosIn(vol, &vol.obj, dir, dos_name);
}

pub fn lookupDosIn(vol: *Volume, tree: *const btree.Tree, dir: u64, dos_name: []const u8) Error!?Entry {
    var buffer: [posfs.max_name]u8 = undefined;
    const name = try fromDos(dos_name, &buffer);
    if (try lookupIn(vol, tree, dir, name)) |entry| return entry;
    const tag = fold.tagOf(dos_name) orelse return null;
    const range = fold.tagRange(tag);
    var key = entryKey(dir, range.first);
    var shown: [posfs.max_name]u8 = undefined;
    while (try btree.seek(vol, tree, key)) |item| {
        if (item.key.offset > range.last) return null;
        const entry = try entryOf(item, dir) orelse return null;
        if (fold.sameLatin1(fold.toDos(entry.name, &shown), dos_name)) return entry;
        key = btree.successor(item.key);
    }
    return null;
}

/// A position for a new name: the lowest slot of its bucket that is
/// free, or that `leaving` (a position) frees.
pub fn freePosition(vol: *Volume, dir: u64, name: []const u8, leaving: ?u64) Error!u64 {
    const bucket = bucketOfName(name);
    var slot: u32 = 0;
    while (slot < fold.bucket_slots) : (slot += 1) {
        const pos = fold.position(bucket, slot);
        if (leaving != null and leaving.? == pos) return pos;
        if (try btree.find(vol, &vol.obj, entryKey(dir, pos)) == null) return pos;
    }
    return error.DiskFull;
}

/// A name put in at `pos`.
pub fn add(vol: *Volume, dir: u64, pos: u64, oid: u64, entry_type: i32, name: []const u8) Error!void {
    var item: [@sizeOf(layout.DirEntry) + posfs.max_name]u8 = undefined;
    const head: layout.DirEntry = .{ .oid = oid, .entry_type = entry_type, .name_len = @intCast(name.len) };
    @memcpy(item[0..@sizeOf(layout.DirEntry)], layout.bytesOf(&head));
    @memcpy(item[@sizeOf(layout.DirEntry)..][0..name.len], name);
    try btree.insert(vol, &vol.obj, entryKey(dir, pos), item[0 .. @sizeOf(layout.DirEntry) + name.len]);
}

/// The name at `pos` taken out.
pub fn remove(vol: *Volume, dir: u64, pos: u64) Error!void {
    if (!try btree.remove(vol, &vol.obj, entryKey(dir, pos))) return error.Corrupt;
}

/// A name from dos as UTF-8, checked: one a new entry may have.
pub fn fromDos(dos_name: []const u8, into: *[posfs.max_name]u8) Error![]const u8 {
    if (dos_name.len == 0) return error.BadName;
    const name = fold.fromDos(dos_name, into) orelse return error.BadName;
    if (!fold.acceptable(name)) return error.BadName;
    for (name) |byte| {
        if (byte < 0x20) return error.BadName;
    }
    return name;
}

/// Whether a name is one posfs keeps for itself in the root.
pub fn reservedInRoot(name: []const u8) bool {
    return fold.same(name, posfs.snapshots_name);
}

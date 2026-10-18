// SPDX-License-Identifier: MPL-2.0
//! Recycled, where a volume's deleted objects wait to be given back, and
//! the orphans, objects with no name left whose data goes a part at a
//! time.
//!
//! **Recycled is a directory** (`recycled_oid`) in the root, named
//! `Recycled`, there while the volume table's VT_RECYCLED is on. A delete
//! of an object's last name - a file's, an empty directory's, a soft
//! link's - moves that name into it instead (a RECYCLE record): the name
//! it had, or with `.1`, `.2`, ... behind it when Recycled has that name
//! already. The object is given a recycle item, the directory it was in,
//! its name there, when it went and its number in the queue. Recycled's
//! own items are the queue - one item a number, numbers counted up over
//! the volume's life, so the oldest comes first - and what it holds
//! altogether (RecycleStats: the objects, the bytes of their data, the
//! next number).
//!
//! **An object leaves Recycled** by a delete there, which is for good, or
//! a rename out of it, which gives it back; either drops its recycle item,
//! its place in the queue and its share of the totals (`forget`). Nothing
//! else changes what is in Recycled: the packets refuse it (fs.zig), so
//! what is in it has one name, there, and a directory there stays empty.
//!
//! **Switched on and off** (`turnOn`, `turnOff`) the tree changes without
//! a record: the setting that does it is committed by two checkpoints.
//!
//! **An orphan** is a file whose last name went while its data was too
//! much to give up in one change (UnlinkRecord.mode unlink_job). The name
//! goes at once; the object stays, with no name, marked INODE_ORPHAN, and
//! an orphan item keyed by it under `orphan_oid` says it is to go. Its data
//! is given up from the end a part at a time between packets
//! (`trimOrphan`), each part committed by the next checkpoint, and the
//! object goes with its last. Nothing names an orphan, so no record touches
//! it: after a cut the job goes on from where the newest checkpoint has it.

const sdk = @import("sdk");
const dos = sdk.dos;
const posfs = dos.posfs;
const layout = posfs.layout;
const fold = posfs.fold;
const volume = @import("volume.zig");
const btree = @import("btree.zig");
const objects = @import("objects.zig");
const dirs = @import("dirs.zig");
const files = @import("files.zig");
const Volume = volume.Volume;
const Error = volume.Error;
const Key = layout.Key;
const Inode = layout.Inode;

/// A file whose data takes more blocks than this goes as a job, and a job
/// gives up about this many blocks a step.
pub const job_blocks: u64 = 4096;

fn recycleKey(oid: u64) Key {
    return .{ .oid = oid, .kind = @intFromEnum(layout.Kind.recycle) };
}

fn statsKey() Key {
    return .{ .oid = posfs.recycled_oid, .kind = @intFromEnum(layout.Kind.recycle_stats) };
}

pub fn queueKey(rseq: u64) Key {
    return .{ .oid = posfs.recycled_oid, .kind = @intFromEnum(layout.Kind.recycle_queue), .offset = rseq };
}

fn orphanKey(oid: u64) Key {
    return .{ .oid = posfs.orphan_oid, .kind = @intFromEnum(layout.Kind.orphan), .offset = oid };
}

/// Whether the volume has Recycled.
pub fn on(vol: *const Volume) bool {
    return vol.voltab.flags & layout.VT_RECYCLED != 0;
}

/// What Recycled holds altogether.
pub fn stats(vol: *Volume) Error!layout.RecycleStats {
    const data = try btree.find(vol, &vol.obj, statsKey()) orelse return error.Corrupt;
    if (data.len != @sizeOf(layout.RecycleStats)) return error.Corrupt;
    var totals: layout.RecycleStats = undefined;
    @memcpy(layout.bytesOfMut(&totals), data);
    return totals;
}

fn putStats(vol: *Volume, totals: *const layout.RecycleStats) Error!void {
    const target = try btree.modify(vol, &vol.obj, statsKey()) orelse return error.Corrupt;
    if (target.len != @sizeOf(layout.RecycleStats)) return error.Corrupt;
    @memcpy(target, layout.bytesOf(totals));
}

/// The bytes an object's data takes, as Recycled counts them.
fn bytesOf(vol: *const Volume, node: *const Inode) u64 {
    return node.blocks << vol.block_shift;
}

// --- switching -----------------------------------------------------------------------

/// Recycled made: its directory, its name in the root, its totals. A
/// name `Recycled` the root has already is Exists.
pub fn turnOn(vol: *Volume) Error!void {
    if (try objects.inode(vol, posfs.recycled_oid) != null) return;
    if (try dirs.lookup(vol, posfs.root_oid, posfs.recycled_name) != null) return error.Exists;
    const pos = try dirs.freePosition(vol, posfs.root_oid, posfs.recycled_name, null);
    const time = vol.now();
    const node: Inode = .{
        .entry_type = dos.ST_USERDIR,
        .fold = layout.fold_1,
        .pos = @intCast(pos),
        .parent = posfs.root_oid,
        .mtime = time,
        .ctime = time,
        .btime = time,
    };
    try objects.touchDir(vol, posfs.root_oid, time, 1);
    try btree.insert(vol, &vol.obj, objects.inodeKey(posfs.recycled_oid), layout.bytesOf(&node));
    const totals: layout.RecycleStats = .{};
    try btree.insert(vol, &vol.obj, statsKey(), layout.bytesOf(&totals));
    try dirs.add(vol, posfs.root_oid, pos, posfs.recycled_oid, dos.ST_USERDIR, posfs.recycled_name);
}

/// Recycled, emptied before, taken away with its name.
pub fn turnOff(vol: *Volume) Error!void {
    const node = try objects.inode(vol, posfs.recycled_oid) orelse return;
    if (try dirs.hasEntries(vol, posfs.recycled_oid)) return error.InUse;
    try dirs.remove(vol, node.parent, node.pos);
    try objects.touchDir(vol, node.parent, vol.now(), -1);
    try objects.destroy(vol, posfs.recycled_oid);
}

// --- what is in it ---------------------------------------------------------------------

/// A name in Recycled and its position.
pub const Spot = struct { name: []const u8, pos: u64 };

/// The name an object deleted as `name` takes in Recycled, kept in `into`:
/// the name, or the first of `name.1`, `name.2`, ... that is free and
/// has room in its bucket - shortened, when it has to be, to make room for
/// the number.
pub fn place(vol: *Volume, name: []const u8, into: *[posfs.max_name]u8) Error!Spot {
    var number: u32 = 0;
    while (number < 100_000) : (number += 1) {
        const candidate = numbered(name, number, into);
        if (try dirs.lookup(vol, posfs.recycled_oid, candidate) != null) continue;
        const pos = dirs.freePosition(vol, posfs.recycled_oid, candidate, null) catch |err| switch (err) {
            error.DiskFull => continue,
            else => return err,
        };
        return .{ .name = candidate, .pos = pos };
    }
    return error.DiskFull;
}

/// `name`, and for a number but 0 a dot and the number behind it.
fn numbered(name: []const u8, number: u32, into: *[posfs.max_name]u8) []const u8 {
    var digits: [11]u8 = undefined;
    var count: usize = 0;
    if (number != 0) {
        var rest = number;
        while (rest != 0) : (rest /= 10) {
            digits[digits.len - 1 - count] = @intCast('0' + rest % 10);
            count += 1;
        }
        count += 1;
        digits[digits.len - count] = '.';
    }
    var keep = @min(name.len, into.len - count);
    // A character is kept whole.
    while (keep > 0 and keep < name.len and name[keep] & 0xC0 == 0x80) keep -= 1;
    @memcpy(into[0..keep], name[0..keep]);
    @memcpy(into[keep..][0..count], digits[digits.len - count ..]);
    return into[0 .. keep + count];
}

/// Where an object in Recycled came from: its directory, its name there,
/// when it went.
pub const Origin = struct { parent: u64, deleted: u64, name: []const u8 };

/// The origin of object `oid`, its name kept in `into`.
pub fn origin(vol: *Volume, oid: u64, into: *[posfs.max_name]u8) Error!Origin {
    const data = try btree.find(vol, &vol.obj, recycleKey(oid)) orelse return error.Corrupt;
    if (data.len < @sizeOf(layout.Recycle)) return error.Corrupt;
    var head: layout.Recycle = undefined;
    @memcpy(layout.bytesOfMut(&head), data[0..@sizeOf(layout.Recycle)]);
    const name = data[@sizeOf(layout.Recycle)..];
    if (head.name_len != name.len or !fold.acceptable(name)) return error.Corrupt;
    @memcpy(into[0..name.len], name);
    return .{ .parent = head.parent, .deleted = head.deleted, .name = into[0..name.len] };
}

/// The object queued at or after `key.*` (a queue key): the oldest first,
/// `key` moved past it; null at the queue's end.
pub fn nextQueued(vol: *Volume, key: *Key) Error!?u64 {
    const item = try btree.seek(vol, &vol.obj, key.*) orelse return null;
    if (item.key.oid != posfs.recycled_oid or item.key.kind != @intFromEnum(layout.Kind.recycle_queue)) return null;
    if (item.data.len != @sizeOf(layout.RecycleQueue)) return error.Corrupt;
    var queued: layout.RecycleQueue = undefined;
    @memcpy(layout.bytesOfMut(&queued), item.data);
    key.* = btree.successor(item.key);
    return queued.oid;
}

/// Record.recycle applied: the name moved into Recycled, the object given
/// its origin, the queue and the totals.
pub fn applyRecycle(vol: *Volume, payload: []const u8) Error!void {
    const record = try objects.fixed(layout.RecycleRecord, payload);
    const head = @sizeOf(layout.RecycleRecord);
    if (payload.len - head != record.name_len) return error.Corrupt;
    const name = payload[head..];
    if (!fold.acceptable(name)) return error.Corrupt;
    if (record.parent == posfs.recycled_oid) return error.Corrupt;
    if (try objects.inode(vol, posfs.recycled_oid) == null) return error.Corrupt;
    const entry = try dirs.at(vol, record.parent, record.pos) orelse return error.Corrupt;
    if (entry.oid != record.oid) return error.Corrupt;
    var original: [posfs.max_name]u8 = undefined;
    const original_len = entry.name.len;
    @memcpy(original[0..original_len], entry.name);
    var node = try objects.inode(vol, record.oid) orelse return error.Corrupt;
    if (node.nlink != 1) return error.Corrupt;
    if (objects.isDir(node.entry_type) and try dirs.hasEntries(vol, record.oid)) return error.Corrupt;
    if (try dirs.at(vol, posfs.recycled_oid, record.new_pos) != null) return error.Corrupt;
    if (try dirs.lookup(vol, posfs.recycled_oid, name) != null) return error.Corrupt;
    var totals = try stats(vol);
    if (record.rseq < totals.next_rseq) return error.Corrupt;

    try dirs.remove(vol, record.parent, record.pos);
    try objects.touchDir(vol, record.parent, record.time, -1);
    try dirs.add(vol, posfs.recycled_oid, record.new_pos, record.oid, node.entry_type, name);
    try objects.touchDir(vol, posfs.recycled_oid, record.time, 1);
    var item: [@sizeOf(layout.Recycle) + posfs.max_name]u8 = undefined;
    const from: layout.Recycle = .{ .parent = record.parent, .deleted = record.time, .rseq = record.rseq, .name_len = @intCast(original_len) };
    @memcpy(item[0..@sizeOf(layout.Recycle)], layout.bytesOf(&from));
    @memcpy(item[@sizeOf(layout.Recycle)..][0..original_len], original[0..original_len]);
    try btree.insert(vol, &vol.obj, recycleKey(record.oid), item[0 .. @sizeOf(layout.Recycle) + original_len]);
    const queued: layout.RecycleQueue = .{ .oid = record.oid };
    try btree.insert(vol, &vol.obj, queueKey(record.rseq), layout.bytesOf(&queued));
    totals.count += 1;
    totals.bytes += bytesOf(vol, &node);
    totals.next_rseq = record.rseq + 1;
    try putStats(vol, &totals);
    node.parent = posfs.recycled_oid;
    node.pos = @intCast(record.new_pos);
    node.ctime = record.time;
    try objects.putInode(vol, record.oid, &node);
}

/// An object leaving Recycled - deleted there, or renamed out - without
/// its origin, its place in the queue and its share of the totals.
pub fn forget(vol: *Volume, oid: u64, node: *const Inode) Error!void {
    const data = try btree.find(vol, &vol.obj, recycleKey(oid)) orelse return error.Corrupt;
    if (data.len < @sizeOf(layout.Recycle)) return error.Corrupt;
    var head: layout.Recycle = undefined;
    @memcpy(layout.bytesOfMut(&head), data[0..@sizeOf(layout.Recycle)]);
    if (!try btree.remove(vol, &vol.obj, queueKey(head.rseq))) return error.Corrupt;
    if (!try btree.remove(vol, &vol.obj, recycleKey(oid))) return error.Corrupt;
    var totals = try stats(vol);
    const bytes = bytesOf(vol, node);
    if (totals.count == 0 or totals.bytes < bytes) return error.Corrupt;
    totals.count -= 1;
    totals.bytes -= bytes;
    try putStats(vol, &totals);
}

// --- orphans ---------------------------------------------------------------------------

/// A file's last name gone as a job: the object kept with no name, and
/// marked to go.
pub fn orphan(vol: *Volume, oid: u64, node: *Inode, time: u64) Error!void {
    if (node.entry_type != dos.ST_FILE) return error.Corrupt;
    node.nlink = 0;
    node.parent = 0;
    node.pos = 0;
    node.flags |= layout.INODE_ORPHAN;
    node.ctime = time;
    try objects.putInode(vol, oid, node);
    const item: layout.Orphan = .{ .flags = layout.ORPHAN_DELETE };
    try btree.insert(vol, &vol.obj, orphanKey(oid), layout.bytesOf(&item));
}

/// Whether an orphan waits for its job.
pub fn hasOrphans(vol: *Volume) Error!bool {
    const item = try btree.seek(vol, &vol.obj, orphanKey(0)) orelse return false;
    return item.key.oid == posfs.orphan_oid and item.key.kind == @intFromEnum(layout.Kind.orphan);
}

/// One step of the first orphan's job: about `round` blocks of its data
/// given up from the end, or - with none left - the object gone, and its
/// orphan item. False when there is no orphan.
pub fn trimOrphan(vol: *Volume, round: u64) Error!bool {
    const item = try btree.seek(vol, &vol.obj, orphanKey(0)) orelse return false;
    if (item.key.oid != posfs.orphan_oid or item.key.kind != @intFromEnum(layout.Kind.orphan)) return false;
    const oid = item.key.offset;
    if (item.data.len != @sizeOf(layout.Orphan)) return error.Corrupt;
    var job: layout.Orphan = undefined;
    @memcpy(layout.bytesOfMut(&job), item.data);
    if (job.flags & layout.ORPHAN_DELETE == 0) return error.NotImplemented;
    var node = try objects.inode(vol, oid) orelse return error.Corrupt;
    if (node.flags & layout.INODE_ORPHAN == 0) return error.Corrupt;
    if (try files.dropLast(vol, oid, round)) |freed| {
        node.blocks -|= freed;
        try objects.putInode(vol, oid, &node);
        return true;
    }
    try objects.destroy(vol, oid);
    if (!try btree.remove(vol, &vol.obj, orphanKey(oid))) return error.Corrupt;
    return true;
}

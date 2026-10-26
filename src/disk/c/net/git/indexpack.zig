// SPDX-License-Identifier: MIT
//! A pack indexed: every entry's id, CRC-32 and offset found, and the
//! idx git keeps beside the pack written.
//!
//! **Pass 1** walks the entries in order. An object that is no delta is
//! hashed as it is inflated - its header, then its bytes a piece at a
//! time - so no object is ever whole in memory here; a delta is inflated
//! only to learn where it ends. The CRC-32 of each entry's bytes as the
//! pack holds them, head and all, is taken on the way.
//!
//! **Pass 2** resolves the deltas from each object that has some: the
//! deltas whose base is at its offset (OFS_DELTA) or has its id
//! (REF_DELTA), found in two lists sorted by base, are applied to it,
//! hashed, and their own deltas resolved in turn - depth first, an
//! explicit stack holding the objects on the way down, each inflated
//! once. A delta whose base is not in the pack is a failure: no thin
//! pack is asked for.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const _git = @import("_git.zig");
const object = @import("object.zig");
const pack = @import("pack.zig");
const idx = @import("idx.zig");
const packread = @import("packread.zig");
const Id = _git.Id;
const Type = object.Type;

pub const Failure = enum {
    none,
    /// The pack could not be read.
    read,
    /// An entry is broken, or the entries do not fill the pack.
    entry,
    /// A delta does not fit its base.
    delta,
    /// Deltas whose bases the pack does not hold.
    base,
    memory,
    /// The idx could not be written.
    sink,
    /// The listener stopped it.
    stopped,
};

pub const Phase = enum { indexing, resolving };

/// How far it has come: false stops it.
pub const Progress = struct {
    context: *anyopaque,
    step: *const fn (context: *anyopaque, phase: Phase, done: u32, total: u32) bool,
};

const Entry = struct {
    offset: u64,
    /// An OFS_DELTA's base's offset.
    base_offset: u64 = 0,
    /// A REF_DELTA's base's id; the object's own id once known.
    id: Id = _git.zero_id,
    base_id: Id = _git.zero_id,
    crc: u32 = 0,
    /// As the entry says in pass 1; the object's type once resolved.
    kind: Type,
    resolved: bool = false,
};

/// An object on pass 2's way down, and the deltas on it still to do.
const Frame = struct {
    data: []u8,
    kind: Type,
    ofs_at: usize,
    ofs_end: usize,
    ref_at: usize,
    ref_end: usize,
};

const scratch_bytes = 32 * 1024;

pub const Indexer = struct {
    sys: *ExecBase,
    cb: *CryptoBase,
    reading: packread.Pack,
    progress: ?Progress = null,
    failure: Failure = .none,
    /// How many deltas pass 1 found, and how many pass 2 resolved.
    deltas: u32 = 0,
    resolved: u32 = 0,
    entries: []Entry = &.{},
    ofs_kids: []u32 = &.{},
    ref_kids: []u32 = &.{},

    pub fn init(indexer: *Indexer, sys: *ExecBase, zb: *CompressionBase, cb: *CryptoBase, source: packread.Source) void {
        indexer.sys = sys;
        indexer.cb = cb;
        indexer.reading.init(sys, zb, source);
        indexer.progress = null;
        indexer.failure = .none;
        indexer.deltas = 0;
        indexer.resolved = 0;
        indexer.entries = &.{};
        indexer.ofs_kids = &.{};
        indexer.ref_kids = &.{};
    }

    pub fn deinit(indexer: *Indexer) void {
        indexer.release(indexer.entries);
        indexer.release(indexer.ofs_kids);
        indexer.release(indexer.ref_kids);
        indexer.entries = &.{};
        indexer.ofs_kids = &.{};
        indexer.ref_kids = &.{};
        indexer.reading.deinit();
    }

    /// The pack of `length` bytes, its `count` entries, indexed; the idx
    /// for it - named by `checksum`, its trailer - written to `sink`.
    pub fn run(indexer: *Indexer, length: u64, count: u32, checksum: *const Id, sink: _git.Sink) bool {
        if (!indexer.walk(length, count)) return false;
        if (!indexer.resolve()) return false;
        // The idx: every entry by id.
        const list = indexer.take(idx.Entry, count) orelse return false;
        defer indexer.release(list);
        for (indexer.entries, list) |*entry, *out| out.* = .{ .id = entry.id, .crc = entry.crc, .offset = entry.offset };
        idx.sort(list);
        if (!idx.write(indexer.cb, list, checksum, sink)) return indexer.fail(.sink);
        return true;
    }

    fn walk(indexer: *Indexer, length: u64, count: u32) bool {
        indexer.entries = indexer.take(Entry, count) orelse return false;
        const scratch = indexer.take(u8, scratch_bytes) orelse return false;
        defer indexer.release(scratch);
        const reader = &indexer.reading.reader;
        const end = length - pack.trailer_bytes;
        var offset: u64 = pack.header_bytes;
        for (indexer.entries, 0..) |*entry, number| {
            if (offset >= end) return indexer.fail(.entry);
            const head = packread.readHead(reader.source, offset) orelse return indexer.fail(.entry);
            var head_bytes: [32]u8 = undefined;
            if (reader.source.read(reader.source.context, offset, head_bytes[0..head.length]) != head.length) return indexer.fail(.read);
            entry.* = .{ .offset = offset, .kind = head.kind };
            const delta = head.kind == .ofs_delta or head.kind == .ref_delta;
            var sha: _git.Sha1 = undefined;
            if (delta) {
                indexer.deltas += 1;
                if (head.kind == .ofs_delta) {
                    if (head.base_distance == 0 or head.base_distance > offset) return indexer.fail(.entry);
                    entry.base_offset = offset - head.base_distance;
                } else {
                    entry.base_id = head.base_id;
                }
            } else {
                sha = _git.Sha1.start(indexer.cb);
                var text: [32]u8 = undefined;
                sha.update(object.header(head.kind, head.size, &text));
            }
            if (!reader.start(offset + head.length, reader.zb.Crc32(0, &head_bytes, @intCast(head.length)))) return indexer.fail(.memory);
            var total: u64 = 0;
            var broken = false;
            while (true) {
                const got = reader.read(scratch) orelse {
                    broken = true;
                    break;
                };
                if (got == 0) break;
                if (!delta) sha.update(scratch[0..got]);
                total += got;
            }
            reader.finish();
            if (broken or total != head.size) return indexer.fail(.entry);
            entry.crc = reader.crc;
            if (!delta) {
                entry.id = sha.finish();
                entry.resolved = true;
            }
            offset += head.length + reader.taken();
            if (!indexer.step(.indexing, @intCast(number + 1), count)) return false;
        }
        if (offset != end) return indexer.fail(.entry);
        return true;
    }

    fn resolve(indexer: *Indexer) bool {
        if (indexer.deltas == 0) return true;
        const entries = indexer.entries;
        var ofs_count: usize = 0;
        var ref_count: usize = 0;
        for (entries) |*entry| {
            if (entry.kind == .ofs_delta) ofs_count += 1;
            if (entry.kind == .ref_delta) ref_count += 1;
        }
        indexer.ofs_kids = indexer.take(u32, ofs_count) orelse return false;
        indexer.ref_kids = indexer.take(u32, ref_count) orelse return false;
        ofs_count = 0;
        ref_count = 0;
        for (entries, 0..) |*entry, number| {
            if (entry.kind == .ofs_delta) {
                indexer.ofs_kids[ofs_count] = @intCast(number);
                ofs_count += 1;
            } else if (entry.kind == .ref_delta) {
                indexer.ref_kids[ref_count] = @intCast(number);
                ref_count += 1;
            }
        }
        _git.heapSort(u32, indexer.ofs_kids, entries, byBaseOffset);
        _git.heapSort(u32, indexer.ref_kids, entries, byBaseId);

        const frames = indexer.take(Frame, indexer.deltas + 1) orelse return false;
        defer indexer.release(frames);
        var depth: usize = 0;
        defer while (depth > 0) {
            depth -= 1;
            indexer.freeData(frames[depth].data);
        };
        for (entries) |*root| {
            if (root.kind == .ofs_delta or root.kind == .ref_delta) continue;
            var frame = indexer.frameOf(root, &.{}, root.kind);
            if (frame.ofs_at == frame.ofs_end and frame.ref_at == frame.ref_end) continue;
            const root_head = packread.readHead(indexer.reading.reader.source, root.offset) orelse return indexer.fail(.read);
            frame.data = indexer.reading.body(root.offset, &root_head) orelse return indexer.failFromPack();
            frames[0] = frame;
            depth = 1;
            while (depth > 0) {
                const top = &frames[depth - 1];
                var child_number: u32 = undefined;
                if (top.ofs_at < top.ofs_end) {
                    child_number = indexer.ofs_kids[top.ofs_at];
                    top.ofs_at += 1;
                } else if (top.ref_at < top.ref_end) {
                    child_number = indexer.ref_kids[top.ref_at];
                    top.ref_at += 1;
                } else {
                    indexer.freeData(top.data);
                    depth -= 1;
                    continue;
                }
                const child = &entries[child_number];
                if (child.resolved) continue;
                const head = packread.readHead(indexer.reading.reader.source, child.offset) orelse return indexer.fail(.read);
                const delta = indexer.reading.body(child.offset, &head) orelse return indexer.failFromPack();
                const result = packread.applied(&indexer.reading, top.data, delta);
                indexer.freeData(delta);
                const data = result orelse return indexer.failFromPack();
                child.kind = top.kind;
                child.id = object.idOfObject(indexer.cb, top.kind, data);
                child.resolved = true;
                indexer.resolved += 1;
                frames[depth] = indexer.frameOf(child, data, top.kind);
                depth += 1;
                if (!indexer.step(.resolving, indexer.resolved, indexer.deltas)) return false;
            }
        }
        if (indexer.resolved != indexer.deltas) return indexer.fail(.base);
        return true;
    }

    /// The frame of a resolved entry: its deltas found in both lists.
    fn frameOf(indexer: *Indexer, entry: *const Entry, data: []u8, kind: Type) Frame {
        const entries = indexer.entries;
        var frame: Frame = .{ .data = data, .kind = kind, .ofs_at = 0, .ofs_end = 0, .ref_at = 0, .ref_end = 0 };
        // The first OFS delta whose base is at or after the entry.
        var low: usize = 0;
        var high: usize = indexer.ofs_kids.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (entries[indexer.ofs_kids[middle]].base_offset < entry.offset) low = middle + 1 else high = middle;
        }
        frame.ofs_at = low;
        frame.ofs_end = low;
        while (frame.ofs_end < indexer.ofs_kids.len and entries[indexer.ofs_kids[frame.ofs_end]].base_offset == entry.offset) frame.ofs_end += 1;
        low = 0;
        high = indexer.ref_kids.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (_git.order(&entries[indexer.ref_kids[middle]].base_id, &entry.id) == .less) low = middle + 1 else high = middle;
        }
        frame.ref_at = low;
        frame.ref_end = low;
        while (frame.ref_end < indexer.ref_kids.len and _git.same(&entries[indexer.ref_kids[frame.ref_end]].base_id, &entry.id)) frame.ref_end += 1;
        return frame;
    }

    fn step(indexer: *Indexer, phase: Phase, done: u32, total: u32) bool {
        const progress = indexer.progress orelse return true;
        if (!progress.step(progress.context, phase, done, total)) return indexer.fail(.stopped);
        return true;
    }

    /// `count` items of `T`, cleared.
    fn take(indexer: *Indexer, comptime T: type, count: usize) ?[]T {
        if (count == 0) return &.{};
        const block = indexer.sys.AllocVec(count * @sizeOf(T), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
            _ = indexer.fail(.memory);
            return null;
        };
        return @as([*]T, @ptrCast(@alignCast(block)))[0..count];
    }

    fn release(indexer: *Indexer, items: anytype) void {
        if (items.len != 0) indexer.sys.FreeVec(@ptrCast(items.ptr));
    }

    fn freeData(indexer: *Indexer, data: []u8) void {
        if (data.len != 0) indexer.sys.FreeVec(data.ptr);
    }

    fn failFromPack(indexer: *Indexer) bool {
        return indexer.fail(switch (indexer.reading.failure) {
            .none, .entry => .entry,
            .read => .read,
            .delta => .delta,
            .base => .base,
            .memory => .memory,
        });
    }

    fn fail(indexer: *Indexer, failure: Failure) bool {
        if (indexer.failure == .none) indexer.failure = failure;
        return false;
    }
};

fn byBaseOffset(entries: []Entry, a: *const u32, b: *const u32) bool {
    return entries[a.*].base_offset < entries[b.*].base_offset;
}

fn byBaseId(entries: []Entry, a: *const u32, b: *const u32) bool {
    return _git.order(&entries[a.*].base_id, &entries[b.*].base_id) == .less;
}

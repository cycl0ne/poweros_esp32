// SPDX-License-Identifier: MPL-2.0
//! posfs's file data: what a file holds on the medium, and what a file
//! being written holds besides until it is closed or flushed.
//!
//! **On the medium** a file is its extents - items keyed by the file
//! offset they start at, each a run of blocks and the bytes of it that
//! count - or, when it is small, one item holding its bytes (inline). An
//! extent always starts on a block of the file; a byte no extent holds
//! is a hole and reads as zero.
//!
//! **A file being written** keeps its changes in an overlay until it is
//! closed or flushed: the blocks being filled, in memory, and the blocks
//! already written to homes of their own, which nothing durable names
//! yet. A block written over is written to a new home, never where it
//! was; the edges of a write that does not cover a block are read first.
//! Reads of the file see the overlay. A close commits it: the data is
//! written, then one record says what it replaces - the journal puts the
//! data on the medium before the record - and applying that record
//! (`applyCommit`) puts the new extents in the tree and gives up the old,
//! so after a cut the file is the old one or the new one, never a mix. A
//! small file's commit carries its bytes in the record.
//!
//! **Checksums** (the volume's VT_CHECKSUMS, unless the file is
//! INODE_NOCSUM): every block written gets a crc, seeded with the
//! volume's id, as it goes to the medium; the commit carries them, and a
//! csum item beside each extent keeps them, cut and split with it. A read
//! checks each block it touches before it gives a byte of it.
//! **Compression** (VT_COMPRESS, unless INODE_NOCOMP) stores a chunk of
//! 64 KiB whole in fewer blocks when it can (compress.zig); a write into
//! a compressed chunk takes all of it into the overlay, so the commit
//! writes it whole again. Either setting changes only what is written
//! after it; each extent says how it was written.

const sdk = @import("sdk");
const dos = sdk.dos;
const posfs = dos.posfs;
const layout = posfs.layout;
const volume = @import("volume.zig");
const btree = @import("btree.zig");
const space = @import("space.zig");
const journal = @import("journal.zig");
const checkpoint = @import("checkpoint.zig");
const objects = @import("objects.zig");
const compress = @import("compress.zig");
const Volume = volume.Volume;
const Error = volume.Error;
const Key = layout.Key;
const Extent = layout.Extent;
const Inode = layout.Inode;

const kind_extent: u32 = @intFromEnum(layout.Kind.extent);

fn extentKey(oid: u64, offset: u64) Key {
    return .{ .oid = oid, .kind = kind_extent, .offset = offset };
}

fn csumKey(oid: u64, offset: u64) Key {
    return .{ .oid = oid, .kind = @intFromEnum(layout.Kind.csum), .offset = offset };
}

/// A checksummed extent's crcs, copied into `into`: one a block.
fn csumsOf(vol: *Volume, tree: *const btree.Tree, oid: u64, found: Found, into: *[layout.max_csums]u32) Error![]const u32 {
    const count: usize = found.extent.blocks;
    const data = try btree.find(vol, tree, csumKey(oid, found.offset)) orelse return error.Corrupt;
    if (count > into.len or data.len != count * 4) return error.Corrupt;
    @memcpy(@as([*]u8, @ptrCast(into))[0..data.len], data);
    return into[0..count];
}

/// A compressed extent as the chunk reader takes it.
fn storedOf(extent: *const Extent) compress.Stored {
    return .{ .block = extent.block, .blocks = extent.blocks, .stored = extent.stored, .crc = extent.crc };
}

fn inlineKey(oid: u64) Key {
    return .{ .oid = oid, .kind = @intFromEnum(layout.Kind.inline_data) };
}

/// An extent and the file offset it starts at.
const Found = struct { offset: u64, extent: Extent };

fn foundOf(item: btree.Item, oid: u64) Error!?Found {
    if (item.key.oid != oid or item.key.kind != kind_extent) return null;
    if (item.data.len != @sizeOf(Extent)) return error.Corrupt;
    var extent: Extent = undefined;
    @memcpy(layout.bytesOfMut(&extent), item.data);
    if (extent.length == 0 or extent.blocks == 0) return error.Corrupt;
    return .{ .offset = item.key.offset, .extent = extent };
}

/// The extent holding byte `offset` of a file.
fn extentAt(vol: *Volume, tree: *const btree.Tree, oid: u64, offset: u64) Error!?Found {
    const item = try btree.floor(vol, tree, extentKey(oid, offset)) orelse return null;
    const found = try foundOf(item, oid) orelse return null;
    if (offset - found.offset >= found.extent.length) return null;
    return found;
}

/// The first extent starting at `offset` or after it.
fn extentFrom(vol: *Volume, tree: *const btree.Tree, oid: u64, offset: u64) Error!?Found {
    const item = try btree.seek(vol, tree, extentKey(oid, offset)) orelse return null;
    return foundOf(item, oid);
}

// --- reading what is committed --------------------------------------------------------------

/// `into.len` bytes of a file as `tree` - the live tree or a snapshot's -
/// has it committed, from `offset`: holes and what lies past its end read
/// as zero.
pub fn readCommitted(vol: *Volume, tree: *const btree.Tree, oid: u64, node: *const Inode, offset: u64, into: []u8) Error!void {
    if (node.flags & layout.INODE_INLINE != 0) {
        const data = try btree.find(vol, tree, inlineKey(oid)) orelse return error.Corrupt;
        @memset(into, 0);
        if (offset < data.len) {
            const piece = @min(into.len, data.len - offset);
            @memcpy(into[0..piece], data[@intCast(offset)..][0..piece]);
        }
        return;
    }
    var done: usize = 0;
    while (done < into.len) {
        const at = offset + done;
        const left = into.len - done;
        if (at >= node.size) {
            @memset(into[done..], 0);
            return;
        }
        const to_end = node.size - at;
        if (try extentAt(vol, tree, oid, at)) |found| {
            const inner = at - found.offset;
            const piece: usize = @intCast(@min(@as(u64, left), @min(found.extent.length - inner, to_end)));
            if (found.extent.compressed()) {
                const plain = try compress.read(vol, storedOf(&found.extent), found.extent.length);
                @memcpy(into[done..][0..piece], plain[@intCast(inner)..][0..piece]);
            } else if (found.extent.checksummed()) {
                var crcs: [layout.max_csums]u32 = undefined;
                try vol.readChecked(found.extent.block, inner, into[done..][0..piece], try csumsOf(vol, tree, oid, found, &crcs));
            } else try vol.readData(found.extent.block, inner, into[done..][0..piece]);
            done += piece;
        } else {
            const next = if (try extentFrom(vol, tree, oid, at)) |found| found.offset else node.size;
            const piece: usize = @intCast(@min(@as(u64, left), @min(next - at, to_end)));
            @memset(into[done..][0..piece], 0);
            done += piece;
        }
    }
}

// --- cutting -------------------------------------------------------------------------------

/// What a file holds in [from, to) given up: extents inside it dropped,
/// one that crosses an end cut there. The blocks given up.
fn cutRange(vol: *Volume, oid: u64, from: u64, to: u64) Error!u64 {
    var freed: u64 = 0;
    if (try extentAt(vol, &vol.obj, oid, from)) |found| {
        if (found.offset < from) freed += try cutExtent(vol, oid, found, from, to);
    }
    while (try extentFrom(vol, &vol.obj, oid, from)) |found| {
        if (found.offset >= to) break;
        freed += try cutExtent(vol, oid, found, from, to);
    }
    return freed;
}

/// One extent's part in [from, to) given up: what is before it kept
/// where it is, what is after it an extent of its own.
fn cutExtent(vol: *Volume, oid: u64, found: Found, from: u64, to: u64) Error!u64 {
    const extent = found.extent;
    const size = vol.block_size;
    const start = found.offset;
    const end = start + extent.length;
    const keep_left: u64 = if (from > start) from - start else 0;
    const has_right = to < end;
    if (extent.compressed()) {
        // A compressed chunk is rewritten whole; only its end moves.
        if (has_right) return error.Corrupt;
        if (keep_left == 0) {
            if (!try btree.remove(vol, &vol.obj, extentKey(oid, start))) return error.Corrupt;
            try space.dropRun(vol, extent.block, extent.birth, extent.blocks);
            return extent.blocks;
        }
        var shorter = extent;
        shorter.length = keep_left;
        try putExtent(vol, oid, start, &shorter);
        return 0;
    }
    const left_blocks = (keep_left + size - 1) / size;
    var right_first: u64 = extent.blocks;
    if (has_right) {
        if ((to - start) % size != 0) return error.Corrupt;
        right_first = (to - start) / size;
    }
    if (left_blocks > right_first) return error.Corrupt;
    // The crcs go with the blocks they are of.
    var crc_buffer: [layout.max_csums]u32 = undefined;
    const crcs: []const u32 = if (extent.checksummed()) try csumsOf(vol, &vol.obj, oid, found, &crc_buffer) else &.{};
    if (keep_left > 0) {
        var left = extent;
        left.length = keep_left;
        left.blocks = @intCast(left_blocks);
        try putExtent(vol, oid, start, &left);
        if (extent.checksummed()) try btree.put(vol, &vol.obj, csumKey(oid, start), crcBytes(crcs[0..@intCast(left_blocks)]));
    } else {
        if (!try btree.remove(vol, &vol.obj, extentKey(oid, start))) return error.Corrupt;
        if (extent.checksummed() and !try btree.remove(vol, &vol.obj, csumKey(oid, start))) return error.Corrupt;
    }
    if (has_right) {
        var right = extent;
        right.block = extent.block + right_first;
        right.blocks = @intCast(extent.blocks - right_first);
        right.length = end - to;
        try btree.insert(vol, &vol.obj, extentKey(oid, to), layout.bytesOf(&right));
        if (extent.checksummed()) try btree.insert(vol, &vol.obj, csumKey(oid, to), crcBytes(crcs[@intCast(right_first)..]));
    }
    const gone = right_first - left_blocks;
    if (gone > 0) try space.dropRun(vol, extent.block + left_blocks, extent.birth, gone);
    return gone;
}

fn crcBytes(crcs: []const u32) []const u8 {
    return @as([*]const u8, @ptrCast(crcs.ptr))[0 .. crcs.len * 4];
}

fn putExtent(vol: *Volume, oid: u64, offset: u64, extent: *const Extent) Error!void {
    const target = try btree.modify(vol, &vol.obj, extentKey(oid, offset)) orelse return error.Corrupt;
    if (target.len != @sizeOf(Extent)) return error.Corrupt;
    @memcpy(target, layout.bytesOf(extent));
}

/// A file's last extents given up, about `round` blocks of them: what an
/// orphan's job does a step at a time. The blocks given up; null when the
/// file holds none.
pub fn dropLast(vol: *Volume, oid: u64, round: u64) Error!?u64 {
    var key = extentKey(oid, ~@as(u64, 0));
    var from: ?u64 = null;
    var blocks: u64 = 0;
    var count: u32 = 0;
    while (blocks < round and count < 256) : (count += 1) {
        const item = try btree.floor(vol, &vol.obj, key) orelse break;
        const found = try foundOf(item, oid) orelse break;
        from = found.offset;
        blocks += found.extent.blocks;
        if (found.offset == 0) break;
        key = extentKey(oid, found.offset - 1);
    }
    return try cutRange(vol, oid, from orelse return null, ~@as(u64, 0));
}

/// What a file holds at and past `from` given up, its inline bytes
/// included. The blocks given up.
pub fn dropFrom(vol: *Volume, oid: u64, from: u64) Error!u64 {
    if (try btree.find(vol, &vol.obj, inlineKey(oid))) |data| {
        if (from == 0) {
            _ = try btree.remove(vol, &vol.obj, inlineKey(oid));
        } else if (from < data.len) {
            var kept: [1024]u8 = undefined;
            if (from > kept.len) return error.Corrupt;
            const len: usize = @intCast(from);
            @memcpy(kept[0..len], data[0..len]);
            try btree.put(vol, &vol.obj, inlineKey(oid), kept[0..len]);
        }
    }
    return cutRange(vol, oid, from, ~@as(u64, 0));
}

// --- commits -------------------------------------------------------------------------------

/// A commit record taken apart.
const Commit = struct {
    record: layout.CommitRecord,
    specs: []const u8,
    inline_bytes: []const u8,

    fn walk(parsed: *const Commit) Specs {
        return .{ .bytes = parsed.specs };
    }
};

/// One ExtSpec of a commit and the crcs that follow it.
const Spec = struct { spec: layout.ExtSpec, crcs: []const u8 };

/// A commit's specs one after another; `parseCommit` has checked them.
const Specs = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(specs: *Specs) ?Spec {
        if (specs.bytes.len - specs.at < @sizeOf(layout.ExtSpec)) return null;
        var value: layout.ExtSpec = undefined;
        @memcpy(layout.bytesOfMut(&value), specs.bytes[specs.at..][0..@sizeOf(layout.ExtSpec)]);
        specs.at += @sizeOf(layout.ExtSpec);
        const crc_len = crcCount(&value) * 4;
        if (specs.bytes.len - specs.at < crc_len) return null;
        const crcs = specs.bytes[specs.at..][0..crc_len];
        specs.at += crc_len;
        return .{ .spec = value, .crcs = crcs };
    }
};

/// The crcs that follow a spec: one a block of a raw, checksummed one.
fn crcCount(spec: *const layout.ExtSpec) usize {
    const checksummed = spec.flags & layout.EXTENT_CHECKSUMMED != 0;
    return if (checksummed and spec.flags & layout.EXTENT_COMPRESSED == 0) spec.blocks else 0;
}

/// A spec read from the medium, checked before anything adds with it.
fn checkSpec(vol: *const Volume, record: *const layout.CommitRecord, spec: *const layout.ExtSpec) Error!void {
    const size: u64 = vol.block_size;
    if (spec.blocks == 0 or spec.length == 0 or spec.offset % size != 0) return error.Corrupt;
    if (spec.offset > record.size or spec.length > record.size - spec.offset) return error.Corrupt;
    if (spec.block >= vol.block_count or spec.blocks > vol.block_count - spec.block) return error.Corrupt;
    const known = layout.EXTENT_COMPRESSED | layout.EXTENT_CHECKSUMMED | (@as(u32, 0xFF) << layout.EXTENT_ALG_SHIFT);
    if (spec.flags & ~known != 0) return error.NotImplemented;
    const alg = (spec.flags >> layout.EXTENT_ALG_SHIFT) & 0xFF;
    if (spec.flags & layout.EXTENT_COMPRESSED != 0) {
        if (alg != layout.alg_lz4) return error.NotImplemented;
        if (spec.offset % layout.chunk_size != 0 or spec.length > layout.chunk_size) return error.Corrupt;
        if (spec.stored == 0 or spec.stored > @as(u64, spec.blocks) * size) return error.Corrupt;
        return;
    }
    if (alg != 0) return error.Corrupt;
    if (spec.length > @as(u64, spec.blocks) * size) return error.Corrupt;
    if (spec.flags & layout.EXTENT_CHECKSUMMED != 0 and spec.blocks > layout.csumPerItem(vol.block_size)) return error.Corrupt;
}

fn parseCommit(vol: *const Volume, payload: []const u8) Error!Commit {
    const record = try objects.fixed(layout.CommitRecord, payload);
    const head = @sizeOf(layout.CommitRecord);
    var at: usize = head;
    for (0..record.specs) |_| {
        if (payload.len - at < @sizeOf(layout.ExtSpec)) return error.Corrupt;
        var spec: layout.ExtSpec = undefined;
        @memcpy(layout.bytesOfMut(&spec), payload[at..][0..@sizeOf(layout.ExtSpec)]);
        try checkSpec(vol, &record, &spec);
        at += @sizeOf(layout.ExtSpec);
        const crc_len = crcCount(&spec) * 4;
        if (payload.len - at < crc_len) return error.Corrupt;
        at += crc_len;
    }
    if (payload.len - at != record.inline_len) return error.Corrupt;
    const parsed: Commit = .{
        .record = record,
        .specs = payload[head..at],
        .inline_bytes = payload[at..],
    };
    if (record.flags & layout.COMMIT_INLINE != 0) {
        if (record.inline_len != record.size or record.specs != 0) return error.Corrupt;
    } else if (record.inline_len != 0) return error.Corrupt;
    return parsed;
}

/// The data blocks a parsed found in replay names, held before any is
/// applied.
pub fn claimCommit(vol: *Volume, payload: []const u8) Error!void {
    const parsed = parseCommit(vol, payload) catch |err| switch (err) {
        // Replay finds it again and stops there.
        error.Corrupt, error.NotImplemented => return,
        else => return err,
    };
    var specs = parsed.walk();
    while (specs.next()) |item| try space.claim(vol, item.spec.block, item.spec.blocks);
}

/// A file's new content in the tree: what it replaces given up first,
/// then the new extents put in and their blocks marked used.
pub fn applyCommit(vol: *Volume, flags: u32, payload: []const u8) Error!void {
    _ = flags;
    const parsed = try parseCommit(vol, payload);
    const record = parsed.record;
    const oid = record.oid;
    var node = try objects.inode(vol, oid) orelse return error.Corrupt;
    if (node.entry_type != dos.ST_FILE) return error.Corrupt;
    var checking = parsed.walk();
    while (checking.next()) |item| {
        const spec = item.spec;
        var addr = spec.block;
        while (addr < spec.block + spec.blocks) : (addr += 1) {
            if (space.isUsed(vol, addr)) return error.Corrupt;
        }
    }
    var blocks = node.blocks;
    if (record.flags & (layout.COMMIT_TRUNC_ALL | layout.COMMIT_INLINE) != 0) {
        blocks -|= try dropFrom(vol, oid, 0);
        node.flags &= ~layout.INODE_INLINE;
    } else if (record.flags & layout.COMMIT_TRIM != 0) {
        blocks -|= try dropFrom(vol, oid, record.trim);
    }
    if (node.flags & layout.INODE_INLINE != 0 and record.flags & layout.COMMIT_INLINE == 0) {
        // A file that grows past inline: its bytes are among the new data.
        _ = try btree.remove(vol, &vol.obj, inlineKey(oid));
        node.flags &= ~layout.INODE_INLINE;
    }
    // What the new data replaces given up, specs one after another at
    // once: a compressed chunk the commit writes anew in pieces goes whole.
    var cutting = parsed.walk();
    var from: u64 = 0;
    var to: u64 = 0;
    while (cutting.next()) |item| {
        const spec = item.spec;
        if (to != 0 and spec.offset == to) {
            to = spec.offset + spec.length;
            continue;
        }
        if (to != 0) blocks -|= try cutRange(vol, oid, from, to);
        from = spec.offset;
        to = spec.offset + spec.length;
    }
    if (to != 0) blocks -|= try cutRange(vol, oid, from, to);
    var placing = parsed.walk();
    while (placing.next()) |item| {
        try space.useClaimed(vol, item.spec.block, item.spec.blocks);
        try placeExtent(vol, oid, &item.spec, item.crcs);
        blocks += item.spec.blocks;
    }
    if (record.flags & layout.COMMIT_INLINE != 0) {
        if (parsed.inline_bytes.len > 0) try btree.insert(vol, &vol.obj, inlineKey(oid), parsed.inline_bytes);
        node.flags |= layout.INODE_INLINE;
    }
    node.blocks = blocks;
    node.size = record.size;
    node.mtime = record.mtime;
    node.ctime = record.time;
    node.protection &= ~dos.FIBF_ARCHIVE;
    try objects.putInode(vol, oid, &node);
}

/// A new extent put in, joined to the one before when it simply goes on
/// from it: the same generation, the next blocks, whole blocks before, and
/// neither checksummed nor compressed. A checksummed one's crcs beside it.
fn placeExtent(vol: *Volume, oid: u64, spec: *const layout.ExtSpec, crcs: []const u8) Error!void {
    if (spec.offset > 0) {
        if (try extentAt(vol, &vol.obj, oid, spec.offset - 1)) |before| {
            var joined = before.extent;
            if (joined.birth == vol.gen and joined.flags == 0 and spec.flags == 0 and
                before.offset + joined.length == spec.offset and
                joined.length == @as(u64, joined.blocks) * vol.block_size and
                joined.block + joined.blocks == spec.block)
            {
                joined.length += spec.length;
                joined.blocks += spec.blocks;
                return putExtent(vol, oid, before.offset, &joined);
            }
        }
    }
    const extent: Extent = .{
        .block = spec.block,
        .birth = vol.gen,
        .length = spec.length,
        .blocks = spec.blocks,
        .flags = spec.flags,
        .stored = spec.stored,
        .crc = spec.crc,
    };
    try btree.insert(vol, &vol.obj, extentKey(oid, spec.offset), layout.bytesOf(&extent));
    if (crcs.len != 0) try btree.insert(vol, &vol.obj, csumKey(oid, spec.offset), crcs);
}

// --- files being written -------------------------------------------------------------------

/// No cut since the last commit.
const no_trim: u64 = ~@as(u64, 0);

/// No crcs: a run written without them.
const no_crcs: u32 = ~@as(u32, 0);

/// Blocks of new data written: `count` blocks of the file from block
/// `file_block`, at `block` on - or, compressed, one chunk of `count`
/// blocks of the file in the blocks its `stored` bytes take.
const Run = struct {
    file_block: u64,
    block: u64,
    count: u64,
    /// A compressed run's bytes on the medium and their crc; 0 for a raw one.
    stored: u32 = 0,
    crc: u32 = 0,
    /// A raw run's first block's crc in the overlay's `crcs`, the others
    /// after it; `no_crcs` for a run without.
    crc_first: u32 = no_crcs,

    fn compressed(run: Run) bool {
        return run.stored != 0;
    }

    /// The blocks it takes on the medium.
    fn blocks(run: Run, vol: *const Volume) u64 {
        if (!run.compressed()) return run.count;
        return (@as(u64, run.stored) + vol.block_size - 1) >> vol.block_shift;
    }

    fn chunk(run: Run, vol: *const Volume) compress.Stored {
        return .{ .block = run.block, .blocks = run.blocks(vol), .stored = run.stored, .crc = run.crc };
    }

    /// The crcs of the run's part from file block `from` on.
    fn crcsFrom(run: Run, from: u64) u32 {
        if (run.crc_first == no_crcs) return no_crcs;
        return run.crc_first + @as(u32, @intCast(from - run.file_block));
    }
};

/// Whether run `after` simply goes on from `before`: next on the file and
/// on the medium, both raw, their crcs one after the other too.
fn joinable(before: Run, after: Run) bool {
    if (before.compressed() or after.compressed()) return false;
    if (before.file_block + before.count != after.file_block or before.block + before.count != after.block) return false;
    if (before.crc_first == no_crcs or after.crc_first == no_crcs) return before.crc_first == after.crc_first;
    return @as(u64, before.crc_first) + before.count == after.crc_first;
}

/// A block of the file being filled, in memory.
const Pending = struct { file_block: u64, buffer: []u8 };

/// What a file being written holds that is not committed yet.
pub const Overlay = struct {
    oid: u64,
    /// Its size as it is now.
    size: u64,
    /// Whether the committed content is inline.
    base_inline: bool,
    /// Everything committed is dropped at the commit (MODE_NEWFILE).
    trunc_all: bool = false,
    /// The committed content at and past this is dropped at the commit.
    trim: u64 = no_trim,
    runs: []Run = &.{},
    run_count: usize = 0,
    pending: []Pending = &.{},
    pending_count: usize = 0,
    /// Changed since the last commit.
    modified: bool = false,
    /// The file's own settings: never checksummed, never compressed.
    no_checksums: bool = false,
    no_compress: bool = false,
    /// The crcs of what the raw runs hold, a block each, from `crc_first`.
    crcs: []u32 = &.{},
    crc_count: usize = 0,
};

/// An overlay for a file as it is committed.
pub fn begin(oid: u64, node: *const Inode) Overlay {
    return .{
        .oid = oid,
        .size = node.size,
        .base_inline = node.flags & layout.INODE_INLINE != 0,
        .no_checksums = node.flags & layout.INODE_NOCSUM != 0,
        .no_compress = node.flags & layout.INODE_NOCOMP != 0,
    };
}

/// How many blocks an overlay fills in memory before it writes them out.
fn pendingMax(vol: *const Volume) usize {
    const blocks = (256 * 1024) / vol.block_size;
    return if (blocks < 4) 4 else blocks;
}

fn pendingOf(ov: *const Overlay, file_block: u64) ?[]u8 {
    for (ov.pending[0..ov.pending_count]) |entry| {
        if (entry.file_block == file_block) return entry.buffer;
    }
    return null;
}

/// The run holding file block `file_block`, by index.
fn runOf(ov: *const Overlay, file_block: u64) ?usize {
    for (ov.runs[0..ov.run_count], 0..) |run, index| {
        if (file_block >= run.file_block and file_block < run.file_block + run.count) return index;
    }
    return null;
}

/// The first file block at or after `file_block` the overlay holds.
fn nextHeld(ov: *const Overlay, file_block: u64) u64 {
    var next: u64 = ~@as(u64, 0);
    for (ov.pending[0..ov.pending_count]) |entry| {
        if (entry.file_block >= file_block and entry.file_block < next) next = entry.file_block;
    }
    for (ov.runs[0..ov.run_count]) |run| {
        const end = run.file_block + run.count;
        if (end > file_block) {
            const first = if (run.file_block > file_block) run.file_block else file_block;
            if (first < next) next = first;
        }
    }
    return next;
}

/// `into.len` bytes of the file from `offset`, as it is now: what the
/// overlay holds, else what is committed and not dropped.
pub fn readThrough(vol: *Volume, ov: *const Overlay, node: *const Inode, offset: u64, into: []u8) Error!void {
    const size = vol.block_size;
    var done: usize = 0;
    while (done < into.len) {
        const at = offset + done;
        const left = into.len - done;
        if (at >= ov.size) {
            @memset(into[done..], 0);
            return;
        }
        const file_block = at >> vol.block_shift;
        const within: usize = @intCast(at & (size - 1));
        const to_end = ov.size - at;
        if (pendingOf(ov, file_block)) |buffer| {
            const piece: usize = @intCast(@min(@as(u64, @min(left, size - within)), to_end));
            @memcpy(into[done..][0..piece], buffer[within..][0..piece]);
            done += piece;
            continue;
        }
        if (runOf(ov, file_block)) |index| {
            const run = ov.runs[index];
            const run_start = run.file_block << vol.block_shift;
            const run_end = (run.file_block + run.count) << vol.block_shift;
            const piece: usize = @intCast(@min(@as(u64, left), @min(run_end - at, to_end)));
            if (run.compressed()) {
                const plain = try compress.read(vol, run.chunk(vol), run.count << vol.block_shift);
                @memcpy(into[done..][0..piece], plain[@intCast(at - run_start)..][0..piece]);
            } else try vol.readData(run.block, at - run_start, into[done..][0..piece]);
            done += piece;
            continue;
        }
        // Up to the next block the overlay holds: what is committed.
        const held = nextHeld(ov, file_block);
        const until = if (held == ~@as(u64, 0)) ov.size else @min(ov.size, held << vol.block_shift);
        const piece: usize = @intCast(@min(@as(u64, left), until - at));
        const limit = if (ov.trunc_all) 0 else @min(ov.trim, node.size);
        if (at >= limit) {
            @memset(into[done..][0..piece], 0);
        } else {
            const valid: usize = @intCast(@min(@as(u64, piece), limit - at));
            try readCommitted(vol, &vol.obj, ov.oid, node, at, into[done..][0..valid]);
            @memset(into[done + valid ..][0 .. piece - valid], 0);
        }
        done += piece;
    }
}

/// Room for one more block: a checkpoint or two give back what earlier
/// ones freed, then a check's pin what it holds - the check stops - and
/// then what the file system above gives up (`Volume.make_room`).
pub fn room(vol: *Volume) Error!void {
    var tries: u32 = 0;
    while (space.available(vol) == 0) : (tries += 1) {
        if (tries < 2) {
            try checkpoint.write(vol, 0);
        } else if (vol.space.pin) {
            try space.unpin(vol);
        } else {
            const make = vol.make_room orelse return error.DiskFull;
            if (!try make(vol)) return error.DiskFull;
        }
    }
}

/// The buffer for file block `file_block`, made when there is none: read
/// in first, unless the caller `fills` that many bytes from the block's
/// start and nothing in it now counts - the rest is cleared. A block of a
/// compressed chunk brings the whole chunk into memory first.
fn pendingFor(vol: *Volume, ov: *Overlay, node: *const Inode, file_block: u64, fills: ?usize) Error![]u8 {
    if (pendingOf(ov, file_block)) |buffer| return buffer;
    if (runOf(ov, file_block)) |index| {
        if (ov.runs[index].compressed()) {
            try unpack(vol, ov, index);
            return pendingOf(ov, file_block) orelse error.Corrupt;
        }
    } else if (!ov.trunc_all) try pullChunk(vol, ov, node, file_block);
    return newPending(vol, ov, node, file_block, fills);
}

/// Room in the overlay's list for `more` blocks in memory.
fn reservePending(vol: *Volume, ov: *Overlay, more: usize) Error!void {
    if (ov.pending_count + more <= ov.pending.len) return;
    var length = if (ov.pending.len == 0) 8 else ov.pending.len * 2;
    while (length < ov.pending_count + more) length *= 2;
    const grown = try vol.allocSlice(Pending, length);
    @memcpy(grown[0..ov.pending_count], ov.pending[0..ov.pending_count]);
    vol.freeSlice(Pending, ov.pending);
    ov.pending = grown;
}

/// A compressed chunk of what is committed, which a write is about to go
/// into: every other block of it taken into the overlay, so the commit
/// writes the whole chunk anew - a compressed chunk is never written over
/// in part.
fn pullChunk(vol: *Volume, ov: *Overlay, node: *const Inode, file_block: u64) Error!void {
    if (node.flags & layout.INODE_INLINE != 0) return;
    const at = file_block << vol.block_shift;
    const limit = @min(ov.trim, @min(node.size, ov.size));
    if (at >= limit) return;
    const found = try extentAt(vol, &vol.obj, ov.oid, at) orelse return;
    if (!found.extent.compressed()) return;
    const end = @min(found.offset + found.extent.length, limit);
    const first = found.offset >> vol.block_shift;
    const last = (end + vol.block_size - 1) >> vol.block_shift;
    var each = first;
    while (each < last) : (each += 1) {
        if (each == file_block or pendingOf(ov, each) != null or runOf(ov, each) != null) continue;
        _ = try newPending(vol, ov, node, each, null);
    }
}

/// A compressed run of the overlay's back in memory a block at a time, so
/// part of it can be written; its blocks given back. Nothing changes when
/// the memory or the room is not there.
fn unpack(vol: *Volume, ov: *Overlay, index: usize) Error!void {
    const run = ov.runs[index];
    const count: usize = @intCast(run.count);
    try reservePending(vol, ov, count);
    if (space.available(vol) + run.blocks(vol) < count) return error.DiskFull;
    const made = ov.pending[ov.pending_count..][0..count];
    var taken: usize = 0;
    errdefer for (made[0..taken]) |entry| vol.giveBlock(entry.buffer);
    while (taken < count) : (taken += 1) {
        made[taken] = .{ .file_block = run.file_block + taken, .buffer = try vol.takeBlock() };
    }
    const plain = try compress.read(vol, run.chunk(vol), run.count << vol.block_shift);
    for (made) |entry| @memcpy(entry.buffer, plain[@intCast((entry.file_block - run.file_block) << vol.block_shift)..][0..vol.block_size]);
    try space.releaseHeld(vol, run.block, run.blocks(vol));
    var at = index;
    while (at + 1 < ov.run_count) : (at += 1) ov.runs[at] = ov.runs[at + 1];
    ov.run_count -= 1;
    ov.pending_count += count;
    vol.space.promised += count;
}

/// A new buffer in memory for file block `file_block`, as `pendingFor`
/// says: every byte of it read in, cleared, or the caller's to fill, so
/// it is not cleared when it is made.
fn newPending(vol: *Volume, ov: *Overlay, node: *const Inode, file_block: u64, fills: ?usize) Error![]u8 {
    if (ov.pending_count >= pendingMax(vol)) try spill(vol, ov, false);
    try room(vol);
    try reservePending(vol, ov, 1);
    const buffer = try vol.takeBlock();
    errdefer vol.giveBlock(buffer);
    if (fills) |count| {
        @memset(buffer[count..], 0);
    } else try readThrough(vol, ov, node, file_block << vol.block_shift, buffer);
    ov.pending[ov.pending_count] = .{ .file_block = file_block, .buffer = buffer };
    ov.pending_count += 1;
    vol.space.promised += 1;
    return buffer;
}

/// Bytes written into the file at `offset`, at most its size: how many
/// went in, all of them unless the error comes after some did (`failed`).
pub fn write(vol: *Volume, ov: *Overlay, node: *const Inode, offset: u64, bytes: []const u8, failed: *?Error) Error!usize {
    if (offset > ov.size) return error.InvalidArgument;
    const size = vol.block_size;
    var done: usize = 0;
    while (done < bytes.len) {
        const at = offset + done;
        const within: usize = @intCast(at & (size - 1));
        const piece = @min(bytes.len - done, size - within);
        const file_block = at >> vol.block_shift;
        // Nothing of the block counts when the write starts it and runs
        // to its end, or to the file's end.
        const whole = within == 0 and (piece == size or at + piece >= ov.size);
        const buffer = pendingFor(vol, ov, node, file_block, if (whole) piece else null) catch |err| {
            if (done == 0) return err;
            failed.* = err;
            return done;
        };
        @memcpy(buffer[within..][0..piece], bytes[done..][0..piece]);
        done += piece;
        if (at + piece > ov.size) ov.size = at + piece;
        ov.modified = true;
    }
    return done;
}

/// The file made `size` bytes long: cut, or grown by a hole.
pub fn setSize(vol: *Volume, ov: *Overlay, node: *const Inode, size: u64) Error!void {
    ov.modified = true;
    if (size >= ov.size) {
        ov.size = size;
        return;
    }
    const block_size = vol.block_size;
    const kept_blocks = (size + block_size - 1) >> vol.block_shift;
    // A compressed run the new end falls inside is cut a block at a time.
    if (kept_blocks > 0) {
        if (runOf(ov, kept_blocks - 1)) |index| {
            const run = ov.runs[index];
            if (run.compressed() and run.file_block + run.count > kept_blocks) try unpack(vol, ov, index);
        }
    }
    // A block of the overlay's the new end falls inside: in memory, its
    // tail cleared, so growing the file again shows zeros there. What is
    // committed past the end reads as zeros already (`trim`).
    if (size % block_size != 0) {
        const last = size >> vol.block_shift;
        if (pendingOf(ov, last) != null or runOf(ov, last) != null) {
            const buffer = try pendingFor(vol, ov, node, last, null);
            @memset(buffer[@intCast(size % block_size)..], 0);
        }
    }
    var index: usize = 0;
    while (index < ov.pending_count) {
        if (ov.pending[index].file_block >= kept_blocks) {
            vol.giveBlock(ov.pending[index].buffer);
            ov.pending[index] = ov.pending[ov.pending_count - 1];
            ov.pending_count -= 1;
            vol.space.promised -= 1;
        } else index += 1;
    }
    try cutRuns(vol, ov, kept_blocks, ~@as(u64, 0));
    if (size < ov.trim) ov.trim = size;
    ov.size = size;
}

/// MODE_NEWFILE: the file empty, everything it held dropped at the commit.
pub fn truncateAll(vol: *Volume, ov: *Overlay) Error!void {
    try discardData(vol, ov);
    ov.trunc_all = true;
    ov.size = 0;
    ov.modified = true;
}

/// The runs' blocks in [from, to) given back.
fn cutRuns(vol: *Volume, ov: *Overlay, from: u64, to: u64) Error!void {
    var index: usize = 0;
    while (index < ov.run_count) {
        const run = ov.runs[index];
        const end = run.file_block + run.count;
        if (end <= from or run.file_block >= to) {
            index += 1;
            continue;
        }
        const cut_start = if (run.file_block > from) run.file_block else from;
        const cut_end = if (end < to) end else to;
        const left = cut_start - run.file_block;
        const right = end - cut_end;
        if (run.compressed()) {
            // Taken back into memory before any part of it is cut.
            if (left > 0 or right > 0) return error.Corrupt;
            try space.releaseHeld(vol, run.block, run.blocks(vol));
        } else try space.releaseHeld(vol, run.block + (cut_start - run.file_block), cut_end - cut_start);
        const rest: Run = .{ .file_block = cut_end, .block = run.block + (cut_end - run.file_block), .count = right, .crc_first = if (right > 0) run.crcsFrom(cut_end) else no_crcs };
        if (left > 0 and right > 0) {
            ov.runs[index].count = left;
            try insertRun(vol, ov, index + 1, rest);
            index += 2;
        } else if (left > 0) {
            ov.runs[index].count = left;
            index += 1;
        } else if (right > 0) {
            ov.runs[index] = rest;
            index += 1;
        } else {
            var at = index;
            while (at + 1 < ov.run_count) : (at += 1) ov.runs[at] = ov.runs[at + 1];
            ov.run_count -= 1;
        }
    }
}

fn insertRun(vol: *Volume, ov: *Overlay, index: usize, run: Run) Error!void {
    if (ov.run_count == ov.runs.len) {
        const grown = try vol.allocSlice(Run, if (ov.runs.len == 0) 16 else ov.runs.len * 2);
        @memcpy(grown[0..ov.run_count], ov.runs[0..ov.run_count]);
        vol.freeSlice(Run, ov.runs);
        ov.runs = grown;
    }
    var at = ov.run_count;
    while (at > index) : (at -= 1) ov.runs[at] = ov.runs[at - 1];
    ov.runs[index] = run;
    ov.run_count += 1;
}

/// New blocks of the file in the runs: what the runs held there given
/// back, the run put in order and joined to its neighbours.
fn placeRun(vol: *Volume, ov: *Overlay, run: Run) Error!void {
    try cutRuns(vol, ov, run.file_block, run.file_block + run.count);
    var index: usize = 0;
    while (index < ov.run_count and ov.runs[index].file_block < run.file_block) index += 1;
    if (index > 0) {
        const before = &ov.runs[index - 1];
        if (joinable(before.*, run)) {
            before.count += run.count;
            joinNext(ov, index - 1);
            return;
        }
    }
    try insertRun(vol, ov, index, run);
    joinNext(ov, index);
}

fn joinNext(ov: *Overlay, index: usize) void {
    if (index + 1 >= ov.run_count) return;
    const run = &ov.runs[index];
    const after = ov.runs[index + 1];
    if (!joinable(run.*, after)) return;
    run.count += after.count;
    var at = index + 1;
    while (at + 1 < ov.run_count) : (at += 1) ov.runs[at] = ov.runs[at + 1];
    ov.run_count -= 1;
}

fn sortPending(pending: []Pending) void {
    var gap = pending.len / 2;
    while (gap > 0) : (gap /= 2) {
        var at = gap;
        while (at < pending.len) : (at += 1) {
            const moving = pending[at];
            var to = at;
            while (to >= gap and pending[to - gap].file_block > moving.file_block) : (to -= gap) pending[to] = pending[to - gap];
            pending[to] = moving;
        }
    }
}

/// The blocks in memory written to homes of their own, as long runs as
/// the free space gives: a whole chunk compressed where that saves, the
/// rest as it is, with their crcs. `final` at a commit: the chunk the
/// file ends in counts as whole, though more may be written to it later.
fn spill(vol: *Volume, ov: *Overlay, final: bool) Error!void {
    if (ov.pending_count == 0) return;
    const pending = ov.pending[0..ov.pending_count];
    sortPending(pending);
    vol.space.promised -= ov.pending_count;
    var written: usize = 0;
    // What was not written stays in memory, promised again.
    defer {
        var kept: usize = 0;
        for (ov.pending[0..ov.pending_count]) |entry| {
            if (entry.buffer.len == 0) continue;
            ov.pending[kept] = entry;
            kept += 1;
        }
        ov.pending_count = kept;
        vol.space.promised += kept;
    }
    const checksums = vol.voltab.flags & layout.VT_CHECKSUMS != 0 and !ov.no_checksums;
    const per_chunk: u64 = @as(u64, layout.chunk_size) >> vol.block_shift;
    const compressing = vol.voltab.flags & layout.VT_COMPRESS != 0 and !ov.no_compress and per_chunk > 1;
    const size_blocks = (ov.size + vol.block_size - 1) >> vol.block_shift;
    while (written < pending.len) {
        // A stretch of the file's blocks one after another.
        var stretch: usize = 1;
        while (written + stretch < pending.len and pending[written + stretch].file_block == pending[written].file_block + stretch) stretch += 1;
        const first = pending[written].file_block;
        var raw = stretch;
        if (compressing) {
            // A chunk is compressed whole or not at all, and a stretch
            // stops at the next chunk so that one may be.
            const next_chunk = (first / per_chunk + 1) * per_chunk;
            if (next_chunk - first < raw) raw = @intCast(next_chunk - first);
            if (first % per_chunk == 0 and first < size_blocks) {
                const chunk_blocks: usize = @intCast(@min(per_chunk, size_blocks - first));
                const whole = stretch >= chunk_blocks and (first + per_chunk <= size_blocks or final);
                if (whole and chunk_blocks > 1 and try packChunk(vol, ov, pending[written..][0..chunk_blocks])) {
                    written += chunk_blocks;
                    continue;
                }
            }
        }
        written += try writeRaw(vol, ov, pending[written..][0..raw], checksums);
    }
}

/// Blocks in memory, one after another in the file, written as they are
/// to as long a run as the free space gives, with their crcs when
/// `checksums`: how many went.
fn writeRaw(vol: *Volume, ov: *Overlay, entries: []Pending, checksums: bool) Error!usize {
    // The room was promised when the blocks were taken in memory: nothing
    // else has been given it since, the reserve included.
    const run = try space.alloc(vol, entries.len, .held, true);
    const count: usize = @intCast(run.count);
    if (checksums) try reserveCrcs(vol, ov, count);
    writeRun(vol, run.start, entries[0..count]) catch |err| {
        try space.releaseHeld(vol, run.start, run.count);
        return err;
    };
    var crc_first = no_crcs;
    if (checksums) {
        crc_first = @intCast(ov.crc_count);
        for (entries[0..count]) |entry| {
            ov.crcs[ov.crc_count] = layout.crcSeeded(&vol.uuid, entry.buffer);
            ov.crc_count += 1;
        }
    }
    try placeRun(vol, ov, .{ .file_block = entries[0].file_block, .block = run.start, .count = run.count, .crc_first = crc_first });
    for (entries[0..count]) |*entry| {
        vol.giveBlock(entry.buffer);
        entry.buffer = &.{};
    }
    return count;
}

/// Blocks in memory written to the run of blocks from `start`: put one
/// after another in the volume's gather buffer and sent in one command
/// for as many as it holds - a command a block costs the time of several
/// blocks on an SSD - or a block at a time when there is no memory for
/// the buffer.
fn writeRun(vol: *Volume, start: u64, entries: []const Pending) Error!void {
    const size: usize = vol.block_size;
    if (entries.len > 1 and vol.gather.len == 0) vol.gather = vol.allocRaw(pendingMax(vol) * size) catch &.{};
    const holds = vol.gather.len / size;
    if (entries.len == 1 or holds < 2) {
        for (entries, 0..) |entry, index| try vol.writeBlocks(start + index, entry.buffer);
        return;
    }
    var done: usize = 0;
    while (done < entries.len) {
        const piece = @min(entries.len - done, holds);
        for (entries[done..][0..piece], 0..) |entry, index| @memcpy(vol.gather[index * size ..][0..size], entry.buffer);
        try vol.writeBlocks(start + done, vol.gather[0 .. piece * size]);
        done += piece;
    }
}

/// A whole chunk in memory compressed and written, when that saves a
/// block and the free space has a run for it: whether it was.
fn packChunk(vol: *Volume, ov: *Overlay, entries: []Pending) Error!bool {
    const plain = try compress.assembly(vol);
    const size: usize = vol.block_size;
    for (entries, 0..) |entry, index| @memcpy(plain[index * size ..][0..size], entry.buffer);
    const result = try compress.pack(vol, plain[0 .. entries.len * size]) orelse return false;
    const blocks = result.bytes.len / size;
    const run = try space.alloc(vol, blocks, .held, true);
    if (run.count < blocks) {
        try space.releaseHeld(vol, run.start, run.count);
        return false;
    }
    vol.writeBlocks(run.start, result.bytes) catch |err| {
        try space.releaseHeld(vol, run.start, run.count);
        return err;
    };
    try placeRun(vol, ov, .{ .file_block = entries[0].file_block, .block = run.start, .count = entries.len, .stored = result.stored, .crc = result.crc });
    for (entries) |*entry| {
        vol.giveBlock(entry.buffer);
        entry.buffer = &.{};
    }
    return true;
}

/// Room in the overlay's crcs for `more`.
fn reserveCrcs(vol: *Volume, ov: *Overlay, more: usize) Error!void {
    if (ov.crc_count + more <= ov.crcs.len) return;
    var length = if (ov.crcs.len == 0) 64 else ov.crcs.len * 2;
    while (length < ov.crc_count + more) length *= 2;
    if (length > no_crcs) return error.NoMemory;
    const grown = try vol.allocSlice(u32, length);
    @memcpy(grown[0..ov.crc_count], ov.crcs[0..ov.crc_count]);
    vol.freeSlice(u32, ov.crcs);
    ov.crcs = grown;
}

/// Everything the overlay holds given back: its blocks, its memory.
fn discardData(vol: *Volume, ov: *Overlay) Error!void {
    for (ov.runs[0..ov.run_count]) |run| try space.releaseHeld(vol, run.block, run.blocks(vol));
    ov.run_count = 0;
    ov.crc_count = 0;
    for (ov.pending[0..ov.pending_count]) |entry| vol.giveBlock(entry.buffer);
    vol.space.promised -= ov.pending_count;
    ov.pending_count = 0;
}

/// The overlay put away without a commit, and its memory freed.
pub fn discard(vol: *Volume, ov: *Overlay) void {
    discardData(vol, ov) catch {};
    vol.freeSlice(Run, ov.runs);
    vol.freeSlice(Pending, ov.pending);
    vol.freeSlice(u32, ov.crcs);
    ov.runs = &.{};
    ov.pending = &.{};
    ov.crcs = &.{};
}

/// The overlay's memory freed and nothing else: for a medium that has
/// gone, whose space the volume keeps no more.
pub fn forget(vol: *Volume, ov: *Overlay) void {
    for (ov.pending[0..ov.pending_count]) |entry| vol.giveBlock(entry.buffer);
    ov.pending_count = 0;
    ov.run_count = 0;
    ov.crc_count = 0;
    vol.freeSlice(Run, ov.runs);
    vol.freeSlice(Pending, ov.pending);
    vol.freeSlice(u32, ov.crcs);
    ov.runs = &.{};
    ov.pending = &.{};
    ov.crcs = &.{};
}

/// The most bytes a file keeps inline.
pub fn inlineLimit(vol: *const Volume) u32 {
    const most = layout.inlineMax(vol.block_size);
    const set = vol.voltab.inline_max;
    return if (set != 0 and set < most) set else most;
}

/// What the overlay holds made the file's committed content: the data
/// written, then the record, then applied - durable with the journal's
/// next flush, which puts the data down first. The overlay matches the
/// tree after it.
pub fn commit(vol: *Volume, ov: *Overlay) Error!void {
    if (!ov.modified) return;
    var node = try objects.needInode(vol, ov.oid);
    const time = vol.now();
    var record: layout.CommitRecord = .{ .oid = ov.oid, .size = ov.size, .mtime = time, .time = time };
    var payload: []u8 = &.{};
    defer vol.free(payload);
    const head = @sizeOf(layout.CommitRecord);
    if (ov.size <= inlineLimit(vol)) {
        const len: usize = @intCast(ov.size);
        payload = try vol.alloc(head + len);
        try readThrough(vol, ov, &node, 0, payload[head..][0..len]);
        record.flags = layout.COMMIT_INLINE | layout.COMMIT_TRUNC_ALL;
        record.inline_len = @intCast(len);
        @memcpy(payload[0..head], layout.bytesOf(&record));
        try objects.change(vol, .commit, payload);
        try discardData(vol, ov);
    } else {
        // Inline bytes that stay are among the new data.
        if (ov.base_inline and !ov.trunc_all and pendingOf(ov, 0) == null and runOf(ov, 0) == null) {
            _ = try pendingFor(vol, ov, &node, 0, null);
        }
        try spill(vol, ov, true);
        if (ov.trunc_all) record.flags |= layout.COMMIT_TRUNC_ALL;
        if (ov.trim != no_trim) {
            record.flags |= layout.COMMIT_TRIM;
            record.trim = ov.trim;
        }
        // A spec a run - a checksummed one cut to what a csum item holds -
        // and its crcs behind it.
        const per_item = layout.csumPerItem(vol.block_size);
        var spec_count: usize = 0;
        var crc_total: usize = 0;
        for (ov.runs[0..ov.run_count]) |run| {
            if (run.crc_first == no_crcs) {
                spec_count += 1;
            } else {
                spec_count += @intCast((run.count + per_item - 1) / per_item);
                crc_total += @intCast(run.count);
            }
        }
        record.specs = @intCast(spec_count);
        payload = try vol.alloc(head + spec_count * @sizeOf(layout.ExtSpec) + crc_total * 4);
        @memcpy(payload[0..head], layout.bytesOf(&record));
        var at: usize = head;
        for (ov.runs[0..ov.run_count]) |run| {
            var done: u64 = 0;
            while (done < run.count) {
                const offset = (run.file_block + done) << vol.block_shift;
                var spec: layout.ExtSpec = .{ .offset = offset, .block = run.block + done };
                var piece = run.count - done;
                if (run.compressed()) {
                    spec.blocks = @intCast(run.blocks(vol));
                    spec.flags = layout.EXTENT_COMPRESSED | (layout.alg_lz4 << layout.EXTENT_ALG_SHIFT);
                    spec.stored = run.stored;
                    spec.crc = run.crc;
                } else {
                    if (run.crc_first != no_crcs) {
                        if (piece > per_item) piece = per_item;
                        spec.flags = layout.EXTENT_CHECKSUMMED;
                    }
                    spec.blocks = @intCast(piece);
                }
                spec.length = @min(piece << vol.block_shift, ov.size - offset);
                @memcpy(payload[at..][0..@sizeOf(layout.ExtSpec)], layout.bytesOf(&spec));
                at += @sizeOf(layout.ExtSpec);
                if (spec.flags == layout.EXTENT_CHECKSUMMED) {
                    const first: usize = run.crcsFrom(run.file_block + done);
                    const bytes = crcBytes(ov.crcs[first..][0..@intCast(piece)]);
                    @memcpy(payload[at..][0..bytes.len], bytes);
                    at += bytes.len;
                }
                done += piece;
            }
        }
        if (payload.len > journal.max_record) {
            // Too big for the journal: in the tree, and committed by two
            // checkpoints - the second, so a mount that falls back one
            // still has it.
            objects.apply(vol, .commit, 0, payload) catch |err| {
                vol.failed = true;
                return err;
            };
            try checkpoint.write(vol, 0);
            try checkpoint.write(vol, 0);
        } else try objects.change(vol, .commit, payload);
        // The runs' blocks are the tree's now.
        ov.run_count = 0;
        ov.crc_count = 0;
    }
    ov.base_inline = ov.size <= inlineLimit(vol);
    ov.trunc_all = false;
    ov.trim = no_trim;
    ov.modified = false;
}

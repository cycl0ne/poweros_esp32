// SPDX-License-Identifier: MIT
//! Host tests of packs read in place and indexed: both fixture packs
//! indexed from memory give the idx files git wrote for them, byte for
//! byte; every object read back whole, its deltas applied, has its id;
//! a broken pack and a delta without its base are refused.

const std = @import("std");
const sdk = @import("sdk");
const rig_file = @import("rig.zig");
const Rig = rig_file.Rig;
const BufferSink = rig_file.BufferSink;
const _git = @import("../_git.zig");
const object = @import("../object.zig");
const pack = @import("../pack.zig");
const idx = @import("../idx.zig");
const packread = @import("../packread.zig");
const indexpack = @import("../indexpack.zig");
const store = @import("../store.zig");
const compression = sdk.compression;
const Id = _git.Id;

const testing = std.testing;

const ofs_pack = @embedFile("fixtures/ofs.pack");
const ofs_idx = @embedFile("fixtures/ofs.idx");
const ref_pack = @embedFile("fixtures/ref.pack");
const ref_idx = @embedFile("fixtures/ref.idx");

/// A pack in memory as a source, counting its reads.
const Memory = struct {
    bytes: []const u8,
    reads: usize = 0,

    fn read(context: *anyopaque, offset: u64, into: []u8) i32 {
        const memory: *Memory = @ptrCast(@alignCast(context));
        memory.reads += 1;
        if (offset >= memory.bytes.len) return 0;
        const start: usize = @intCast(offset);
        const count = @min(into.len, memory.bytes.len - start);
        @memcpy(into[0..count], memory.bytes[start..][0..count]);
        return @intCast(count);
    }

    fn source(memory: *Memory) packread.Source {
        return .{ .context = memory, .read = read };
    }
};

var indexer_store: indexpack.Indexer = undefined;
var reading_store: packread.Pack = undefined;
var idx_out: [4096]u8 = undefined;

const Steps = struct {
    indexing: u32 = 0,
    resolving: u32 = 0,
    total_deltas: u32 = 0,

    fn step(context: *anyopaque, phase: indexpack.Phase, done: u32, total: u32) bool {
        const steps: *Steps = @ptrCast(@alignCast(context));
        switch (phase) {
            .indexing => steps.indexing = done,
            .resolving => {
                steps.resolving = done;
                steps.total_deltas = total;
            },
        }
        return true;
    }
};

test "both packs indexed: git's idx, byte for byte" {
    var rig = try Rig.init();
    for ([_][]const u8{ ofs_pack, ref_pack }, [_][]const u8{ ofs_idx, ref_idx }) |bytes, expected| {
        var memory: Memory = .{ .bytes = bytes };
        const indexer = &indexer_store;
        indexer.init(rig.sys, rig.zb, rig.cb, memory.source());
        var steps: Steps = .{};
        indexer.progress = .{ .context = &steps, .step = Steps.step };
        var buffer: BufferSink = .{ .out = .{ .into = &idx_out } };
        const count = pack.parseHeader(bytes).?;
        const ok = indexer.run(bytes.len, count, bytes[bytes.len - 20 ..][0..20], buffer.sink());
        indexer.deinit();
        try testing.expect(ok);
        try testing.expectEqualSlices(u8, expected, buffer.out.written());
        try testing.expectEqual(@as(u32, 20), steps.indexing);
        try testing.expectEqual(@as(u32, 3), steps.resolving);
        try testing.expectEqual(@as(u32, 3), steps.total_deltas);
    }
    try rig.deinit();
}

/// A REF_DELTA's base looked up in the same pack through its idx.
const SamePack = struct {
    reading: *packread.Pack,
    index: idx.Idx,

    fn lookup(context: *anyopaque, id: *const Id) ?packread.Object {
        const same: *SamePack = @ptrCast(@alignCast(context));
        const position = same.index.find(id) orelse return null;
        // A pack of its own for the base, as the store reads one.
        var base_reading: packread.Pack = undefined;
        base_reading.init(same.reading.sys, same.reading.reader.zb, same.reading.reader.source);
        base_reading.lookup = lookup;
        base_reading.lookup_context = context;
        defer base_reading.deinit();
        return base_reading.readObject(same.index.offsetAt(position).?);
    }
};

test "every object read whole from both packs, deltas applied, with its id" {
    var rig = try Rig.init();
    for ([_][]const u8{ ofs_pack, ref_pack }, [_][]const u8{ ofs_idx, ref_idx }) |bytes, index_bytes| {
        var memory: Memory = .{ .bytes = bytes };
        const reading = &reading_store;
        reading.init(rig.sys, rig.zb, memory.source());
        var same: SamePack = .{ .reading = reading, .index = idx.Idx.open(index_bytes).? };
        reading.lookup = SamePack.lookup;
        reading.lookup_context = &same;
        for (0..same.index.count) |position| {
            const wanted = same.index.idAt(@intCast(position));
            var found = reading.readObject(same.index.offsetAt(@intCast(position)).?) orelse return error.Unreadable;
            defer found.free(rig.sys);
            try testing.expectEqual(wanted.*, object.idOfObject(rig.cb, found.kind, found.data));
        }
        reading.deinit();
    }
    try rig.deinit();
}

test "a broken entry, a delta without its base, a pack cut short" {
    var rig = try Rig.init();
    const indexer = &indexer_store;

    // A byte of the first entry's stream changed.
    var broken: [ofs_pack.len]u8 = ofs_pack.*;
    broken[pack.header_bytes + 4] ^= 0x55;
    var memory: Memory = .{ .bytes = &broken };
    indexer.init(rig.sys, rig.zb, rig.cb, memory.source());
    var buffer: BufferSink = .{ .out = .{ .into = &idx_out } };
    try testing.expect(!indexer.run(broken.len, 20, broken[broken.len - 20 ..][0..20], buffer.sink()));
    try testing.expectEqual(indexpack.Failure.entry, indexer.failure);
    indexer.deinit();

    // The REF pack's entries without the objects its deltas are made
    // on: a pack of only its deltas.
    const ref_index = idx.Idx.open(ref_idx).?;
    var offsets: [20]u64 = undefined;
    for (0..20) |position| offsets[position] = ref_index.offsetAt(@intCast(position)).?;
    std.mem.sort(u64, &offsets, {}, std.sort.asc(u64));
    var thin: [ref_pack.len]u8 = undefined;
    var length: usize = pack.header_bytes;
    var count: u32 = 0;
    for (offsets, 0..) |offset, position| {
        const end = if (position + 1 < offsets.len) offsets[position + 1] else ref_pack.len - 20;
        const head = pack.parseEntryHead(ref_pack[@intCast(offset)..]).head;
        if (head.kind != .ref_delta) continue;
        const entry = ref_pack[@intCast(offset)..@intCast(end)];
        @memcpy(thin[length..][0..entry.len], entry);
        length += entry.len;
        count += 1;
    }
    try testing.expectEqual(@as(u32, 3), count);
    pack.putHeader(thin[0..pack.header_bytes], count);
    const sum = _git.sha1Of(rig.cb, thin[0..length]);
    @memcpy(thin[length..][0..20], &sum);
    length += 20;
    memory = .{ .bytes = thin[0..length] };
    indexer.init(rig.sys, rig.zb, rig.cb, memory.source());
    buffer = .{ .out = .{ .into = &idx_out } };
    try testing.expect(!indexer.run(length, count, &sum, buffer.sink()));
    try testing.expectEqual(indexpack.Failure.base, indexer.failure);
    indexer.deinit();

    // Fewer bytes than the entries need.
    memory = .{ .bytes = ofs_pack[0 .. ofs_pack.len - 100] };
    indexer.init(rig.sys, rig.zb, rig.cb, memory.source());
    buffer = .{ .out = .{ .into = &idx_out } };
    try testing.expect(!indexer.run(ofs_pack.len - 100, 20, ofs_pack[ofs_pack.len - 20 ..][0..20], buffer.sink()));
    try testing.expectEqual(indexpack.Failure.entry, indexer.failure);
    indexer.deinit();
    try rig.deinit();
}

/// `body` as a loose object of `kind`: its header and itself, zlib over
/// both.
fn looseOf(rig: *Rig, kind: []const u8, body: []const u8, into: []u8) ![]u8 {
    var raw: [2048]u8 = undefined;
    var out: _git.Out = .{ .into = &raw };
    out.put(kind);
    out.byte(' ');
    out.decimal(body.len);
    out.byte(0);
    out.put(body);
    var stream: compression.Stream = .{};
    stream.next_in = &raw;
    stream.avail_in = @intCast(out.at);
    stream.next_out = into.ptr;
    stream.avail_out = @intCast(into.len);
    try testing.expectEqual(compression.COMPRESS_OK, rig.zb.Compress(&stream, compression.FORMAT_ZLIB, compression.LEVEL_DEFAULT));
    return into[0..@intCast(stream.total_out)];
}

test "loose objects: one that comes whole with its header, a larger one, one cut short" {
    var rig = try Rig.init();
    var packed_bytes: [2048]u8 = undefined;
    const bodies = [_][]const u8{ "", "bee\n", "1234567890" ** 100 };
    for (bodies) |body| {
        const loose = try looseOf(&rig, "blob", body, &packed_bytes);
        var found = store.inflateLoose(rig.sys, rig.zb, loose) orelse return error.NotRead;
        defer found.free(rig.sys);
        try testing.expectEqual(object.Type.blob, found.kind);
        try testing.expectEqualStrings(body, found.data);
    }
    for (bodies[1..]) |body| {
        const loose = try looseOf(&rig, "blob", body, &packed_bytes);
        try testing.expect(store.inflateLoose(rig.sys, rig.zb, loose[0 .. loose.len - 6]) == null);
    }
    try rig.deinit();
}

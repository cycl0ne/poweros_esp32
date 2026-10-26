// SPDX-License-Identifier: MIT
//! Host tests of Git's formats against bytes the host's git made
//! (fixtures/): a repository of three commits, a tag, a subdirectory, an
//! executable and a link, packed once with OFS deltas and once with REF
//! deltas, the two packs' indexes, the index file and a loose object.
//! Every object comes out of both packs with git's own id; the indexes
//! are read and written again byte for byte; pkt-lines come through a
//! source that hands them over in pieces of every size. SHA-1 and zlib
//! are crypto.library's and compression.library's, made on the ROM's
//! exec as a program opens them.

const std = @import("std");
const sdk = @import("sdk");
const rig_file = @import("rig.zig");
const Rig = rig_file.Rig;
const BufferSink = rig_file.BufferSink;
const _git = @import("../_git.zig");
const pktline = @import("../pktline.zig");
const object = @import("../object.zig");
const pack = @import("../pack.zig");
const idx = @import("../idx.zig");
const index = @import("../index.zig");
const files = @import("../files.zig");
const Id = _git.Id;

const testing = std.testing;

const ofs_pack = @embedFile("fixtures/ofs.pack");
const ofs_idx = @embedFile("fixtures/ofs.idx");
const ref_pack = @embedFile("fixtures/ref.pack");
const ref_idx = @embedFile("fixtures/ref.idx");
const index_file = @embedFile("fixtures/index");
const loose_readme = @embedFile("fixtures/loose-26e228");

/// Every object in the fixture repository, as `git cat-file
/// --batch-all-objects --batch-check` lists them.
const objects = [_]struct { id: []const u8, kind: object.Type, size: usize }{
    .{ .id = "1ca9282cde00c6b6bb3f7b9f0b3e7deb25aea389", .kind = .blob, .size = 9 },
    .{ .id = "26e2285260bbd6af3d90d3ab44e86b07f94afd7b", .kind = .blob, .size = 57 },
    .{ .id = "4163036efa65bd4a469e752267498f01ea36a55c", .kind = .blob, .size = 18 },
    .{ .id = "614e24a92f7c24e3b41e3a96e4a281d3766357a0", .kind = .blob, .size = 3242 },
    .{ .id = "62c9c9efdbc9e1c0c7d1bc39fa52880911e4c4b9", .kind = .blob, .size = 3170 },
    .{ .id = "902b554db075c1aa8c2a58d7b9f088a5f93bd741", .kind = .blob, .size = 22 },
    .{ .id = "a8190125a65d3e197c0fcd0deededa487d15509c", .kind = .blob, .size = 32 },
    .{ .id = "cd41d0d330a3b983243892c5188d77126dfc02b8", .kind = .blob, .size = 47 },
    .{ .id = "f3b3024be25a3cc79f04294123e1c88bd05262f9", .kind = .blob, .size = 3240 },
    .{ .id = "f5289bf9fb854f9c16f70e12dec3de89ac12fb7c", .kind = .blob, .size = 39 },
    .{ .id = "2402fc2a7f25ec4ef15e4e2c9b1b75bffe4b1afd", .kind = .commit, .size = 255 },
    .{ .id = "3dd183b58d469e7d140b1761fbe082e208739533", .kind = .commit, .size = 228 },
    .{ .id = "5882a8cc99e60e3d40f68f6e1ff9f9fc7c979035", .kind = .commit, .size = 177 },
    .{ .id = "6c6d6d6ca9d196896bf1b659bb669f34a661fc55", .kind = .tag, .size = 137 },
    .{ .id = "8227a73cd08bc3c4e7195e49cca3374c528922e6", .kind = .tree, .size = 37 },
    .{ .id = "977f530f7d56a8325668ca5e7335c78d1c57d7ed", .kind = .tree, .size = 170 },
    .{ .id = "9ff1f2e13a25093afd701961624229b5925787e1", .kind = .tree, .size = 170 },
    .{ .id = "ade1217c35c63b6e2d8fa1b7ec1e261816cb0cff", .kind = .tree, .size = 67 },
    .{ .id = "b3aae519e0a77a2693b1a0b59fe1f2b41b464a13", .kind = .tree, .size = 67 },
    .{ .id = "d2a6ab968608746016fd28c8a9f09765e5cda26c", .kind = .tree, .size = 170 },
};

fn id(comptime text: []const u8) Id {
    return _git.idOf(text).?;
}

test "ids in hex and back" {
    const text = "9ff1f2e13a25093afd701961624229b5925787e1";
    var hex: [40]u8 = undefined;
    _git.hexOf(&id(text), &hex);
    try testing.expectEqualStrings(text, &hex);
    try testing.expectEqual(id(text), _git.idOf("9FF1F2E13A25093AFD701961624229B5925787E1").?);
    try testing.expectEqual(@as(?Id, null), _git.idOf("9ff1f2e13a25093afd701961624229b5925787e"));
    try testing.expectEqual(@as(?Id, null), _git.idOf("9ff1f2e13a25093afd701961624229b5925787eg"));
}

// --- pkt-lines -----------------------------------------------------------------

test "pkt-line lengths, and packets written" {
    try testing.expectEqual(pktline.Kind.flush, pktline.lengthOf("0000").?.kind);
    try testing.expectEqual(pktline.Kind.delim, pktline.lengthOf("0001").?.kind);
    try testing.expectEqual(pktline.Kind.response_end, pktline.lengthOf("0002").?.kind);
    try testing.expectEqual(@as(usize, 0), pktline.lengthOf("0004").?.length);
    try testing.expectEqual(@as(usize, 6), pktline.lengthOf("000a").?.length);
    try testing.expectEqual(@as(usize, 65516), pktline.lengthOf("fff0").?.length);
    for ([_]*const [4]u8{ "0003", "fff1", "ffff", "00g0", "-001" }) |bad| {
        try testing.expect(pktline.lengthOf(bad) == null);
    }
    var bytes: [128]u8 = undefined;
    var out: _git.Out = .{ .into = &bytes };
    pktline.put(&out, "command=ls-refs\n");
    pktline.putParts(&out, &.{ "want ", "2402fc2a7f25ec4ef15e4e2c9b1b75bffe4b1afd", "\n" });
    out.put(pktline.delim);
    out.put(pktline.flush);
    try testing.expectEqualStrings("0014command=ls-refs\n0032want 2402fc2a7f25ec4ef15e4e2c9b1b75bffe4b1afd\n00010000", out.written());
}

/// A source that hands over `bytes` in pieces of at most `piece`.
const Pieces = struct {
    bytes: []const u8,
    piece: usize,
    at: usize = 0,
    fail_at: ?usize = null,

    fn read(context: *anyopaque, into: []u8) i32 {
        const pieces: *Pieces = @ptrCast(@alignCast(context));
        if (pieces.fail_at) |where| if (pieces.at >= where) return -2;
        const count = @min(into.len, pieces.piece, pieces.bytes.len - pieces.at);
        @memcpy(into[0..count], pieces.bytes[pieces.at..][0..count]);
        pieces.at += count;
        return @intCast(count);
    }

    fn source(pieces: *Pieces) pktline.Source {
        return .{ .context = pieces, .read = read };
    }
};

var reader_buffer: [pktline.buffer_bytes]u8 = undefined;

test "pkt-lines read in pieces of every size, and what follows them" {
    var long: [1000]u8 = undefined;
    for (&long, 0..) |*byte, at| byte.* = @intCast('a' + at % 26);
    var stream: [1200]u8 = undefined;
    var out: _git.Out = .{ .into = &stream };
    pktline.put(&out, "version 2\n");
    out.put(pktline.delim);
    pktline.put(&out, &long);
    pktline.put(&out, "");
    out.put(pktline.response_end);
    out.put(pktline.flush);
    out.put("PACK-after");
    const written = out.written();

    for ([_]usize{ 1, 2, 3, 5, 7, 64, 511, 512, 513, 4096 }) |piece| {
        var pieces: Pieces = .{ .bytes = written, .piece = piece };
        var reader: pktline.Reader = .{ .source = pieces.source(), .buffer = &reader_buffer };
        const first = reader.next().?;
        try testing.expectEqualStrings("version 2", pktline.line(first.data));
        try testing.expectEqual(pktline.Kind.delim, reader.next().?.kind);
        try testing.expectEqualStrings(&long, reader.next().?.data);
        const empty = reader.next().?;
        try testing.expectEqual(pktline.Kind.data, empty.kind);
        try testing.expectEqual(@as(usize, 0), empty.data.len);
        try testing.expectEqual(pktline.Kind.response_end, reader.next().?.kind);
        try testing.expectEqual(pktline.Kind.flush, reader.next().?.kind);
        // What came along after the flush waits for whoever reads on.
        var after: [16]u8 = undefined;
        const left = reader.leftOver();
        @memcpy(after[0..left.len], left);
        reader.dropLeftOver();
        var rest = left.len;
        while (rest < 10) {
            const got = Pieces.read(&pieces, after[rest..10]);
            if (got <= 0) break;
            rest += @intCast(got);
        }
        try testing.expectEqualStrings("PACK-after", after[0..rest]);
    }

    // The end between packets is an end; inside one, a packet cut short.
    var clean: Pieces = .{ .bytes = "0000", .piece = 2 };
    var reader: pktline.Reader = .{ .source = clean.source(), .buffer = &reader_buffer };
    try testing.expectEqual(pktline.Kind.flush, reader.next().?.kind);
    try testing.expect(reader.next() == null);
    try testing.expectEqual(pktline.Error.ended, reader.failure);
    var cut: Pieces = .{ .bytes = "000ahel", .piece = 100 };
    reader = .{ .source = cut.source(), .buffer = &reader_buffer };
    try testing.expect(reader.next() == null);
    try testing.expectEqual(pktline.Error.malformed, reader.failure);
    var bad: Pieces = .{ .bytes = "00x0", .piece = 100 };
    reader = .{ .source = bad.source(), .buffer = &reader_buffer };
    try testing.expect(reader.next() == null);
    try testing.expectEqual(pktline.Error.malformed, reader.failure);
    var failing: Pieces = .{ .bytes = "0008abcd0008efgh", .piece = 100, .fail_at = 8 };
    reader = .{ .source = failing.source(), .buffer = &reader_buffer };
    try testing.expectEqualStrings("abcd", reader.next().?.data);
    // The first read took all sixteen bytes; the second packet is there.
    try testing.expectEqualStrings("efgh", reader.next().?.data);
    try testing.expect(reader.next() == null);
    try testing.expectEqual(pktline.Error.failed, reader.failure);
    try testing.expectEqual(@as(i32, -2), reader.code);
}

// --- objects ---------------------------------------------------------------------

test "objects: the header, the id, a loose object, a commit, a tag, a tree" {
    var rig = try Rig.init();
    var head: [32]u8 = undefined;
    try testing.expectEqualStrings("blob 6\x00", object.header(.blob, 6, &head));
    // git's id of "hello\n".
    try testing.expectEqual(id("ce013625030ba8dba906f756967f9e9ca394464a"), object.idOfObject(rig.cb, .blob, "hello\n"));

    var loose: [128]u8 = undefined;
    const readme = "# Fixture\n\nA repository for the tests.\nSecond paragraph.\n";
    const unpacked_length = "blob 57\x00".len + readme.len;
    _ = try rig.inflate(loose_readme, loose[0..unpacked_length]);
    const parsed = object.parseHeader(loose[0..unpacked_length]).?;
    try testing.expectEqual(object.Type.blob, parsed.kind);
    try testing.expectEqual(@as(u64, 57), parsed.size);
    try testing.expectEqualStrings(readme, loose[parsed.body_at..unpacked_length]);
    try testing.expectEqual(id("26e2285260bbd6af3d90d3ab44e86b07f94afd7b"), _git.sha1Of(rig.cb, loose[0..unpacked_length]));
    for ([_][]const u8{ "blob", "blob 5", "blob x\x00", "blub 5\x00", "blob \x00" }) |bad| {
        try testing.expect(object.parseHeader(bad) == null);
    }

    const commit_text =
        "tree 9ff1f2e13a25093afd701961624229b5925787e1\n" ++
        "parent 2402fc2a7f25ec4ef15e4e2c9b1b75bffe4b1afd\n" ++
        "author Test Author <test@example.org> 1761407200 +0100\n" ++
        "committer Test Author <test@example.org> 1761407200 +0100\n" ++
        "\n" ++
        "third: more changes\n";
    try testing.expectEqual(id("3dd183b58d469e7d140b1761fbe082e208739533"), object.idOfObject(rig.cb, .commit, commit_text));
    const commit = object.parseCommit(commit_text).?;
    try testing.expectEqual(id("9ff1f2e13a25093afd701961624229b5925787e1"), commit.tree);
    try testing.expectEqual(@as(usize, 1), commit.parent_count);
    try testing.expectEqual(id("2402fc2a7f25ec4ef15e4e2c9b1b75bffe4b1afd"), commit.parent(0));
    try testing.expectEqualStrings("Test Author", commit.author.name);
    try testing.expectEqualStrings("test@example.org", commit.author.email);
    try testing.expectEqual(@as(i64, 1761407200), commit.committer.time);
    try testing.expectEqual(@as(i32, 60), commit.committer.offset);
    try testing.expectEqualStrings("third: more changes\n", commit.message);
    try testing.expectEqualStrings("third: more changes", commit.subject());
    const merge = object.parseCommit("tree 9ff1f2e13a25093afd701961624229b5925787e1\nparent 2402fc2a7f25ec4ef15e4e2c9b1b75bffe4b1afd\nparent 5882a8cc99e60e3d40f68f6e1ff9f9fc7c979035\nauthor A <a> 1 -0230\ncommitter A <a> 2 +0000\ngpgsig x\n\nmerge").?;
    try testing.expectEqual(@as(usize, 2), merge.parent_count);
    try testing.expectEqual(id("5882a8cc99e60e3d40f68f6e1ff9f9fc7c979035"), merge.parent(1));
    try testing.expectEqual(@as(i32, -150), merge.author.offset);
    const root = object.parseCommit("tree 9ff1f2e13a25093afd701961624229b5925787e1\nauthor A <a> 1 +0000\ncommitter A <a> 2 +0000\n\nfirst").?;
    try testing.expectEqual(@as(usize, 0), root.parent_count);
    try testing.expect(object.parseCommit("parent 2402fc2a7f25ec4ef15e4e2c9b1b75bffe4b1afd\nauthor A <a> 1 +0000\ncommitter A <a> 2 +0000\n\nno tree") == null);

    const tag_text = "object 2402fc2a7f25ec4ef15e4e2c9b1b75bffe4b1afd\ntype commit\ntag v1\ntagger Test Author <test@example.org> 1761403600 +0100\n\nthe first tag\n";
    try testing.expectEqual(id("6c6d6d6ca9d196896bf1b659bb669f34a661fc55"), object.idOfObject(rig.cb, .tag, tag_text));
    const tag = object.parseTag(tag_text).?;
    try testing.expectEqual(id("2402fc2a7f25ec4ef15e4e2c9b1b75bffe4b1afd"), tag.object);
    try testing.expectEqual(object.Type.commit, tag.kind);
    try testing.expectEqualStrings("v1", tag.name);
    try testing.expectEqualStrings("the first tag\n", tag.message);

    // The root tree of the third commit, taken apart and put together.
    const entries = [_]struct { mode: u32, name: []const u8, id: []const u8 }{
        .{ .mode = object.mode_file, .name = "README.md", .id = "26e2285260bbd6af3d90d3ab44e86b07f94afd7b" },
        .{ .mode = object.mode_link, .name = "link", .id = "1ca9282cde00c6b6bb3f7b9f0b3e7deb25aea389" },
        .{ .mode = object.mode_executable, .name = "run.sh", .id = "4163036efa65bd4a469e752267498f01ea36a55c" },
        .{ .mode = object.mode_tree, .name = "src", .id = "ade1217c35c63b6e2d8fa1b7ec1e261816cb0cff" },
        .{ .mode = object.mode_file, .name = "story.txt", .id = "62c9c9efdbc9e1c0c7d1bc39fa52880911e4c4b9" },
    };
    var tree_bytes: [256]u8 = undefined;
    var out: _git.Out = .{ .into = &tree_bytes };
    for (entries) |entry| object.putTreeEntry(&out, entry.mode, entry.name, &_git.idOf(entry.id).?);
    try testing.expectEqual(id("9ff1f2e13a25093afd701961624229b5925787e1"), object.idOfObject(rig.cb, .tree, out.written()));
    var walk: object.TreeEntries = .{ .body = out.written() };
    for (entries) |entry| {
        const got = walk.next().?;
        try testing.expectEqual(entry.mode, got.mode);
        try testing.expectEqualStrings(entry.name, got.name);
        try testing.expectEqual(_git.idOf(entry.id).?, got.id);
    }
    try testing.expect(walk.next() == null);
    try testing.expect(!walk.bad);
    var broken: object.TreeEntries = .{ .body = out.written()[0..40] };
    _ = broken.next();
    try testing.expect(broken.next() == null);
    try testing.expect(broken.bad);
    try rig.deinit();
}

// --- packs and their indexes ----------------------------------------------------

/// What a pack's walk found of each entry.
const Walked = struct {
    offset: u64,
    end: u64,
    kind: object.Type = .blob,
    id: Id = _git.zero_id,
    body: []u8 = &.{},
    resolved: bool = false,
    /// For a delta not resolved yet: its instructions, and its base.
    delta: []u8 = &.{},
    base_offset: u64 = 0,
    base_id: ?Id = null,
};

var bodies: [64 * 1024]u8 = undefined;

/// Every entry of `bytes`, inflated, its deltas resolved, its id worked
/// out, into `walked`.
fn walkPack(rig: *Rig, bytes: []const u8, walked: []Walked) !usize {
    const count = pack.parseHeader(bytes).?;
    try testing.expect(count <= walked.len);
    const end = bytes.len - pack.trailer_bytes;
    try testing.expectEqual(_git.sha1Of(rig.cb, bytes[0..end]), bytes[end..][0..20].*);
    var used: usize = 0;
    var at: usize = pack.header_bytes;
    for (walked[0..count]) |*entry| {
        const head = switch (pack.parseEntryHead(bytes[at..end])) {
            .head => |head| head,
            .err => return error.BadEntry,
        };
        const size: usize = @intCast(head.size);
        const into = bodies[used..][0..size];
        used += size;
        const took = try rig.inflate(bytes[at + head.length .. end], into);
        entry.* = .{ .offset = at, .end = at + head.length + took };
        switch (head.kind) {
            .ofs_delta => {
                entry.delta = into;
                entry.base_offset = at - head.base_distance;
            },
            .ref_delta => {
                entry.delta = into;
                entry.base_id = head.base_id;
            },
            else => {
                entry.kind = head.kind;
                entry.body = into;
                entry.id = object.idOfObject(rig.cb, head.kind, into);
                entry.resolved = true;
            },
        }
        at = @intCast(entry.end);
    }
    try testing.expectEqual(end, at);

    // Deltas whose bases are resolved, until none is left.
    var left = true;
    while (left) {
        left = false;
        var progress = false;
        for (walked[0..count]) |*entry| {
            if (entry.resolved) continue;
            const base = for (walked[0..count]) |*other| {
                if (!other.resolved) continue;
                if (entry.base_id) |base_id| {
                    if (_git.same(&other.id, &base_id)) break other;
                } else if (other.offset == entry.base_offset) break other;
            } else {
                left = true;
                continue;
            };
            const sizes = pack.deltaSizes(entry.delta).?;
            const into = bodies[used..][0..@intCast(sizes.result)];
            used += into.len;
            try testing.expect(pack.applyDelta(base.body, entry.delta, into));
            entry.kind = base.kind;
            entry.body = into;
            entry.id = object.idOfObject(rig.cb, base.kind, into);
            entry.resolved = true;
            progress = true;
        }
        if (left and !progress) return error.UnresolvedDelta;
    }
    return count;
}

var walked_store: [32]Walked = undefined;
var idx_out: [4096]u8 = undefined;

test "both packs: every object with git's id, deltas of either kind resolved" {
    var rig = try Rig.init();
    for ([_][]const u8{ ofs_pack, ref_pack }, [_][]const u8{ ofs_idx, ref_idx }, [_]object.Type{ .ofs_delta, .ref_delta }) |bytes, index_bytes, delta_kind| {
        // The fixture packs hold deltas of the kind they are named for.
        var deltas: usize = 0;
        const count = try walkPack(&rig, bytes, &walked_store);
        try testing.expectEqual(objects.len, count);
        for (walked_store[0..count]) |entry| {
            const head = pack.parseEntryHead(bytes[@intCast(entry.offset)..]).head;
            if (head.kind == delta_kind) deltas += 1;
            try testing.expect(head.kind == delta_kind or @intFromEnum(head.kind) < 5);
        }
        try testing.expectEqual(@as(usize, 3), deltas);
        for (objects) |expected| {
            const found = for (walked_store[0..count]) |entry| {
                if (_git.same(&entry.id, &_git.idOf(expected.id).?)) break entry;
            } else return error.Missing;
            try testing.expectEqual(expected.kind, found.kind);
            try testing.expectEqual(expected.size, found.body.len);
        }

        // git's index: every id found where the walk found it, with the
        // CRC-32 of its entry as the pack holds it.
        const read = idx.Idx.open(index_bytes).?;
        try testing.expect(read.verify(rig.cb));
        try testing.expectEqual(@as(u32, objects.len), read.count);
        try testing.expectEqual(bytes[bytes.len - 20 ..][0..20].*, read.packChecksum().*);
        var entries: [objects.len]idx.Entry = undefined;
        for (walked_store[0..count], 0..) |entry, at| {
            const position = read.find(&entry.id).?;
            try testing.expectEqual(entry.offset, read.offsetAt(position).?);
            const raw = bytes[@intCast(entry.offset)..@intCast(entry.end)];
            const crc = rig.zb.Crc32(0, raw.ptr, @intCast(raw.len));
            try testing.expectEqual(crc, read.crcAt(position));
            entries[at] = .{ .id = entry.id, .crc = crc, .offset = entry.offset };
        }
        try testing.expect(read.find(&id("0000000000000000000000000000000000000001")) == null);
        try testing.expect(read.find(&id("ffffffffffffffffffffffffffffffffffffffff")) == null);

        // The same index written here, byte for byte.
        idx.sort(&entries);
        var buffer: BufferSink = .{ .out = .{ .into = &idx_out } };
        try testing.expect(idx.write(rig.cb, &entries, read.packChecksum(), buffer.sink()));
        try testing.expectEqualSlices(u8, index_bytes, buffer.out.written());
    }
    try rig.deinit();
}

test "an index with offsets past 2 GiB, and entries sorted" {
    var rig = try Rig.init();
    var entries: [300]idx.Entry = undefined;
    var seed: u32 = 99;
    for (&entries, 0..) |*entry, at| {
        for (&entry.id) |*byte| {
            seed = seed *% 1103515245 +% 12345;
            byte.* = @truncate(seed >> 16);
        }
        entry.crc = @intCast(at);
        entry.offset = if (at % 3 == 0) 0x1_0000_0000 + at else at * 100;
    }
    idx.sort(&entries);
    for (entries[1..], 0..) |entry, at| try testing.expect(_git.order(&entries[at].id, &entry.id) == .less);
    var buffer: BufferSink = .{ .out = .{ .into = &large_out } };
    try testing.expect(idx.write(rig.cb, &entries, &id("9ff1f2e13a25093afd701961624229b5925787e1"), buffer.sink()));
    try testing.expectEqual(idx.size(300, 100), buffer.out.at);
    const read = idx.Idx.open(buffer.out.written()).?;
    try testing.expect(read.verify(rig.cb));
    try testing.expectEqual(@as(usize, 100), read.large_count);
    for (entries) |entry| {
        const position = read.find(&entry.id).?;
        try testing.expectEqual(entry.offset, read.offsetAt(position).?);
        try testing.expectEqual(entry.crc, read.crcAt(position));
    }
    try testing.expect(idx.Idx.open(buffer.out.written()[0..1000]) == null);
    try rig.deinit();
}

var large_out: [16 * 1024]u8 = undefined;

test "entry heads and OFS distances, written and read; deltas applied and refused" {
    for ([_]u64{ 0, 1, 15, 16, 127, 128, 1000, 65536, 1 << 35, (1 << 60) - 1 }) |size| {
        var head: [10]u8 = undefined;
        const written = pack.putEntryHead(&head, .blob, size);
        const read = pack.parseEntryHead(written).head;
        try testing.expectEqual(object.Type.blob, read.kind);
        try testing.expectEqual(size, read.size);
        try testing.expectEqual(written.len, read.length);
        try testing.expectEqual(pack.HeadError.short, pack.parseEntryHead(written[0 .. written.len - 1]).err);
    }
    try testing.expectEqual(pack.HeadError.bad, pack.parseEntryHead(&.{0x50}).err);
    // git's way of writing a distance: each byte before the last stands
    // for one more than it says.
    for ([_]u64{ 1, 127, 128, 129, 16511, 16512, 1 << 20, 123456789 }) |distance| {
        var bytes: [16]u8 = undefined;
        var at: usize = bytes.len - 1;
        var rest = distance;
        bytes[at] = @truncate(rest & 0x7F);
        rest >>= 7;
        while (rest != 0) {
            rest -= 1;
            at -= 1;
            bytes[at] = 0x80 | @as(u8, @truncate(rest & 0x7F));
            rest >>= 7;
        }
        var entry: [20]u8 = undefined;
        entry[0] = 0x60 | 5;
        const length = bytes.len - at;
        @memcpy(entry[1..][0..length], bytes[at..]);
        const read = pack.parseEntryHead(entry[0 .. 1 + length]).head;
        try testing.expectEqual(object.Type.ofs_delta, read.kind);
        try testing.expectEqual(distance, read.base_distance);
    }

    const base = "hello, wide world";
    // From 17 bytes to 15: "hello" copied, " big" inserted, " world"
    // copied.
    const delta = [_]u8{ 17, 15, 0x90 | 0x01, 0, 5, 4, ' ', 'b', 'i', 'g', 0x91, 11, 6 };
    var into: [15]u8 = undefined;
    try testing.expect(pack.applyDelta(base, &delta, &into));
    try testing.expectEqualStrings("hello big world", &into);
    var wrong: [14]u8 = undefined;
    try testing.expect(!pack.applyDelta(base, &delta, &wrong));
    try testing.expect(!pack.applyDelta(base[0..16], &delta, &into));
    // A copy past the base, a reserved 0, and instructions cut short.
    try testing.expect(!pack.applyDelta(base, &[_]u8{ 17, 5, 0x91, 14, 5 }, into[0..5]));
    try testing.expect(!pack.applyDelta(base, &[_]u8{ 17, 1, 0 }, into[0..1]));
    try testing.expect(!pack.applyDelta(base, &[_]u8{ 17, 5, 5, 'a' }, into[0..5]));
    // A copy of size 0 is 65536 bytes.
    var big_base: [70000]u8 = undefined;
    for (&big_base, 0..) |*byte, at| byte.* = @truncate(at);
    var big: [65536]u8 = undefined;
    try testing.expect(pack.applyDelta(&big_base, &[_]u8{ 0xF0, 0xA2, 0x04, 0x80, 0x80, 0x04, 0x80 }, &big));
    try testing.expectEqualSlices(u8, big_base[0..65536], &big);
}

// --- the index file -------------------------------------------------------------

var index_out: [1024]u8 = undefined;

test "the index: git's read, with its extension passed over, and written again" {
    var rig = try Rig.init();
    const read = index.Index.open(index_file).?;
    try testing.expect(read.verify(rig.cb));
    try testing.expectEqual(@as(u32, 2), read.version);
    try testing.expectEqual(@as(u32, 6), read.count);
    const expected = [_]struct { mode: u32, path: []const u8, id: []const u8, size: u32 }{
        .{ .mode = 0o100644, .path = "README.md", .id = "26e2285260bbd6af3d90d3ab44e86b07f94afd7b", .size = 57 },
        .{ .mode = 0o120000, .path = "link", .id = "1ca9282cde00c6b6bb3f7b9f0b3e7deb25aea389", .size = 9 },
        .{ .mode = 0o100755, .path = "run.sh", .id = "4163036efa65bd4a469e752267498f01ea36a55c", .size = 18 },
        .{ .mode = 0o100644, .path = "src/deep/notes.txt", .id = "a8190125a65d3e197c0fcd0deededa487d15509c", .size = 32 },
        .{ .mode = 0o100644, .path = "src/main.zig", .id = "cd41d0d330a3b983243892c5188d77126dfc02b8", .size = 47 },
        .{ .mode = 0o100644, .path = "story.txt", .id = "62c9c9efdbc9e1c0c7d1bc39fa52880911e4c4b9", .size = 3170 },
    };
    var entries: [6]index.Entry = undefined;
    var walk = read.entries();
    for (expected, 0..) |want, at| {
        const got = walk.next().?;
        try testing.expectEqual(want.mode, got.mode);
        try testing.expectEqualStrings(want.path, got.path);
        try testing.expectEqual(_git.idOf(want.id).?, got.id);
        try testing.expectEqual(want.size, got.size);
        try testing.expectEqual(@as(u2, 0), got.stage);
        entries[at] = got;
    }
    try testing.expect(walk.next() == null);
    try testing.expect(!walk.bad);
    for (entries[1..], 0..) |entry, at| try testing.expect(index.before(&entries[at], &entry));
    // What follows the entries is git's TREE extension.
    try testing.expectEqualStrings("TREE", index_file[walk.at..][0..4]);

    // Written here: the same entries byte for byte, no extension, its
    // own checksum.
    var buffer: BufferSink = .{ .out = .{ .into = &index_out } };
    var writer = index.Writer.start(rig.cb, buffer.sink(), 6, false);
    for (&entries) |*entry| writer.entry(entry);
    try testing.expect(writer.finish());
    const written = buffer.out.written();
    try testing.expectEqualSlices(u8, index_file[0..walk.at], written[0..walk.at]);
    try testing.expectEqual(walk.at + 20, written.len);
    const again = index.Index.open(written).?;
    try testing.expect(again.verify(rig.cb));

    // One entry skip-worktree: version 3, read back as it was written.
    var marked = entries;
    marked[2].skip_worktree = true;
    var extended_buffer: BufferSink = .{ .out = .{ .into = &index_out } };
    var extended_writer = index.Writer.start(rig.cb, extended_buffer.sink(), 6, true);
    for (&marked) |*entry| extended_writer.entry(entry);
    try testing.expect(extended_writer.finish());
    const version3 = index.Index.open(extended_buffer.out.written()).?;
    try testing.expectEqual(@as(u32, 3), version3.version);
    try testing.expect(version3.verify(rig.cb));
    var walk3 = version3.entries();
    for (&marked) |*want| {
        const got = walk3.next().?;
        try testing.expectEqualStrings(want.path, got.path);
        try testing.expectEqual(want.skip_worktree, got.skip_worktree);
        try testing.expectEqual(want.id, got.id);
    }
    try testing.expect(walk3.next() == null and !walk3.bad);

    try testing.expect(index.Index.open(index_file[0..20]) == null);
    var version4 = index_file.*;
    version4[7] = 4;
    try testing.expect(index.Index.open(&version4) == null);
    try rig.deinit();
}

test "names: UTF-8 made Latin-1 where it fits, and back; a server's text made Latin-1 in pieces" {
    var local: [64]u8 = undefined;
    var back: [64]u8 = undefined;
    try testing.expectEqualStrings("gr\xFC\xDFe.txt", files.localName(&local, "grüße.txt").?);
    try testing.expectEqualStrings("grüße.txt", files.gitName(&back, "gr\xFC\xDFe.txt").?);
    // Beyond Latin-1: the bytes kept, both ways.
    try testing.expectEqualStrings("日本語.txt", files.localName(&local, "日本語.txt").?);
    try testing.expectEqualStrings("日本語.txt", files.gitName(&back, "日本語.txt").?);

    const text = "Objekte aufzählen: 3 € 日\n";
    for ([_]usize{ 1, 2, 3, text.len }) |piece| {
        var latin: files.Latin1 = .{};
        var out: [64]u8 = undefined;
        var length: usize = 0;
        var at: usize = 0;
        while (at < text.len) : (at += piece) {
            for (text[at..@min(at + piece, text.len)]) |byte| {
                if (latin.take(byte)) |char| {
                    out[length] = char;
                    length += 1;
                }
            }
        }
        try testing.expectEqualStrings("Objekte aufz\xE4hlen: 3 ? ?\n", out[0..length]);
    }
}

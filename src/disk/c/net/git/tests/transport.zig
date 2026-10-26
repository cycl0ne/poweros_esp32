// SPDX-License-Identifier: MIT
//! Host tests of the transport against what the host's `git
//! http-backend` answered (fixtures/http-*): the advertisement in both
//! versions, `ls-refs`, a fetch with and without a depth. A scripted link
//! hands each answer out in pieces of a chosen size and keeps the
//! request it was sent, which must be the request expected byte for
//! byte. The pack the version 2 fetch brings is the one in
//! fixtures/ofs.pack: the server packed the same repository the same way.
//! A push is answered as the host's `git receive-pack` answers: its
//! advertisement's capabilities are the ones it gave.

const std = @import("std");
const rig_file = @import("rig.zig");
const Rig = rig_file.Rig;
const BufferSink = rig_file.BufferSink;
const _git = @import("../_git.zig");
const transport = @import("../transport.zig");
const receive = @import("../receive.zig");
const url = @import("../url.zig");
const Id = _git.Id;

const testing = std.testing;

const v2_caps = @embedFile("fixtures/http-v2-caps");
const v2_ls_refs = @embedFile("fixtures/http-v2-ls-refs");
const v2_fetch = @embedFile("fixtures/http-v2-fetch");
const v2_fetch_deepen = @embedFile("fixtures/http-v2-fetch-deepen");
const v0_refs = @embedFile("fixtures/http-v0-refs");
const v0_fetch = @embedFile("fixtures/http-v0-fetch");
const v0_fetch_deepen = @embedFile("fixtures/http-v0-fetch-deepen");
const ofs_pack = @embedFile("fixtures/ofs.pack");

const head_id = "3dd183b58d469e7d140b1761fbe082e208739533";
const agent_line = "agent=" ++ transport.agent ++ "\n";

/// `text` as one pkt-line.
fn pkt(comptime text: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    const length = text.len + 4;
    return &[4]u8{ digits[length >> 12], digits[length >> 8 & 15], digits[length >> 4 & 15], digits[length & 15] } ++ text;
}

fn id(comptime text: []const u8) Id {
    return _git.idOf(text).?;
}

/// A link that answers from a script: the first answer is the
/// advertisement, each exchange moves to the next.
const Script = struct {
    answers: []const []const u8,
    piece: usize,
    answer: usize = 0,
    at: usize = 0,
    /// The last request sent, and the version it went in.
    request: [1024]u8 = undefined,
    request_length: usize = 0,
    version: u8 = 0,
    exchanges: usize = 0,
    /// A request sent in pieces: the length it was begun with.
    begun: u64 = 0,

    fn exchange(context: *anyopaque, body: []const u8, version: u8) bool {
        const script: *Script = @ptrCast(@alignCast(context));
        @memcpy(script.request[0..body.len], body);
        script.request_length = body.len;
        script.version = version;
        script.exchanges += 1;
        script.answer += 1;
        script.at = 0;
        return script.answer < script.answers.len;
    }

    fn read(context: *anyopaque, into: []u8) i32 {
        const script: *Script = @ptrCast(@alignCast(context));
        const answer = script.answers[script.answer];
        const count = @min(into.len, script.piece, answer.len - script.at);
        @memcpy(into[0..count], answer[script.at..][0..count]);
        script.at += count;
        return @intCast(count);
    }

    fn begin(context: *anyopaque, length: u64, version: u8) bool {
        const script: *Script = @ptrCast(@alignCast(context));
        script.request_length = 0;
        script.version = version;
        script.begun = length;
        return true;
    }

    fn write(context: *anyopaque, bytes: []const u8) bool {
        const script: *Script = @ptrCast(@alignCast(context));
        @memcpy(script.request[script.request_length..][0..bytes.len], bytes);
        script.request_length += bytes.len;
        return true;
    }

    /// The pieces must have come to the length begun with.
    fn end(context: *anyopaque) bool {
        const script: *Script = @ptrCast(@alignCast(context));
        script.exchanges += 1;
        script.answer += 1;
        script.at = 0;
        return script.request_length == script.begun and script.answer < script.answers.len;
    }

    fn link(script: *Script) transport.Link {
        return .{ .context = script, .exchange = exchange, .read = read, .begin = begin, .write = write, .end = end };
    }

    fn sent(script: *const Script) []const u8 {
        return script.request[0..script.request_length];
    }
};

var remote_store: transport.Remote = undefined;

/// The refs a listing handed over, their names copied.
const Listed = struct {
    count: usize = 0,
    ids: [8]Id = undefined,
    names: [8][64]u8 = undefined,
    name_lengths: [8]usize = undefined,
    peeled: [8]?Id = undefined,
    target_text: [8][64]u8 = undefined,
    targets: [8]?[]const u8 = undefined,
    unborn: [8]bool = undefined,

    fn take(context: *anyopaque, ref: *const transport.Ref) bool {
        const listed: *Listed = @ptrCast(@alignCast(context));
        const at = listed.count;
        listed.ids[at] = ref.id;
        @memcpy(listed.names[at][0..ref.name.len], ref.name);
        listed.name_lengths[at] = ref.name.len;
        listed.peeled[at] = ref.peeled;
        listed.targets[at] = null;
        if (ref.target) |target| {
            @memcpy(listed.target_text[at][0..target.len], target);
            listed.targets[at] = listed.target_text[at][0..target.len];
        }
        listed.unborn[at] = ref.unborn;
        listed.count += 1;
        return true;
    }

    fn name(listed: *const Listed, at: usize) []const u8 {
        return listed.names[at][0..listed.name_lengths[at]];
    }

    /// HEAD on main, main, and the tag v1 peeled to the second commit.
    fn expectFixture(listed: *const Listed) !void {
        try testing.expectEqual(@as(usize, 3), listed.count);
        try testing.expectEqualStrings("HEAD", listed.name(0));
        try testing.expectEqual(id(head_id), listed.ids[0]);
        try testing.expectEqualStrings("refs/heads/main", listed.targets[0].?);
        try testing.expectEqualStrings("refs/heads/main", listed.name(1));
        try testing.expectEqual(id(head_id), listed.ids[1]);
        try testing.expect(listed.targets[1] == null);
        try testing.expectEqualStrings("refs/tags/v1", listed.name(2));
        try testing.expectEqual(id("6c6d6d6ca9d196896bf1b659bb669f34a661fc55"), listed.ids[2]);
        try testing.expectEqual(id("2402fc2a7f25ec4ef15e4e2c9b1b75bffe4b1afd"), listed.peeled[2].?);
    }
};

/// What the server said while the pack came.
const Heard = struct {
    text: [2048]u8 = undefined,
    length: usize = 0,
    received: u64 = 0,
    boundary: [4]Id = undefined,
    boundary_shallow: [4]bool = undefined,
    boundary_count: usize = 0,

    fn onText(context: *anyopaque, text: []const u8) bool {
        const heard: *Heard = @ptrCast(@alignCast(context));
        @memcpy(heard.text[heard.length..][0..text.len], text);
        heard.length += text.len;
        return true;
    }

    fn onReceived(context: *anyopaque, bytes: u64) bool {
        const heard: *Heard = @ptrCast(@alignCast(context));
        heard.received = bytes;
        return true;
    }

    fn onBoundary(context: *anyopaque, boundary_id: *const Id, shallow: bool) bool {
        const heard: *Heard = @ptrCast(@alignCast(context));
        heard.boundary[heard.boundary_count] = boundary_id.*;
        heard.boundary_shallow[heard.boundary_count] = shallow;
        heard.boundary_count += 1;
        return true;
    }

    fn listener(heard: *Heard) transport.Listener {
        return .{ .context = heard, .text = onText, .received = onReceived };
    }

    fn has(heard: *const Heard, wanted: []const u8) bool {
        return std.mem.indexOf(u8, heard.text[0..heard.length], wanted) != null;
    }
};

var pack_out: [8192]u8 = undefined;

test "version 2: the advertisement, ls-refs and a fetch, read in pieces of every size" {
    var rig = try Rig.init();
    for ([_]usize{ 1, 3, 64, 600, 100000 }) |piece| {
        var script: Script = .{ .answers = &.{ v2_caps, v2_ls_refs, v2_fetch }, .piece = piece };
        const remote = &remote_store;
        remote.init(script.link(), rig.cb);
        try testing.expect(remote.start());
        try testing.expectEqual(@as(u8, 2), remote.version);
        try testing.expectEqualStrings("shallow wait-for-done", remote.capability("fetch").?);
        try testing.expectEqualStrings("", remote.capability("server-option").?);
        try testing.expect(remote.feature("fetch", "shallow"));
        try testing.expect(!remote.feature("fetch", "filter"));
        try testing.expect(remote.feature("ls-refs", "unborn"));
        try testing.expect(remote.capability("ls-ref") == null);

        var listed: Listed = .{};
        try testing.expect(remote.listRefs(&.{ "HEAD", "refs/heads/", "refs/tags/" }, Listed.take, &listed));
        try testing.expectEqualStrings(comptime pkt("command=ls-refs\n") ++ pkt(agent_line) ++ pkt("object-format=sha1\n") ++ "0001" ++
            pkt("peel\n") ++ pkt("symrefs\n") ++ pkt("unborn\n") ++
            pkt("ref-prefix HEAD\n") ++ pkt("ref-prefix refs/heads/\n") ++ pkt("ref-prefix refs/tags/\n") ++ "0000", script.sent());
        try testing.expectEqual(@as(u8, 2), script.version);
        try listed.expectFixture();

        var heard: Heard = .{};
        remote.listener = heard.listener();
        var buffer: BufferSink = .{ .out = .{ .into = &pack_out } };
        const received = remote.fetch(&.{ .wants = &.{id(head_id)} }, buffer.sink()).?;
        try testing.expectEqualStrings(comptime pkt("command=fetch\n") ++ pkt(agent_line) ++ pkt("object-format=sha1\n") ++ "0001" ++
            pkt("ofs-delta\n") ++ pkt("include-tag\n") ++ pkt("want " ++ head_id ++ "\n") ++ pkt("done\n") ++ "0000", script.sent());
        try testing.expectEqual(@as(u32, 20), received.count);
        try testing.expectEqual(@as(u64, ofs_pack.len), received.bytes);
        try testing.expectEqualSlices(u8, ofs_pack, buffer.out.written());
        try testing.expectEqual(ofs_pack[ofs_pack.len - 20 ..][0..20].*, received.checksum);
        try testing.expectEqual(@as(u64, ofs_pack.len), heard.received);
        try testing.expect(heard.has("Enumerating objects: 20, done.\n"));
        try testing.expect(heard.has("Total 20 (delta 3)"));
    }
    try rig.deinit();
}

test "version 2: a fetch with a depth hears where history is cut" {
    var rig = try Rig.init();
    var script: Script = .{ .answers = &.{ v2_caps, v2_fetch_deepen }, .piece = 50 };
    const remote = &remote_store;
    remote.init(script.link(), rig.cb);
    try testing.expect(remote.start());
    var heard: Heard = .{};
    var buffer: BufferSink = .{ .out = .{ .into = &pack_out } };
    const received = remote.fetch(&.{
        .wants = &.{id(head_id)},
        .depth = 1,
        .include_tags = false,
        .quiet = true,
        .boundary = Heard.onBoundary,
        .boundary_context = &heard,
    }, buffer.sink()).?;
    try testing.expectEqualStrings(comptime pkt("command=fetch\n") ++ pkt(agent_line) ++ pkt("object-format=sha1\n") ++ "0001" ++
        pkt("no-progress\n") ++ pkt("ofs-delta\n") ++ pkt("deepen 1\n") ++ pkt("want " ++ head_id ++ "\n") ++ pkt("done\n") ++ "0000", script.sent());
    try testing.expectEqual(@as(u32, 10), received.count);
    try testing.expectEqual(@as(usize, 1), heard.boundary_count);
    try testing.expectEqual(id(head_id), heard.boundary[0]);
    try testing.expect(heard.boundary_shallow[0]);
    try rig.deinit();
}

test "version 0: the refs advertised, HEAD's target from the capabilities, a fetch" {
    var rig = try Rig.init();
    for ([_]usize{ 1, 7, 100000 }) |piece| {
        var script: Script = .{ .answers = &.{ v0_refs, v0_fetch }, .piece = piece };
        const remote = &remote_store;
        remote.init(script.link(), rig.cb);
        try testing.expect(remote.start());
        try testing.expectEqual(@as(u8, 0), remote.version);
        try testing.expect(remote.capability("side-band-64k") != null);
        try testing.expect(remote.capability("side-band") != null);
        try testing.expectEqualStrings("sha1", remote.capability("object-format").?);
        var listed: Listed = .{};
        try testing.expect(remote.listRefs(&.{}, Listed.take, &listed));
        try listed.expectFixture();

        var heard: Heard = .{};
        remote.listener = heard.listener();
        var buffer: BufferSink = .{ .out = .{ .into = &pack_out } };
        const received = remote.fetch(&.{ .wants = &.{id(head_id)} }, buffer.sink()).?;
        try testing.expectEqualStrings(comptime pkt("want " ++ head_id ++ " multi_ack_detailed side-band-64k ofs-delta include-tag " ++ agent_line[0 .. agent_line.len - 1] ++ " object-format=sha1\n") ++
            "0000" ++ pkt("done\n"), script.sent());
        try testing.expectEqual(@as(u8, 0), script.version);
        try testing.expectEqual(@as(u32, 20), received.count);
        try testing.expectEqualSlices(u8, ofs_pack, buffer.out.written());
        try testing.expect(heard.has("Total 20 (delta 3)"));
    }
    try rig.deinit();
}

test "version 0: a prefix leaves refs out, and a depth is cut where the server says" {
    var rig = try Rig.init();
    var script: Script = .{ .answers = &.{ v0_refs, v0_fetch_deepen }, .piece = 13 };
    const remote = &remote_store;
    remote.init(script.link(), rig.cb);
    try testing.expect(remote.start());
    var listed: Listed = .{};
    try testing.expect(remote.listRefs(&.{"refs/tags/"}, Listed.take, &listed));
    try testing.expectEqual(@as(usize, 1), listed.count);
    try testing.expectEqualStrings("refs/tags/v1", listed.name(0));
    try testing.expect(listed.peeled[0] != null);

    var heard: Heard = .{};
    var buffer: BufferSink = .{ .out = .{ .into = &pack_out } };
    const received = remote.fetch(&.{
        .wants = &.{id(head_id)},
        .depth = 1,
        .include_tags = false,
        .boundary = Heard.onBoundary,
        .boundary_context = &heard,
    }, buffer.sink()).?;
    try testing.expectEqualStrings(comptime pkt("want " ++ head_id ++ " multi_ack_detailed side-band-64k ofs-delta shallow " ++ agent_line[0 .. agent_line.len - 1] ++ " object-format=sha1\n") ++
        pkt("deepen 1\n") ++ "0000" ++ pkt("done\n"), script.sent());
    try testing.expectEqual(@as(u32, 10), received.count);
    try testing.expectEqual(@as(usize, 1), heard.boundary_count);
    try testing.expectEqual(id(head_id), heard.boundary[0]);
    try rig.deinit();
}

test "version 0: a shallow repository's cut named, without a depth, gets no boundary back" {
    var rig = try Rig.init();
    var script: Script = .{ .answers = &.{ v0_refs, v0_fetch }, .piece = 11 };
    const remote = &remote_store;
    remote.init(script.link(), rig.cb);
    try testing.expect(remote.start());
    var heard: Heard = .{};
    var buffer: BufferSink = .{ .out = .{ .into = &pack_out } };
    const received = remote.fetch(&.{
        .wants = &.{id(head_id)},
        .shallow = &.{id(head_id)},
        .include_tags = false,
        .boundary = Heard.onBoundary,
        .boundary_context = &heard,
    }, buffer.sink()).?;
    try testing.expectEqualStrings(comptime pkt("want " ++ head_id ++ " multi_ack_detailed side-band-64k ofs-delta shallow " ++ agent_line[0 .. agent_line.len - 1] ++ " object-format=sha1\n") ++
        pkt("shallow " ++ head_id ++ "\n") ++ "0000" ++ pkt("done\n"), script.sent());
    try testing.expectEqual(@as(u32, 20), received.count);
    try testing.expectEqual(@as(usize, 0), heard.boundary_count);
    try rig.deinit();
}

test "advertisements: a service line before version 2, an empty repository, a server's ERR" {
    var rig = try Rig.init();
    const remote = &remote_store;

    // As GitHub answers.
    const github = comptime pkt("# service=git-upload-pack\n") ++ "0000" ++ pkt("version 2\n") ++ pkt("agent=git/github\n") ++
        pkt("ls-refs=unborn\n") ++ pkt("fetch=shallow wait-for-done filter\n") ++ pkt("server-option\n") ++ pkt("object-format=sha1\n") ++ "0000";
    var script: Script = .{ .answers = &.{github}, .piece = 9 };
    remote.init(script.link(), rig.cb);
    try testing.expect(remote.start());
    try testing.expectEqual(@as(u8, 2), remote.version);
    try testing.expect(remote.feature("fetch", "filter"));

    // An empty repository in version 2: HEAD unborn.
    const unborn = comptime pkt("unborn HEAD symref-target:refs/heads/main\n") ++ "0000";
    script = .{ .answers = &.{ github, unborn }, .piece = 100 };
    remote.init(script.link(), rig.cb);
    try testing.expect(remote.start());
    var listed: Listed = .{};
    try testing.expect(remote.listRefs(&.{"HEAD"}, Listed.take, &listed));
    try testing.expectEqual(@as(usize, 1), listed.count);
    try testing.expect(listed.unborn[0]);
    try testing.expectEqualStrings("refs/heads/main", listed.targets[0].?);

    // An empty repository in version 0: its capabilities on no ref.
    const empty0 = comptime pkt("# service=git-upload-pack\n") ++ "0000" ++
        pkt("0000000000000000000000000000000000000000 capabilities^{}\x00multi_ack side-band-64k object-format=sha1\n") ++ "0000";
    script = .{ .answers = &.{empty0}, .piece = 100 };
    remote.init(script.link(), rig.cb);
    try testing.expect(remote.start());
    listed = .{};
    try testing.expect(remote.listRefs(&.{}, Listed.take, &listed));
    try testing.expectEqual(@as(usize, 0), listed.count);

    // A repository of another object format.
    const sha256 = comptime pkt("version 2\n") ++ pkt("ls-refs\n") ++ pkt("fetch\n") ++ pkt("object-format=sha256\n") ++ "0000";
    script = .{ .answers = &.{sha256}, .piece = 100 };
    remote.init(script.link(), rig.cb);
    try testing.expect(!remote.start());
    try testing.expectEqual(transport.Failure.object_format, remote.failure);

    // The server's own error.
    script = .{ .answers = &.{comptime pkt("ERR access denied or repository not exported\n")}, .piece = 100 };
    remote.init(script.link(), rig.cb);
    try testing.expect(!remote.start());
    try testing.expectEqual(transport.Failure.remote, remote.failure);
    try testing.expectEqualStrings("access denied or repository not exported", std.mem.sliceTo(&remote.message, 0));

    // Cut short, and no protocol at all.
    script = .{ .answers = &.{comptime pkt("version 2\n") ++ pkt("ls-refs\n")}, .piece = 100 };
    remote.init(script.link(), rig.cb);
    try testing.expect(!remote.start());
    try testing.expectEqual(transport.Failure.ended, remote.failure);
    script = .{ .answers = &.{"<html>Not a repository</html>"}, .piece = 100 };
    remote.init(script.link(), rig.cb);
    try testing.expect(!remote.start());
    try testing.expectEqual(transport.Failure.malformed, remote.failure);
    try rig.deinit();
}

test "a fetch whose pack is broken, or whose server fails in band 3" {
    var rig = try Rig.init();
    const remote = &remote_store;
    var buffer: BufferSink = .{ .out = .{ .into = &pack_out } };

    // The pack's last byte changed: its checksum is wrong.
    var broken: [v2_fetch.len]u8 = v2_fetch.*;
    broken[broken.len - 5] ^= 1;
    var script: Script = .{ .answers = &.{ v2_caps, &broken }, .piece = 100 };
    remote.init(script.link(), rig.cb);
    try testing.expect(remote.start());
    try testing.expect(remote.fetch(&.{ .wants = &.{id(head_id)} }, buffer.sink()) == null);
    try testing.expectEqual(transport.Failure.pack, remote.failure);

    const failing = comptime pkt("packfile\n") ++ pkt("\x02Counting objects\n") ++ pkt("\x03upload-pack: not our ref\n") ++ "0000";
    script = .{ .answers = &.{ v2_caps, failing }, .piece = 100 };
    remote.init(script.link(), rig.cb);
    buffer = .{ .out = .{ .into = &pack_out } };
    try testing.expect(remote.start());
    try testing.expect(remote.fetch(&.{ .wants = &.{id(head_id)} }, buffer.sink()) == null);
    try testing.expectEqual(transport.Failure.remote, remote.failure);
    try testing.expectEqualStrings("upload-pack: not our ref", std.mem.sliceTo(&remote.message, 0));

    // A sink that fills up.
    script = .{ .answers = &.{ v2_caps, v2_fetch }, .piece = 100 };
    remote.init(script.link(), rig.cb);
    buffer = .{ .out = .{ .into = pack_out[0..1000] } };
    try testing.expect(remote.start());
    try testing.expect(remote.fetch(&.{ .wants = &.{id(head_id)} }, buffer.sink()) == null);
    try testing.expectEqual(transport.Failure.sink, remote.failure);
    try rig.deinit();
}

test "a pack received in pieces of every size: its count and checksum" {
    var rig = try Rig.init();
    for ([_]usize{ 1, 2, 11, 19, 20, 21, 64, 1916, 1917 }) |piece| {
        var buffer: BufferSink = .{ .out = .{ .into = &pack_out } };
        var receiver = receive.Receiver.start(rig.cb, buffer.sink());
        var at: usize = 0;
        while (at < ofs_pack.len) {
            const count = @min(piece, ofs_pack.len - at);
            try testing.expect(receiver.take(ofs_pack[at..][0..count]));
            at += count;
        }
        const received = receiver.finish().?;
        try testing.expectEqual(@as(u32, 20), received.count);
        try testing.expectEqual(ofs_pack[ofs_pack.len - 20 ..][0..20].*, received.checksum);
    }
    // Cut short of its trailer, and no pack at all.
    var buffer: BufferSink = .{ .out = .{ .into = &pack_out } };
    var receiver = receive.Receiver.start(rig.cb, buffer.sink());
    try testing.expect(receiver.take(ofs_pack[0 .. ofs_pack.len - 1]));
    try testing.expect(receiver.finish() == null);
    receiver = receive.Receiver.start(rig.cb, buffer.sink());
    try testing.expect(!receiver.take("PUCK\x00\x00\x00\x02\x00\x00\x00\x01"));
    try rig.deinit();
}

/// A pack to send, handed out in pieces of `piece` bytes.
const PieceSource = struct {
    bytes: []const u8,
    piece: usize,
    at: usize = 0,

    fn read(context: *anyopaque, into: []u8) i32 {
        const source: *PieceSource = @ptrCast(@alignCast(context));
        const count = @min(into.len, source.piece, source.bytes.len - source.at);
        @memcpy(into[0..count], source.bytes[source.at..][0..count]);
        source.at += count;
        return @intCast(count);
    }

    fn pack(source: *PieceSource) transport.PackSource {
        return .{ .context = source, .length = source.bytes.len, .read = read };
    }
};

const zero_hex = "0000000000000000000000000000000000000000";
const new_hex = "1b913b7cbd5eb76f6e749799f188aec468afde2a";
const receive_caps = "report-status report-status-v2 delete-refs side-band-64k quiet atomic ofs-delta object-format=sha1 agent=git/2.56.0-Linux";

test "push: the refs set, their capabilities asked on the first, the pack in pieces, the report in band 1" {
    var rig = try Rig.init();
    const advertisement = comptime pkt(head_id ++ " refs/heads/main\x00" ++ receive_caps ++ "\n") ++
        pkt("6c6d6d6ca9d196896bf1b659bb669f34a661fc55 refs/tags/v1\n") ++ "0000";
    // The report cut across two band 1 packets, progress between them.
    const report = comptime pkt("unpack ok\n") ++ pkt("ok refs/heads/main\n") ++ pkt("ng refs/heads/topic pre-receive hook declined\n") ++ "0000";
    const answer = comptime pkt("\x02Resolving deltas: 100% (2/2), done.\n") ++ pkt("\x01" ++ report[0..20]) ++
        pkt("\x02remote side says hello\n") ++ pkt("\x01" ++ report[20..]) ++ "0000";
    const pack_bytes = "PACK" ++ "\x00\x00\x00\x02" ++ "\x00\x00\x00\x00" ++ "x" ** 120;
    for ([_]usize{ 1, 5, 100000 }) |piece| {
        var script: Script = .{ .answers = &.{ advertisement, answer }, .piece = piece };
        const remote = &remote_store;
        remote.init(script.link(), rig.cb);
        try testing.expect(remote.start());
        try testing.expectEqual(@as(u8, 0), remote.version);
        var listed: Listed = .{};
        try testing.expect(remote.listRefs(&.{}, Listed.take, &listed));
        try testing.expectEqual(@as(usize, 2), listed.count);
        try testing.expectEqualStrings("refs/heads/main", listed.name(0));

        var heard: Heard = .{};
        remote.listener = heard.listener();
        var updates = [_]transport.Update{
            .{ .name = "refs/heads/main", .old = id(head_id), .new = id(new_hex) },
            .{ .name = "refs/heads/topic", .old = _git.zero_id, .new = id(new_hex) },
        };
        var source: PieceSource = .{ .bytes = pack_bytes, .piece = 7 };
        var request: transport.Push = .{ .updates = &updates, .pack = source.pack(), .quiet = true };
        try testing.expect(remote.push(&request));
        try testing.expectEqualStrings(comptime pkt(head_id ++ " " ++ new_hex ++ " refs/heads/main\x00report-status side-band-64k quiet " ++ agent_line[0 .. agent_line.len - 1] ++ " object-format=sha1\n") ++
            pkt(zero_hex ++ " " ++ new_hex ++ " refs/heads/topic\n") ++ "0000" ++ pack_bytes, script.sent());
        try testing.expectEqual(transport.Update.Status.done, updates[0].status);
        try testing.expectEqual(transport.Update.Status.refused, updates[1].status);
        try testing.expectEqualStrings("pre-receive hook declined", updates[1].reasonText());
        try testing.expect(heard.has("Resolving deltas: 100% (2/2), done.\n"));
        try testing.expect(heard.has("remote side says hello\n"));
    }
    try rig.deinit();
}

test "push: an empty repository, a server without side-band, one that cannot unpack" {
    var rig = try Rig.init();
    const advertisement = comptime pkt(zero_hex ++ " capabilities^{}\x00report-status delete-refs ofs-delta\n") ++ "0000";
    const answer = comptime pkt("unpack index-pack abnormal exit\n") ++ pkt("ng refs/heads/main unpacker error\n") ++ "0000";
    var script: Script = .{ .answers = &.{ advertisement, answer }, .piece = 9 };
    const remote = &remote_store;
    remote.init(script.link(), rig.cb);
    try testing.expect(remote.start());
    var listed: Listed = .{};
    try testing.expect(remote.listRefs(&.{}, Listed.take, &listed));
    try testing.expectEqual(@as(usize, 0), listed.count);
    var updates = [_]transport.Update{.{ .name = "refs/heads/main", .old = _git.zero_id, .new = id(new_hex) }};
    var source: PieceSource = .{ .bytes = "PACK", .piece = 100 };
    var request: transport.Push = .{ .updates = &updates, .pack = source.pack(), .quiet = true };
    try testing.expect(!remote.push(&request));
    try testing.expectEqual(transport.Failure.unpack, remote.failure);
    try testing.expectEqualStrings("index-pack abnormal exit", std.mem.sliceTo(&remote.message, 0));
    try testing.expectEqualStrings(comptime pkt(zero_hex ++ " " ++ new_hex ++ " refs/heads/main\x00report-status\n") ++ "0000PACK", script.sent());
    try rig.deinit();
}

test "URLs: the user and token taken out, the slashes at the end dropped" {
    var remote: url.RemoteUrl = undefined;
    try testing.expect(url.parse("https://github.com/cycl0ne/poweros_esp32/", &remote));
    try testing.expectEqualStrings("https://github.com/cycl0ne/poweros_esp32", remote.text());
    try testing.expectEqualStrings("https://github.com", remote.origin());
    try testing.expect(!remote.has_user);
    try testing.expect(url.parse("http://claus:t%40k%3An@10.0.2.2:8765/repo", &remote));
    try testing.expectEqualStrings("http://10.0.2.2:8765/repo", remote.text());
    try testing.expectEqualStrings("http://10.0.2.2:8765", remote.origin());
    try testing.expectEqualStrings("claus", remote.userText().?);
    try testing.expectEqualStrings("t@k:n", remote.password[0..remote.password_length]);
    try testing.expectEqual(@as(u8, 0), remote.url[remote.url_length]);
    try testing.expect(url.parse("https://user@host", &remote));
    try testing.expect(remote.has_user and !remote.has_password);
    try testing.expectEqualStrings("https://host", remote.text());
    try testing.expect(url.parse("git@github.com:cycl0ne/poweros_esp32.git", &remote));
    try testing.expectEqual(url.Kind.ssh, remote.kind);
    try testing.expectEqualStrings("git", remote.userText().?);
    try testing.expectEqualStrings("github.com", remote.hostText());
    try testing.expectEqualStrings("cycl0ne/poweros_esp32.git", remote.pathText());
    try testing.expectEqual(@as(u16, 0), remote.port);
    try testing.expectEqualStrings("git@github.com:cycl0ne/poweros_esp32.git", remote.text());
    try testing.expect(url.parse("ssh://me@[::1]:2222/srv/git/repo/", &remote));
    try testing.expectEqualStrings("me", remote.userText().?);
    try testing.expectEqualStrings("::1", remote.hostText());
    try testing.expectEqual(@as(u16, 2222), remote.port);
    try testing.expectEqualStrings("/srv/git/repo", remote.pathText());
    try testing.expect(url.parse("ssh://host/~me/repo", &remote));
    try testing.expect(!remote.has_user);
    try testing.expectEqualStrings("~me/repo", remote.pathText());
    for ([_][]const u8{ "ftp://host/x", "https://", "https:///path", "https://u:%4@host/", "ssh://host", "ssh://host:99999/x", "host:", "ssh://:22/x" }) |bad| {
        try testing.expect(!url.parse(bad, &remote));
    }
    var encoded: [64]u8 = undefined;
    var out: _git.Out = .{ .into = &encoded };
    url.encode(&out, "a b@c:d/é");
    try testing.expectEqualStrings("a%20b%40c%3Ad%2F%C3%A9", out.written());
}

// SPDX-License-Identifier: MIT
//! What shares a server has, asked of `srvsvc` - the service every SMB
//! server keeps on the `IPC$` pipe for the questions that are about the
//! server itself rather than about one of its shares.
//!
//! **The question** is the operation `NetrShareEnum`, number 15, at level
//! 1: the answer then holds, for each share, its name, what kind of share
//! it is and the comment the server's own settings give it. Levels above
//! it say more - who may use a share, how many may at once - and a server
//! lets only an administrator ask them; level 1 is the one a guest is
//! answered.
//!
//! **What is asked and what comes back** are written in NDR
//! (`rpc.zig`): the question carries the server's own name, the level, an
//! empty container for the answer to be put in, and no resume handle,
//! since one question is asked and all of it answered. The answer carries
//! the level again, a pointer to the container, how many shares were read,
//! then that many triples of two pointers and a kind, and after them the
//! names and comments the pointers stand for - every one of them a string
//! of UTF-16 characters, in the order the triples name them.
//!
//! The strings are not copied: a `Share` points into the buffer the answer
//! was gathered in, which the caller keeps for as long as it reads them.

const sdk = @import("sdk");
const smb = sdk.dos.smb;
const wire = @import("wire.zig");
const commands = @import("commands.zig");
const session_area = @import("session.zig");
const logon_area = @import("logon.zig");
const rpc = @import("rpc.zig");
const Session = session_area.Session;
const Error = session_area.Error;

/// `srvsvc`, version 3.0: the interface, and the pipe it is reached on.
pub const srvsvc = rpc.Uuid.of(0x4b324fc8, 0x1670, 0x01d3, "\x12\x78\x5a\x47\xbf\x6e\xe1\x88");
pub const srvsvc_version: u32 = 3;
pub const srvsvc_pipe = "srvsvc";

/// `NetrShareEnum` ([MS-SRVS] 3.1.4.8), and the level that names a
/// share, its kind and its comment.
pub const opnum_share_enum: u16 = 15;
pub const level_name_kind_comment: u32 = 1;

/// What a share is for. The kind is the low bits of what the server says;
/// the two flags above them mark the shares the server keeps for itself
/// and those that go when it is restarted.
pub const STYPE_DISKTREE: u32 = 0;
pub const STYPE_PRINTQ: u32 = 1;
pub const STYPE_DEVICE: u32 = 2;
pub const STYPE_IPC: u32 = 3;
pub const STYPE_MASK: u32 = 0x0FFF_FFFF;
pub const STYPE_TEMPORARY: u32 = 0x4000_0000;
pub const STYPE_SPECIAL: u32 = 0x8000_0000;

/// What the operation itself came to, as `NET_API_STATUS`: there were
/// more shares than the answer had room for, which is not an error - what
/// came is what there was room for.
pub const NERR_SUCCESS: u32 = 0;
pub const ERROR_ACCESS_DENIED: u32 = 5;
pub const ERROR_MORE_DATA: u32 = 234;

/// One share the server has. `name` and `comment` are UTF-16LE, pointing
/// into the buffer the answer came in.
pub const Share = struct {
    name: []const u8 = &.{},
    comment: []const u8 = &.{},
    /// What the server said it is, flags and all.
    kind_word: u32 = 0,

    /// What kind of share it is, without the flags.
    pub fn kind(share: *const Share) u32 {
        return share.kind_word & STYPE_MASK;
    }

    /// Whether it holds files, which is the only kind that can be
    /// mounted.
    pub fn isDisk(share: *const Share) bool {
        return share.kind() == STYPE_DISKTREE;
    }

    /// Whether the server keeps it for itself - `IPC$`, `ADMIN$`, a
    /// drive's `C$`. Its name ends in `$`, and it is not offered to be
    /// browsed.
    pub fn isSpecial(share: *const Share) bool {
        return share.kind_word & STYPE_SPECIAL != 0;
    }
};

/// What a listing came to.
pub const Listing = struct {
    /// How many of the caller's `Share`s were filled in.
    count: usize = 0,
    /// How many shares the server says it has, which is more than
    /// `count` when the caller's room ran out.
    total: u32 = 0,
    /// The operation's own answer: NERR_SUCCESS, or why not.
    status: u32 = NERR_SUCCESS,
    /// The share the pipe itself failed at, as an NTSTATUS, or
    /// STATUS_SUCCESS.
    pipe_status: u32 = smb.STATUS_SUCCESS,
    /// Set when the server refused the bind or faulted on the call: it
    /// has no `srvsvc` to ask.
    refused: bool = false,

    pub fn ok(listing: *const Listing) bool {
        return !listing.refused and listing.pipe_status == smb.STATUS_SUCCESS and
            (listing.status == NERR_SUCCESS or listing.status == ERROR_MORE_DATA);
    }
};

/// The room the question needs: the pointer and the three counts in
/// front of the server's name, the name itself in UTF-16 as `\\server`
/// with its NUL, the padding that puts the next number on four bytes,
/// and the seven numbers after it.
pub const question_max: usize = 16 + 2 * (smb.SMB_SERVER_MAX + 3) + 2 + 28;

/// `NetrShareEnum`'s arguments written into `into`: the server's name,
/// the level, an empty container, as much as the server will give, and no
/// resume handle. The bytes of them.
pub fn question(into: []u8, server: []const u8) []u8 {
    var at: usize = 0;
    // The server's name, `\\server`, as a pointer to a string.
    const units = 2 + wire.utf16Length(server) + 1;
    wire.put32(into, at, 0x0002_0000); // it is there
    wire.put32(into, at + 4, @intCast(units)); // the room there is
    wire.put32(into, at + 8, 0); // the characters start at its front
    wire.put32(into, at + 12, @intCast(units)); // and there are this many
    at += 16;
    var name: wire.Writer = .{ .bytes = into[at..] };
    wire.utf16(&name, "\\\\");
    wire.utf16(&name, server);
    name.uint16(0);
    at += name.at;
    at = (at + 3) & ~@as(usize, 3);
    // The level, twice - once as the structure's own field, once as what
    // the container after it is - then the container, empty.
    wire.put32(into, at, level_name_kind_comment);
    wire.put32(into, at + 4, level_name_kind_comment);
    wire.put32(into, at + 8, 0x0002_0004); // the container is there
    wire.put32(into, at + 12, 0); // no shares read into it yet
    wire.put32(into, at + 16, 0); // and nothing for them to go in
    wire.put32(into, at + 20, 0xFFFF_FFFF); // as much as the server gives
    wire.put32(into, at + 24, 0); // no resume handle: all of it at once
    return into[0 .. at + 28];
}

/// `NetrShareEnum`'s answer read into `into`: as many shares as there is
/// room for, and what the operation came to.
pub fn answer(stub: []const u8, into: []Share) Listing {
    var listing: Listing = .{};
    var ndr = rpc.Ndr.of(stub);
    if (ndr.uint32() != level_name_kind_comment) return .{ .refused = true };
    if (ndr.uint32() != level_name_kind_comment) return .{ .refused = true };
    if (ndr.uint32() == 0) return listing; // no container: no shares
    const read = ndr.uint32();
    const buffer_there = ndr.uint32() != 0;
    if (!buffer_there or read == 0) {
        listing.total = read;
        return listing;
    }
    const counted = ndr.uint32(); // the array's room, which is `read`
    if (ndr.short) return .{ .refused = true };
    const sent: usize = @min(read, counted);
    const taken: usize = @min(sent, into.len);

    // Every triple the server sent, the kinds of those taken kept: the
    // strings follow all of them, named in the same order.
    for (0..sent) |index| {
        _ = ndr.uint32(); // that its name is there
        const kind_word = ndr.uint32();
        _ = ndr.uint32(); // and its comment
        if (index < taken) into[index] = .{ .kind_word = kind_word };
    }
    if (ndr.short) return .{ .refused = true };
    for (0..sent) |index| {
        const name = ndr.string();
        const comment = ndr.string();
        if (ndr.short) {
            // What came whole is kept; the rest of the answer is not
            // there to be read.
            listing.count = @min(index, taken);
            listing.total = read;
            return listing;
        }
        if (index < taken) {
            into[index].name = name;
            into[index].comment = comment;
        }
    }
    listing.count = taken;
    listing.total = ndr.uint32();
    if (ndr.uint32() != 0) _ = ndr.uint32(); // the resume handle, unasked
    listing.status = ndr.uint32();
    if (listing.total < read) listing.total = read;
    return listing;
}

/// Every share `server` has, as `srvsvc` says: the `IPC$` tree
/// connected, the pipe opened, the interface bound, the question asked
/// and the pipe closed again. The session is left logged on with no tree.
///
/// INPUTS:
/// - `session` - logged on, with no tree connected.
/// - `server` - the server's name as it was logged on to.
/// - `into` - the shares, as many as there is room for.
/// - `gather` - where the answer is read; the shares' names point into
///   it, so it is the caller's until it has done with them.
pub fn listOf(session: *Session, server: []const u8, into: []Share, gather: []u8) Error!Listing {
    const tree = try logon_area.connectPipes(session, server);
    switch (tree) {
        .security => return .{ .refused = true },
        .status => |status| if (status != smb.STATUS_SUCCESS) return .{ .pipe_status = status },
    }
    defer {
        var replies = session_area.noReplies();
        var request = session.begin(.tree_disconnect);
        request.writer.uint16(4);
        request.writer.uint16(0);
        session.exchange(&request, &replies) catch {};
        session.tree_id = 0;
        session.encrypt_tree = false;
    }

    // The pipe, read and written, opened as it is.
    var open = session.begin(.create);
    var pipe_name: [2 * srvsvc_pipe.len]u8 = undefined;
    for (srvsvc_pipe, 0..) |char, index| wire.put16(&pipe_name, 2 * index, char);
    commands.create(
        &open,
        &pipe_name,
        commands.FILE_READ_DATA | commands.FILE_WRITE_DATA | commands.FILE_READ_ATTRIBUTES,
        0,
        commands.FILE_OPEN,
        0,
    );
    var replies = session_area.noReplies();
    try session.exchange(&open, &replies);
    if (replies[0].failed()) return .{ .pipe_status = replies[0].status() };
    const pipe = commands.created(&replies[0]) orelse return error.Protocol;
    defer {
        var shut = session.begin(.close);
        commands.close(&shut, &pipe.file_id);
        var closing = session_area.noReplies();
        session.exchange(&shut, &closing) catch {};
    }

    // The bind, then the question. Each takes a buffer of its own in
    // front of the gathering one, so that neither is written over what it
    // is still being read from.
    var message: [question_max + rpc.stub_at]u8 = undefined;
    if (!try rpc.bindTo(session, &pipe.file_id, &srvsvc, srvsvc_version, &message, gather)) {
        return .{ .refused = true };
    }
    var stub: [question_max]u8 = undefined;
    const asked = rpc.request(&message, 2, opnum_share_enum, question(&stub, server));
    const got = try rpc.transceive(session, &pipe.file_id, asked, gather);
    if (got.status != smb.STATUS_SUCCESS) return .{ .pipe_status = got.status };
    if (!got.ok()) return .{ .refused = true };
    return answer(got.stub, into);
}

// --- tests (host) ------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// A string as NDR writes it, at `at`: the counts and the characters with
/// their NUL, to the next four-byte boundary. Where it ends.
fn putString(bytes: []u8, at: usize, text: []const u8) usize {
    const units = text.len + 1;
    wire.put32(bytes, at, @intCast(units));
    wire.put32(bytes, at + 4, 0);
    wire.put32(bytes, at + 8, @intCast(units));
    for (text, 0..) |char, index| wire.put16(bytes, at + 12 + 2 * index, char);
    wire.put16(bytes, at + 12 + 2 * text.len, 0);
    return (at + 12 + 2 * units + 3) & ~@as(usize, 3);
}

test "the question names the server and asks for every share at level 1" {
    var buffer: [question_max]u8 = undefined;
    const asked = question(&buffer, "nas");
    // The pointer, then `\\nas` with its NUL: five characters.
    try testing.expectEqual(@as(u32, 0x0002_0000), wire.u32At(asked, 0));
    try testing.expectEqual(@as(u32, 6), wire.u32At(asked, 4));
    try testing.expectEqual(@as(u32, 0), wire.u32At(asked, 8));
    try testing.expectEqual(@as(u32, 6), wire.u32At(asked, 12));
    try testing.expectEqual(@as(u16, '\\'), wire.u16At(asked, 16));
    try testing.expectEqual(@as(u16, 'n'), wire.u16At(asked, 20));
    try testing.expectEqual(@as(u16, 0), wire.u16At(asked, 26));
    // 16 + 12 bytes of string come to a boundary already.
    try testing.expectEqual(@as(u32, 1), wire.u32At(asked, 28));
    try testing.expectEqual(@as(u32, 1), wire.u32At(asked, 32));
    try testing.expect(wire.u32At(asked, 36) != 0);
    try testing.expectEqual(@as(u32, 0), wire.u32At(asked, 40));
    try testing.expectEqual(@as(u32, 0), wire.u32At(asked, 44));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), wire.u32At(asked, 48));
    try testing.expectEqual(@as(u32, 0), wire.u32At(asked, 52));
    try testing.expectEqual(@as(usize, 56), asked.len);
}

test "the answer: three shares, their kinds and their comments" {
    var stub: [256]u8 = @splat(0);
    wire.put32(&stub, 0, 1); // the level
    wire.put32(&stub, 4, 1); // and the container's
    wire.put32(&stub, 8, 0x20000); // the container is there
    wire.put32(&stub, 12, 3); // three shares read
    wire.put32(&stub, 16, 0x20004); // and a buffer holding them
    wire.put32(&stub, 20, 3); // the array's room
    var at: usize = 24;
    for ([_]u32{ STYPE_DISKTREE, STYPE_IPC | STYPE_SPECIAL, STYPE_PRINTQ }) |kind| {
        wire.put32(&stub, at, 0x20008);
        wire.put32(&stub, at + 4, kind);
        wire.put32(&stub, at + 8, 0x2000C);
        at += 12;
    }
    at = putString(&stub, at, "public");
    at = putString(&stub, at, "the files");
    at = putString(&stub, at, "IPC$");
    at = putString(&stub, at, "");
    at = putString(&stub, at, "laser");
    at = putString(&stub, at, "the printer");
    wire.put32(&stub, at, 3); // TotalEntries
    wire.put32(&stub, at + 4, 0); // no resume handle came back
    wire.put32(&stub, at + 8, NERR_SUCCESS);
    at += 12;

    var found: [8]Share = undefined;
    const listing = answer(stub[0..at], &found);
    try testing.expect(listing.ok());
    try testing.expectEqual(@as(usize, 3), listing.count);
    try testing.expectEqual(@as(u32, 3), listing.total);
    try testing.expectEqual(@as(u32, 6 * 2), @as(u32, @intCast(found[0].name.len)));
    try testing.expectEqual(@as(u16, 'p'), wire.u16At(found[0].name, 0));
    try testing.expectEqual(@as(u16, 'c'), wire.u16At(found[0].name, 10));
    try testing.expect(found[0].isDisk());
    try testing.expect(!found[0].isSpecial());
    try testing.expectEqual(@as(u16, 't'), wire.u16At(found[0].comment, 0));
    try testing.expectEqual(STYPE_IPC, found[1].kind());
    try testing.expect(found[1].isSpecial());
    try testing.expectEqual(@as(usize, 0), found[1].comment.len);
    try testing.expectEqual(STYPE_PRINTQ, found[2].kind());
    try testing.expect(!found[2].isDisk());
}

test "the answer: more shares than there is room for, and the count the server gives" {
    var stub: [256]u8 = @splat(0);
    wire.put32(&stub, 0, 1);
    wire.put32(&stub, 4, 1);
    wire.put32(&stub, 8, 0x20000);
    wire.put32(&stub, 12, 2);
    wire.put32(&stub, 16, 0x20004);
    wire.put32(&stub, 20, 2);
    var at: usize = 24;
    for (0..2) |_| {
        wire.put32(&stub, at, 0x20008);
        wire.put32(&stub, at + 4, STYPE_DISKTREE);
        wire.put32(&stub, at + 8, 0x2000C);
        at += 12;
    }
    at = putString(&stub, at, "one");
    at = putString(&stub, at, "");
    at = putString(&stub, at, "two");
    at = putString(&stub, at, "");
    wire.put32(&stub, at, 9); // the server has nine in all
    wire.put32(&stub, at + 4, 0);
    wire.put32(&stub, at + 8, ERROR_MORE_DATA);
    at += 12;

    var found: [1]Share = undefined;
    const listing = answer(stub[0..at], &found);
    try testing.expect(listing.ok());
    try testing.expectEqual(@as(usize, 1), listing.count);
    try testing.expectEqual(@as(u32, 9), listing.total);
    try testing.expectEqual(ERROR_MORE_DATA, listing.status);
    try testing.expectEqual(@as(u16, 'o'), wire.u16At(found[0].name, 0));
}

test "the answer: nothing there, cut short, and a level that is not the one asked" {
    var found: [4]Share = undefined;
    var stub: [64]u8 = @splat(0);
    wire.put32(&stub, 0, 1);
    wire.put32(&stub, 4, 1);
    wire.put32(&stub, 8, 0); // no container
    const none = answer(stub[0..12], &found);
    try testing.expect(none.ok());
    try testing.expectEqual(@as(usize, 0), none.count);

    wire.put32(&stub, 8, 0x20000);
    wire.put32(&stub, 12, 0); // a container with nothing in it
    wire.put32(&stub, 16, 0);
    const empty = answer(stub[0..20], &found);
    try testing.expect(empty.ok());
    try testing.expectEqual(@as(usize, 0), empty.count);

    wire.put32(&stub, 0, 2);
    try testing.expect(answer(stub[0..20], &found).refused);
    try testing.expect(answer(&[_]u8{}, &found).refused);

    // A share whose strings were cut off: what came whole is kept.
    var cut: [128]u8 = @splat(0);
    wire.put32(&cut, 0, 1);
    wire.put32(&cut, 4, 1);
    wire.put32(&cut, 8, 0x20000);
    wire.put32(&cut, 12, 2);
    wire.put32(&cut, 16, 0x20004);
    wire.put32(&cut, 20, 2);
    var at: usize = 24;
    for (0..2) |_| {
        wire.put32(&cut, at, 0x20008);
        wire.put32(&cut, at + 4, STYPE_DISKTREE);
        wire.put32(&cut, at + 8, 0x2000C);
        at += 12;
    }
    at = putString(&cut, at, "one");
    at = putString(&cut, at, "first");
    const short = answer(cut[0..at], &found);
    try testing.expectEqual(@as(usize, 1), short.count);
    try testing.expectEqual(@as(u32, 2), short.total);
}

// SPDX-License-Identifier: MIT
//! DCE/RPC over a named pipe on the server, and the NDR its arguments are
//! written in: what it takes to ask one of the server's own services
//! something - `srvsvc`, which says what shares it has.
//!
//! **A call is two round trips.** The pipe is opened with CREATE on the
//! `IPC$` share (`shares.zig`), and each message goes to it as the input
//! of an FSCTL_PIPE_TRANSCEIVE: the bind, which says which interface is
//! wanted and that its arguments are in NDR, and then the request itself.
//! The answer comes back as the IOCTL's output.
//!
//! **A message is a PDU**: a 16-byte header - the version, what kind of
//! PDU it is, which fragment of the message it holds, how long it is and
//! which call it belongs to - and a body whose shape the kind decides. A
//! request's body begins with the operation's number, a response's with
//! the counts before its arguments; the arguments themselves, the stub,
//! follow. An answer longer than the pipe hands over at once comes in
//! fragments, the rest read from the pipe with READ, and only the last
//! says so: `gather` reads until it has them all and gives back the
//! stubs joined, which is the answer as NDR wrote it.
//!
//! **NDR** is how the arguments are laid out: every integer little-endian
//! and on a boundary of its own size, a pointer as a number that is not
//! zero when something is there (its referent), and the thing it points at
//! written after the structure that holds the pointer rather than in it. A
//! string is a count of the room, where in it the text starts, how many
//! characters there are, and then the characters in UTF-16 with their NUL.
//! `Strings` reads them back; what writes them is the one request this
//! file is used for, which writes its own.

const sdk = @import("sdk");
const smb = sdk.dos.smb;
const wire = @import("wire.zig");
const commands = @import("commands.zig");
const crypt = @import("crypt.zig");
const session_area = @import("session.zig");
const Session = session_area.Session;
const Error = session_area.Error;

/// The kinds of PDU that are met here.
pub const PTYPE_REQUEST: u8 = 0;
pub const PTYPE_RESPONSE: u8 = 2;
pub const PTYPE_FAULT: u8 = 3;
pub const PTYPE_BIND: u8 = 11;
pub const PTYPE_BIND_ACK: u8 = 12;
pub const PTYPE_BIND_NAK: u8 = 13;

/// `pfc_flags`: the first fragment of a message, and the last.
pub const PFC_FIRST: u8 = 0x01;
pub const PFC_LAST: u8 = 0x02;

/// The PDU header, and where a response's stub begins after it.
pub const header_size: usize = 16;
pub const response_body: usize = 8;
pub const stub_at: usize = header_size + response_body;

/// What the pipe takes a message on: the input is written to it and the
/// answer read back in one request.
pub const FSCTL_PIPE_TRANSCEIVE: u32 = 0x0011_C017;

/// The largest fragment either side may send. A share list is far below
/// it; a server that cannot send so much says a smaller one in its
/// bind_ack and keeps to it.
pub const fragment_max: u16 = 4280;

/// The NDR transfer syntax, 2.0: the one way the arguments here are
/// written.
pub const ndr_syntax = Uuid.of(0x8a885d04, 0x1ceb, 0x11c9, "\x9f\xe8\x08\x00\x2b\x10\x48\x60");
pub const ndr_version: u32 = 2;

/// An interface's name: the first three fields little-endian, the last
/// eight bytes as they are, which is how one goes on the wire.
pub const Uuid = struct {
    bytes: [16]u8,

    pub fn of(low: u32, mid: u16, high: u16, rest: *const [8]u8) Uuid {
        var uuid: Uuid = .{ .bytes = undefined };
        wire.put32(&uuid.bytes, 0, low);
        wire.put16(&uuid.bytes, 4, mid);
        wire.put16(&uuid.bytes, 6, high);
        @memcpy(uuid.bytes[8..16], rest);
        return uuid;
    }
};

/// A PDU header written at the start of `into`, `body` bytes of body
/// following it.
fn putHeader(into: []u8, ptype: u8, call_id: u32, body: usize) void {
    into[0] = 5; // the version, and 5.0
    into[1] = 0;
    into[2] = ptype;
    into[3] = PFC_FIRST | PFC_LAST;
    into[4] = 0x10; // little-endian, ASCII, IEEE floats
    into[5] = 0;
    into[6] = 0;
    into[7] = 0;
    wire.put16(into, 8, @intCast(header_size + body));
    wire.put16(into, 10, 0); // nothing is signed
    wire.put32(into, 12, call_id);
}

/// The bind for an interface, into `into`: the fragments either side will
/// take, and the one context - the interface wanted, and NDR for its
/// arguments. The bytes of it.
pub fn bind(into: []u8, call_id: u32, interface: *const Uuid, version: u32) []u8 {
    const body = 12 + 44;
    putHeader(into[0 .. header_size + body], PTYPE_BIND, call_id, body);
    var at = header_size;
    wire.put16(into, at, fragment_max); // max_xmit_frag
    wire.put16(into, at + 2, fragment_max); // max_recv_frag
    wire.put32(into, at + 4, 0); // assoc_group_id: a new association
    into[at + 8] = 1; // one context
    into[at + 9] = 0;
    wire.put16(into, at + 10, 0);
    at += 12;
    wire.put16(into, at, 0); // context id
    into[at + 2] = 1; // one transfer syntax
    into[at + 3] = 0;
    at += 4;
    @memcpy(into[at .. at + 16], &interface.bytes);
    wire.put32(into, at + 16, version);
    at += 20;
    @memcpy(into[at .. at + 16], &ndr_syntax.bytes);
    wire.put32(into, at + 16, ndr_version);
    at += 20;
    return into[0..at];
}

/// A request for the operation `opnum` carrying `stub`, into `into`: the
/// bytes of it.
pub fn request(into: []u8, call_id: u32, opnum: u16, stub: []const u8) []u8 {
    const body = 8 + stub.len;
    putHeader(into[0 .. header_size + body], PTYPE_REQUEST, call_id, body);
    wire.put32(into, header_size, @intCast(stub.len)); // alloc_hint
    wire.put16(into, header_size + 4, 0); // the context bound above
    wire.put16(into, header_size + 6, opnum);
    @memcpy(into[header_size + 8 ..][0..stub.len], stub);
    return into[0 .. header_size + 8 + stub.len];
}

/// One PDU out of a stream of them: its kind, whether it ends the
/// message, and the bytes after its header.
pub const Pdu = struct {
    ptype: u8,
    last: bool,
    body: []const u8,
    length: usize,
};

/// The PDU at the start of `bytes`, or null while it is not all there.
pub fn pduOf(bytes: []const u8) ?Pdu {
    if (bytes.len < header_size) return null;
    if (bytes[0] != 5) return null;
    const length = wire.u16At(bytes, 8);
    if (length < header_size or bytes.len < length) return null;
    return .{
        .ptype = bytes[2],
        .last = bytes[3] & PFC_LAST != 0,
        .body = bytes[header_size..length],
        .length = length,
    };
}

/// How far a stream of PDUs has come.
const Standing = enum { more, done, broken };

/// Whether every fragment of the answer is in `bytes` yet.
fn standingOf(bytes: []const u8) Standing {
    var at: usize = 0;
    while (at < bytes.len) {
        const pdu = pduOf(bytes[at..]) orelse return .more;
        if (pdu.ptype == PTYPE_FAULT or pdu.ptype == PTYPE_BIND_NAK) return .broken;
        if (pdu.last) return .done;
        at += pdu.length;
    }
    return .more;
}

/// What a call came to: the PDUs of the answer in the caller's buffer,
/// and the stubs of them joined - `.broken` when the server refused the
/// bind or faulted, and the server's status when the pipe itself failed.
pub const Answer = struct {
    /// STATUS_SUCCESS unless the pipe refused the message.
    status: u32 = 0,
    /// The kind of the first PDU that came back.
    ptype: u8 = PTYPE_RESPONSE,
    /// The stubs of every fragment, one after the other, at the front of
    /// the gathering buffer.
    stub: []const u8 = &.{},

    pub fn ok(answer: *const Answer) bool {
        return answer.status == smb.STATUS_SUCCESS and answer.ptype == PTYPE_RESPONSE;
    }
};

/// One message to the pipe and its whole answer: the message as the input
/// of an FSCTL_PIPE_TRANSCEIVE, the rest of the answer read from the pipe
/// with READ until a fragment says it is the last, all of it kept in
/// `gather`.
///
/// INPUTS:
/// - `session` - logged on, with the `IPC$` tree connected.
/// - `file_id` - the open pipe.
/// - `message` - the PDU to send.
/// - `gather` - where the answer's PDUs are read into; it holds the
///   joined stubs afterwards, so the answer may not be larger than it.
pub fn transceive(session: *Session, file_id: *const [16]u8, message: []const u8, gather: []u8) Error!Answer {
    const room: u32 = @min(@as(u32, @intCast(@min(gather.len, session.max_transact))), answerRoom(session));
    if (room == 0) return error.Protocol;
    var filled: usize = 0;
    {
        var ask = session.begin(.ioctl);
        commands.ioctl(&ask, FSCTL_PIPE_TRANSCEIVE, file_id, @intCast(message.len), room);
        ask.writer.raw(message);
        ask.charge(@max(@as(u32, @intCast(message.len)), room));
        var replies = session_area.noReplies();
        try session.exchange(&ask, &replies);
        const reply = &replies[0];
        const status = reply.status();
        if (status != smb.STATUS_SUCCESS and status != smb.STATUS_BUFFER_OVERFLOW) return .{ .status = status };
        const out = commands.ioctlOutput(reply) orelse return error.Protocol;
        if (out.len > gather.len) return error.Protocol;
        @memcpy(gather[0..out.len], out);
        filled = out.len;
    }
    // What the transact did not take comes off the pipe, fragment by
    // fragment, until one says it is the last.
    while (standingOf(gather[0..filled]) == .more) {
        if (filled == gather.len) return error.Protocol;
        var ask = session.begin(.read);
        const want: u32 = @min(@as(u32, @intCast(@min(gather.len - filled, session.pieceMax(session.max_read)))), answerRoom(session));
        if (want == 0) return error.Protocol;
        commands.read(&ask, file_id, 0, want);
        ask.charge(want);
        var replies = session_area.noReplies();
        try session.exchange(&ask, &replies);
        const reply = &replies[0];
        const status = reply.status();
        if (status != smb.STATUS_SUCCESS and status != smb.STATUS_BUFFER_OVERFLOW) return .{ .status = status };
        const data = commands.readData(reply) orelse return error.Protocol;
        if (data.len == 0 or data.len > gather.len - filled) return error.Protocol;
        @memcpy(gather[filled..][0..data.len], data);
        filled += data.len;
    }
    // The stubs moved to the front, one after the other: a message that
    // came in fragments is one NDR answer.
    var at: usize = 0;
    var kept: usize = 0;
    var first: u8 = PTYPE_RESPONSE;
    while (at < filled) {
        const pdu = pduOf(gather[at..filled]) orelse break;
        if (at == 0) first = pdu.ptype;
        if (pdu.ptype != PTYPE_RESPONSE) return .{ .ptype = pdu.ptype };
        if (pdu.body.len > response_body) {
            const stub = pdu.body[response_body..];
            // Backwards is never needed: the stub only ever moves down.
            for (stub, 0..) |byte, index| gather[kept + index] = byte;
            kept += stub.len;
        }
        const last = pdu.last;
        at += pdu.length;
        if (last) break;
    }
    return .{ .ptype = first, .stub = gather[0..kept] };
}

/// The most an answer may carry and still fit the session's receive
/// buffer: what is left of it once a header and a seal have their room.
/// A tool that only asks a question keeps a buffer far smaller than a
/// mounted share's handler, so what is asked for is cut to it.
fn answerRoom(session: *const Session) u32 {
    const spare = crypt.header_size + wire.header_size + 512;
    if (session.receive_buffer.len <= spare) return 0;
    return @intCast(session.receive_buffer.len - spare);
}

/// The bind for an interface sent and its answer taken: true when the
/// server took it.
pub fn bindTo(session: *Session, file_id: *const [16]u8, interface: *const Uuid, version: u32, scratch: []u8, gather: []u8) Error!bool {
    const message = bind(scratch, 1, interface, version);
    const answer = try transceive(session, file_id, message, gather);
    return answer.status == smb.STATUS_SUCCESS and answer.ptype == PTYPE_BIND_ACK;
}

// --- NDR ---------------------------------------------------------------------------

/// Reading NDR: the integers of a stub at four-byte boundaries, and the
/// strings that follow the structures pointing at them.
pub const Ndr = struct {
    bytes: []const u8,
    at: usize = 0,
    /// Set once anything was asked for that is not there: every answer
    /// after it is zero or empty, so a short stub is found at the end
    /// rather than at each step.
    short: bool = false,

    pub fn of(bytes: []const u8) Ndr {
        return .{ .bytes = bytes };
    }

    /// The next 32-bit number, 0 when the stub is too short.
    pub fn uint32(ndr: *Ndr) u32 {
        if (ndr.at + 4 > ndr.bytes.len) {
            ndr.short = true;
            return 0;
        }
        const value = wire.u32At(ndr.bytes, ndr.at);
        ndr.at += 4;
        return value;
    }

    pub fn skip(ndr: *Ndr, count: usize) void {
        if (ndr.at + count > ndr.bytes.len) {
            ndr.short = true;
            ndr.at = ndr.bytes.len;
            return;
        }
        ndr.at += count;
    }

    /// The next string: its UTF-16LE characters without the NUL, and the
    /// four-byte boundary taken up again after them. Empty when the stub
    /// is too short for it.
    pub fn string(ndr: *Ndr) []const u8 {
        _ = ndr.uint32(); // the room there is for it
        _ = ndr.uint32(); // where in it the characters start
        const count = ndr.uint32();
        if (ndr.short or count > ndr.bytes.len / 2) {
            ndr.short = true;
            return &.{};
        }
        const start = ndr.at;
        ndr.skip(2 * count);
        if (ndr.short) return &.{};
        ndr.at = (ndr.at + 3) & ~@as(usize, 3);
        if (ndr.at > ndr.bytes.len) ndr.at = ndr.bytes.len;
        var units = count;
        // The NUL the string carries is not part of it.
        if (units > 0 and wire.u16At(ndr.bytes, start + 2 * (units - 1)) == 0) units -= 1;
        return ndr.bytes[start..][0 .. 2 * units];
    }
};

// --- tests (host) ------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "a bind names the interface and NDR" {
    var buffer: [128]u8 = undefined;
    const srvsvc = Uuid.of(0x4b324fc8, 0x1670, 0x01d3, "\x12\x78\x5a\x47\xbf\x6e\xe1\x88");
    const message = bind(&buffer, 7, &srvsvc, 3);
    try testing.expectEqual(@as(usize, 72), message.len);
    try testing.expectEqual(@as(u8, 5), message[0]);
    try testing.expectEqual(PTYPE_BIND, message[2]);
    try testing.expectEqual(PFC_FIRST | PFC_LAST, message[3]);
    try testing.expectEqual(@as(u16, 72), wire.u16At(message, 8));
    try testing.expectEqual(@as(u32, 7), wire.u32At(message, 12));
    try testing.expectEqual(@as(u8, 1), message[header_size + 8]);
    // The interface, then NDR 2.0.
    try testing.expectEqual(@as(u32, 0x4b324fc8), wire.u32At(message, header_size + 16));
    try testing.expectEqual(@as(u16, 0x1670), wire.u16At(message, header_size + 20));
    try testing.expectEqual(@as(u32, 3), wire.u32At(message, header_size + 32));
    try testing.expect(wire.same(message[header_size + 36 ..][0..16], &ndr_syntax.bytes));
    try testing.expectEqual(@as(u32, 2), wire.u32At(message, header_size + 52));
}

test "a request carries its operation's number and its stub" {
    var buffer: [64]u8 = undefined;
    const message = request(&buffer, 2, 15, &[_]u8{ 1, 2, 3, 4 });
    try testing.expectEqual(@as(usize, 28), message.len);
    try testing.expectEqual(PTYPE_REQUEST, message[2]);
    try testing.expectEqual(@as(u32, 4), wire.u32At(message, header_size));
    try testing.expectEqual(@as(u16, 15), wire.u16At(message, header_size + 6));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, message[stub_at..]);
}

test "a PDU is read when all of it is there, and a stream of them ends at the last" {
    var buffer: [64]u8 = undefined;
    const message = request(&buffer, 1, 15, &[_]u8{ 9, 9, 9, 9 });
    try testing.expect(pduOf(message[0 .. message.len - 1]) == null);
    try testing.expect(pduOf(message[0..8]) == null);
    const pdu = pduOf(message).?;
    try testing.expectEqual(PTYPE_REQUEST, pdu.ptype);
    try testing.expect(pdu.last);
    try testing.expectEqual(@as(usize, 12), pdu.body.len);
    try testing.expectEqual(Standing.done, standingOf(message));
    try testing.expectEqual(Standing.more, standingOf(message[0 .. message.len - 2]));
    // A fragment that is not the last leaves the stream wanting more.
    var two: [64]u8 = undefined;
    @memcpy(two[0..message.len], message);
    two[3] = PFC_FIRST;
    try testing.expectEqual(Standing.more, standingOf(two[0..message.len]));
    two[2] = PTYPE_FAULT;
    try testing.expectEqual(Standing.broken, standingOf(two[0..message.len]));
}

test "NDR: numbers and the strings after them" {
    // Two numbers, then a string of three characters with its NUL, then a
    // number after the boundary it takes up, and the stub ends there.
    var bytes: [32]u8 = @splat(0);
    wire.put32(&bytes, 0, 1);
    wire.put32(&bytes, 4, 0x20000);
    wire.put32(&bytes, 8, 4); // the room
    wire.put32(&bytes, 12, 0); // where it starts
    wire.put32(&bytes, 16, 4); // four characters, the last the NUL
    wire.put16(&bytes, 20, 'N');
    wire.put16(&bytes, 22, 'A');
    wire.put16(&bytes, 24, 'S');
    wire.put16(&bytes, 26, 0);
    wire.put32(&bytes, 28, 77);
    var ndr = Ndr.of(&bytes);
    try testing.expectEqual(@as(u32, 1), ndr.uint32());
    try testing.expectEqual(@as(u32, 0x20000), ndr.uint32());
    const text = ndr.string();
    try testing.expectEqual(@as(usize, 6), text.len);
    try testing.expectEqual(@as(u16, 'N'), wire.u16At(text, 0));
    try testing.expectEqual(@as(u16, 'S'), wire.u16At(text, 4));
    try testing.expectEqual(@as(u32, 77), ndr.uint32());
    try testing.expect(!ndr.short);
    // Past the end: nothing, and said.
    _ = ndr.uint32();
    try testing.expect(ndr.short);
}

test "NDR: a string whose count is past the end is refused" {
    var bytes: [16]u8 = @splat(0);
    wire.put32(&bytes, 0, 0xFFFF);
    wire.put32(&bytes, 4, 0);
    wire.put32(&bytes, 8, 0xFFFF);
    var ndr = Ndr.of(&bytes);
    try testing.expectEqual(@as(usize, 0), ndr.string().len);
    try testing.expect(ndr.short);
}

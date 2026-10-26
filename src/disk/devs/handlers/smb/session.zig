// SPDX-License-Identifier: MIT
//! A session with the server, and every request made in it: one request -
//! or one compound of them - at a time, answered before the next goes;
//! only a request sent ahead is left unanswered for a while (see below).
//!
//! **A request** is written into the send buffer by its command's code
//! (`commands.zig`) behind room for its header, and `exchange` does the
//! rest: the header (the next message id, the credits, the session and
//! the tree), the signature, the seal when the session or the share is
//! encrypted, the framing, and the wait for the answers.
//!
//! **A compound** is up to `compound_max` requests in one message, each
//! at an 8-byte boundary, NextCommand saying where the next begins and
//! every one after the first marked as following on from it: a CREATE, a
//! QUERY_INFO and a CLOSE, the last two naming the file the first opens,
//! go in one round trip. Each is signed over its own bytes up to the next.
//! The server may answer all of them in one message or each in its own;
//! the answers are read into the receive buffer one after the other until
//! every request has its own.
//!
//! **Message ids and credits.** Every request costs a credit for each 64
//! KiB it reads or writes, at least one (none on 2.0.2, which has no
//! charge), and takes as many message ids, from the next. Only a server
//! that takes more than a credit's worth in one request (CAP_LARGE_MTU,
//! 2.1 and later) is asked for more, and never for more than the credits
//! there are pay for. Each request asks for `credits_asked` more, so a
//! session never runs out.
//!
//! **What is believed.** In a signed session every answer must carry a
//! right signature, but the few a server sends before it can sign - an
//! interim STATUS_PENDING, a session that has ended - which are taken
//! only as the end of the request. In an encrypted one every answer must
//! come sealed under the session's key. An answer that fails either is
//! the connection's end: nothing after it can be trusted.
//!
//! **A READ's data streamed.** `exchangeRead` reads a READ's answer
//! straight into the caller's buffer as it comes, not into the receive
//! buffer to be copied out, when the session is not encrypted and signs
//! with GMAC or not at all: its header and fields first, and when they are
//! the READ's successful answer, the data in pieces of `stream_piece`,
//! each taken into the signature (`UpdateGmac`) while the next arrives.
//! The signature is known only at the end, so data that fails it is in
//! the buffer by then: the read fails, and the buffer's contents are not
//! the file's. Any other answer is read whole and taken as `exchange`
//! takes it.
//!
//! **A request sent ahead** (`sendAhead`) - a READ reading ahead, a
//! WRITE writing behind - is not waited for: its answer is read off the
//! connection as it comes, into the buffer it was given, by `pump`
//! between packets - a READ's checked as it comes when it would stream -
//! and kept in `landed` once all of it has come. Every other request
//! takes the rest of it first (`settle`), so answers still come one
//! request at a time.

const sdk = @import("sdk");
const smb = sdk.dos.smb;
const crypto = sdk.crypto;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const wire = @import("wire.zig");
const signing = @import("signing.zig");
const crypt = @import("crypt.zig");
const Connection = @import("connection.zig").Connection;
const frame_header = @import("connection.zig").frame_header;
const Header = wire.Header;
const Command = wire.Command;
const Writer = wire.Writer;
const Reader = wire.Reader;

/// What one credit pays for, and so what one QUERY_DIRECTORY asks for.
pub const credit_bytes: u32 = 64 * 1024;

/// The most one READ or WRITE moves: 1 MiB where memory is plenty, so a
/// big file costs a round trip a MiB; a credit's worth on the ESP32s.
pub const io_max: u32 = if (sdk.hardware.chip == .rv64sbi or sdk.hardware.chip == .a64psci) 1 << 20 else credit_bytes;

/// The largest message either way: a READ's answer or a WRITE's request
/// of `io_max`, and their headers.
pub const message_max: usize = io_max + 1024;

/// What goes in front of a message in the send buffer: the framing and a
/// transform header's room.
pub const message_at: usize = frame_header + crypt.header_size;

/// The buffers' sizes. A compound's answers may come one by one, each in
/// a frame of its own: they are small, and the receive buffer has room
/// for them after the largest.
pub const send_size: usize = message_at + message_max;
pub const receive_size: usize = crypt.header_size + message_max + 8 * 1024;

/// The most requests in one compound.
pub const compound_max: usize = 4;

/// What comes before a READ's data in its answer: the header and the
/// READ's own fields.
const read_lead: usize = wire.header_size + 16;

/// How much of a streamed READ is read before it goes into the signature.
const stream_piece: usize = 32 * 1024;

/// Credits each request asks for: more than the most one costs.
const credits_asked: u16 = 32;
comptime {
    if (io_max / credit_bytes >= credits_asked) @compileError("a request would cost more credits than it asks for");
}

/// A FileId that stands for the one the compound's CREATE opens.
pub const related_file: [16]u8 = @splat(0xFF);

pub const Error = error{
    /// The connection failed, closed or ran out of time.
    Network,
    /// An answer that makes no sense.
    Protocol,
    /// An answer whose signature or seal is wrong, or a session that must
    /// be signed or encrypted and cannot be.
    Security,
};

/// One answer: its header and the whole message.
pub const Reply = struct {
    header: Header = .{},
    message: []u8 = &.{},

    /// A reader over the answer's own fields, after its header.
    pub fn body(reply: *const Reply) Reader {
        return .{ .bytes = reply.message, .at = wire.header_size };
    }

    pub fn status(reply: *const Reply) u32 {
        return reply.header.status;
    }

    pub fn failed(reply: *const Reply) bool {
        return smb.isError(reply.header.status);
    }
};

/// Requests being written: their commands, and where each begins.
pub const Request = struct {
    writer: Writer,
    starts: [compound_max]usize = undefined,
    commands: [compound_max]Command = undefined,
    /// What each costs, in credits.
    charges: [compound_max]u16 = undefined,
    count: usize = 0,
    /// Whether the session's tree is named (every command after
    /// TREE_CONNECT but LOGOFF and ECHO).
    on_tree: bool = true,

    /// Another request: the one before padded to 8 bytes, and room for
    /// this one's header.
    pub fn add(request: *Request, command: Command) void {
        if (request.count == compound_max) {
            request.writer.full = true;
            return;
        }
        if (request.count > 0) request.writer.alignTo(8);
        request.starts[request.count] = request.writer.at;
        request.commands[request.count] = command;
        request.charges[request.count] = 1;
        request.count += 1;
        request.writer.zeros(wire.header_size);
    }

    /// The last request added made to cost what moving `bytes` does: a
    /// credit for each 64 KiB, at least one.
    pub fn charge(request: *Request, bytes: u32) void {
        if (request.count == 0) return;
        request.charges[request.count - 1] = @intCast(@max(1, (bytes + credit_bytes - 1) / credit_bytes));
    }

    /// The bytes of the `index`th request: from its header to the next's,
    /// or to the end.
    pub fn message(request: *const Request, index: usize) []u8 {
        const end = if (index + 1 < request.count) request.starts[index + 1] else request.writer.at;
        return request.writer.bytes[request.starts[index]..end];
    }
};

pub const Session = struct {
    cb: *CryptoBase,
    connection: Connection,
    /// `send_size` and `receive_size` bytes.
    send_buffer: []u8,
    receive_buffer: []u8,

    /// The dialect (SMB2_DIALECT_*), 0 before the negotiation.
    dialect: u16 = 0,
    message_id: u64 = 0,
    credits: u32 = 1,
    session_id: u64 = 0,
    tree_id: u32 = 0,
    /// How requests are signed and answers checked.
    signer: signing.Signer = .{},
    /// Whether every answer must be signed.
    signed: bool = false,
    /// The session's cipher keys, and whether the session's messages are
    /// encrypted - all of them, or those on the tree.
    keys: crypt.Keys = .{},
    encrypt_all: bool = false,
    encrypt_tree: bool = false,

    /// What the negotiation found.
    server_security: u16 = 0,
    server_capabilities: u32 = 0,
    server_guid: [16]u8 = @splat(0),
    server_time: u64 = 0,
    max_transact: u32 = credit_bytes,
    max_read: u32 = credit_bytes,
    max_write: u32 = credit_bytes,
    /// Whether a request may cost more than one credit: a dialect after
    /// 2.0.2 on a server with CAP_LARGE_MTU.
    multi_credit: bool = false,
    /// 3.1.1's choices: the cipher and the signing algorithm.
    cipher: u16 = smb.SMB2_CIPHER_NONE,
    signing_algorithm: u16 = smb.SMB2_SIGNING_AES_CMAC,
    /// The client's GUID, the same for every connection the handler makes.
    client_guid: [16]u8 = @splat(0),
    /// 3.1.1: the hash of the negotiation, which every logon on the
    /// connection starts from.
    preauth: signing.Preauth = .{},

    /// What the logon and the tree connection found: the share's flags,
    /// and what the user may do on it (MaximalAccess, a CREATE's access
    /// bits).
    session_flags: u16 = 0,
    share_flags: u32 = 0,
    maximal_access: u32 = 0,

    /// The request sent ahead while its answer comes, and the answer once
    /// all of it has, until it is taken.
    ahead: ?Ahead = null,
    landed: ?Landed = null,

    /// Requests begun: the send buffer's message room.
    pub fn begin(session: *Session, command: Command) Request {
        var request: Request = .{ .writer = .{ .bytes = session.send_buffer[message_at..] } };
        request.add(command);
        return request;
    }

    /// The most one READ or WRITE may move now: `io_max` within the
    /// server's `limit` (MaxReadSize or MaxWriteSize), a credit's worth
    /// where a request may not cost more, and what the credits there are
    /// pay for.
    pub fn pieceMax(session: *const Session, limit: u32) u32 {
        const most = @min(io_max, limit);
        if (!session.multi_credit) return @min(most, credit_bytes);
        return @intCast(@min(most, @as(u64, @max(session.credits, 1)) * credit_bytes));
    }

    /// Everything a connection had, forgotten: the next one starts again
    /// from the negotiation.
    pub fn reset(session: *Session) void {
        session.connection.close();
        const kept: Session = .{
            .cb = session.cb,
            .connection = session.connection,
            .send_buffer = session.send_buffer,
            .receive_buffer = session.receive_buffer,
            .client_guid = session.client_guid,
        };
        session.* = kept;
    }

    /// The requests sent and their answers read into `replies`, one for
    /// each request in order. A request whose answer says it failed is
    /// not an error here: its status is in its reply.
    pub fn exchange(session: *Session, request: *Request, replies: []Reply) Error!void {
        try session.settle();
        var ids: [compound_max]u64 = undefined;
        const encrypt = try session.send(request, replies, &ids);
        var answered: usize = 0;
        try session.answers(request, replies, &ids, encrypt, 0, &answered);
    }

    /// One READ sent, and its data read straight into `into` as it comes
    /// when it can be (see the top): the data's length then. Null when its
    /// answer was read whole, as `exchange` reads it, and is `replies[0]`,
    /// its data still to be taken from there. A failed READ is not an
    /// error here: its status is in its reply.
    pub fn exchangeRead(session: *Session, request: *Request, replies: []Reply, into: []u8) Error!?usize {
        try session.settle();
        var ids: [compound_max]u64 = undefined;
        const encrypt = try session.send(request, replies, &ids);
        var answered: usize = 0;
        if (!session.streamable(request, encrypt)) {
            try session.answers(request, replies, &ids, encrypt, 0, &answered);
            return null;
        }
        const buffer = session.receive_buffer;
        const length = session.connection.frameLength(buffer.len) orelse return error.Network;
        const lead = buffer[0..@min(length, read_lead)];
        if (!session.connection.readAll(lead)) return error.Network;
        if (session.streams(lead, length, ids[0], into.len)) |count| {
            const header = Header.read(lead).?;
            const verify = header.flags & wire.FLAGS_SIGNED != 0 and session.signer.signs();
            try session.stream(lead, length, into[0..count], verify);
            session.credits += header.credits;
            replies[0] = .{ .header = header, .message = lead };
            return count;
        }
        // Not one to stream: the rest read too, and taken as any answer.
        if (!session.connection.readAll(buffer[lead.len..length])) return error.Network;
        try session.take(buffer[0..length], ids[0..request.count], replies, encrypt, &answered);
        try session.answers(request, replies, &ids, encrypt, (length + 7) & ~@as(usize, 7), &answered);
        return null;
    }

    /// Whether the answer to `request` may be streamed: a READ alone, not
    /// sealed, in a session that signs with GMAC or not at all.
    fn streamable(session: *const Session, request: *const Request, encrypt: bool) bool {
        const gmac = session.signer.algorithm == smb.SMB2_SIGNING_AES_GMAC;
        return request.count == 1 and request.commands[0] == .read and !encrypt and (!session.signer.signs() or gmac);
    }

    /// One request sent ahead - a READ or a WRITE - its answer left to
    /// come into `buffer` (`receive_size` bytes) while the handler goes on,
    /// whatever was ahead before taken in first. Its message id: `landed`
    /// has its answer, with that id, once `pump` or `settle` has read all
    /// of it.
    pub fn sendAhead(session: *Session, request: *Request, buffer: []u8) Error!u64 {
        try session.settle();
        var ids: [compound_max]u64 = undefined;
        var replies = noReplies();
        const encrypt = try session.send(request, &replies, &ids);
        session.ahead = .{ .buffer = buffer, .id = ids[0], .encrypt = encrypt, .may_stream = session.streamable(request, encrypt) };
        return ids[0];
    }

    /// Whether the answer to the request sent ahead as `id` is still
    /// coming.
    pub fn aheadOf(session: *const Session, id: u64) bool {
        const ahead = session.ahead orelse return false;
        return ahead.id == id;
    }

    /// What has come of the answer ahead taken in, without waiting.
    pub fn pump(session: *Session) Error!void {
        try session.advance(false);
    }

    /// All of the answer ahead taken in, waiting for what has not come.
    pub fn settle(session: *Session) Error!void {
        try session.advance(true);
    }

    /// The answer ahead read on - with `wait` to its end, without as far
    /// as it has come - and kept in `landed` when all of it is there. An
    /// interim answer is passed over for the one after it. A failure ends
    /// it: the connection is gone or not to be trusted.
    fn advance(session: *Session, wait: bool) Error!void {
        if (session.ahead == null) return;
        errdefer session.ahead = null;
        const ahead = &session.ahead.?;
        while (true) {
            if (ahead.framed < frame_header) {
                const got = try session.some(ahead.framing[ahead.framed..], wait);
                if (got == 0) return;
                ahead.framed += got;
                if (ahead.framed < frame_header) continue;
                ahead.length = @as(usize, ahead.framing[1]) << 16 | @as(usize, ahead.framing[2]) << 8 | ahead.framing[3];
                // Anything but a session message is not SMB's.
                if (ahead.framing[0] != 0 or ahead.length > ahead.buffer.len) {
                    session.connection.close();
                    return error.Network;
                }
                continue;
            }
            // The lead first, to know whether it streams; then the rest.
            const lead_end = @min(ahead.length, read_lead);
            const until = if (ahead.looked) ahead.length else lead_end;
            if (ahead.got < until) {
                const got = try session.some(ahead.buffer[ahead.got..until], wait);
                if (got == 0) return;
                ahead.got += got;
            }
            if (!ahead.looked and ahead.got == lead_end) {
                ahead.looked = true;
                if (ahead.may_stream) try session.lookAhead(ahead);
            }
            if (ahead.verify and ahead.hashed < ahead.got) {
                session.cb.UpdateGmac(&ahead.context, ahead.buffer[ahead.hashed..].ptr, @intCast(ahead.got - ahead.hashed));
                ahead.hashed = ahead.got;
            }
            if (ahead.got < ahead.length) continue;
            if (try session.land(ahead)) {
                session.ahead = null;
                return;
            }
            ahead.* = .{ .buffer = ahead.buffer, .id = ahead.id, .encrypt = ahead.encrypt, .may_stream = ahead.may_stream };
        }
    }

    /// Of the stream into `into`, as `Connection.readSome` reads it.
    fn some(session: *Session, into: []u8, wait: bool) Error!usize {
        return session.connection.readSome(into, wait) orelse error.Network;
    }

    /// The answer ahead's lead come: whether it streams, as `streams`
    /// says, and when it is to be checked, its GMAC begun.
    fn lookAhead(session: *Session, ahead: *Ahead) Error!void {
        const lead = ahead.buffer[0..ahead.got];
        ahead.streamed = session.streams(lead, ahead.length, ahead.id, ahead.buffer.len) orelse return;
        const header = Header.read(lead).?;
        ahead.verify = header.flags & wire.FLAGS_SIGNED != 0 and session.signer.signs();
        if (!ahead.verify) return;
        @memcpy(&ahead.given, lead[wire.signature_at..][0..16]);
        @memset(lead[wire.signature_at..][0..16], 0);
        const nonce = signing.gmacNonce(lead);
        if (session.cb.InitGmac(&ahead.context, &session.signer.key, 16, &nonce, nonce.len) != crypto.CRYPTOERR_OK) return error.Security;
    }

    /// The answer ahead, all of it come, checked and kept in `landed`:
    /// true, or false when it was not the request's answer yet - an
    /// interim one, or a message for no request.
    fn land(session: *Session, ahead: *Ahead) Error!bool {
        const message = ahead.buffer[0..ahead.length];
        if (ahead.streamed) |count| {
            const header = Header.read(message).?;
            if (ahead.verify and !session.gmacRight(&ahead.context, &ahead.given)) return error.Security;
            session.credits += header.credits;
            session.landed = .{ .id = ahead.id, .reply = .{ .header = header, .message = message[0..read_lead] }, .data = message[read_lead..][0..count] };
            return true;
        }
        var replies = noReplies();
        var answered: usize = 0;
        try session.take(message, (&ahead.id)[0..1], &replies, ahead.encrypt, &answered);
        if (answered == 0) return false;
        session.landed = .{ .id = ahead.id, .reply = replies[0], .data = null };
        return true;
    }

    /// Whether the GMAC taken in `context` is `given`, every byte
    /// compared whatever the first that differs.
    fn gmacRight(session: *Session, context: *crypto.GmacContext, given: *const [16]u8) bool {
        var signature: [crypto.GCM_TAG]u8 = undefined;
        if (session.cb.FinishGmac(context, &signature) != crypto.CRYPTOERR_OK) return false;
        var difference: u8 = 0;
        for (given, signature) |one, other| difference |= one ^ other;
        return difference == 0;
    }

    /// The length of the data a READ's answer carries when it is to be
    /// streamed - the successful answer to the READ whose message id is
    /// `id`, alone in its message, believed, its data right after its
    /// fields and no longer than `room` - or null.
    ///
    /// INPUTS:
    /// - `lead` - the message's first `read_lead` bytes, or all of it.
    /// - `length` - the whole message's.
    fn streams(session: *const Session, lead: []const u8, length: usize, id: u64, room: usize) ?usize {
        if (lead.len < read_lead) return null;
        const header = Header.read(lead) orelse return null;
        if (header.flags & wire.FLAGS_SERVER_TO_REDIR == 0 or header.flags & wire.FLAGS_ASYNC_COMMAND != 0) return null;
        if (header.message_id != id or header.command != .read or header.status != smb.STATUS_SUCCESS or header.next_command != 0) return null;
        // Unsigned in a signed session: `take` finds it not believed.
        if (header.flags & wire.FLAGS_SIGNED == 0 and session.signed) return null;
        const fields = lead[wire.header_size..];
        if (wire.u16At(fields, 0) != 17 or fields[2] != read_lead) return null;
        const count: usize = wire.u32At(fields, 4);
        if (count > room or read_lead + count > length) return null;
        return count;
    }

    /// A READ's answer whose first `read_lead` bytes are in `lead` read on:
    /// its data into `into`, whatever follows it into the receive buffer
    /// after `lead`, and when `verify`, its signature checked over all of
    /// it as it comes.
    fn stream(session: *Session, lead: []u8, length: usize, into: []u8, verify: bool) Error!void {
        const cb = session.cb;
        var context: crypto.GmacContext = .{};
        var given: [16]u8 = undefined;
        if (verify) {
            @memcpy(&given, lead[wire.signature_at..][0..16]);
            @memset(lead[wire.signature_at..][0..16], 0);
            const nonce = signing.gmacNonce(lead);
            if (cb.InitGmac(&context, &session.signer.key, 16, &nonce, nonce.len) != crypto.CRYPTOERR_OK) return error.Security;
            cb.UpdateGmac(&context, lead.ptr, @intCast(lead.len));
        }
        var at: usize = 0;
        while (at < into.len) {
            const piece = into[at..][0..@min(into.len - at, stream_piece)];
            if (!session.connection.readAll(piece)) return error.Network;
            if (verify) cb.UpdateGmac(&context, piece.ptr, @intCast(piece.len));
            at += piece.len;
        }
        const rest = session.receive_buffer[lead.len..][0 .. length - lead.len - into.len];
        if (!session.connection.readAll(rest)) return error.Network;
        if (!verify) return;
        cb.UpdateGmac(&context, rest.ptr, @intCast(rest.len));
        if (!session.gmacRight(&context, &given)) return error.Security;
    }

    /// The requests' headers written, signed or sealed, and sent; each
    /// one's message id in `ids`. Whether they went encrypted.
    fn send(session: *Session, request: *Request, replies: []Reply, ids: *[compound_max]u64) Error!bool {
        if (request.writer.full or request.count == 0 or replies.len < request.count) return error.Protocol;
        const cb = session.cb;
        const encrypt = session.encrypt_all or (request.on_tree and session.encrypt_tree);
        const sign = session.signer.signs() and !encrypt;
        // Each request's message id, the first of those its charge takes.
        var spent: u32 = 0;
        for (0..request.count) |index| {
            const message = request.message(index);
            const charge: u16 = if (session.dialect == smb.SMB2_DIALECT_0202 or request.commands[index] == .negotiate) 0 else request.charges[index];
            ids[index] = session.message_id;
            const header: Header = .{
                .credit_charge = charge,
                .command = request.commands[index],
                .credits = credits_asked,
                .flags = if (index > 0) wire.FLAGS_RELATED_OPERATIONS else 0,
                .next_command = if (index + 1 < request.count) @intCast(message.len) else 0,
                .message_id = session.message_id,
                .tree_id = if (request.on_tree) session.tree_id else 0,
                .session_id = session.session_id,
            };
            header.write(message);
            session.message_id += @max(charge, 1);
            spent += @max(charge, 1);
            if (sign) session.signer.sign(cb, message);
        }
        session.credits -|= spent;

        const length = request.writer.at;
        const frame = if (encrypt) blk: {
            if (!session.keys.encrypts()) return error.Security;
            const sealed = crypt.seal(cb, &session.keys, session.session_id, session.send_buffer[frame_header..], length);
            break :blk session.send_buffer[0 .. frame_header + sealed.len];
        } else session.send_buffer[message_at - frame_header .. message_at + length];
        if (!session.connection.send(frame)) return error.Network;
        return encrypt;
    }

    /// The answers read into the receive buffer from `room` on, until each
    /// request has its own; `answered` counts those that have.
    fn answers(session: *Session, request: *const Request, replies: []Reply, ids: *const [compound_max]u64, encrypt: bool, room: usize, answered: *usize) Error!void {
        var at = room;
        while (answered.* < request.count) {
            const got = session.connection.receive(session.receive_buffer[at..]) orelse return error.Network;
            try session.take(got, ids[0..request.count], replies, encrypt, answered);
            at += got.len;
            at = (at + 7) & ~@as(usize, 7);
        }
    }

    /// The answers in one message as it came, `got`, put in `replies` by
    /// their requests' message ids, `ids`; `answered` counts the requests
    /// that have one.
    fn take(session: *Session, got: []u8, ids: []const u64, replies: []Reply, encrypt: bool, answered: *usize) Error!void {
        const sealed = wire.same(got[0..@min(got.len, 4)], &wire.transform_id);
        const plain = if (sealed) blk: {
            if (!session.keys.encrypts()) return error.Security;
            break :blk crypt.open(session.cb, &session.keys, session.session_id, got) orelse return error.Security;
        } else blk: {
            if (encrypt) return error.Security;
            break :blk got;
        };
        // The messages in it, by their NextCommand.
        var at: usize = 0;
        while (at < plain.len) {
            const rest = plain[at..];
            const header = Header.read(rest) orelse return error.Protocol;
            const end: usize = if (header.next_command == 0) rest.len else header.next_command;
            if (end < wire.header_size or end > rest.len) return error.Protocol;
            const message = rest[0..end];
            at += end;
            session.credits += header.credits;
            if (header.flags & wire.FLAGS_SERVER_TO_REDIR == 0) return error.Protocol;
            const index = for (ids, 0..) |id, at_index| {
                if (id == header.message_id) break at_index;
            } else continue;
            // An interim answer: the real one comes later.
            if (header.status == smb.STATUS_PENDING and header.flags & wire.FLAGS_ASYNC_COMMAND != 0) continue;
            if (!sealed and !session.believes(message, &header)) return error.Security;
            if (replies[index].message.len == 0) answered.* += 1;
            replies[index] = .{ .header = header, .message = message };
        }
    }

    /// Whether an answer that came unsealed can be taken: signed and right
    /// when the session signs, or one of the few answers a server sends
    /// unsigned - which are taken only as failures.
    fn believes(session: *Session, message: []u8, header: *const Header) bool {
        if (header.flags & wire.FLAGS_SIGNED != 0) {
            if (!session.signer.signs()) return true;
            return session.signer.verify(session.cb, message);
        }
        if (!session.signed) return true;
        return switch (header.status) {
            smb.STATUS_USER_SESSION_DELETED, smb.STATUS_NETWORK_SESSION_EXPIRED, smb.STATUS_INVALID_PARAMETER => true,
            else => false,
        };
    }
};

/// A request sent ahead (`Session.sendAhead`) while its answer comes.
pub const Ahead = struct {
    /// Where the answer comes, the request's message id, whether it went
    /// sealed, and whether its answer may be streamed.
    buffer: []u8,
    id: u64,
    encrypt: bool,
    may_stream: bool,
    /// The message's framing as it comes, then its length, and how much
    /// of it has come.
    framing: [frame_header]u8 = undefined,
    framed: usize = 0,
    length: usize = 0,
    got: usize = 0,
    /// Its lead looked at; the data's length when it streams.
    looked: bool = false,
    streamed: ?usize = null,
    /// Checked as it comes: the signature it came with, and the GMAC over
    /// the first `hashed` bytes.
    verify: bool = false,
    given: [16]u8 = undefined,
    context: crypto.GmacContext = .{},
    hashed: usize = 0,
};

/// The answer to a request sent ahead: the request's message id, its
/// reply, and a READ's data when it streamed, both in the buffer it came
/// into.
pub const Landed = struct {
    id: u64,
    reply: Reply,
    data: ?[]u8,
};

/// The requests' replies, cleared for an exchange.
pub fn noReplies() [compound_max]Reply {
    return @splat(.{});
}

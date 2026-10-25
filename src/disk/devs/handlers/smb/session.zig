// SPDX-License-Identifier: MIT
//! A session with the server, and every request made in it: one request -
//! or one compound of them - at a time, answered before the next goes.
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
//! **Message ids and credits.** Every request takes the next message id
//! and costs one credit (none on 2.0.2, which has no charge): nothing
//! here asks for more than 64 KiB at a time. Each asks for `credits_asked`
//! more, so a session never runs out.
//!
//! **What is believed.** In a signed session every answer must carry a
//! right signature, but the few a server sends before it can sign - an
//! interim STATUS_PENDING, a session that has ended - which are taken
//! only as the end of the request. In an encrypted one every answer must
//! come sealed under the session's key. An answer that fails either is
//! the connection's end: nothing after it can be trusted.

const sdk = @import("sdk");
const smb = sdk.dos.smb;
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

/// The most one request reads or writes, and so what one QUERY_DIRECTORY
/// asks for: one credit's worth.
pub const io_max: u32 = 64 * 1024;

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

/// Credits each request asks for.
const credits_asked: u16 = 32;

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
        request.count += 1;
        request.writer.zeros(wire.header_size);
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
    max_transact: u32 = io_max,
    max_read: u32 = io_max,
    max_write: u32 = io_max,
    /// 3.1.1's choices: the cipher and the signing algorithm.
    cipher: u16 = smb.SMB2_CIPHER_NONE,
    signing_algorithm: u16 = smb.SMB2_SIGNING_AES_CMAC,
    /// The client's GUID, the same for every connection the handler makes.
    client_guid: [16]u8 = @splat(0),
    /// 3.1.1: the hash of the negotiation, which every logon on the
    /// connection starts from.
    preauth: signing.Preauth = .{},

    /// What the logon and the tree connection found.
    session_flags: u16 = 0,
    share_flags: u32 = 0,

    /// Requests begun: the send buffer's message room.
    pub fn begin(session: *Session, command: Command) Request {
        var request: Request = .{ .writer = .{ .bytes = session.send_buffer[message_at..] } };
        request.add(command);
        return request;
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
        if (request.writer.full or request.count == 0 or replies.len < request.count) return error.Protocol;
        const cb = session.cb;
        const encrypt = session.encrypt_all or (request.on_tree and session.encrypt_tree);
        const sign = session.signer.signs() and !encrypt;
        const first_id = session.message_id;
        for (0..request.count) |index| {
            const message = request.message(index);
            const header: Header = .{
                .credit_charge = if (session.dialect == smb.SMB2_DIALECT_0202 or request.commands[index] == .negotiate) 0 else 1,
                .command = request.commands[index],
                .credits = credits_asked,
                .flags = if (index > 0) wire.FLAGS_RELATED_OPERATIONS else 0,
                .next_command = if (index + 1 < request.count) @intCast(message.len) else 0,
                .message_id = session.message_id,
                .tree_id = if (request.on_tree) session.tree_id else 0,
                .session_id = session.session_id,
            };
            header.write(message);
            session.message_id += 1;
            if (sign) session.signer.sign(cb, message);
        }
        if (session.credits >= request.count) session.credits -= @intCast(request.count) else session.credits = 0;

        const length = request.writer.at;
        const frame = if (encrypt) blk: {
            if (!session.keys.encrypts()) return error.Security;
            const sealed = crypt.seal(cb, &session.keys, session.session_id, session.send_buffer[frame_header..], length);
            break :blk session.send_buffer[0 .. frame_header + sealed.len];
        } else session.send_buffer[message_at - frame_header .. message_at + length];
        if (!session.connection.send(frame)) return error.Network;

        // The answers, until each request has its own.
        var answered: usize = 0;
        var room: usize = 0;
        while (answered < request.count) {
            const got = session.connection.receive(session.receive_buffer[room..]) orelse return error.Network;
            const sealed = wire.same(got[0..@min(got.len, 4)], &wire.transform_id);
            const plain = if (sealed) blk: {
                if (!session.keys.encrypts()) return error.Security;
                break :blk crypt.open(cb, &session.keys, session.session_id, got) orelse return error.Security;
            } else blk: {
                if (encrypt) return error.Security;
                break :blk got;
            };
            room += got.len;
            room = (room + 7) & ~@as(usize, 7);
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
                if (header.message_id < first_id or header.message_id >= first_id + request.count) continue;
                const index: usize = @intCast(header.message_id - first_id);
                // An interim answer: the real one comes later.
                if (header.status == smb.STATUS_PENDING and header.flags & wire.FLAGS_ASYNC_COMMAND != 0) continue;
                if (!sealed and !session.believes(message, &header)) return error.Security;
                if (replies[index].message.len == 0) answered += 1;
                replies[index] = .{ .header = header, .message = message };
            }
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

/// The requests' replies, cleared for an exchange.
pub fn noReplies() [compound_max]Reply {
    return @splat(.{});
}

// SPDX-License-Identifier: MIT
//! One SSH connection, the server's end, as a machine that takes bytes in
//! and gives bytes out (it touches no socket: the unit's task does that,
//! and the tests play a client against it): the transport
//! (`transport.zig`) with the server's part of the key exchange, the
//! login (RFC 4252) and one session channel (`channel.zig`).
//!
//! **The key exchange.** mlkem768x25519-sha256 when the client has it -
//! the client's ML-KEM-768 encapsulation key and X25519 share; our
//! ciphertext and X25519 share; K the SHA-256 of the two secrets - or
//! else curve25519-sha256 (RFC 8731), K the X25519 secret. H is signed
//! with the Ed25519 host key.
//!
//! **The login**: `ssh-userauth`, then requests until one succeeds -
//! `password` against the password given, or `publickey` with an Ed25519
//! key among those given, asked about first (PK_OK) and then signed over
//! the session id and the request. Six failures end the connection.
//!
//! **The channel**: one `session` channel; `pty-req` (the terminal's type
//! and size), `env` (refused), then `shell` or `exec` (a command), which
//! is when the session is ready. `signal` INT and `break` come as Ctrl-C.
//! At the end: `exit-status`, EOF and CLOSE.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const ssh = sdk.devices.ssh;
const ssh_keys = sdk.devices.ssh.keys;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const wire = @import("wire.zig");
const transport_file = @import("transport.zig");
const channel_file = @import("channel.zig");
const Transport = transport_file.Transport;
const Channel = channel_file.Channel;
const Packet = transport_file.Packet;
const Reader = wire.Reader;
const Writer = wire.Writer;

const msg = transport_file;

/// Failed logins before the connection ends.
pub const tries_max = 6;

pub const Connection = struct {
    transport: Transport,
    channel: Channel = .{},

    // --- the login ---------------------------------------------------------

    host_seed: [32]u8 = @splat(0),
    host_public: [32]u8 = @splat(0),
    password: [ssh.SSH_PASSWORD_MAX]u8 = @splat(0),
    password_length: usize = 0,
    keys: [ssh.SSH_KEYS_MAX][32]u8 = @splat(@splat(0)),
    key_count: usize = 0,
    service_accepted: bool = false,
    authenticated: bool = false,
    failures: u32 = 0,
    user: [64]u8 = @splat(0),

    // --- the session -------------------------------------------------------

    session_ready: bool = false,
    kind: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    terminal: [32]u8 = @splat(0),
    command: [512]u8 = @splat(0),

    /// A new connection in `conn`'s memory, made there: it is too big for
    /// a stack.
    pub fn init(conn: *Connection, cb: *CryptoBase) void {
        conn.* = .{ .transport = .{ .cb = cb, .role = .server } };
    }

    /// The connection ready: the credentials taken, and our version line
    /// and first KEXINIT queued.
    pub fn start(conn: *Connection, accept: *const ssh.SshAccept) void {
        conn.host_seed = accept.host_seed;
        conn.host_public = accept.host_public;
        conn.password_length = @min(accept.password_length, ssh.SSH_PASSWORD_MAX);
        @memcpy(conn.password[0..conn.password_length], accept.password[0..conn.password_length]);
        conn.key_count = @min(accept.key_count, ssh.SSH_KEYS_MAX);
        for (0..conn.key_count) |index| conn.keys[index] = accept.keys[index];
        conn.transport.start();
    }

    /// Everything whole that came in, taken, while there is room for
    /// what it answers.
    pub fn process(conn: *Connection) void {
        const t = &conn.transport;
        while (t.roomForReply()) {
            const packet = t.next() orelse return;
            if (packet.payload.len > 0) conn.handle(packet);
            // A handler may end the connection, but never moves the input.
            t.done();
            if (t.phase != .packets) return;
        }
    }

    fn handle(conn: *Connection, packet: Packet) void {
        const t = &conn.transport;
        const kind = packet.payload[0];
        if (t.common(packet)) {
            // The window held back while the keys changed.
            if (kind == msg.msg_newkeys) conn.channel.acknowledge(t, false);
            return;
        }
        var reader = Reader{ .bytes = packet.payload, .at = 1 };
        switch (kind) {
            msg.msg_kex_ecdh_init => conn.ecdhInit(&reader),
            msg.msg_service_request => conn.serviceRequest(&reader),
            msg.msg_userauth_request => conn.userauth(&reader),
            msg.msg_global_request => {
                _ = reader.string();
                if (reader.boolean() and !reader.bad) t.send(&.{msg.msg_request_failure});
            },
            msg.msg_channel_open...msg.msg_channel_failure => {
                if (!conn.authenticated) return t.disconnect(msg.reason_protocol_error, "not logged in");
                conn.channelMessage(kind, &reader);
            },
            else => t.unimplemented(packet.sequence),
        }
    }

    // --- the key exchange --------------------------------------------------

    /// The client's shares: ours made, K and H, H signed, the reply and
    /// NEWKEYS sent, and our direction's keys on.
    fn ecdhInit(conn: *Connection, reader: *Reader) void {
        const t = &conn.transport;
        if (t.kex != .exchanging) return t.disconnect(msg.reason_protocol_error, "unexpected KEX_ECDH_INIT");
        // Hybrid: the ML-KEM encapsulation key, then the X25519 share.
        const client_blob = reader.string();
        if (t.skip_guess) {
            t.skip_guess = false;
            return;
        }
        const blob_length: usize = if (t.hybrid) crypto.MLKEM768_PUBLIC + 32 else 32;
        if (reader.bad or client_blob.len != blob_length) return t.disconnect(msg.reason_key_exchange_failed, "bad share");
        const client_share = client_blob[client_blob.len - 32 ..];
        const cb = t.cb;
        var private: [32]u8 = undefined;
        var public: [32]u8 = undefined;
        var public_length: u32 = 32;
        defer transport_file.wipe(&private);
        var secret: [32]u8 = undefined;
        defer transport_file.wipe(&secret);
        if (cb.MakeKeyPair(crypto.CURVE_X25519, &private, &public, &public_length) != crypto.CRYPTOERR_OK or
            cb.SharedSecret(crypto.CURVE_X25519, &private, &crypto.Bytes.of(client_share), &secret) != crypto.CRYPTOERR_OK)
        {
            return t.disconnect(msg.reason_key_exchange_failed, "no shared secret");
        }
        // What we answer with: the ML-KEM ciphertext, then our X25519
        // share; or the share alone.
        var server_bytes: [crypto.MLKEM768_CIPHERTEXT + 32]u8 = undefined;
        var server_blob: []const u8 = &public;
        var kem_secret: [crypto.KEM_SECRET]u8 = undefined;
        defer transport_file.wipe(&kem_secret);
        if (t.hybrid) {
            if (cb.Encapsulate(crypto.KEM_MLKEM768, &crypto.Bytes.of(client_blob[0..crypto.MLKEM768_PUBLIC]), &server_bytes, &kem_secret) != crypto.CRYPTOERR_OK) {
                return t.disconnect(msg.reason_key_exchange_failed, "bad ML-KEM key");
            }
            server_bytes[crypto.MLKEM768_CIPHERTEXT..].* = public;
            server_blob = &server_bytes;
        }
        var shared_bytes: [37]u8 = undefined;
        defer transport_file.wipe(&shared_bytes);
        var shared = Writer{ .bytes = &shared_bytes };
        t.encodeShared(if (t.hybrid) &kem_secret else null, &secret, &shared);

        const host_blob = ssh_keys.blob(&conn.host_public);
        const exchange_hash = t.exchangeHash(&host_blob, client_blob, server_blob, shared.written());
        var signature: [crypto.SIGNATURE_ED25519]u8 = undefined;
        if (cb.Sign(crypto.SIG_ED25519, &conn.host_seed, &crypto.Bytes.of(&exchange_hash), &signature) != crypto.CRYPTOERR_OK) {
            return t.disconnect(msg.reason_key_exchange_failed, "cannot sign");
        }
        var reply_bytes: [1400]u8 = undefined;
        var reply = Writer{ .bytes = &reply_bytes };
        reply.byte(msg.msg_kex_ecdh_reply);
        reply.string(&host_blob);
        reply.string(server_blob);
        var signature_blob_bytes: [4 + 11 + 4 + 64]u8 = undefined;
        var signature_blob = Writer{ .bytes = &signature_blob_bytes };
        signature_blob.string(ssh_keys.key_type);
        signature_blob.string(&signature);
        reply.string(signature_blob.written());
        t.send(reply.written());
        t.newKeys(shared.written(), &exchange_hash);
    }

    // --- the login ---------------------------------------------------------

    fn serviceRequest(conn: *Connection, reader: *Reader) void {
        const t = &conn.transport;
        const service = reader.string();
        if (!t.exchanged or reader.bad or !wire.same(service, "ssh-userauth")) {
            return t.disconnect(msg.reason_service_not_available, "service not available");
        }
        conn.service_accepted = true;
        var bytes: [32]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(msg.msg_service_accept);
        writer.string(service);
        t.send(writer.written());
    }

    fn methods(conn: *const Connection) []const u8 {
        if (conn.key_count > 0 and conn.password_length > 0) return "publickey,password";
        if (conn.key_count > 0) return "publickey";
        return "password";
    }

    fn failure(conn: *Connection, counts: bool) void {
        const t = &conn.transport;
        if (counts) {
            conn.failures += 1;
            if (conn.failures >= tries_max) return t.disconnect(msg.reason_no_more_auth_methods, "too many tries");
        }
        var bytes: [64]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(msg.msg_userauth_failure);
        writer.string(conn.methods());
        writer.boolean(false);
        t.send(writer.written());
    }

    fn userauth(conn: *Connection, reader: *Reader) void {
        const t = &conn.transport;
        // Asked again once in: no answer (RFC 4252, 5.1).
        if (conn.authenticated) return;
        if (!conn.service_accepted) return t.disconnect(msg.reason_protocol_error, "no ssh-userauth");
        const user = reader.string();
        const service = reader.string();
        const method = reader.string();
        if (reader.bad or user.len >= conn.user.len) return conn.failure(true);
        if (!wire.same(service, "ssh-connection")) return t.disconnect(msg.reason_service_not_available, "service not available");
        if (wire.same(method, "password")) {
            const change = reader.boolean();
            const given = reader.string();
            if (reader.bad or change or conn.password_length == 0) return conn.failure(true);
            if (!sameSecret(given, conn.password[0..conn.password_length])) return conn.failure(true);
            return conn.success(user);
        }
        if (wire.same(method, "publickey")) {
            const signed = reader.boolean();
            const algorithm = reader.string();
            const key_blob = reader.string();
            if (reader.bad or !wire.same(algorithm, ssh_keys.key_type)) return conn.failure(signed);
            const key = ssh_keys.fromBlob(key_blob) orelse return conn.failure(signed);
            if (!conn.allowed(&key)) return conn.failure(signed);
            if (!signed) {
                // Asked whether the key would do: it would.
                var bytes: [128]u8 = undefined;
                var writer = Writer{ .bytes = &bytes };
                writer.byte(msg.msg_userauth_pk_ok);
                writer.string(algorithm);
                writer.string(key_blob);
                return t.send(writer.written());
            }
            var signature_reader = Reader{ .bytes = reader.string() };
            const signature_type = signature_reader.string();
            const signature = signature_reader.string();
            if (reader.bad or signature_reader.bad or !wire.same(signature_type, ssh_keys.key_type) or signature.len != 64) {
                return conn.failure(true);
            }
            var data_bytes: [512]u8 = undefined;
            const data = signedData(&data_bytes, &t.session_id, user, &key) orelse return conn.failure(true);
            const public_key: crypto.PublicKey = .{ .point = crypto.Bytes.of(&key) };
            if (t.cb.VerifySignature(crypto.SIG_ED25519, &public_key, &crypto.Bytes.of(data), &crypto.Bytes.of(signature)) != crypto.CRYPTOERR_OK) {
                return conn.failure(true);
            }
            return conn.success(user);
        }
        // "none", and every method this end does not have.
        conn.failure(false);
    }

    fn allowed(conn: *const Connection, key: *const [32]u8) bool {
        for (conn.keys[0..conn.key_count]) |*held| {
            if (wire.same(held, key)) return true;
        }
        return false;
    }

    fn success(conn: *Connection, user: []const u8) void {
        conn.authenticated = true;
        @memcpy(conn.user[0..user.len], user);
        conn.user[user.len] = 0;
        conn.transport.send(&.{msg.msg_userauth_success});
    }

    // --- the channel -------------------------------------------------------

    fn channelMessage(conn: *Connection, kind: u8, reader: *Reader) void {
        const t = &conn.transport;
        if (kind == msg.msg_channel_open) return conn.channelOpen(reader);
        const recipient = reader.uint32();
        if (reader.bad or !conn.channel.open or recipient != 0) return t.disconnect(msg.reason_protocol_error, "no such channel");
        if (conn.channel.handle(t, kind, reader)) return;
        if (kind == msg.msg_channel_request) conn.channelRequest(reader);
    }

    fn channelOpen(conn: *Connection, reader: *Reader) void {
        const t = &conn.transport;
        const channel_type = reader.string();
        const sender = reader.uint32();
        const window = reader.uint32();
        const max_packet = reader.uint32();
        if (reader.bad) return t.disconnect(msg.reason_protocol_error, "bad CHANNEL_OPEN");
        var bytes: [64]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        if (!wire.same(channel_type, "session") or conn.channel.open) {
            writer.byte(msg.msg_channel_open_failure);
            writer.uint32(sender);
            // Administratively prohibited; resource shortage for a second
            // session.
            writer.uint32(if (conn.channel.open) 4 else 1);
            writer.string("");
            writer.string("");
            return t.send(writer.written());
        }
        conn.channel.opened(sender, window, max_packet);
        writer.byte(msg.msg_channel_open_confirmation);
        writer.uint32(sender);
        writer.uint32(0);
        writer.uint32(channel_file.ring_bytes);
        writer.uint32(channel_file.our_max_packet);
        t.send(writer.written());
    }

    fn channelRequest(conn: *Connection, reader: *Reader) void {
        const t = &conn.transport;
        const request = reader.string();
        const want_reply = reader.boolean();
        if (reader.bad) return t.disconnect(msg.reason_protocol_error, "bad CHANNEL_REQUEST");
        var ok = false;
        if (wire.same(request, "pty-req")) {
            const terminal = reader.string();
            const columns = reader.uint32();
            const rows = reader.uint32();
            if (!reader.bad) {
                const length = @min(terminal.len, conn.terminal.len - 1);
                @memcpy(conn.terminal[0..length], terminal[0..length]);
                conn.terminal[length] = 0;
                conn.columns = columns;
                conn.rows = rows;
                ok = true;
            }
        } else if (wire.same(request, "window-change")) {
            const columns = reader.uint32();
            const rows = reader.uint32();
            if (!reader.bad) {
                conn.columns = columns;
                conn.rows = rows;
            }
            return;
        } else if (wire.same(request, "shell") and !conn.session_ready) {
            conn.kind = ssh.SSHSESSION_SHELL;
            conn.session_ready = true;
            ok = true;
        } else if (wire.same(request, "exec") and !conn.session_ready) {
            const command = reader.string();
            if (!reader.bad and command.len < conn.command.len) {
                @memcpy(conn.command[0..command.len], command);
                conn.command[command.len] = 0;
                conn.kind = ssh.SSHSESSION_EXEC;
                conn.session_ready = true;
                ok = true;
            }
        } else if (wire.same(request, "signal")) {
            const name = reader.string();
            if (!reader.bad and wire.same(name, "INT")) {
                conn.channel.pushByte(3);
                ok = true;
            }
        } else if (wire.same(request, "break")) {
            conn.channel.pushByte(3);
            ok = true;
        }
        if (want_reply) conn.channel.reply(t, if (ok) msg.msg_channel_success else msg.msg_channel_failure);
    }

    // --- the unit's side ---------------------------------------------------

    /// What the client sent, into `into`: how many bytes.
    pub fn read(conn: *Connection, into: []u8) usize {
        return conn.channel.read(&conn.transport, into);
    }

    /// `data` to the client, as much as its window, its packet size and
    /// the output take: how many bytes.
    pub fn write(conn: *Connection, data: []const u8) usize {
        return conn.channel.write(&conn.transport, data);
    }

    /// Whether the client's input has ended: it sent its end, or went.
    pub fn inputEnded(conn: *const Connection) bool {
        return conn.channel.inputEnded(&conn.transport);
    }

    /// The session over: its exit status told, the channel ended and
    /// closed.
    pub fn exit(conn: *Connection, status: u32) void {
        const t = &conn.transport;
        if (t.phase != .packets or !conn.channel.open or conn.channel.closed) return;
        var bytes: [32]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(msg.msg_channel_request);
        writer.uint32(conn.channel.peer_channel);
        writer.string("exit-status");
        writer.boolean(false);
        writer.uint32(status);
        t.send(writer.written());
        conn.channel.endOutput(t);
        conn.channel.close(t);
    }
};

/// What a `publickey` login signs (RFC 4252, 7): the session id, then the
/// request itself up to its signature. Null when `bytes` is too small.
pub fn signedData(bytes: []u8, session_id: *const [32]u8, user: []const u8, key: *const [32]u8) ?[]const u8 {
    var data = Writer{ .bytes = bytes };
    data.string(session_id);
    data.byte(msg.msg_userauth_request);
    data.string(user);
    data.string("ssh-connection");
    data.string("publickey");
    data.boolean(true);
    data.string(ssh_keys.key_type);
    data.string(&ssh_keys.blob(key));
    if (data.full) return null;
    return data.written();
}

/// Two secrets compared in a time that does not tell where they differ.
fn sameSecret(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var difference: u8 = 0;
    for (a, b) |x, y| difference |= x ^ y;
    return difference == 0;
}

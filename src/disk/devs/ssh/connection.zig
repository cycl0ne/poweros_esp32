// SPDX-License-Identifier: MIT
//! One SSH connection, the server's end, as a machine that takes bytes in
//! and gives bytes out (it touches no socket: the unit's task does that,
//! and the tests play a client against it): the transport (RFC 4253),
//! the login (RFC 4252) and one session channel (RFC 4254).
//!
//! **The transport.** The version lines first, each end's sent at once;
//! then packets, each its length, a padding length, the message and at
//! least four bytes of random padding. The key exchange is
//! curve25519-sha256 (RFC 8731): the exchange hash H over both version
//! lines, both KEXINIT messages, the host key, both X25519 shares and the
//! shared secret K; H signed with the Ed25519 host key; the first H the
//! session id; each direction's key and nonce made from K, H, a letter and
//! the session id (RFC 4253, 7.2). From NEWKEYS on, packets are sealed
//! with AES-GCM (RFC 5647): the length stays in clear and is
//! authenticated, the rest is encrypted, a 16-byte tag follows, and the
//! nonce's last eight bytes count the packets. With OpenSSH's strict key
//! exchange (the client's `kex-strict-c-v00@openssh.com`), the first
//! exchange takes nothing but its own messages, and the sequence numbers
//! start again at each NEWKEYS. The client may exchange keys again at any
//! time; nothing but the exchange goes out while it runs.
//!
//! **The login**: `ssh-userauth`, then requests until one succeeds -
//! `password` against the password given, or `publickey` with an Ed25519
//! key among those given, asked about first (PK_OK) and then signed over
//! the session id and the request. Six failures end the connection.
//!
//! **The channel**: one `session` channel; `pty-req` (the terminal's type
//! and size), `env` (refused), then `shell` or `exec` (a command), which
//! is when the session is ready. What the client sends goes into a ring
//! of `ring_bytes`, which is the window the client is given; reading from
//! it gives the window back in halves. What goes to the client keeps to
//! the window and the packet size it gave. `signal` INT and `break` come
//! as Ctrl-C. At the end: `exit-status`, EOF and CLOSE.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const ssh = sdk.devices.ssh;
const ssh_keys = sdk.devices.ssh.keys;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const wire = @import("wire.zig");
const Reader = wire.Reader;
const Writer = wire.Writer;

/// This end's version line, without its CR LF.
pub const version = "SSH-2.0-PowerOS_1.0";

// Message numbers.
pub const msg_disconnect: u8 = 1;
pub const msg_ignore: u8 = 2;
pub const msg_unimplemented: u8 = 3;
pub const msg_debug: u8 = 4;
pub const msg_service_request: u8 = 5;
pub const msg_service_accept: u8 = 6;
pub const msg_kexinit: u8 = 20;
pub const msg_newkeys: u8 = 21;
pub const msg_kex_ecdh_init: u8 = 30;
pub const msg_kex_ecdh_reply: u8 = 31;
pub const msg_userauth_request: u8 = 50;
pub const msg_userauth_failure: u8 = 51;
pub const msg_userauth_success: u8 = 52;
pub const msg_userauth_pk_ok: u8 = 60;
pub const msg_global_request: u8 = 80;
pub const msg_request_failure: u8 = 82;
pub const msg_channel_open: u8 = 90;
pub const msg_channel_open_confirmation: u8 = 91;
pub const msg_channel_open_failure: u8 = 92;
pub const msg_channel_window_adjust: u8 = 93;
pub const msg_channel_data: u8 = 94;
pub const msg_channel_extended_data: u8 = 95;
pub const msg_channel_eof: u8 = 96;
pub const msg_channel_close: u8 = 97;
pub const msg_channel_request: u8 = 98;
pub const msg_channel_success: u8 = 99;
pub const msg_channel_failure: u8 = 100;

// Disconnect reasons.
pub const reason_protocol_error: u32 = 2;
pub const reason_key_exchange_failed: u32 = 3;
pub const reason_mac_error: u32 = 5;
pub const reason_service_not_available: u32 = 7;
pub const reason_protocol_version: u32 = 8;
pub const reason_by_application: u32 = 11;
pub const reason_no_more_auth_methods: u32 = 14;

/// What this end offers: the key exchanges, and among them the mark that
/// it does the strict exchange.
pub const kex_names = "curve25519-sha256,curve25519-sha256@libssh.org";
pub const kex_algorithms = kex_names ++ ",kex-strict-s-v00@openssh.com";
pub const host_key_algorithms = ssh_keys.key_type;
pub const ciphers = "aes256-gcm@openssh.com,aes128-gcm@openssh.com";
/// Never used - an AEAD cipher brings its own - but a list must be there.
pub const macs = "hmac-sha2-256";
pub const compressions = "none";
const strict_client = "kex-strict-c-v00@openssh.com";

/// The longest packet taken: its length field's value, RFC 4253's least
/// every end takes.
pub const packet_max: u32 = 35000;
const tag_bytes = crypto.GCM_TAG;
pub const in_bytes = 4 + packet_max + tag_bytes;
pub const out_bytes = 16384;
/// The window the client is given, and the most data one packet of it
/// may carry.
pub const ring_bytes = 16384;
pub const our_max_packet: u32 = 8192;
/// The most data one packet to the client carries.
const data_max: u32 = 4096;
/// Room a reply needs in the output before another packet is taken in.
const reply_room = 1024;
/// Failed logins before the connection ends.
pub const tries_max = 6;
/// The longest version line, CR LF included.
const version_max = 255;

pub const Phase = enum(u8) { version, packets, ended };

/// One direction's cipher: off until its NEWKEYS, then AES-GCM with this
/// key and a nonce whose last eight bytes count the packets.
pub const Direction = struct {
    on: bool = false,
    key: [32]u8 = @splat(0),
    key_length: u32 = 0,
    nonce: [12]u8 = @splat(0),

    fn advance(direction: *Direction) void {
        var at: usize = 12;
        while (at > 4) {
            at -= 1;
            direction.nonce[at] +%= 1;
            if (direction.nonce[at] != 0) break;
        }
    }
};

const KexState = enum(u8) { idle, sent, exchanging, finishing };

pub const Connection = struct {
    cb: *CryptoBase,
    phase: Phase = .version,
    /// Why it ended, for the log.
    reason: u32 = 0,

    /// What came in and is not taken yet, and what is to go out.
    in: [in_bytes]u8 = undefined,
    in_length: usize = 0,
    out: [out_bytes]u8 = undefined,
    out_length: usize = 0,
    receive_sequence: u32 = 0,
    send_sequence: u32 = 0,
    receiving: Direction = .{},
    sending: Direction = .{},

    // --- the key exchange --------------------------------------------------

    client_version: [version_max]u8 = undefined,
    client_version_length: usize = 0,
    kex: KexState = .idle,
    /// Our KEXINIT's message, which H takes.
    our_kexinit: [512]u8 = undefined,
    our_kexinit_length: usize = 0,
    /// H under way, from both KEXINITs on.
    exchange: crypto.HashContext = .{},
    /// The key length the KEXINITs chose for what we send.
    sending_key_length: u32 = 32,
    strict: bool = false,
    /// The first exchange is done; the next packet from a wrong guess is
    /// to be dropped.
    exchanged: bool = false,
    skip_guess: bool = false,
    session_id: [32]u8 = @splat(0),
    /// The keys the client's NEWKEYS turns on.
    next_receiving: Direction = .{},

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

    // --- the channel -------------------------------------------------------

    channel_open: bool = false,
    peer_channel: u32 = 0,
    peer_window: u32 = 0,
    peer_max_packet: u32 = 0,
    /// The client sent its end; it closed the channel; we closed it.
    input_ended: bool = false,
    peer_closed: bool = false,
    closed: bool = false,
    session_ready: bool = false,
    kind: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    terminal: [32]u8 = @splat(0),
    command: [512]u8 = @splat(0),
    /// What the client sent, and what of the window is read but not given
    /// back yet.
    ring: [ring_bytes]u8 = undefined,
    ring_start: usize = 0,
    ring_length: usize = 0,
    unacknowledged: u32 = 0,
    window_left: u32 = ring_bytes,

    /// The connection ready: the credentials taken, and our version line
    /// and first KEXINIT queued.
    pub fn start(conn: *Connection, accept: *const ssh.SshAccept) void {
        conn.host_seed = accept.host_seed;
        conn.host_public = accept.host_public;
        conn.password_length = @min(accept.password_length, ssh.SSH_PASSWORD_MAX);
        @memcpy(conn.password[0..conn.password_length], accept.password[0..conn.password_length]);
        conn.key_count = @min(accept.key_count, ssh.SSH_KEYS_MAX);
        for (0..conn.key_count) |index| conn.keys[index] = accept.keys[index];
        conn.queueRaw(version ++ "\r\n");
        conn.sendKexinit();
    }

    pub fn ended(conn: *const Connection) bool {
        return conn.phase == .ended;
    }

    /// What is to go out, and that so much of it went.
    pub fn pending(conn: *const Connection) []const u8 {
        return conn.out[0..conn.out_length];
    }

    pub fn sent(conn: *Connection, count: usize) void {
        const rest = conn.out_length - count;
        if (rest > 0) copyDown(&conn.out, count, rest);
        conn.out_length = rest;
    }

    /// Room for bytes from the client.
    pub fn inRoom(conn: *const Connection) usize {
        return conn.in.len - conn.in_length;
    }

    /// Bytes from the client, no more than `inRoom`; taken by `process`.
    pub fn feed(conn: *Connection, bytes: []const u8) void {
        const count = @min(bytes.len, conn.inRoom());
        @memcpy(conn.in[conn.in_length..][0..count], bytes[0..count]);
        conn.in_length += count;
    }

    /// Whether `process` has work: a packet may be whole and there is
    /// room for its answer.
    pub fn processable(conn: *const Connection) bool {
        return conn.phase != .ended and conn.in_length > 0 and conn.out.len - conn.out_length >= reply_room;
    }

    /// Everything whole that came in, taken, while there is room for
    /// what it answers.
    pub fn process(conn: *Connection) void {
        if (conn.phase == .version) conn.versionLine();
        while (conn.phase == .packets and conn.out.len - conn.out_length >= reply_room) {
            if (!conn.nextPacket()) return;
        }
    }

    // --- the version line --------------------------------------------------

    fn versionLine(conn: *Connection) void {
        const length = @min(conn.in_length, version_max);
        const line_end = for (conn.in[0..length], 0..) |byte, index| {
            if (byte == '\n') break index;
        } else {
            if (conn.in_length >= version_max) conn.end(reason_protocol_version);
            return;
        };
        var line = conn.in[0..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (!startsWith(line, "SSH-2.0-") and !startsWith(line, "SSH-1.99-")) {
            conn.queueRaw("Protocol mismatch.\r\n");
            return conn.end(reason_protocol_version);
        }
        @memcpy(conn.client_version[0..line.len], line);
        conn.client_version_length = line.len;
        conn.take(line_end + 1);
        conn.phase = .packets;
    }

    // --- packets in --------------------------------------------------------

    /// The next whole packet opened and handled: false when there is none.
    fn nextPacket(conn: *Connection) bool {
        if (conn.in_length < 4) return false;
        const length = wire.get32(conn.in[0..4]);
        const sealed = conn.receiving.on;
        const block: u32 = if (sealed) 16 else 8;
        // Encrypted, the length is not part of the blocks.
        const aligned = if (sealed) length else length + 4;
        if (length < 5 or length > packet_max or aligned % block != 0) {
            conn.disconnect(reason_protocol_error, "bad packet length");
            return false;
        }
        const total: usize = 4 + length + (if (sealed) tag_bytes else 0);
        if (conn.in_length < total) return false;
        if (sealed) {
            const body = conn.in[4..][0..length];
            const message: crypto.GcmMessage = .{
                .key = &conn.receiving.key,
                .key_length = conn.receiving.key_length,
                .nonce = &conn.receiving.nonce,
                .nonce_length = 12,
                .aad = conn.in[0..4].ptr,
                .aad_length = 4,
                .input = body.ptr,
                .output = body.ptr,
                .length = length,
                .tag = conn.in[4 + length ..][0..tag_bytes],
            };
            if (conn.cb.OpenGcm(&message) != crypto.CRYPTOERR_OK) {
                conn.disconnect(reason_mac_error, "packet authentication failed");
                return false;
            }
            conn.receiving.advance();
        }
        const padding = conn.in[4];
        if (@as(u32, padding) + 1 > length or padding < 4) {
            conn.disconnect(reason_protocol_error, "bad padding");
            return false;
        }
        const payload = conn.in[5 .. 4 + length - padding];
        const sequence = conn.receive_sequence;
        conn.receive_sequence +%= 1;
        if (payload.len > 0) conn.handle(payload, sequence);
        // The handler may have ended the connection, but never moved the
        // input.
        conn.take(total);
        return conn.phase == .packets;
    }

    fn handle(conn: *Connection, payload: []const u8, sequence: u32) void {
        const kind = payload[0];
        var reader = Reader{ .bytes = payload, .at = 1 };
        // The first exchange, strict: its own messages only.
        if (conn.strict and !conn.exchanged and kind != msg_kexinit and kind != msg_kex_ecdh_init and kind != msg_newkeys) {
            return conn.disconnect(reason_protocol_error, "unexpected message during key exchange");
        }
        switch (kind) {
            msg_disconnect => conn.end(reason_by_application),
            msg_ignore, msg_debug, msg_unimplemented => {},
            msg_kexinit => conn.kexinit(payload, sequence),
            msg_kex_ecdh_init => conn.ecdhInit(&reader),
            msg_newkeys => conn.newkeys(),
            msg_service_request => conn.serviceRequest(&reader),
            msg_userauth_request => conn.userauth(&reader),
            msg_global_request => {
                _ = reader.string();
                if (reader.boolean() and !reader.bad) conn.sendMessage(&.{msg_request_failure});
            },
            msg_channel_open...msg_channel_failure => {
                if (!conn.authenticated) return conn.disconnect(reason_protocol_error, "not logged in");
                conn.channelMessage(kind, &reader);
            },
            else => {
                var reply: [5]u8 = undefined;
                reply[0] = msg_unimplemented;
                wire.put32(reply[1..5], sequence);
                conn.sendMessage(&reply);
            },
        }
    }

    // --- packets out -------------------------------------------------------

    fn queueRaw(conn: *Connection, bytes: []const u8) void {
        if (conn.out.len - conn.out_length < bytes.len) return conn.end(reason_protocol_error);
        @memcpy(conn.out[conn.out_length..][0..bytes.len], bytes);
        conn.out_length += bytes.len;
    }

    /// `payload` as a packet: padded, and sealed once our NEWKEYS is sent.
    pub fn sendMessage(conn: *Connection, payload: []const u8) void {
        if (conn.phase == .ended) return;
        const sealed = conn.sending.on;
        const block: usize = if (sealed) 16 else 8;
        const counted: usize = if (sealed) 1 + payload.len else 4 + 1 + payload.len;
        var padding = block - counted % block;
        if (padding < 4) padding += block;
        const length = 1 + payload.len + padding;
        const total = 4 + length + (if (sealed) tag_bytes else 0);
        if (conn.out.len - conn.out_length < total) return conn.end(reason_protocol_error);
        const packet = conn.out[conn.out_length..][0..total];
        wire.put32(packet[0..4], @intCast(length));
        packet[4] = @intCast(padding);
        @memcpy(packet[5..][0..payload.len], payload);
        conn.cb.RandomBytes(packet[5 + payload.len ..].ptr, @intCast(padding));
        if (sealed) {
            const message: crypto.GcmMessage = .{
                .key = &conn.sending.key,
                .key_length = conn.sending.key_length,
                .nonce = &conn.sending.nonce,
                .nonce_length = 12,
                .aad = packet[0..4].ptr,
                .aad_length = 4,
                .input = packet[4..].ptr,
                .output = packet[4..].ptr,
                .length = @intCast(length),
                .tag = packet[4 + length ..][0..tag_bytes],
            };
            _ = conn.cb.SealGcm(&message);
            conn.sending.advance();
        }
        conn.out_length += total;
        conn.send_sequence +%= 1;
    }

    /// DISCONNECT sent with `text`, and the end.
    pub fn disconnect(conn: *Connection, reason: u32, text: []const u8) void {
        if (conn.phase == .ended) return;
        var bytes: [128]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(msg_disconnect);
        writer.uint32(reason);
        writer.string(text[0..@min(text.len, 100)]);
        writer.string("");
        if (conn.phase == .packets) conn.sendMessage(writer.written());
        conn.end(reason);
    }

    /// The connection lost under the protocol: the client went, or the
    /// socket failed. Nothing more is said.
    pub fn lose(conn: *Connection) void {
        if (conn.phase != .ended) conn.end(reason_by_application);
    }

    fn end(conn: *Connection, reason: u32) void {
        conn.phase = .ended;
        conn.reason = reason;
        conn.input_ended = true;
        conn.peer_closed = true;
    }

    /// The first `count` bytes of the input dropped.
    fn take(conn: *Connection, count: usize) void {
        const rest = conn.in_length - count;
        if (rest > 0) copyDown(&conn.in, count, rest);
        conn.in_length = rest;
    }

    // --- the key exchange --------------------------------------------------

    fn sendKexinit(conn: *Connection) void {
        var writer = Writer{ .bytes = &conn.our_kexinit };
        writer.byte(msg_kexinit);
        var cookie: [16]u8 = undefined;
        conn.cb.RandomBytes(&cookie, cookie.len);
        writer.raw(&cookie);
        writer.string(kex_algorithms);
        writer.string(host_key_algorithms);
        writer.string(ciphers);
        writer.string(ciphers);
        writer.string(macs);
        writer.string(macs);
        writer.string(compressions);
        writer.string(compressions);
        writer.string("");
        writer.string("");
        writer.boolean(false);
        writer.uint32(0);
        conn.our_kexinit_length = writer.at;
        conn.kex = .sent;
        conn.sendMessage(writer.written());
    }

    fn hashString(conn: *Connection, bytes: []const u8) void {
        var length: [4]u8 = undefined;
        wire.put32(&length, @intCast(bytes.len));
        conn.cb.UpdateHash(&conn.exchange, &length, 4);
        conn.cb.UpdateHash(&conn.exchange, bytes.ptr, @intCast(bytes.len));
    }

    /// The client's KEXINIT: the algorithms chosen, ours sent if the
    /// client began this exchange, and H begun.
    fn kexinit(conn: *Connection, payload: []const u8, sequence: u32) void {
        if (conn.kex == .exchanging or conn.kex == .finishing) {
            return conn.disconnect(reason_protocol_error, "KEXINIT during a key exchange");
        }
        var reader = Reader{ .bytes = payload, .at = 17 };
        const kex_list = reader.string();
        const host_key_list = reader.string();
        const ciphers_in = reader.string();
        const ciphers_out = reader.string();
        _ = reader.string();
        _ = reader.string();
        const compression_in = reader.string();
        const compression_out = reader.string();
        _ = reader.string();
        _ = reader.string();
        const guessed = reader.boolean();
        _ = reader.uint32();
        if (reader.bad) return conn.disconnect(reason_protocol_error, "bad KEXINIT");
        if (!conn.exchanged) {
            conn.strict = wire.hasName(kex_list, strict_client);
            // Strict: the client's KEXINIT is its first packet.
            if (conn.strict and sequence != 0) return conn.disconnect(reason_protocol_error, "KEXINIT not first");
        }
        const kex_name = wire.choose(kex_list, kex_names);
        const cipher_in = wire.choose(ciphers_in, ciphers);
        const cipher_out = wire.choose(ciphers_out, ciphers);
        if (kex_name == null or !wire.hasName(host_key_list, host_key_algorithms) or cipher_in == null or cipher_out == null or
            !wire.hasName(compression_in, compressions) or !wire.hasName(compression_out, compressions))
        {
            return conn.disconnect(reason_key_exchange_failed, "no algorithms in common");
        }
        conn.next_receiving.key_length = if (wire.same(cipher_in.?, "aes256-gcm@openssh.com")) 32 else 16;
        conn.sending_key_length = if (wire.same(cipher_out.?, "aes256-gcm@openssh.com")) 32 else 16;
        conn.skip_guess = guessed and (!wire.same(wire.first(kex_list), kex_name.?) or !wire.same(wire.first(host_key_list), host_key_algorithms));
        if (conn.kex == .idle) conn.sendKexinit();
        _ = conn.cb.InitHash(&conn.exchange, crypto.HASH_SHA256);
        conn.hashString(conn.client_version[0..conn.client_version_length]);
        conn.hashString(version);
        conn.hashString(payload);
        conn.hashString(conn.our_kexinit[0..conn.our_kexinit_length]);
        conn.kex = .exchanging;
    }

    /// The client's share: ours made, K and H, H signed, the reply and
    /// NEWKEYS sent, and our direction's keys on.
    fn ecdhInit(conn: *Connection, reader: *Reader) void {
        if (conn.kex != .exchanging) return conn.disconnect(reason_protocol_error, "unexpected KEX_ECDH_INIT");
        const client_share = reader.string();
        if (conn.skip_guess) {
            conn.skip_guess = false;
            return;
        }
        if (reader.bad or client_share.len != 32) return conn.disconnect(reason_key_exchange_failed, "bad share");
        const cb = conn.cb;
        var private: [32]u8 = undefined;
        var public: [32]u8 = undefined;
        var public_length: u32 = 32;
        defer @memset(&private, 0);
        var secret: [32]u8 = undefined;
        defer @memset(&secret, 0);
        if (cb.MakeKeyPair(crypto.CURVE_X25519, &private, &public, &public_length) != crypto.CRYPTOERR_OK or
            cb.SharedSecret(crypto.CURVE_X25519, &private, &crypto.Bytes.of(client_share), &secret) != crypto.CRYPTOERR_OK)
        {
            return conn.disconnect(reason_key_exchange_failed, "no shared secret");
        }
        var shared_bytes: [37]u8 = undefined;
        var shared = Writer{ .bytes = &shared_bytes };
        shared.mpint(&secret);
        defer @memset(&shared_bytes, 0);

        const host_blob = ssh_keys.blob(&conn.host_public);
        conn.hashString(&host_blob);
        conn.hashString(client_share);
        conn.hashString(&public);
        cb.UpdateHash(&conn.exchange, shared.written().ptr, @intCast(shared.at));
        var exchange_hash: [32]u8 = undefined;
        _ = cb.FinishHash(&conn.exchange, &exchange_hash);
        if (!conn.exchanged) conn.session_id = exchange_hash;

        var signature: [crypto.SIGNATURE_ED25519]u8 = undefined;
        if (cb.Sign(crypto.SIG_ED25519, &conn.host_seed, &crypto.Bytes.of(&exchange_hash), &signature) != crypto.CRYPTOERR_OK) {
            return conn.disconnect(reason_key_exchange_failed, "cannot sign");
        }
        var reply_bytes: [256]u8 = undefined;
        var reply = Writer{ .bytes = &reply_bytes };
        reply.byte(msg_kex_ecdh_reply);
        reply.string(&host_blob);
        reply.string(&public);
        var signature_blob_bytes: [4 + 11 + 4 + 64]u8 = undefined;
        var signature_blob = Writer{ .bytes = &signature_blob_bytes };
        signature_blob.string(ssh_keys.key_type);
        signature_blob.string(&signature);
        reply.string(signature_blob.written());
        conn.sendMessage(reply.written());

        // The keys: client to server nonce A and key C, server to client
        // nonce B and key D.
        conn.next_receiving.on = true;
        conn.derive(shared.written(), &exchange_hash, 'A', &conn.next_receiving.nonce);
        var key: [32]u8 = undefined;
        conn.derive(shared.written(), &exchange_hash, 'C', &key);
        conn.next_receiving.key = key;
        var sending: Direction = .{ .on = true, .key_length = conn.sending_key_length };
        conn.derive(shared.written(), &exchange_hash, 'B', &sending.nonce);
        conn.derive(shared.written(), &exchange_hash, 'D', &key);
        sending.key = key;
        @memset(&key, 0);
        conn.sendMessage(&.{msg_newkeys});
        conn.sending = sending;
        if (conn.strict) conn.send_sequence = 0;
        conn.kex = .finishing;
    }

    /// RFC 4253, 7.2: HASH(K || H || letter || session_id), as many bytes
    /// of it as `into` holds (no key here is longer than one SHA-256).
    fn derive(conn: *Connection, shared_mpint: []const u8, exchange_hash: *const [32]u8, letter: u8, into: []u8) void {
        var context: crypto.HashContext = .{};
        _ = conn.cb.InitHash(&context, crypto.HASH_SHA256);
        conn.cb.UpdateHash(&context, shared_mpint.ptr, @intCast(shared_mpint.len));
        conn.cb.UpdateHash(&context, exchange_hash, 32);
        conn.cb.UpdateHash(&context, &letter, 1);
        conn.cb.UpdateHash(&context, &conn.session_id, 32);
        var digest: [32]u8 = undefined;
        _ = conn.cb.FinishHash(&context, &digest);
        @memcpy(into, digest[0..into.len]);
    }

    /// The client's NEWKEYS: its direction's keys on, the exchange done.
    fn newkeys(conn: *Connection) void {
        if (conn.kex != .finishing) return conn.disconnect(reason_protocol_error, "unexpected NEWKEYS");
        conn.receiving = conn.next_receiving;
        conn.next_receiving = .{};
        if (conn.strict) conn.receive_sequence = 0;
        conn.kex = .idle;
        conn.exchanged = true;
        // The window held back while the keys changed.
        conn.acknowledge(false);
    }

    // --- the login ---------------------------------------------------------

    fn serviceRequest(conn: *Connection, reader: *Reader) void {
        const service = reader.string();
        if (!conn.exchanged or reader.bad or !wire.same(service, "ssh-userauth")) {
            return conn.disconnect(reason_service_not_available, "service not available");
        }
        conn.service_accepted = true;
        var bytes: [32]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(msg_service_accept);
        writer.string(service);
        conn.sendMessage(writer.written());
    }

    fn methods(conn: *const Connection) []const u8 {
        if (conn.key_count > 0 and conn.password_length > 0) return "publickey,password";
        if (conn.key_count > 0) return "publickey";
        return "password";
    }

    fn failure(conn: *Connection, counts: bool) void {
        if (counts) {
            conn.failures += 1;
            if (conn.failures >= tries_max) return conn.disconnect(reason_no_more_auth_methods, "too many tries");
        }
        var bytes: [64]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(msg_userauth_failure);
        writer.string(conn.methods());
        writer.boolean(false);
        conn.sendMessage(writer.written());
    }

    fn userauth(conn: *Connection, reader: *Reader) void {
        // Asked again once in: no answer (RFC 4252, 5.1).
        if (conn.authenticated) return;
        if (!conn.service_accepted) return conn.disconnect(reason_protocol_error, "no ssh-userauth");
        const user = reader.string();
        const service = reader.string();
        const method = reader.string();
        if (reader.bad or user.len >= conn.user.len) return conn.failure(true);
        if (!wire.same(service, "ssh-connection")) return conn.disconnect(reason_service_not_available, "service not available");
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
                writer.byte(msg_userauth_pk_ok);
                writer.string(algorithm);
                writer.string(key_blob);
                return conn.sendMessage(writer.written());
            }
            var signature_reader = Reader{ .bytes = reader.string() };
            const signature_type = signature_reader.string();
            const signature = signature_reader.string();
            if (reader.bad or signature_reader.bad or !wire.same(signature_type, ssh_keys.key_type) or signature.len != 64) {
                return conn.failure(true);
            }
            // What the client signed: the session id, then the request
            // itself up to its signature.
            var data_bytes: [512]u8 = undefined;
            var data = Writer{ .bytes = &data_bytes };
            data.string(&conn.session_id);
            data.byte(msg_userauth_request);
            data.string(user);
            data.string(service);
            data.string(method);
            data.boolean(true);
            data.string(algorithm);
            data.string(key_blob);
            if (data.full) return conn.failure(true);
            const public_key: crypto.PublicKey = .{ .point = crypto.Bytes.of(&key) };
            if (conn.cb.VerifySignature(crypto.SIG_ED25519, &public_key, &crypto.Bytes.of(data.written()), &crypto.Bytes.of(signature)) != crypto.CRYPTOERR_OK) {
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
        conn.sendMessage(&.{msg_userauth_success});
    }

    // --- the channel -------------------------------------------------------

    fn channelMessage(conn: *Connection, kind: u8, reader: *Reader) void {
        if (kind == msg_channel_open) return conn.channelOpen(reader);
        const recipient = reader.uint32();
        if (reader.bad or !conn.channel_open or recipient != 0) return conn.disconnect(reason_protocol_error, "no such channel");
        switch (kind) {
            msg_channel_window_adjust => {
                const more = reader.uint32();
                conn.peer_window +|= more;
            },
            msg_channel_data => {
                const data = reader.string();
                if (reader.bad or data.len > conn.window_left) return conn.disconnect(reason_protocol_error, "past the window");
                conn.window_left -= @intCast(data.len);
                conn.push(data);
            },
            msg_channel_extended_data => {
                _ = reader.uint32();
                const data = reader.string();
                if (reader.bad or data.len > conn.window_left) return conn.disconnect(reason_protocol_error, "past the window");
                // Not read by anyone: the window given back at once.
                conn.unacknowledged += @intCast(data.len);
                conn.window_left -= @intCast(data.len);
                conn.acknowledge(false);
            },
            msg_channel_eof => conn.input_ended = true,
            msg_channel_close => {
                conn.input_ended = true;
                conn.peer_closed = true;
                if (!conn.closed) {
                    conn.closed = true;
                    conn.channelReply(msg_channel_close);
                }
            },
            msg_channel_request => conn.channelRequest(reader),
            else => {},
        }
    }

    fn channelOpen(conn: *Connection, reader: *Reader) void {
        const channel_type = reader.string();
        const sender = reader.uint32();
        const window = reader.uint32();
        const max_packet = reader.uint32();
        if (reader.bad) return conn.disconnect(reason_protocol_error, "bad CHANNEL_OPEN");
        var bytes: [64]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        if (!wire.same(channel_type, "session") or conn.channel_open) {
            writer.byte(msg_channel_open_failure);
            writer.uint32(sender);
            // Administratively prohibited; resource shortage for a second
            // session.
            writer.uint32(if (conn.channel_open) 4 else 1);
            writer.string("");
            writer.string("");
            return conn.sendMessage(writer.written());
        }
        conn.channel_open = true;
        conn.peer_channel = sender;
        conn.peer_window = window;
        conn.peer_max_packet = max_packet;
        writer.byte(msg_channel_open_confirmation);
        writer.uint32(sender);
        writer.uint32(0);
        writer.uint32(ring_bytes);
        writer.uint32(our_max_packet);
        conn.sendMessage(writer.written());
    }

    /// A message about the channel with nothing but the peer's number.
    fn channelReply(conn: *Connection, kind: u8) void {
        var bytes: [5]u8 = undefined;
        bytes[0] = kind;
        wire.put32(bytes[1..5], conn.peer_channel);
        conn.sendMessage(&bytes);
    }

    fn channelRequest(conn: *Connection, reader: *Reader) void {
        const request = reader.string();
        const want_reply = reader.boolean();
        if (reader.bad) return conn.disconnect(reason_protocol_error, "bad CHANNEL_REQUEST");
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
                conn.interrupt();
                ok = true;
            }
        } else if (wire.same(request, "break")) {
            conn.interrupt();
            ok = true;
        }
        if (want_reply) conn.channelReply(if (ok) msg_channel_success else msg_channel_failure);
    }

    /// Ctrl-C in among what the client typed.
    fn interrupt(conn: *Connection) void {
        if (conn.ring_length < conn.ring.len) conn.pushByte(3);
    }

    fn pushByte(conn: *Connection, byte: u8) void {
        conn.ring[(conn.ring_start + conn.ring_length) % conn.ring.len] = byte;
        conn.ring_length += 1;
    }

    fn push(conn: *Connection, data: []const u8) void {
        for (data) |byte| {
            // The window keeps the client within the ring; an interrupt
            // may have taken a byte of it.
            if (conn.ring_length == conn.ring.len) return;
            conn.pushByte(byte);
        }
    }

    /// The window given back when half of it is read - or now, with
    /// `now`.
    fn acknowledge(conn: *Connection, now: bool) void {
        if (conn.unacknowledged == 0 or conn.closed or conn.peer_closed or conn.kex != .idle) return;
        if (!now and conn.unacknowledged < ring_bytes / 2) return;
        var bytes: [9]u8 = undefined;
        bytes[0] = msg_channel_window_adjust;
        wire.put32(bytes[1..5], conn.peer_channel);
        wire.put32(bytes[5..9], conn.unacknowledged);
        conn.sendMessage(&bytes);
        conn.window_left += conn.unacknowledged;
        conn.unacknowledged = 0;
    }

    /// What the client sent, into `into`: how many bytes.
    pub fn read(conn: *Connection, into: []u8) usize {
        const count = @min(into.len, conn.ring_length);
        for (into[0..count]) |*byte| {
            byte.* = conn.ring[conn.ring_start];
            conn.ring_start = (conn.ring_start + 1) % conn.ring.len;
        }
        conn.ring_length -= count;
        conn.unacknowledged += @intCast(count);
        if (conn.out.len - conn.out_length >= reply_room) conn.acknowledge(false);
        return count;
    }

    pub fn readable(conn: *const Connection) usize {
        return conn.ring_length;
    }

    /// Whether data can go to the client now.
    pub fn writable(conn: *const Connection) bool {
        return conn.phase == .packets and conn.channel_open and !conn.closed and !conn.peer_closed and conn.kex == .idle and
            conn.peer_window > 0 and conn.out.len - conn.out_length >= data_max + 64;
    }

    /// Whether data can never go to the client again.
    pub fn writeEnded(conn: *const Connection) bool {
        return conn.phase == .ended or conn.closed or conn.peer_closed;
    }

    /// `data` to the client, as much as its window, its packet size and
    /// the output take: how many bytes.
    pub fn write(conn: *Connection, data: []const u8) usize {
        if (!conn.writable()) return 0;
        const most = @min(@min(conn.peer_window, conn.peer_max_packet), data_max);
        const count: u32 = @intCast(@min(data.len, most));
        if (count == 0) return 0;
        var bytes: [9 + data_max]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(msg_channel_data);
        writer.uint32(conn.peer_channel);
        writer.string(data[0..count]);
        conn.sendMessage(writer.written());
        conn.peer_window -= count;
        return count;
    }

    /// The session over: its exit status told, the channel ended and
    /// closed.
    pub fn exit(conn: *Connection, status: u32) void {
        if (conn.phase != .packets or !conn.channel_open or conn.closed) return;
        var bytes: [32]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(msg_channel_request);
        writer.uint32(conn.peer_channel);
        writer.string("exit-status");
        writer.boolean(false);
        writer.uint32(status);
        conn.sendMessage(writer.written());
        conn.channelReply(msg_channel_eof);
        conn.channelReply(msg_channel_close);
        conn.closed = true;
    }
};

fn startsWith(bytes: []const u8, prefix: []const u8) bool {
    return bytes.len >= prefix.len and wire.same(bytes[0..prefix.len], prefix);
}

/// Two secrets compared in a time that does not tell where they differ.
fn sameSecret(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var difference: u8 = 0;
    for (a, b) |x, y| difference |= x ^ y;
    return difference == 0;
}

/// `count` bytes at `from` moved to the start of `buffer`.
fn copyDown(buffer: []u8, from: usize, count: usize) void {
    for (0..count) |index| buffer[index] = buffer[from + index];
}

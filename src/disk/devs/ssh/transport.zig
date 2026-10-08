// SPDX-License-Identifier: MIT
//! SSH's transport (RFC 4253), either end's: the version lines, the
//! packets, and the parts of the key exchange both ends do alike. The
//! server (`connection.zig`) and the client (`client.zig`) each hold one,
//! and do the rest of the exchange - who makes which share, who signs and
//! who checks - themselves.
//!
//! **Packets.** The version lines first, each end's sent at once; then
//! packets, each its length, a padding length, the message and at least
//! four bytes of random padding. From NEWKEYS on they are sealed with
//! AES-GCM (RFC 5647): the length stays in clear and is authenticated, the
//! rest is encrypted, a 16-byte tag follows, and the nonce's last eight
//! bytes count the packets.
//!
//! **The key exchange.** Each end's KEXINIT lists what it has; each
//! algorithm is the client's first that the server has too (7.1). The
//! exchange hash H runs over both version lines, both KEXINIT messages,
//! the host key, both ends' shares and the shared secret K; the first H is
//! the session id. Each direction's key and nonce come from K, H, a letter
//! and the session id (7.2): A and C the client's, B and D the server's.
//! A NEWKEYS turns on the keys of the direction it went in. With OpenSSH's
//! strict exchange (`kex-strict-c-v00@openssh.com` from the client,
//! `kex-strict-s-v00@openssh.com` from the server), the first exchange
//! takes nothing but its own messages, each end's KEXINIT has to be its
//! first packet, and the sequence numbers start again at every NEWKEYS.
//! Either end may exchange keys again at any time. Nothing but the
//! exchange goes out while it runs: a message of the login or the
//! channel sent meanwhile is held, and goes once our NEWKEYS has.

const sdk = @import("sdk");
const crypto = sdk.crypto;
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
pub const msg_userauth_banner: u8 = 53;
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
const ssh = sdk.devices.ssh;
pub const reason_protocol_error = ssh.SSH_DISCONNECT_PROTOCOL_ERROR;
pub const reason_key_exchange_failed = ssh.SSH_DISCONNECT_KEY_EXCHANGE_FAILED;
pub const reason_mac_error = ssh.SSH_DISCONNECT_MAC_ERROR;
pub const reason_service_not_available = ssh.SSH_DISCONNECT_SERVICE_NOT_AVAILABLE;
pub const reason_protocol_version = ssh.SSH_DISCONNECT_PROTOCOL_VERSION_NOT_SUPPORTED;
pub const reason_host_key_not_verifiable = ssh.SSH_DISCONNECT_HOST_KEY_NOT_VERIFIABLE;
pub const reason_connection_lost = ssh.SSH_DISCONNECT_CONNECTION_LOST;
pub const reason_by_application = ssh.SSH_DISCONNECT_BY_APPLICATION;
pub const reason_no_more_auth_methods = ssh.SSH_DISCONNECT_NO_MORE_AUTH_METHODS_AVAILABLE;

/// The key exchanges both ends have: ML-KEM-768 with X25519, the one a
/// quantum computer cannot undo, first.
pub const kex_names = hybrid_kex ++ ",curve25519-sha256,curve25519-sha256@libssh.org";
pub const hybrid_kex = "mlkem768x25519-sha256";
/// The marks of the strict exchange, each end's.
pub const strict_server = "kex-strict-s-v00@openssh.com";
pub const strict_client = "kex-strict-c-v00@openssh.com";
pub const host_key_algorithms = ssh_keys.key_type;
pub const ciphers = "aes256-gcm@openssh.com,aes128-gcm@openssh.com";
/// Never used - an AEAD cipher brings its own - but a list must be there.
pub const macs = "hmac-sha2-256";
pub const compressions = "none";

/// The longest packet taken: its length field's value, RFC 4253's least
/// every end takes.
pub const packet_max: u32 = 35000;
pub const tag_bytes = crypto.GCM_TAG;
pub const in_bytes = 4 + packet_max + tag_bytes;
pub const out_bytes = 16384;
/// Room a reply needs in the output before another packet is taken in.
pub const reply_room = 2048;
/// Room for the messages held while keys are exchanged.
const held_bytes = 512;
/// The longest version line, CR LF included.
const version_max = 255;

pub const Role = enum(u8) { server, client };
pub const Phase = enum(u8) { version, packets, ended };
pub const KexState = enum(u8) { idle, sent, exchanging, finishing };

/// One direction's cipher: off until its NEWKEYS, then AES-GCM with this
/// key and a nonce whose last eight bytes count the packets.
pub const Direction = struct {
    on: bool = false,
    key: [32]u8 = @splat(0),
    key_length: u32 = 0,
    nonce: [12]u8 = @splat(0),

    pub fn advance(direction: *Direction) void {
        var at: usize = 12;
        while (at > 4) {
            at -= 1;
            direction.nonce[at] +%= 1;
            if (direction.nonce[at] != 0) break;
        }
    }
};

/// A message as it came: its bytes, from its type on, and its sequence
/// number.
pub const Packet = struct {
    payload: []const u8,
    sequence: u32,
};

pub const Transport = struct {
    cb: *CryptoBase,
    role: Role,
    phase: Phase = .version,
    /// Why it ended, for the log.
    reason: u32 = 0,

    /// What came in and is not taken yet, and what is to go out.
    in: [in_bytes]u8 = undefined,
    in_length: usize = 0,
    /// The bytes of the packet `next` handed out, dropped by `done`.
    taken: usize = 0,
    out: [out_bytes]u8 = undefined,
    out_length: usize = 0,
    receive_sequence: u32 = 0,
    send_sequence: u32 = 0,
    receiving: Direction = .{},
    sending: Direction = .{},

    // --- the key exchange --------------------------------------------------

    peer_version: [version_max]u8 = undefined,
    peer_version_length: usize = 0,
    kex: KexState = .idle,
    /// Our KEXINIT's message, which H takes.
    our_kexinit: [512]u8 = undefined,
    our_kexinit_length: usize = 0,
    /// H under way, from both KEXINITs on.
    exchange: crypto.HashContext = .{},
    /// The key lengths the KEXINITs chose for each direction.
    sending_key_length: u32 = 32,
    receiving_key_length: u32 = 32,
    /// The exchange chosen is the hybrid one.
    hybrid: bool = false,
    strict: bool = false,
    /// The first exchange is done; the next packet from a wrong guess is
    /// to be dropped.
    exchanged: bool = false,
    skip_guess: bool = false,
    session_id: [32]u8 = @splat(0),
    /// The keys the peer's NEWKEYS turns on.
    next_receiving: Direction = .{},
    /// The messages held while keys are exchanged, each its length (two
    /// bytes) and its bytes.
    held: [held_bytes]u8 = undefined,
    held_length: usize = 0,

    /// Our version line and first KEXINIT queued.
    pub fn start(t: *Transport) void {
        t.queueRaw(version ++ "\r\n");
        t.sendKexinit();
    }

    pub fn ended(t: *const Transport) bool {
        return t.phase == .ended;
    }

    /// What is to go out, and that so much of it went.
    pub fn pending(t: *const Transport) []const u8 {
        return t.out[0..t.out_length];
    }

    pub fn sent(t: *Transport, count: usize) void {
        const rest = t.out_length - count;
        if (rest > 0) copyDown(&t.out, count, rest);
        t.out_length = rest;
    }

    /// Room for bytes from the peer.
    pub fn inRoom(t: *const Transport) usize {
        return t.in.len - t.in_length;
    }

    /// Bytes from the peer, no more than `inRoom`.
    pub fn feed(t: *Transport, bytes: []const u8) void {
        const count = @min(bytes.len, t.inRoom());
        @memcpy(t.in[t.in_length..][0..count], bytes[0..count]);
        t.in_length += count;
    }

    /// Whether there is room for what a packet taken in might answer.
    pub fn roomForReply(t: *const Transport) bool {
        return t.out.len - t.out_length >= reply_room;
    }

    /// Whether a packet is whole and there is room for its answer: more
    /// to do before the peer sends more.
    pub fn processable(t: *const Transport) bool {
        return t.whole() and t.roomForReply();
    }

    /// Whether the input holds what `next` takes whole: the version line
    /// while it is awaited, then a packet - or a length `next` refuses.
    /// A packet's start alone waits for the rest from the connection.
    fn whole(t: *const Transport) bool {
        switch (t.phase) {
            .ended => return false,
            .version => {
                if (t.in_length >= version_max) return true;
                for (t.in[0..t.in_length]) |byte| {
                    if (byte == '\n') return true;
                }
                return false;
            },
            .packets => {
                if (t.in_length < 4) return false;
                const length = wire.get32(t.in[0..4]);
                if (length < 5 or length > packet_max) return true;
                const total: usize = 4 + @as(usize, length) + (if (t.receiving.on) tag_bytes else 0);
                return t.in_length >= total;
            },
        }
    }

    /// The next whole message, opened; null when none is whole. It stays
    /// in the input until `done`.
    pub fn next(t: *Transport) ?Packet {
        if (t.phase == .version) t.versionLine();
        if (t.phase != .packets or t.in_length < 4) return null;
        const length = wire.get32(t.in[0..4]);
        const sealed = t.receiving.on;
        const block: u32 = if (sealed) 16 else 8;
        // Encrypted, the length is not part of the blocks.
        const aligned = if (sealed) length else length + 4;
        if (length < 5 or length > packet_max or aligned % block != 0) {
            t.disconnect(reason_protocol_error, "bad packet length");
            return null;
        }
        const total: usize = 4 + length + (if (sealed) tag_bytes else 0);
        if (t.in_length < total) return null;
        if (sealed) {
            const body = t.in[4..][0..length];
            const message: crypto.GcmMessage = .{
                .key = &t.receiving.key,
                .key_length = t.receiving.key_length,
                .nonce = &t.receiving.nonce,
                .nonce_length = 12,
                .aad = t.in[0..4].ptr,
                .aad_length = 4,
                .input = body.ptr,
                .output = body.ptr,
                .length = length,
                .tag = t.in[4 + length ..][0..tag_bytes],
            };
            if (t.cb.OpenGcm(&message) != crypto.CRYPTOERR_OK) {
                t.disconnect(reason_mac_error, "packet authentication failed");
                return null;
            }
            t.receiving.advance();
        }
        const padding = t.in[4];
        if (@as(u32, padding) + 1 > length or padding < 4) {
            t.disconnect(reason_protocol_error, "bad padding");
            return null;
        }
        const sequence = t.receive_sequence;
        t.receive_sequence +%= 1;
        t.taken = total;
        return .{ .payload = t.in[5 .. 4 + length - padding], .sequence = sequence };
    }

    /// The message `next` handed out, dropped.
    pub fn done(t: *Transport) void {
        t.take(t.taken);
        t.taken = 0;
    }

    /// The messages every end answers alike - the end, those that say
    /// nothing, KEXINIT and NEWKEYS - handled: whether `packet` was one.
    /// The first exchange, strict, takes nothing but its own messages.
    pub fn common(t: *Transport, packet: Packet) bool {
        const kind = packet.payload[0];
        const exchange_message = kind == msg_kexinit or kind == msg_newkeys or (kind >= 30 and kind <= 49);
        if (t.strict and !t.exchanged and !exchange_message and kind != msg_disconnect) {
            t.disconnect(reason_protocol_error, "unexpected message during key exchange");
            return true;
        }
        switch (kind) {
            msg_disconnect => {
                // The peer's reason, for whoever asks why it ended.
                var reader = Reader{ .bytes = packet.payload, .at = 1 };
                const reason = reader.uint32();
                t.end(if (reader.bad) reason_by_application else reason);
            },
            msg_ignore, msg_debug, msg_unimplemented => {},
            msg_kexinit => t.kexinit(packet.payload, packet.sequence),
            msg_newkeys => t.peerNewkeys(),
            else => return false,
        }
        return true;
    }

    /// UNIMPLEMENTED for a message this end does not have.
    pub fn unimplemented(t: *Transport, sequence: u32) void {
        var reply: [5]u8 = undefined;
        reply[0] = msg_unimplemented;
        wire.put32(reply[1..5], sequence);
        t.send(&reply);
    }

    // --- the version line --------------------------------------------------

    /// The peer's version line, once it is whole. A server may send other
    /// lines before its own (RFC 4253, 4.2), which a client passes over.
    fn versionLine(t: *Transport) void {
        while (true) {
            const length = @min(t.in_length, version_max);
            const line_end = for (t.in[0..length], 0..) |byte, index| {
                if (byte == '\n') break index;
            } else {
                if (t.in_length >= version_max) t.end(reason_protocol_version);
                return;
            };
            var line = t.in[0..line_end];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (t.role == .client and !startsWith(line, "SSH-")) {
                t.take(line_end + 1);
                continue;
            }
            if (!startsWith(line, "SSH-2.0-") and !startsWith(line, "SSH-1.99-")) {
                if (t.role == .server) t.queueRaw("Protocol mismatch.\r\n");
                return t.end(reason_protocol_version);
            }
            @memcpy(t.peer_version[0..line.len], line);
            t.peer_version_length = line.len;
            t.take(line_end + 1);
            t.phase = .packets;
            return;
        }
    }

    /// The peer's version line, without its line end.
    pub fn peerVersion(t: *const Transport) []const u8 {
        return t.peer_version[0..t.peer_version_length];
    }

    // --- packets out -------------------------------------------------------

    fn queueRaw(t: *Transport, bytes: []const u8) void {
        if (t.out.len - t.out_length < bytes.len) return t.end(reason_protocol_error);
        @memcpy(t.out[t.out_length..][0..bytes.len], bytes);
        t.out_length += bytes.len;
    }

    /// `payload` as a packet: padded, and sealed once our NEWKEYS is sent;
    /// held while keys are exchanged, unless it is one of the transport's
    /// own.
    pub fn send(t: *Transport, payload: []const u8) void {
        if (t.phase == .ended) return;
        const kind = payload[0];
        const transport_message = kind < msg_service_request or (kind >= msg_kexinit and kind <= 49);
        if ((t.kex == .sent or t.kex == .exchanging) and !transport_message) {
            if (held_bytes - t.held_length < 2 + payload.len) return t.end(reason_protocol_error);
            t.held[t.held_length] = @truncate(payload.len >> 8);
            t.held[t.held_length + 1] = @truncate(payload.len);
            @memcpy(t.held[t.held_length + 2 ..][0..payload.len], payload);
            t.held_length += 2 + payload.len;
            return;
        }
        const sealed = t.sending.on;
        const block: usize = if (sealed) 16 else 8;
        const counted: usize = if (sealed) 1 + payload.len else 4 + 1 + payload.len;
        var padding = block - counted % block;
        if (padding < 4) padding += block;
        const length = 1 + payload.len + padding;
        const total = 4 + length + (if (sealed) tag_bytes else 0);
        if (t.out.len - t.out_length < total) return t.end(reason_protocol_error);
        const packet = t.out[t.out_length..][0..total];
        wire.put32(packet[0..4], @intCast(length));
        packet[4] = @intCast(padding);
        @memcpy(packet[5..][0..payload.len], payload);
        t.cb.RandomBytes(packet[5 + payload.len ..].ptr, @intCast(padding));
        if (sealed) {
            const message: crypto.GcmMessage = .{
                .key = &t.sending.key,
                .key_length = t.sending.key_length,
                .nonce = &t.sending.nonce,
                .nonce_length = 12,
                .aad = packet[0..4].ptr,
                .aad_length = 4,
                .input = packet[4..].ptr,
                .output = packet[4..].ptr,
                .length = @intCast(length),
                .tag = packet[4 + length ..][0..tag_bytes],
            };
            _ = t.cb.SealGcm(&message);
            t.sending.advance();
        }
        t.out_length += total;
        t.send_sequence +%= 1;
    }

    /// DISCONNECT sent with `text`, and the end.
    pub fn disconnect(t: *Transport, reason: u32, text: []const u8) void {
        if (t.phase == .ended) return;
        var bytes: [128]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(msg_disconnect);
        writer.uint32(reason);
        writer.string(text[0..@min(text.len, 100)]);
        writer.string("");
        if (t.phase == .packets) t.send(writer.written());
        t.end(reason);
    }

    /// The connection lost under the protocol: the peer went, or the
    /// socket failed. Nothing more is said.
    pub fn lose(t: *Transport) void {
        if (t.phase != .ended) t.end(reason_connection_lost);
    }

    pub fn end(t: *Transport, reason: u32) void {
        t.phase = .ended;
        t.reason = reason;
    }

    /// The first `count` bytes of the input dropped.
    fn take(t: *Transport, count: usize) void {
        const rest = t.in_length - count;
        if (rest > 0) copyDown(&t.in, count, rest);
        t.in_length = rest;
    }

    // --- the key exchange --------------------------------------------------

    /// Keys exchanged again, begun by this end: our KEXINIT, unless an
    /// exchange runs.
    pub fn renew(t: *Transport) void {
        if (t.phase == .packets and t.kex == .idle and t.exchanged) t.sendKexinit();
    }

    fn sendKexinit(t: *Transport) void {
        var writer = Writer{ .bytes = &t.our_kexinit };
        writer.byte(msg_kexinit);
        var cookie: [16]u8 = undefined;
        t.cb.RandomBytes(&cookie, cookie.len);
        writer.raw(&cookie);
        writer.string(if (t.role == .server) kex_names ++ "," ++ strict_server else kex_names ++ "," ++ strict_client);
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
        t.our_kexinit_length = writer.at;
        t.kex = .sent;
        t.send(writer.written());
    }

    pub fn hashString(t: *Transport, bytes: []const u8) void {
        var length: [4]u8 = undefined;
        wire.put32(&length, @intCast(bytes.len));
        t.cb.UpdateHash(&t.exchange, &length, 4);
        t.cb.UpdateHash(&t.exchange, bytes.ptr, @intCast(bytes.len));
    }

    /// The peer's KEXINIT: the algorithms chosen, ours sent if the peer
    /// began this exchange, and H begun with both version lines and both
    /// KEXINITs, the client's first.
    fn kexinit(t: *Transport, payload: []const u8, sequence: u32) void {
        if (t.kex == .exchanging or t.kex == .finishing) {
            return t.disconnect(reason_protocol_error, "KEXINIT during a key exchange");
        }
        var reader = Reader{ .bytes = payload, .at = 17 };
        const kex_list = reader.string();
        const host_key_list = reader.string();
        const ciphers_client = reader.string();
        const ciphers_server = reader.string();
        _ = reader.string();
        _ = reader.string();
        const compression_client = reader.string();
        const compression_server = reader.string();
        _ = reader.string();
        _ = reader.string();
        const guessed = reader.boolean();
        _ = reader.uint32();
        if (reader.bad) return t.disconnect(reason_protocol_error, "bad KEXINIT");
        const server = t.role == .server;
        if (!t.exchanged) {
            t.strict = wire.hasName(kex_list, if (server) strict_client else strict_server);
            // Strict: the peer's KEXINIT is its first packet.
            if (t.strict and sequence != 0) return t.disconnect(reason_protocol_error, "KEXINIT not first");
        }
        // The client's list decides; the other side is ours.
        const kex_name = if (server) wire.choose(kex_list, kex_names) else wire.choose(kex_names, kex_list);
        const cipher_client = if (server) wire.choose(ciphers_client, ciphers) else wire.choose(ciphers, ciphers_client);
        const cipher_server = if (server) wire.choose(ciphers_server, ciphers) else wire.choose(ciphers, ciphers_server);
        if (kex_name == null or !wire.hasName(host_key_list, host_key_algorithms) or cipher_client == null or cipher_server == null or
            !wire.hasName(compression_client, compressions) or !wire.hasName(compression_server, compressions))
        {
            return t.disconnect(reason_key_exchange_failed, "no algorithms in common");
        }
        t.hybrid = wire.same(kex_name.?, hybrid_kex);
        const client_key: u32 = if (wire.same(cipher_client.?, "aes256-gcm@openssh.com")) 32 else 16;
        const server_key: u32 = if (wire.same(cipher_server.?, "aes256-gcm@openssh.com")) 32 else 16;
        t.sending_key_length = if (server) server_key else client_key;
        t.receiving_key_length = if (server) client_key else server_key;
        // A wrong guess of the client's is the server's to drop.
        t.skip_guess = server and guessed and (!wire.same(wire.first(kex_list), kex_name.?) or !wire.same(wire.first(host_key_list), host_key_algorithms));
        if (t.kex == .idle) t.sendKexinit();
        _ = t.cb.InitHash(&t.exchange, crypto.HASH_SHA256);
        const ours = t.our_kexinit[0..t.our_kexinit_length];
        if (server) {
            t.hashString(t.peerVersion());
            t.hashString(version);
            t.hashString(payload);
            t.hashString(ours);
        } else {
            t.hashString(version);
            t.hashString(t.peerVersion());
            t.hashString(ours);
            t.hashString(payload);
        }
        t.kex = .exchanging;
    }

    /// H made from the host key, both ends' shares and K as the exchange
    /// encodes it; the first one kept as the session id.
    pub fn exchangeHash(t: *Transport, host_blob: []const u8, client_blob: []const u8, server_blob: []const u8, shared_encoded: []const u8) [32]u8 {
        t.hashString(host_blob);
        t.hashString(client_blob);
        t.hashString(server_blob);
        t.cb.UpdateHash(&t.exchange, shared_encoded.ptr, @intCast(shared_encoded.len));
        var exchange_hash: [32]u8 = undefined;
        _ = t.cb.FinishHash(&t.exchange, &exchange_hash);
        if (!t.exchanged) t.session_id = exchange_hash;
        return exchange_hash;
    }

    /// K encoded as the exchange has it: the hybrid's SHA-256 of the
    /// ML-KEM secret and the X25519 secret, as a string; X25519's alone,
    /// as an mpint.
    pub fn encodeShared(t: *Transport, kem_secret: ?*const [crypto.KEM_SECRET]u8, x25519_secret: *const [32]u8, into: *Writer) void {
        if (kem_secret) |kem| {
            var combined: [32]u8 = undefined;
            defer wipe(&combined);
            var context: crypto.HashContext = .{};
            _ = t.cb.InitHash(&context, crypto.HASH_SHA256);
            t.cb.UpdateHash(&context, kem, kem.len);
            t.cb.UpdateHash(&context, x25519_secret, 32);
            _ = t.cb.FinishHash(&context, &combined);
            into.string(&combined);
        } else {
            into.mpint(x25519_secret);
        }
    }

    /// Both directions' keys made, our NEWKEYS sent and our direction's
    /// keys on; the peer's wait for its NEWKEYS.
    pub fn newKeys(t: *Transport, shared_encoded: []const u8, exchange_hash: *const [32]u8) void {
        const server = t.role == .server;
        var client_to_server: Direction = .{ .on = true, .key_length = if (server) t.receiving_key_length else t.sending_key_length };
        var server_to_client: Direction = .{ .on = true, .key_length = if (server) t.sending_key_length else t.receiving_key_length };
        var key: [32]u8 = undefined;
        t.derive(shared_encoded, exchange_hash, 'A', &client_to_server.nonce);
        t.derive(shared_encoded, exchange_hash, 'B', &server_to_client.nonce);
        t.derive(shared_encoded, exchange_hash, 'C', &key);
        client_to_server.key = key;
        t.derive(shared_encoded, exchange_hash, 'D', &key);
        server_to_client.key = key;
        wipe(&key);
        t.next_receiving = if (server) client_to_server else server_to_client;
        t.send(&.{msg_newkeys});
        t.sending = if (server) server_to_client else client_to_server;
        if (t.strict) t.send_sequence = 0;
        t.kex = .finishing;
        // What was held while the keys changed, under the new ones.
        var at: usize = 0;
        while (at < t.held_length) {
            const length = @as(usize, t.held[at]) << 8 | t.held[at + 1];
            t.send(t.held[at + 2 ..][0..length]);
            at += 2 + length;
        }
        t.held_length = 0;
    }

    /// RFC 4253, 7.2: HASH(K || H || letter || session_id), as many bytes
    /// of it as `into` holds (no key here is longer than one SHA-256).
    fn derive(t: *Transport, shared_encoded: []const u8, exchange_hash: *const [32]u8, letter: u8, into: []u8) void {
        var context: crypto.HashContext = .{};
        _ = t.cb.InitHash(&context, crypto.HASH_SHA256);
        t.cb.UpdateHash(&context, shared_encoded.ptr, @intCast(shared_encoded.len));
        t.cb.UpdateHash(&context, exchange_hash, 32);
        t.cb.UpdateHash(&context, &letter, 1);
        t.cb.UpdateHash(&context, &t.session_id, 32);
        var digest: [32]u8 = undefined;
        _ = t.cb.FinishHash(&context, &digest);
        @memcpy(into, digest[0..into.len]);
        wipe(&digest);
    }

    /// The peer's NEWKEYS: its direction's keys on, the exchange done.
    fn peerNewkeys(t: *Transport) void {
        if (t.kex != .finishing) return t.disconnect(reason_protocol_error, "unexpected NEWKEYS");
        t.receiving = t.next_receiving;
        t.next_receiving = .{};
        if (t.strict) t.receive_sequence = 0;
        t.kex = .idle;
        t.exchanged = true;
    }
};

fn startsWith(bytes: []const u8, prefix: []const u8) bool {
    return bytes.len >= prefix.len and wire.same(bytes[0..prefix.len], prefix);
}

/// `count` bytes at `from` moved to the start of `buffer`.
fn copyDown(buffer: []u8, from: usize, count: usize) void {
    for (0..count) |index| buffer[index] = buffer[from + index];
}

pub fn wipe(bytes: []u8) void {
    const volatile_bytes: []volatile u8 = bytes;
    for (volatile_bytes) |*byte| byte.* = 0;
}

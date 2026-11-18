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
//! bytes count the packets. Or with OpenSSH's chacha20-poly1305@openssh.com
//! (its PROTOCOL.chacha20poly1305): the 64-byte key is two, K_2 then K_1;
//! the nonce is the packet's sequence number, 64 bits big-endian; the
//! length is encrypted with K_1 from block 0, the rest with K_2 from block
//! 1, and the tag is Poly1305 over both as sent, its one-time key the
//! first 32 bytes of K_2's block 0. So the length is opened first, with
//! K_1 alone, to know where the packet ends (`packetLength`); the packet
//! is decrypted only once its tag is right.
//!
//! Which cipher comes first in our list is the machine's: AES-GCM where
//! crypto.library's AES runs on hardware, ChaCha20-Poly1305 where it is
//! software (its CryptoEngines). A crypto.library before 2.13 has no
//! ChaCha20-Poly1305 to offer.
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

const std = @import("std");
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
pub const chacha_name = "chacha20-poly1305@openssh.com";
const aes_names = "aes256-gcm@openssh.com,aes128-gcm@openssh.com";
/// The ciphers offered: AES-GCM's first where AES is hardware,
/// ChaCha20-Poly1305 first where it is not, and AES-GCM's alone with a
/// crypto.library that has no ChaCha20-Poly1305 (`cipherList`).
pub const ciphers_aes_first = aes_names ++ "," ++ chacha_name;
pub const ciphers_chacha_first = chacha_name ++ "," ++ aes_names;
pub const ciphers_aes_only = aes_names;
/// Never used - an AEAD cipher brings its own - but a list must be there.
pub const macs = "hmac-sha2-256";
pub const compressions = "none";

/// The longest packet taken: its length field's value, RFC 4253's least
/// every end takes.
pub const packet_max: u32 = 35000;
/// AES-GCM's tag and Poly1305's: 16 bytes each.
pub const tag_bytes = crypto.GCM_TAG;
comptime {
    if (crypto.GCM_TAG != crypto.POLY1305_TAG) @compileError("ssh.device takes both ciphers' tags to be the same length");
}
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

/// The ciphers there are.
pub const Cipher = enum(u8) { aes_gcm, chacha };

/// A cipher a KEXINIT chose: which, and its key's length - AES-GCM's 16
/// or 32, ChaCha20-Poly1305's two keys of 32.
pub const Choice = struct {
    cipher: Cipher = .aes_gcm,
    key_length: u32 = 32,

    pub fn of(name: []const u8) Choice {
        if (wire.same(name, chacha_name)) return .{ .cipher = .chacha, .key_length = 64 };
        return .{ .key_length = if (wire.same(name, "aes256-gcm@openssh.com")) 32 else 16 };
    }
};

/// One direction's cipher: off until its NEWKEYS, then AES-GCM with this
/// key and a nonce whose last eight bytes count the packets, or
/// ChaCha20-Poly1305 with its two keys and the sequence number as nonce.
pub const Direction = struct {
    on: bool = false,
    cipher: Cipher = .aes_gcm,
    /// AES-GCM's key; ChaCha20-Poly1305's K_2 (the packet's), then K_1
    /// (the length's).
    key: [64]u8 = @splat(0),
    key_length: u32 = 0,
    nonce: [12]u8 = @splat(0),

    /// The size the packet past its length is padded to.
    pub fn block(direction: *const Direction) usize {
        return if (direction.cipher == .chacha) 8 else 16;
    }

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
    /// The ciphers the KEXINITs chose for each direction.
    sending_choice: Choice = .{},
    receiving_choice: Choice = .{},
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
                const length = t.packetLength();
                if (length < 5 or length > packet_max) return true;
                const total: usize = 4 + @as(usize, length) + (if (t.receiving.on) tag_bytes else 0);
                return t.in_length >= total;
            },
        }
    }

    /// The length of the packet at the input's start, from its first four
    /// bytes: as they are, or ChaCha20-Poly1305's opened with K_1. The
    /// input is left as it came, which the tag is over.
    fn packetLength(t: *const Transport) u32 {
        if (!t.receiving.on or t.receiving.cipher != .chacha) return wire.get32(t.in[0..4]);
        var length: [4]u8 = t.in[0..4].*;
        var context: crypto.CipherContext = .{};
        defer wipe(std.mem.asBytes(&context));
        const iv = chachaIv(t.receive_sequence);
        _ = t.cb.InitCipher(&context, crypto.CIPHER_CHACHA20, t.receiving.key[32..64], 32, &iv);
        _ = t.cb.UpdateCipher(&context, &length, &length, 4);
        return wire.get32(&length);
    }

    /// The next whole message, opened; null when none is whole. It stays
    /// in the input until `done`.
    pub fn next(t: *Transport) ?Packet {
        if (t.phase == .version) t.versionLine();
        if (t.phase != .packets or t.in_length < 4) return null;
        const length = t.packetLength();
        const sealed = t.receiving.on;
        const block: u32 = if (sealed) @intCast(t.receiving.block()) else 8;
        // Encrypted, the length is not part of the blocks.
        const aligned = if (sealed) length else length + 4;
        if (length < 5 or length > packet_max or aligned % block != 0) {
            t.disconnect(reason_protocol_error, "bad packet length");
            return null;
        }
        const total: usize = 4 + length + (if (sealed) tag_bytes else 0);
        if (t.in_length < total) return null;
        if (sealed) {
            const opened = switch (t.receiving.cipher) {
                .chacha => openChaCha(t.cb, &t.receiving, t.receive_sequence, t.in[0 .. 4 + length], t.in[4 + length ..][0..tag_bytes]),
                .aes_gcm => opened: {
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
                    break :opened t.cb.OpenGcm(&message) == crypto.CRYPTOERR_OK;
                },
            };
            if (!opened) {
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
        const block: usize = if (sealed) t.sending.block() else 8;
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
        if (sealed) switch (t.sending.cipher) {
            .chacha => sealChaCha(t.cb, &t.sending, t.send_sequence, packet[0 .. 4 + length], packet[4 + length ..][0..tag_bytes]),
            .aes_gcm => {
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
            },
        };
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

    /// Our cipher list, the same for every KEXINIT: the machine's order.
    pub fn cipherList(t: *const Transport) []const u8 {
        if (!hasChaCha(t.cb)) return ciphers_aes_only;
        return if (t.cb.CryptoEngines() & crypto.CRYPTOENG_AES != 0) ciphers_aes_first else ciphers_chacha_first;
    }

    fn sendKexinit(t: *Transport) void {
        var writer = Writer{ .bytes = &t.our_kexinit };
        writer.byte(msg_kexinit);
        var cookie: [16]u8 = undefined;
        t.cb.RandomBytes(&cookie, cookie.len);
        writer.raw(&cookie);
        writer.string(if (t.role == .server) kex_names ++ "," ++ strict_server else kex_names ++ "," ++ strict_client);
        writer.string(host_key_algorithms);
        writer.string(t.cipherList());
        writer.string(t.cipherList());
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
        const ciphers = t.cipherList();
        const cipher_client = if (server) wire.choose(ciphers_client, ciphers) else wire.choose(ciphers, ciphers_client);
        const cipher_server = if (server) wire.choose(ciphers_server, ciphers) else wire.choose(ciphers, ciphers_server);
        if (kex_name == null or !wire.hasName(host_key_list, host_key_algorithms) or cipher_client == null or cipher_server == null or
            !wire.hasName(compression_client, compressions) or !wire.hasName(compression_server, compressions))
        {
            return t.disconnect(reason_key_exchange_failed, "no algorithms in common");
        }
        t.hybrid = wire.same(kex_name.?, hybrid_kex);
        const client_choice = Choice.of(cipher_client.?);
        const server_choice = Choice.of(cipher_server.?);
        t.sending_choice = if (server) server_choice else client_choice;
        t.receiving_choice = if (server) client_choice else server_choice;
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
        const client_choice = if (server) t.receiving_choice else t.sending_choice;
        const server_choice = if (server) t.sending_choice else t.receiving_choice;
        var client_to_server: Direction = .{ .on = true, .cipher = client_choice.cipher, .key_length = client_choice.key_length };
        var server_to_client: Direction = .{ .on = true, .cipher = server_choice.cipher, .key_length = server_choice.key_length };
        t.derive(shared_encoded, exchange_hash, 'A', &client_to_server.nonce);
        t.derive(shared_encoded, exchange_hash, 'B', &server_to_client.nonce);
        t.derive(shared_encoded, exchange_hash, 'C', client_to_server.key[0..client_to_server.key_length]);
        t.derive(shared_encoded, exchange_hash, 'D', server_to_client.key[0..server_to_client.key_length]);
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
    /// of it as `into` holds - and for a key longer than one SHA-256
    /// (ChaCha20-Poly1305's 64 bytes), HASH(K || H || what there is so
    /// far) after it, as often as it takes.
    fn derive(t: *Transport, shared_encoded: []const u8, exchange_hash: *const [32]u8, letter: u8, into: []u8) void {
        var context: crypto.HashContext = .{};
        _ = t.cb.InitHash(&context, crypto.HASH_SHA256);
        t.cb.UpdateHash(&context, shared_encoded.ptr, @intCast(shared_encoded.len));
        t.cb.UpdateHash(&context, exchange_hash, 32);
        t.cb.UpdateHash(&context, &letter, 1);
        t.cb.UpdateHash(&context, &t.session_id, 32);
        var digest: [32]u8 = undefined;
        _ = t.cb.FinishHash(&context, &digest);
        var at: usize = @min(into.len, digest.len);
        @memcpy(into[0..at], digest[0..at]);
        while (at < into.len) {
            context = .{};
            _ = t.cb.InitHash(&context, crypto.HASH_SHA256);
            t.cb.UpdateHash(&context, shared_encoded.ptr, @intCast(shared_encoded.len));
            t.cb.UpdateHash(&context, exchange_hash, 32);
            t.cb.UpdateHash(&context, into.ptr, @intCast(at));
            _ = t.cb.FinishHash(&context, &digest);
            const more = @min(into.len - at, digest.len);
            @memcpy(into[at..][0..more], digest[0..more]);
            at += more;
        }
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

/// Whether crypto.library has ChaCha20-Poly1305, Poly1305Pieces and
/// CryptoEngines: 2.13 or later.
pub fn hasChaCha(cb: *CryptoBase) bool {
    const lib = cb.lib();
    return lib.version > 2 or (lib.version == 2 and lib.revision >= 13);
}

/// chacha20-poly1305@openssh.com's IV for CIPHER_CHACHA20: block counter
/// 0 in the first eight bytes (a 64-bit counter, as the original ChaCha20
/// has it), the sequence number as a 64-bit big-endian nonce in the last
/// eight.
pub fn chachaIv(sequence: u32) [16]u8 {
    var iv: [16]u8 = @splat(0);
    wire.put32(iv[12..16], sequence);
    return iv;
}

/// A ChaCha20-Poly1305 context at block 0 of K_2, which made the
/// one-time Poly1305 key from that block and stands at block 1, where
/// the packet's bytes begin.
fn chachaPacket(cb: *CryptoBase, direction: *const Direction, sequence: u32, context: *crypto.CipherContext, poly_key: *[64]u8) void {
    const iv = chachaIv(sequence);
    _ = cb.InitCipher(context, crypto.CIPHER_CHACHA20, direction.key[0..32], 32, &iv);
    poly_key.* = @splat(0);
    _ = cb.UpdateCipher(context, poly_key, poly_key, 64);
}

/// The packet - its length and the rest, `packet` - sealed with
/// chacha20-poly1305@openssh.com, and its tag into `tag`.
fn sealChaCha(cb: *CryptoBase, direction: *const Direction, sequence: u32, packet: []u8, tag: *[tag_bytes]u8) void {
    var context: crypto.CipherContext = .{};
    defer wipe(std.mem.asBytes(&context));
    var poly_key: [64]u8 = undefined;
    defer wipe(&poly_key);
    const iv = chachaIv(sequence);
    _ = cb.InitCipher(&context, crypto.CIPHER_CHACHA20, direction.key[32..64], 32, &iv);
    _ = cb.UpdateCipher(&context, packet.ptr, packet.ptr, 4);
    chachaPacket(cb, direction, sequence, &context, &poly_key);
    _ = cb.UpdateCipher(&context, packet[4..].ptr, packet[4..].ptr, @intCast(packet.len - 4));
    const pieces = [_]crypto.Bytes{.of(packet)};
    _ = cb.Poly1305Pieces(poly_key[0..32], &pieces, pieces.len, tag);
}

/// The packet - its length and the rest as they came, `packet` - checked
/// against `tag` and, if it is right, the rest decrypted in place; the
/// length is left as it came. Whether the tag was right.
fn openChaCha(cb: *CryptoBase, direction: *const Direction, sequence: u32, packet: []u8, tag: *const [tag_bytes]u8) bool {
    var context: crypto.CipherContext = .{};
    defer wipe(std.mem.asBytes(&context));
    var poly_key: [64]u8 = undefined;
    defer wipe(&poly_key);
    chachaPacket(cb, direction, sequence, &context, &poly_key);
    const pieces = [_]crypto.Bytes{.of(packet)};
    var expected: [tag_bytes]u8 = undefined;
    defer wipe(&expected);
    _ = cb.Poly1305Pieces(poly_key[0..32], &pieces, pieces.len, &expected);
    var differ: u8 = 0;
    for (expected, tag) |a, b| differ |= a ^ b;
    if (differ != 0) return false;
    _ = cb.UpdateCipher(&context, packet[4..].ptr, packet[4..].ptr, @intCast(packet.len - 4));
    return true;
}

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

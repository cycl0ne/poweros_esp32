// SPDX-License-Identifier: MIT
//! A TLS client: TLS 1.3 (RFC 8446) and, for the servers that speak
//! nothing newer, TLS 1.2 (RFC 5246) - the handshake from ClientHello to
//! both Finished messages, then application data and alerts.
//!
//! The client works on whole records and buffers, not on a socket: the
//! caller hands it each record that arrives (`receive`), and sends what
//! the client puts into the output it passed. So the same code runs over
//! a socket in the library and over RFC 8448's recorded bytes in the
//! tests.
//!
//! One ClientHello offers both. TLS 1.3 with AES-128-GCM-SHA256 and
//! AES-256-GCM-SHA384, an X25519 key share, and P-256 or P-384 should a
//! server ask for one of them instead (HelloRetryRequest). TLS 1.2 with
//! ECDHE and AES-GCM, the server signing with ECDSA or RSA (RFC 5289),
//! the extended master secret when the server agrees (RFC 7627) and no
//! renegotiation ever (RFC 5746: an empty renegotiation_info, a server's
//! HelloRequest passed over). A server that speaks 1.3 but answers 1.2 -
//! its random ends in the downgrade marker - is refused: someone in
//! between took the newer version away.
//!
//! A server's certificates are checked against the trust stores it was
//! given (`x509/chain.zig`) unless it was told not to; its key then
//! checks what the server signed - TLS 1.3's CertificateVerify, TLS
//! 1.2's ServerKeyExchange - and its Finished the transcript. A server
//! that asks for a client certificate is sent an empty one.
//!
//! The ClientHello carries a session ID of 32 random bytes, and under
//! TLS 1.3 a ChangeCipherSpec goes before the client's Finished, the
//! "middlebox compatibility" RFC 8446 describes; a hello with an empty
//! session ID (RFC 8448's) sends none.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const schedule = @import("schedule.zig");
const prf = @import("prf.zig");
const record = @import("record.zig");
const wire = @import("wire.zig");
const certificate = @import("../x509/certificate.zig");
const chain = @import("../x509/chain.zig");

// Handshake message types.
const HELLO_REQUEST: u8 = 0;
const CLIENT_HELLO: u8 = 1;
const SERVER_HELLO: u8 = 2;
const NEW_SESSION_TICKET: u8 = 4;
const ENCRYPTED_EXTENSIONS: u8 = 8;
const CERTIFICATE: u8 = 11;
const SERVER_KEY_EXCHANGE: u8 = 12;
const CERTIFICATE_REQUEST: u8 = 13;
const SERVER_HELLO_DONE: u8 = 14;
const CERTIFICATE_VERIFY: u8 = 15;
const CLIENT_KEY_EXCHANGE: u8 = 16;
const FINISHED: u8 = 20;
const KEY_UPDATE: u8 = 24;
const MESSAGE_HASH: u8 = 254;

// Extensions.
const EXT_SERVER_NAME: u16 = 0;
const EXT_SUPPORTED_GROUPS: u16 = 10;
const EXT_EC_POINT_FORMATS: u16 = 11;
const EXT_SIGNATURE_ALGORITHMS: u16 = 13;
const EXT_ALPN: u16 = 16;
const EXT_EXTENDED_MASTER_SECRET: u16 = 23;
const EXT_SUPPORTED_VERSIONS: u16 = 43;
const EXT_COOKIE: u16 = 44;
const EXT_KEY_SHARE: u16 = 51;
const EXT_RENEGOTIATION_INFO: u16 = 0xff01;

// Groups.
const GROUP_P256: u16 = 0x0017;
const GROUP_P384: u16 = 0x0018;
const GROUP_X25519: u16 = 0x001d;

pub const TLS12: u16 = 0x0303;
pub const TLS13: u16 = 0x0304;

/// The ServerHello random that makes it a HelloRetryRequest:
/// SHA-256("HelloRetryRequest").
const retry_random = [_]u8{
    0xcf, 0x21, 0xad, 0x74, 0xe5, 0x9a, 0x61, 0x11, 0xbe, 0x1d, 0x8c, 0x02, 0x1e, 0x65, 0xb8, 0x91,
    0xc2, 0xa2, 0x11, 0x16, 0x7a, 0xbb, 0x8c, 0x5e, 0x07, 0x9e, 0x09, 0xe2, 0xc8, 0xa8, 0x33, 0x9c,
};

/// What a TLS 1.3 server's random ends in when it answers 1.2 or older
/// (RFC 8446, 4.1.3): "DOWNGRD" and 1 or 0.
const downgrade_marker = [_]u8{ 0x44, 0x4F, 0x57, 0x4E, 0x47, 0x52, 0x44 };

/// The signature algorithms offered, ours to check: ECDSA, RSA-PSS,
/// Ed25519, and RSA's PKCS #1 for certificates and TLS 1.2.
const signature_algorithms = [_]u16{ 0x0403, 0x0503, 0x0804, 0x0805, 0x0806, 0x0807, 0x0401, 0x0501, 0x0601 };

/// Alert descriptions.
pub const ALERT_CLOSE_NOTIFY: u8 = 0;
const ALERT_UNEXPECTED_MESSAGE: u8 = 10;
const ALERT_BAD_RECORD_MAC: u8 = 20;
const ALERT_BAD_CERTIFICATE: u8 = 42;
const ALERT_UNSUPPORTED_CERTIFICATE: u8 = 43;
const ALERT_CERTIFICATE_EXPIRED: u8 = 45;
const ALERT_ILLEGAL_PARAMETER: u8 = 47;
const ALERT_UNKNOWN_CA: u8 = 48;
const ALERT_DECODE_ERROR: u8 = 50;
const ALERT_DECRYPT_ERROR: u8 = 51;
const ALERT_PROTOCOL_VERSION: u8 = 70;

/// The longest handshake message taken whole: a certificate chain.
pub const pending_max = 32768;
const hello_max = 768;
const leaf_max = 8192;

pub const Config = struct {
    /// The server's name, for SNI and to check its certificate against.
    host: []const u8,
    /// Seconds since 1970, for the certificates' dates.
    now: i64,
    /// Whether the server's certificates are checked at all. Off, only
    /// what its key signed and its Finished are.
    verify: bool = true,
    /// The trust stores (`x509/anchors.zig`) a chain may end in.
    stores: []const []const u8 = &.{},
    /// An ALPN protocol to ask for, or empty.
    alpn: []const u8 = "",
};

/// Why a connection ended.
pub const Failure = enum {
    none,
    /// A message out of its place, or one there is not.
    unexpected,
    /// A message that could not be read.
    decode,
    /// No version, suite, group or signature algorithm in common.
    unsupported,
    /// The certificates: `verdict` says which check.
    certificate,
    /// What the server's key signed did not check.
    signature,
    /// The server's Finished did not match the transcript.
    finished,
    /// A record that did not decrypt.
    record,
    /// The server sent an alert: `peer_alert`.
    alert,
    /// The connection was closed.
    closed,
};

const State = enum {
    start,
    wait_server_hello,
    // TLS 1.3
    wait_encrypted_extensions,
    wait_certificate,
    wait_certificate_verify,
    wait_finished,
    // TLS 1.2
    wait_certificate12,
    wait_server_key_exchange,
    wait_server_hello_done,
    wait_change_cipher_spec,
    wait_finished12,
    connected,
    closed,
    failed,
};

/// Where the client puts records to send.
pub const Output = struct {
    buffer: []u8,
    length: usize = 0,

    fn room(output: *Output) []u8 {
        return output.buffer[output.length..];
    }
};

/// What a record received came to.
pub const Event = union(enum) {
    /// Nothing for the caller yet: send what is in the output, if
    /// anything, and hand over the next record.
    more,
    /// The handshake is done; the output holds the client's Finished.
    connected,
    /// Application data, in the record's own buffer.
    data: []u8,
    /// The server closed the connection.
    closed,
    /// The connection failed (`failure`); the output may hold an alert.
    failed,
};

pub const Client = struct {
    cb: *CryptoBase,
    config: Config,
    state: State = .start,
    failure: Failure = .none,
    verdict: chain.Verdict = .trusted,
    peer_alert: u8 = 0,
    /// TLS13 or TLS12, once the server has said.
    version: u16 = TLS13,
    suite: schedule.Suite = schedule.TLS_AES_128_GCM_SHA256,

    random: [32]u8 = @splat(0),
    server_random: [32]u8 = @splat(0),
    session_id: [32]u8 = @splat(0),
    session_id_length: u8 = 32,
    /// The key share sent: X25519's, then P-256's or P-384's after a
    /// HelloRetryRequest.
    group: u16 = GROUP_X25519,
    private_key: [crypto.CURVE_PRIVATE_MAX]u8 = @splat(0),
    public_key: [crypto.CURVE_PUBLIC_MAX]u8 = @splat(0),
    public_length: u32 = 0,
    retried: bool = false,
    cookie: [256]u8 = @splat(0),
    cookie_length: u16 = 0,

    hello: [hello_max]u8 = @splat(0),
    hello_length: usize = 0,
    transcript: crypto.HashContext = .{},
    transcript_started: bool = false,

    handshake_secret: schedule.Secret = @splat(0),
    client_traffic: schedule.Secret = @splat(0),
    server_traffic: schedule.Secret = @splat(0),
    read_keys: schedule.TrafficKeys = .{},
    write_keys: schedule.TrafficKeys = .{},
    reading_protected: bool = false,
    writing_protected: bool = false,
    certificate_requested: bool = false,
    alpn: [32]u8 = @splat(0),
    alpn_length: u8 = 0,

    /// TLS 1.2: the server's ECDHE share and its group, whether the
    /// master secret is the extended one, and the master secret.
    server_share: [crypto.CURVE_PUBLIC_MAX]u8 = @splat(0),
    server_share_length: usize = 0,
    server_group: u16 = 0,
    extended_master: bool = false,
    master: [48]u8 = @splat(0),

    leaf: [leaf_max]u8 = @splat(0),
    leaf_length: usize = 0,
    pending: [pending_max]u8 = @splat(0),
    pending_length: usize = 0,

    /// A client for `config`, its random values and its X25519 key drawn.
    /// Made in place, a field at a time: the client is far larger than a
    /// program's stack, which a whole value would be built on first.
    pub fn init(client: *Client, cb: *CryptoBase, config: Config) void {
        const bytes: [*]volatile u8 = @ptrCast(client);
        for (0..@sizeOf(Client)) |index| bytes[index] = 0;
        client.cb = cb;
        client.config = config;
        client.version = TLS13;
        client.suite = schedule.TLS_AES_128_GCM_SHA256;
        client.session_id_length = 32;
        client.group = GROUP_X25519;
        client.transcript = .{};
        cb.RandomBytes(&client.random, 32);
        cb.RandomBytes(&client.session_id, 32);
        _ = cb.MakeKeyPair(crypto.CURVE_X25519, &client.private_key, &client.public_key, &client.public_length);
    }

    // --- sending ------------------------------------------------------------

    /// The ClientHello, as a record in `output`.
    pub fn start(client: *Client, output: *Output) void {
        client.hello_length = client.buildHello();
        client.sendHello(output);
    }

    /// A ClientHello given whole (RFC 8448's, in the tests), as a record in
    /// `output`. Its random and session ID are taken as the client's own.
    pub fn startWith(client: *Client, message: []const u8, output: *Output) void {
        @memcpy(client.hello[0..message.len], message);
        client.hello_length = message.len;
        var reader = wire.Reader.of(message[4..]);
        _ = reader.bytes(2);
        client.random = (reader.bytes(32) orelse return)[0..32].*;
        const session = reader.vector(1) orelse return;
        @memcpy(client.session_id[0..session.len], session);
        client.session_id_length = @intCast(session.len);
        client.sendHello(output);
    }

    fn sendHello(client: *Client, output: *Output) void {
        output.length += record.plain(record.HANDSHAKE, !client.retried, client.hello[0..client.hello_length], output.room());
        if (client.retried) client.absorb(client.hello[0..client.hello_length]);
        client.state = .wait_server_hello;
    }

    fn buildHello(client: *Client) usize {
        var w = wire.Writer.of(&client.hello);
        w.number(1, CLIENT_HELLO);
        const body = w.open(3);
        w.number(2, TLS12);
        w.bytes(&client.random);
        w.number(1, client.session_id_length);
        w.bytes(client.session_id[0..client.session_id_length]);
        w.number(2, 2 * schedule.offered.len);
        for (schedule.offered) |suite| w.number(2, suite.id);
        w.number(1, 1);
        w.number(1, 0);
        const extensions = w.open(2);

        if (!isAddress(client.config.host) and client.config.host.len != 0) {
            w.number(2, EXT_SERVER_NAME);
            const ext = w.open(2);
            const list = w.open(2);
            w.number(1, 0);
            w.number(2, @intCast(client.config.host.len));
            w.bytes(client.config.host);
            w.close(2, list);
            w.close(2, ext);
        }
        w.number(2, EXT_SUPPORTED_VERSIONS);
        w.number(2, 5);
        w.number(1, 4);
        w.number(2, TLS13);
        w.number(2, TLS12);
        w.number(2, EXT_SUPPORTED_GROUPS);
        w.number(2, 8);
        w.number(2, 6);
        w.number(2, GROUP_X25519);
        w.number(2, GROUP_P256);
        w.number(2, GROUP_P384);
        w.number(2, EXT_EC_POINT_FORMATS);
        w.number(2, 2);
        w.number(1, 1);
        w.number(1, 0); // uncompressed
        w.number(2, EXT_SIGNATURE_ALGORITHMS);
        w.number(2, 2 + 2 * signature_algorithms.len);
        w.number(2, 2 * signature_algorithms.len);
        for (signature_algorithms) |algorithm| w.number(2, algorithm);
        w.number(2, EXT_EXTENDED_MASTER_SECRET);
        w.number(2, 0);
        w.number(2, EXT_RENEGOTIATION_INFO);
        w.number(2, 1);
        w.number(1, 0);
        w.number(2, EXT_KEY_SHARE);
        const share_ext = w.open(2);
        const shares = w.open(2);
        w.number(2, client.group);
        w.number(2, client.public_length);
        w.bytes(client.public_key[0..client.public_length]);
        w.close(2, shares);
        w.close(2, share_ext);
        if (client.cookie_length != 0) {
            w.number(2, EXT_COOKIE);
            w.number(2, client.cookie_length + 2);
            w.number(2, client.cookie_length);
            w.bytes(client.cookie[0..client.cookie_length]);
        }
        if (client.config.alpn.len != 0) {
            w.number(2, EXT_ALPN);
            const ext = w.open(2);
            const list = w.open(2);
            w.number(1, @intCast(client.config.alpn.len));
            w.bytes(client.config.alpn);
            w.close(2, list);
            w.close(2, ext);
        }
        w.close(2, extensions);
        w.close(3, body);
        return w.length;
    }

    /// One record of `content_type`, protected as the version has it.
    fn sealRecord(client: *Client, content_type: u8, content: []const u8, output: *Output) void {
        if (client.version == TLS12) {
            output.length += record.seal12(client.cb, &client.write_keys, content_type, content, output.room());
        } else {
            output.length += record.seal(client.cb, &client.write_keys, content_type, content, output.room());
        }
    }

    /// Application data, in records of at most 2^14 bytes, into `output`.
    pub fn send(client: *Client, data: []const u8, output: *Output) void {
        var left = data;
        while (left.len > 0) {
            const take = @min(left.len, record.max_plaintext);
            client.sealRecord(record.APPLICATION_DATA, left[0..take], output);
            left = left[take..];
        }
    }

    /// close_notify, into `output`.
    pub fn close(client: *Client, output: *Output) void {
        if (client.state != .connected) return;
        client.sendAlert(ALERT_CLOSE_NOTIFY, output);
        client.state = .closed;
    }

    fn sendAlert(client: *Client, description: u8, output: *Output) void {
        const alert = [_]u8{ if (description == ALERT_CLOSE_NOTIFY) 1 else 2, description };
        if (client.writing_protected) {
            client.sealRecord(record.ALERT, &alert, output);
        } else {
            output.length += record.plain(record.ALERT, false, &alert, output.room());
        }
    }

    fn fail(client: *Client, failure: Failure, alert: u8, output: *Output) Event {
        if (client.state != .failed) client.sendAlert(alert, output);
        client.failure = failure;
        client.state = .failed;
        return .failed;
    }

    // --- receiving ----------------------------------------------------------

    /// One whole record from the server, header and all; opened in its
    /// own buffer.
    pub fn receive(client: *Client, received: []u8, output: *Output) Event {
        if (client.state == .failed) return .failed;
        if (client.state == .closed) return .closed;
        if (received.len < record.header_length) return client.fail(.decode, ALERT_DECODE_ERROR, output);
        const content_type = received[0];
        const content = received[record.header_length..];

        if (content_type == record.CHANGE_CIPHER_SPEC) {
            if (content.len != 1 or content[0] != 1) return client.fail(.decode, ALERT_DECODE_ERROR, output);
            if (client.version == TLS12) {
                // TLS 1.2: from here the server's records are protected.
                if (client.state != .wait_change_cipher_spec) return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output);
                client.reading_protected = true;
                client.state = .wait_finished12;
                return .more;
            }
            // TLS 1.3: only the compatibility one, before Finished.
            if (client.state == .connected) return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output);
            return .more;
        }
        if (!client.reading_protected) {
            if (content_type == record.ALERT) return client.peerAlert(content);
            if (content_type != record.HANDSHAKE) return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output);
            return client.handshake(content, output);
        }

        const opened = (if (client.version == TLS12)
            record.open12(client.cb, &client.read_keys, received)
        else
            record.open(client.cb, &client.read_keys, received)) orelse return client.fail(.record, ALERT_BAD_RECORD_MAC, output);
        return switch (opened.content_type) {
            record.HANDSHAKE => client.handshake(opened.content, output),
            record.ALERT => client.peerAlert(opened.content),
            record.APPLICATION_DATA => if (client.state == .connected) .{ .data = opened.content } else client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output),
            else => client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output),
        };
    }

    fn peerAlert(client: *Client, content: []const u8) Event {
        if (content.len != 2) {
            client.failure = .decode;
            client.state = .failed;
            return .failed;
        }
        if (content[1] == ALERT_CLOSE_NOTIFY) {
            client.state = .closed;
            client.failure = .closed;
            return .closed;
        }
        // A warning other than close_notify (TLS 1.2's no_renegotiation)
        // ends nothing.
        if (content[0] == 1 and client.version == TLS12) return .more;
        client.peer_alert = content[1];
        client.failure = .alert;
        client.state = .failed;
        return .failed;
    }

    /// Handshake bytes, gathered into whole messages and each worked.
    fn handshake(client: *Client, content: []const u8, output: *Output) Event {
        if (client.pending_length + content.len > pending_max) return client.fail(.decode, ALERT_DECODE_ERROR, output);
        @memcpy(client.pending[client.pending_length..][0..content.len], content);
        client.pending_length += content.len;
        var event: Event = .more;
        while (client.pending_length >= 4) {
            const length = @as(usize, client.pending[1]) << 16 | @as(usize, client.pending[2]) << 8 | client.pending[3];
            if (client.pending_length < 4 + length) break;
            event = client.work(client.pending[0 .. 4 + length], output);
            // What is left moves to the front.
            const rest = client.pending_length - (4 + length);
            for (0..rest) |index| client.pending[index] = client.pending[4 + length + index];
            client.pending_length = rest;
            if (event == .failed or event == .closed) return event;
        }
        return event;
    }

    fn absorb(client: *Client, bytes: []const u8) void {
        client.cb.UpdateHash(&client.transcript, bytes.ptr, @intCast(bytes.len));
    }

    /// The transcript's digest so far, without ending it.
    fn digest(client: *Client, out: *schedule.Secret) []const u8 {
        var copy = client.transcript;
        const length = client.cb.FinishHash(&copy, out);
        return out[0..length];
    }

    fn work(client: *Client, bytes: []const u8, output: *Output) Event {
        const kind = bytes[0];
        const body = bytes[4..];
        switch (client.state) {
            .wait_server_hello => {
                if (kind != SERVER_HELLO) return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output);
                return client.serverHello(bytes, body, output);
            },
            .wait_encrypted_extensions => {
                if (kind != ENCRYPTED_EXTENSIONS) return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output);
                if (!client.encryptedExtensions(body)) return client.fail(.decode, ALERT_DECODE_ERROR, output);
                client.absorb(bytes);
                client.state = .wait_certificate;
                return .more;
            },
            .wait_certificate => {
                if (kind == CERTIFICATE_REQUEST) {
                    client.certificate_requested = true;
                    client.absorb(bytes);
                    return .more;
                }
                if (kind != CERTIFICATE) return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output);
                const event = client.certificates(body, output);
                if (event == .failed) return event;
                client.absorb(bytes);
                client.state = .wait_certificate_verify;
                return .more;
            },
            .wait_certificate_verify => {
                if (kind != CERTIFICATE_VERIFY) return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output);
                const event = client.certificateVerify(body, output);
                if (event == .failed) return event;
                client.absorb(bytes);
                client.state = .wait_finished;
                return .more;
            },
            .wait_finished => {
                if (kind != FINISHED) return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output);
                return client.finished(bytes, body, output);
            },
            .wait_certificate12 => {
                if (kind != CERTIFICATE) return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output);
                const event = client.certificates12(body, output);
                if (event == .failed) return event;
                client.absorb(bytes);
                client.state = .wait_server_key_exchange;
                return .more;
            },
            .wait_server_key_exchange => {
                if (kind != SERVER_KEY_EXCHANGE) return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output);
                const event = client.serverKeyExchange(body, output);
                if (event == .failed) return event;
                client.absorb(bytes);
                client.state = .wait_server_hello_done;
                return .more;
            },
            .wait_server_hello_done => {
                if (kind == CERTIFICATE_REQUEST) {
                    client.certificate_requested = true;
                    client.absorb(bytes);
                    return .more;
                }
                if (kind != SERVER_HELLO_DONE or body.len != 0) return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output);
                client.absorb(bytes);
                return client.clientFlight12(output);
            },
            .wait_finished12 => {
                if (kind != FINISHED) return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output);
                return client.finished12(bytes, body, output);
            },
            .connected => {
                if (client.version == TLS12) {
                    // No renegotiation: a HelloRequest is passed over.
                    if (kind == HELLO_REQUEST and body.len == 0) return .more;
                    return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output);
                }
                return client.afterHandshake(kind, body, output);
            },
            else => return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output),
        }
    }

    fn serverHello(client: *Client, bytes: []const u8, body: []const u8, output: *Output) Event {
        var reader = wire.Reader.of(body);
        const version = reader.u16_() orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        const random = reader.bytes(32) orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        const session = reader.vector(1) orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        const suite_id = reader.u16_() orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        const compression = reader.u8_() orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        // A TLS 1.2 server may send no extensions at all.
        const extensions = if (reader.atEnd()) &[_]u8{} else reader.vector(2) orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        if (version != TLS12 or compression != 0) return client.fail(.unsupported, ALERT_PROTOCOL_VERSION, output);
        const suite = schedule.suiteOf(suite_id) orelse return client.fail(.unsupported, ALERT_ILLEGAL_PARAMETER, output);

        var chosen_version: u16 = TLS12;
        var share_group: u16 = 0;
        var share: []const u8 = &.{};
        var cookie: []const u8 = &.{};
        var extended_master = false;
        var renegotiation_ok = true;
        var alpn: []const u8 = &.{};
        const retry = same(random, &retry_random);
        var ext = wire.Reader.of(extensions);
        while (!ext.atEnd()) {
            const ext_type = ext.u16_() orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
            const raw = ext.vector(2) orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
            var data = wire.Reader.of(raw);
            switch (ext_type) {
                EXT_SUPPORTED_VERSIONS => chosen_version = data.u16_() orelse 0,
                EXT_KEY_SHARE => {
                    share_group = data.u16_() orelse 0;
                    if (!retry) share = data.vector(2) orelse &.{};
                },
                EXT_COOKIE => cookie = data.vector(2) orelse &.{},
                EXT_EXTENDED_MASTER_SECRET => extended_master = true,
                EXT_RENEGOTIATION_INFO => renegotiation_ok = raw.len == 1 and raw[0] == 0,
                EXT_ALPN => {
                    var names = wire.Reader.of(data.vector(2) orelse &.{});
                    alpn = names.vector(1) orelse &.{};
                },
                else => {},
            }
        }

        if (chosen_version == TLS12) {
            return client.serverHello12(bytes, random, suite, extended_master, renegotiation_ok, alpn, output);
        }
        if (chosen_version != TLS13) return client.fail(.unsupported, ALERT_PROTOCOL_VERSION, output);
        if (suite.tls12) return client.fail(.unsupported, ALERT_ILLEGAL_PARAMETER, output);
        if (!same(session, client.session_id[0..client.session_id_length])) return client.fail(.decode, ALERT_ILLEGAL_PARAMETER, output);

        if (retry) {
            if (client.retried or share_group == client.group or (share_group != GROUP_P256 and share_group != GROUP_P384) or cookie.len > client.cookie.len) {
                return client.fail(.unsupported, ALERT_ILLEGAL_PARAMETER, output);
            }
            client.suite = suite;
            client.startTranscript();
            // The first ClientHello stands in the transcript as its hash.
            var first: schedule.Secret = undefined;
            var hashed: crypto.HashContext = .{};
            _ = client.cb.InitHash(&hashed, suite.hash);
            client.cb.UpdateHash(&hashed, &client.hello, @intCast(client.hello_length));
            _ = client.cb.FinishHash(&hashed, &first);
            const header = [_]u8{ MESSAGE_HASH, 0, 0, @intCast(suite.hash_length) };
            client.absorb(&header);
            client.absorb(first[0..suite.hash_length]);
            client.absorb(bytes);
            client.retried = true;
            client.group = share_group;
            const curve: u32 = if (share_group == GROUP_P256) crypto.CURVE_P256 else crypto.CURVE_P384;
            _ = client.cb.MakeKeyPair(curve, &client.private_key, &client.public_key, &client.public_length);
            @memcpy(client.cookie[0..cookie.len], cookie);
            client.cookie_length = @intCast(cookie.len);
            client.hello_length = client.buildHello();
            client.sendHello(output);
            return .more;
        }

        if (share_group != client.group) return client.fail(.unsupported, ALERT_ILLEGAL_PARAMETER, output);
        if (client.retried and suite.id != client.suite.id) return client.fail(.unsupported, ALERT_ILLEGAL_PARAMETER, output);
        client.suite = suite;
        if (!client.transcript_started) {
            client.startTranscript();
            client.absorb(client.hello[0..client.hello_length]);
        }
        client.absorb(bytes);

        var shared: [crypto.CURVE_SECRET_MAX]u8 = undefined;
        const curve = curveOf(client.group);
        if (client.cb.SharedSecret(curve, &client.private_key, &Bytes.of(share), &shared) != crypto.CRYPTOERR_OK) {
            return client.fail(.unsupported, ALERT_ILLEGAL_PARAMETER, output);
        }
        schedule.wipe(&client.private_key);
        schedule.handshakeSecret(client.cb, suite, shared[0..crypto.secretLength(curve)], &client.handshake_secret);
        schedule.wipe(&shared);
        var hash: schedule.Secret = undefined;
        const so_far = client.digest(&hash);
        const secret = client.handshake_secret[0..suite.hash_length];
        schedule.deriveSecret(client.cb, suite, secret, "c hs traffic", so_far, &client.client_traffic);
        schedule.deriveSecret(client.cb, suite, secret, "s hs traffic", so_far, &client.server_traffic);
        client.read_keys = schedule.trafficKeys(client.cb, suite, client.server_traffic[0..suite.hash_length]);
        client.write_keys = schedule.trafficKeys(client.cb, suite, client.client_traffic[0..suite.hash_length]);
        client.reading_protected = true;
        client.writing_protected = true;
        client.state = .wait_encrypted_extensions;
        return .more;
    }

    fn startTranscript(client: *Client) void {
        _ = client.cb.InitHash(&client.transcript, client.suite.hash);
        client.transcript_started = true;
    }

    fn encryptedExtensions(client: *Client, body: []const u8) bool {
        var reader = wire.Reader.of(body);
        var ext = wire.Reader.of(reader.vector(2) orelse return false);
        if (!reader.atEnd()) return false;
        while (!ext.atEnd()) {
            const ext_type = ext.u16_() orelse return false;
            const data = ext.vector(2) orelse return false;
            if (ext_type == EXT_ALPN) {
                var list = wire.Reader.of(data);
                var names = wire.Reader.of(list.vector(2) orelse return false);
                const name = names.vector(1) orelse return false;
                if (!client.keepProtocol(name)) return false;
            }
        }
        return true;
    }

    fn keepProtocol(client: *Client, name: []const u8) bool {
        if (name.len > client.alpn.len) return false;
        @memcpy(client.alpn[0..name.len], name);
        client.alpn_length = @intCast(name.len);
        return true;
    }

    /// TLS 1.3's Certificate: a context, then entries with extensions.
    fn certificates(client: *Client, body: []const u8, output: *Output) Event {
        var reader = wire.Reader.of(body);
        const context = reader.vector(1) orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        if (context.len != 0) return client.fail(.decode, ALERT_ILLEGAL_PARAMETER, output);
        var list = wire.Reader.of(reader.vector(3) orelse return client.fail(.decode, ALERT_DECODE_ERROR, output));
        var ders: [chain.max_chain][]const u8 = undefined;
        var count: usize = 0;
        while (!list.atEnd()) {
            const der = list.vector(3) orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
            _ = list.vector(2) orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
            if (count == chain.max_chain) return client.fail(.certificate, ALERT_BAD_CERTIFICATE, output);
            ders[count] = der;
            count += 1;
        }
        return client.checkChain(ders[0..count], output);
    }

    /// TLS 1.2's Certificate: the entries alone.
    fn certificates12(client: *Client, body: []const u8, output: *Output) Event {
        var reader = wire.Reader.of(body);
        var list = wire.Reader.of(reader.vector(3) orelse return client.fail(.decode, ALERT_DECODE_ERROR, output));
        if (!reader.atEnd()) return client.fail(.decode, ALERT_DECODE_ERROR, output);
        var ders: [chain.max_chain][]const u8 = undefined;
        var count: usize = 0;
        while (!list.atEnd()) {
            const der = list.vector(3) orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
            if (count == chain.max_chain) return client.fail(.certificate, ALERT_BAD_CERTIFICATE, output);
            ders[count] = der;
            count += 1;
        }
        return client.checkChain(ders[0..count], output);
    }

    /// The server's chain checked, and its first certificate kept for the
    /// key that signs.
    fn checkChain(client: *Client, ders: []const []const u8, output: *Output) Event {
        if (ders.len == 0 or ders[0].len > leaf_max) return client.fail(.certificate, ALERT_BAD_CERTIFICATE, output);
        @memcpy(client.leaf[0..ders[0].len], ders[0]);
        client.leaf_length = ders[0].len;
        if (client.config.verify) {
            client.verdict = chain.verify(client.cb, ders, client.config.stores, client.config.host, client.config.now);
            if (client.verdict != .trusted) return client.fail(.certificate, alertFor(client.verdict), output);
        } else if (certificate.parse(ders[0]) == null) {
            client.verdict = .malformed;
            return client.fail(.certificate, ALERT_BAD_CERTIFICATE, output);
        }
        return .more;
    }

    /// Whether the server's key signed `signed` with `scheme`. TLS 1.3
    /// takes no PKCS #1; a TLS 1.2 suite names the key's kind.
    fn checkSigned(client: *Client, scheme: u16, signed: []const u8, signature: []const u8) Failure {
        const leaf = certificate.parse(client.leaf[0..client.leaf_length]) orelse return .certificate;
        const key = &leaf.key;
        const ec = key.kind == .p256 or key.kind == .p384;
        if (client.version == TLS12) {
            if (client.suite.ecdsa and !(ec or key.kind == .ed25519)) return .unsupported;
            if (!client.suite.ecdsa and key.kind != .rsa) return .unsupported;
        }
        var hash: u32 = 0;
        var algorithm: u32 = 0;
        switch (scheme) {
            // ECDSA: in TLS 1.3 the scheme names the curve; in TLS 1.2 only
            // the hash, the key the curve.
            0x0403, 0x0503, 0x0603 => if (ec and (client.version == TLS12 or
                (scheme == 0x0403 and key.kind == .p256) or (scheme == 0x0503 and key.kind == .p384)))
            {
                hash = switch (scheme) {
                    0x0403 => crypto.HASH_SHA256,
                    0x0503 => crypto.HASH_SHA384,
                    else => crypto.HASH_SHA512,
                };
                algorithm = if (key.kind == .p256) crypto.SIG_ECDSA_P256 else crypto.SIG_ECDSA_P384;
            },
            0x0804, 0x0805, 0x0806 => if (key.kind == .rsa) {
                hash = switch (scheme) {
                    0x0804 => crypto.HASH_SHA256,
                    0x0805 => crypto.HASH_SHA384,
                    else => crypto.HASH_SHA512,
                };
                algorithm = switch (scheme) {
                    0x0804 => crypto.SIG_RSA_PSS_SHA256,
                    0x0805 => crypto.SIG_RSA_PSS_SHA384,
                    else => crypto.SIG_RSA_PSS_SHA512,
                };
            },
            0x0401, 0x0501, 0x0601 => if (key.kind == .rsa and client.version == TLS12) {
                hash = switch (scheme) {
                    0x0401 => crypto.HASH_SHA256,
                    0x0501 => crypto.HASH_SHA384,
                    else => crypto.HASH_SHA512,
                };
                algorithm = switch (scheme) {
                    0x0401 => crypto.SIG_RSA_PKCS1_SHA256,
                    0x0501 => crypto.SIG_RSA_PKCS1_SHA384,
                    else => crypto.SIG_RSA_PKCS1_SHA512,
                };
            },
            0x0807 => if (key.kind == .ed25519) {
                algorithm = crypto.SIG_ED25519;
            },
            else => {},
        }
        if (algorithm == 0) return .unsupported;

        var message_digest: [crypto.DIGEST_MAX]u8 = undefined;
        var checked = Bytes.of(signed);
        if (hash != 0) {
            var context: crypto.HashContext = .{};
            _ = client.cb.InitHash(&context, hash);
            client.cb.UpdateHash(&context, signed.ptr, @intCast(signed.len));
            const length = client.cb.FinishHash(&context, &message_digest);
            checked = Bytes.of(message_digest[0..length]);
        }
        const public_key: crypto.PublicKey = .{
            .modulus = Bytes.of(key.modulus),
            .exponent = Bytes.of(key.exponent),
            .point = Bytes.of(key.point),
        };
        if (client.cb.VerifySignature(algorithm, &public_key, &checked, &Bytes.of(signature)) != crypto.CRYPTOERR_OK) return .signature;
        return .none;
    }

    fn certificateVerify(client: *Client, body: []const u8, output: *Output) Event {
        var reader = wire.Reader.of(body);
        const scheme = reader.u16_() orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        const signature = reader.vector(2) orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        if (!reader.atEnd()) return client.fail(.decode, ALERT_DECODE_ERROR, output);

        // 64 spaces, the context string, a zero, the transcript's digest.
        var content: [64 + 34 + schedule.secret_max]u8 = undefined;
        @memset(content[0..64], 0x20);
        const label = "TLS 1.3, server CertificateVerify";
        @memcpy(content[64..][0..label.len], label);
        content[64 + label.len] = 0;
        var transcript_hash: schedule.Secret = undefined;
        const so_far = client.digest(&transcript_hash);
        @memcpy(content[64 + label.len + 1 ..][0..so_far.len], so_far);
        const signed = content[0 .. 64 + label.len + 1 + so_far.len];
        return switch (client.checkSigned(scheme, signed, signature)) {
            .none => .more,
            .signature => client.fail(.signature, ALERT_DECRYPT_ERROR, output),
            .certificate => client.fail(.certificate, ALERT_BAD_CERTIFICATE, output),
            else => client.fail(.unsupported, ALERT_ILLEGAL_PARAMETER, output),
        };
    }

    fn finished(client: *Client, bytes: []const u8, body: []const u8, output: *Output) Event {
        const suite = client.suite;
        const length = suite.hash_length;
        var transcript_hash: schedule.Secret = undefined;
        var expected: schedule.Secret = undefined;
        schedule.finished(client.cb, suite, client.server_traffic[0..length], client.digest(&transcript_hash), &expected);
        if (body.len != length or !sameTime(body, expected[0..length])) return client.fail(.finished, ALERT_DECRYPT_ERROR, output);
        client.absorb(bytes);

        // The application secrets come from the transcript to here.
        var master: schedule.Secret = undefined;
        schedule.masterSecret(client.cb, suite, client.handshake_secret[0..length], &master);
        const through_server = client.digest(&transcript_hash);
        var client_application: schedule.Secret = undefined;
        var server_application: schedule.Secret = undefined;
        schedule.deriveSecret(client.cb, suite, master[0..length], "c ap traffic", through_server, &client_application);
        schedule.deriveSecret(client.cb, suite, master[0..length], "s ap traffic", through_server, &server_application);
        schedule.wipe(&master);

        if (client.session_id_length != 0) {
            output.length += record.plain(record.CHANGE_CIPHER_SPEC, false, &.{1}, output.room());
        }
        var message_buffer: [4 + schedule.secret_max]u8 = undefined;
        if (client.certificate_requested) {
            // No certificate of our own: an empty list.
            const empty = [_]u8{ CERTIFICATE, 0, 0, 4, 0, 0, 0, 0 };
            client.absorb(&empty);
            output.length += record.seal(client.cb, &client.write_keys, record.HANDSHAKE, &empty, output.room());
        }
        message_buffer[0] = FINISHED;
        message_buffer[1] = 0;
        message_buffer[2] = 0;
        message_buffer[3] = @intCast(length);
        schedule.finished(client.cb, suite, client.client_traffic[0..length], client.digest(&transcript_hash), message_buffer[4..]);
        client.absorb(message_buffer[0 .. 4 + length]);
        output.length += record.seal(client.cb, &client.write_keys, record.HANDSHAKE, message_buffer[0 .. 4 + length], output.room());

        client.client_traffic = client_application;
        client.server_traffic = server_application;
        client.read_keys = schedule.trafficKeys(client.cb, suite, server_application[0..length]);
        client.write_keys = schedule.trafficKeys(client.cb, suite, client_application[0..length]);
        schedule.wipe(&client.handshake_secret);
        client.state = .connected;
        return .connected;
    }

    fn afterHandshake(client: *Client, kind: u8, body: []const u8, output: *Output) Event {
        const length = client.suite.hash_length;
        switch (kind) {
            NEW_SESSION_TICKET => return .more, // no resumption
            KEY_UPDATE => {
                if (body.len != 1 or body[0] > 1) return client.fail(.decode, ALERT_DECODE_ERROR, output);
                var next: schedule.Secret = undefined;
                schedule.nextSecret(client.cb, client.suite, client.server_traffic[0..length], &next);
                client.server_traffic = next;
                client.read_keys = schedule.trafficKeys(client.cb, client.suite, next[0..length]);
                if (body[0] == 1) {
                    // Asked to update ours too: say so under the old keys.
                    const update = [_]u8{ KEY_UPDATE, 0, 0, 1, 0 };
                    output.length += record.seal(client.cb, &client.write_keys, record.HANDSHAKE, &update, output.room());
                    schedule.nextSecret(client.cb, client.suite, client.client_traffic[0..length], &next);
                    client.client_traffic = next;
                    client.write_keys = schedule.trafficKeys(client.cb, client.suite, next[0..length]);
                }
                return .more;
            },
            else => return client.fail(.unexpected, ALERT_UNEXPECTED_MESSAGE, output),
        }
    }

    // --- TLS 1.2 ------------------------------------------------------------

    fn serverHello12(
        client: *Client,
        bytes: []const u8,
        random: []const u8,
        suite: schedule.Suite,
        extended_master: bool,
        renegotiation_ok: bool,
        alpn: []const u8,
        output: *Output,
    ) Event {
        if (!suite.tls12 or client.retried) return client.fail(.unsupported, ALERT_ILLEGAL_PARAMETER, output);
        // A server that could have answered 1.3 says so in its random.
        if (same(random[24..31], &downgrade_marker) and random[31] <= 1) return client.fail(.unsupported, ALERT_ILLEGAL_PARAMETER, output);
        if (!renegotiation_ok) return client.fail(.unsupported, ALERT_HANDSHAKE_FAILURE, output);
        if (alpn.len != 0 and !client.keepProtocol(alpn)) return client.fail(.decode, ALERT_DECODE_ERROR, output);
        client.version = TLS12;
        client.suite = suite;
        client.server_random = random[0..32].*;
        client.extended_master = extended_master;
        client.startTranscript();
        client.absorb(client.hello[0..client.hello_length]);
        client.absorb(bytes);
        client.state = .wait_certificate12;
        return .more;
    }

    /// ServerKeyExchange: the server's ECDHE share, signed with its key
    /// over both randoms and the share.
    fn serverKeyExchange(client: *Client, body: []const u8, output: *Output) Event {
        var reader = wire.Reader.of(body);
        const curve_type = reader.u8_() orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        const group = reader.u16_() orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        const share = reader.vector(1) orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        const parameters = body[0 .. 4 + share.len];
        const scheme = reader.u16_() orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        const signature = reader.vector(2) orelse return client.fail(.decode, ALERT_DECODE_ERROR, output);
        if (!reader.atEnd() or curve_type != 3) return client.fail(.decode, ALERT_DECODE_ERROR, output);
        if (group != GROUP_X25519 and group != GROUP_P256 and group != GROUP_P384) return client.fail(.unsupported, ALERT_ILLEGAL_PARAMETER, output);
        if (share.len > client.server_share.len) return client.fail(.decode, ALERT_DECODE_ERROR, output);

        var signed: [64 + 4 + crypto.CURVE_PUBLIC_MAX]u8 = undefined;
        @memcpy(signed[0..32], &client.random);
        @memcpy(signed[32..64], &client.server_random);
        @memcpy(signed[64..][0..parameters.len], parameters);
        switch (client.checkSigned(scheme, signed[0 .. 64 + parameters.len], signature)) {
            .none => {},
            .signature => return client.fail(.signature, ALERT_DECRYPT_ERROR, output),
            .certificate => return client.fail(.certificate, ALERT_BAD_CERTIFICATE, output),
            else => return client.fail(.unsupported, ALERT_ILLEGAL_PARAMETER, output),
        }
        @memcpy(client.server_share[0..share.len], share);
        client.server_share_length = share.len;
        client.server_group = group;
        return .more;
    }

    /// After ServerHelloDone: an empty Certificate if one was asked for,
    /// ClientKeyExchange, ChangeCipherSpec and the client's Finished.
    fn clientFlight12(client: *Client, output: *Output) Event {
        const suite = client.suite;
        if (client.certificate_requested) {
            const empty = [_]u8{ CERTIFICATE, 0, 0, 3, 0, 0, 0 };
            client.absorb(&empty);
            output.length += record.plain(record.HANDSHAKE, false, &empty, output.room());
        }

        // Our share on the server's group: the hello's X25519 one, or one
        // made now.
        const curve = curveOf(client.server_group);
        if (client.server_group != client.group) {
            _ = client.cb.MakeKeyPair(curve, &client.private_key, &client.public_key, &client.public_length);
            client.group = client.server_group;
        }
        var exchange: [5 + crypto.CURVE_PUBLIC_MAX]u8 = undefined;
        const share_length = client.public_length;
        exchange[0] = CLIENT_KEY_EXCHANGE;
        exchange[1] = 0;
        exchange[2] = 0;
        exchange[3] = @intCast(share_length + 1);
        exchange[4] = @intCast(share_length);
        @memcpy(exchange[5..][0..share_length], client.public_key[0..share_length]);
        const message = exchange[0 .. 5 + share_length];
        client.absorb(message);
        output.length += record.plain(record.HANDSHAKE, false, message, output.room());

        var shared: [crypto.CURVE_SECRET_MAX]u8 = undefined;
        if (client.cb.SharedSecret(curve, &client.private_key, &Bytes.of(client.server_share[0..client.server_share_length]), &shared) != crypto.CRYPTOERR_OK) {
            return client.fail(.unsupported, ALERT_ILLEGAL_PARAMETER, output);
        }
        schedule.wipe(&client.private_key);
        const pre_master = shared[0..crypto.secretLength(curve)];
        var transcript_hash: schedule.Secret = undefined;
        if (client.extended_master) {
            prf.prf(client.cb, suite.hash, pre_master, "extended master secret", &.{client.digest(&transcript_hash)}, &client.master);
        } else {
            prf.prf(client.cb, suite.hash, pre_master, "master secret", &.{ &client.random, &client.server_random }, &client.master);
        }
        schedule.wipe(&shared);
        prf.keys(client.cb, suite, &client.master, &client.random, &client.server_random, &client.write_keys, &client.read_keys);

        output.length += record.plain(record.CHANGE_CIPHER_SPEC, false, &.{1}, output.room());
        client.writing_protected = true;
        var finished_message: [16]u8 = undefined;
        finished_message[0] = FINISHED;
        finished_message[1] = 0;
        finished_message[2] = 0;
        finished_message[3] = 12;
        prf.prf(client.cb, suite.hash, &client.master, "client finished", &.{client.digest(&transcript_hash)}, finished_message[4..16]);
        client.absorb(&finished_message);
        output.length += record.seal12(client.cb, &client.write_keys, record.HANDSHAKE, &finished_message, output.room());
        client.state = .wait_change_cipher_spec;
        return .more;
    }

    fn finished12(client: *Client, bytes: []const u8, body: []const u8, output: *Output) Event {
        var transcript_hash: schedule.Secret = undefined;
        var expected: [12]u8 = undefined;
        prf.prf(client.cb, client.suite.hash, &client.master, "server finished", &.{client.digest(&transcript_hash)}, &expected);
        if (body.len != 12 or !sameTime(body, &expected)) return client.fail(.finished, ALERT_DECRYPT_ERROR, output);
        client.absorb(bytes);
        schedule.wipe(&client.master);
        client.state = .connected;
        return .connected;
    }

    /// The protocol the server chose by ALPN, or empty.
    pub fn protocol(client: *const Client) []const u8 {
        return client.alpn[0..client.alpn_length];
    }
};

const ALERT_HANDSHAKE_FAILURE: u8 = 40;

fn curveOf(group: u16) u32 {
    return switch (group) {
        GROUP_X25519 => crypto.CURVE_X25519,
        GROUP_P256 => crypto.CURVE_P256,
        else => crypto.CURVE_P384,
    };
}

fn alertFor(verdict: chain.Verdict) u8 {
    return switch (verdict) {
        .expired, .not_yet_valid => ALERT_CERTIFICATE_EXPIRED,
        .unknown_issuer => ALERT_UNKNOWN_CA,
        .unsupported => ALERT_UNSUPPORTED_CERTIFICATE,
        else => ALERT_BAD_CERTIFICATE,
    };
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// The same, taking the same time whatever the bytes: for a MAC.
fn sameTime(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var any: u8 = 0;
    for (a, b) |x, y| any |= x ^ y;
    return any == 0;
}

/// Whether a host is an address rather than a name: SNI carries only
/// names.
fn isAddress(host: []const u8) bool {
    var digits_and_dots = true;
    for (host) |char| {
        if (char == ':') return true;
        if (!(char == '.' or (char >= '0' and char <= '9'))) digits_and_dots = false;
    }
    return digits_and_dots;
}

// SPDX-License-Identifier: MIT
//! One SSH connection, the client's end, as a machine that takes bytes in
//! and gives bytes out (it touches no socket: the unit's task does that,
//! and the tests play it against the server's end): the transport
//! (`transport.zig`) with the client's part of the key exchange, the
//! login (RFC 4252) and one session channel (`channel.zig`). It moves on
//! in steps, each begun by its caller and over when `step` says so.
//!
//! **Connecting.** The version lines and the key exchange:
//! mlkem768x25519-sha256 when the server has it - our ML-KEM-768
//! encapsulation key and X25519 share; the server's ciphertext and X25519
//! share; K the SHA-256 of the two secrets - or else curve25519-sha256,
//! K the X25519 secret. The server's Ed25519 signature over H is checked
//! with the host key it sent; whether that key is the right one is the
//! caller's to say, before it logs in. A later exchange must come with
//! the same key.
//!
//! **The login.** `ssh-userauth` asked for once, then each way given, in
//! turn, while the server still takes it: the key, signed over the
//! session id and the request (RFC 4252, 7), then the password; with
//! neither, `none`, which asks the server what it takes. When every way
//! given is refused, `methods` holds what the server still takes, and a
//! login may be tried again with others. A banner the server sends
//! meanwhile is kept for the caller, as it came.
//!
//! **The session.** One `session` channel; a terminal asked for with its
//! type and size (`pty-req`; a refusal leaves the session without one),
//! then `shell`, `exec` with a command, or `subsystem` with a name. Its errors come with its data.
//! The window may change (`window-change`); our input may end (EOF). The
//! server's `exit-status` is kept, and `exit-signal` is a status of 255;
//! the session is over when the server closes the channel.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const ssh = sdk.devices.ssh;
const ssh_keys = sdk.devices.ssh.keys;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const wire = @import("wire.zig");
const transport_file = @import("transport.zig");
const channel_file = @import("channel.zig");
const connection_file = @import("connection.zig");
const Transport = transport_file.Transport;
const Channel = channel_file.Channel;
const Packet = transport_file.Packet;
const Reader = wire.Reader;
const Writer = wire.Writer;

const msg = transport_file;

/// The status of a session that ended without one.
pub const status_none: u32 = 255;
/// The terminal mode a pty-req sets (RFC 4254, 8): the erase character,
/// DEL, as an xterm's backspace sends it.
const mode_verase: u8 = 3;
const mode_end: u8 = 0;

pub const Step = enum(u8) {
    /// The version lines and the first key exchange.
    connecting,
    /// The keys in use; the host key known.
    connected,
    /// ssh-userauth asked for; a login request out.
    service,
    authenticating,
    /// Logged in; or every way given refused.
    logged_in,
    refused,
    /// The channel asked for; a terminal asked for; the shell or command.
    opening,
    terminal,
    starting,
    /// The session runs; or the server would not have it.
    running,
    failed,
};

pub const Client = struct {
    transport: Transport,
    channel: Channel = .{ .keep_extended = true },
    step: Step = .connecting,

    // --- the key exchange --------------------------------------------------

    /// The server's host key, from the first exchange on.
    host_public: [32]u8 = @splat(0),
    /// Our shares for the exchange under way: the X25519 private key, the
    /// ML-KEM decapsulation key, and what was sent - the encapsulation
    /// key and the X25519 share, or the share alone.
    x25519_private: [32]u8 = @splat(0),
    kem_private: [crypto.MLKEM768_PRIVATE]u8 = undefined,
    client_blob: [crypto.MLKEM768_PUBLIC + 32]u8 = undefined,
    client_blob_length: usize = 0,

    // --- the login ---------------------------------------------------------

    service_accepted: bool = false,
    user: [64]u8 = @splat(0),
    user_length: usize = 0,
    key_seed: [32]u8 = @splat(0),
    key_public: [32]u8 = @splat(0),
    key_given: bool = false,
    key_tried: bool = false,
    password: [ssh.SSH_PASSWORD_MAX]u8 = @splat(0),
    password_length: usize = 0,
    password_tried: bool = false,
    none_tried: bool = false,
    /// What the server still takes, as its last refusal said; empty until
    /// one came.
    methods: [128]u8 = @splat(0),
    methods_length: usize = 0,
    /// The banners the server sent since the caller last took them, as
    /// much as fits.
    banner: [ssh.SSH_BANNER_MAX]u8 = undefined,
    banner_length: usize = 0,

    // --- the session -------------------------------------------------------

    command: [512]u8 = @splat(0),
    command_length: usize = 0,
    /// The command is a subsystem's name.
    subsystem: bool = false,
    terminal: [32]u8 = @splat(0),
    terminal_length: usize = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    /// The server gave the session a terminal.
    has_terminal: bool = false,
    exit_status: u32 = status_none,
    status_given: bool = false,

    /// A new client in `client`'s memory, made there: it is too big for a
    /// stack.
    pub fn init(client: *Client, cb: *CryptoBase) void {
        client.* = .{ .transport = .{ .cb = cb, .role = .client } };
    }

    /// Our version line and first KEXINIT queued.
    pub fn start(client: *Client) void {
        client.transport.start();
    }

    /// Everything whole that came in, taken, while there is room for
    /// what it answers.
    pub fn process(client: *Client) void {
        const t = &client.transport;
        while (t.roomForReply()) {
            const packet = t.next() orelse return;
            if (packet.payload.len > 0) client.handle(packet);
            t.done();
            if (t.phase != .packets) return;
        }
    }

    fn handle(client: *Client, packet: Packet) void {
        const t = &client.transport;
        const kind = packet.payload[0];
        if (t.common(packet)) {
            switch (kind) {
                // The server's KEXINIT, the first or a later one: ours
                // went, so our shares go.
                msg.msg_kexinit => if (t.kex == .exchanging) client.sendShares(),
                msg.msg_newkeys => if (t.kex == .idle) {
                    if (client.step == .connecting) client.step = .connected;
                    client.channel.acknowledge(t, false);
                },
                else => {},
            }
            return;
        }
        var reader = Reader{ .bytes = packet.payload, .at = 1 };
        switch (kind) {
            msg.msg_kex_ecdh_reply => client.ecdhReply(&reader),
            msg.msg_service_accept => client.serviceAccept(),
            msg.msg_userauth_failure => client.loginFailure(&reader),
            msg.msg_userauth_success => client.loginSuccess(),
            // A password change asked for (60 after a password): not
            // given.
            msg.msg_userauth_pk_ok => if (client.step == .authenticating) client.tryNext(),
            msg.msg_userauth_banner => client.keepBanner(&reader),
            msg.msg_global_request => {
                _ = reader.string();
                if (reader.boolean() and !reader.bad) t.send(&.{msg.msg_request_failure});
            },
            msg.msg_request_failure => {},
            msg.msg_channel_open => client.refuseChannel(&reader),
            msg.msg_channel_open_confirmation...msg.msg_channel_failure => client.channelMessage(kind, &reader),
            else => t.unimplemented(packet.sequence),
        }
    }

    // --- the key exchange --------------------------------------------------

    /// Our shares for the exchange the KEXINITs chose: an X25519 key, and
    /// for the hybrid an ML-KEM-768 key in front of it.
    fn sendShares(client: *Client) void {
        const t = &client.transport;
        const cb = t.cb;
        var public: [32]u8 = undefined;
        var public_length: u32 = 32;
        if (cb.MakeKeyPair(crypto.CURVE_X25519, &client.x25519_private, &public, &public_length) != crypto.CRYPTOERR_OK) {
            return t.disconnect(msg.reason_key_exchange_failed, "no X25519 key");
        }
        var length: usize = 32;
        if (t.hybrid) {
            if (cb.KemKeyPair(crypto.KEM_MLKEM768, client.client_blob[0..crypto.MLKEM768_PUBLIC], &client.kem_private) != crypto.CRYPTOERR_OK) {
                return t.disconnect(msg.reason_key_exchange_failed, "no ML-KEM key");
            }
            length += crypto.MLKEM768_PUBLIC;
        }
        client.client_blob[length - 32 ..][0..32].* = public;
        client.client_blob_length = length;
        var bytes: [8 + crypto.MLKEM768_PUBLIC + 32]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(msg.msg_kex_ecdh_init);
        writer.string(client.client_blob[0..length]);
        t.send(writer.written());
    }

    /// The server's reply: its host key, its shares and its signature; K
    /// and H, the signature checked, NEWKEYS sent and our keys on.
    fn ecdhReply(client: *Client, reader: *Reader) void {
        const t = &client.transport;
        const cb = t.cb;
        if (t.kex != .exchanging or client.client_blob_length == 0) return t.disconnect(msg.reason_protocol_error, "unexpected KEX_ECDH_REPLY");
        const host_blob = reader.string();
        const server_blob = reader.string();
        var signature_reader = Reader{ .bytes = reader.string() };
        const signature_type = signature_reader.string();
        const signature = signature_reader.string();
        const blob_length: usize = if (t.hybrid) crypto.MLKEM768_CIPHERTEXT + 32 else 32;
        if (reader.bad or signature_reader.bad or server_blob.len != blob_length) return t.disconnect(msg.reason_key_exchange_failed, "bad KEX_ECDH_REPLY");
        const host_public = ssh_keys.fromBlob(host_blob) orelse return t.disconnect(msg.reason_key_exchange_failed, "host key not ssh-ed25519");
        if (t.exchanged and !wire.same(&host_public, &client.host_public)) return t.disconnect(msg.reason_host_key_not_verifiable, "host key changed");
        if (!wire.same(signature_type, ssh_keys.key_type) or signature.len != crypto.SIGNATURE_ED25519) return t.disconnect(msg.reason_key_exchange_failed, "bad signature");

        var secret: [32]u8 = undefined;
        defer transport_file.wipe(&secret);
        var kem_secret: [crypto.KEM_SECRET]u8 = undefined;
        defer transport_file.wipe(&kem_secret);
        defer transport_file.wipe(&client.x25519_private);
        defer transport_file.wipe(&client.kem_private);
        const server_share = server_blob[server_blob.len - 32 ..];
        if (cb.SharedSecret(crypto.CURVE_X25519, &client.x25519_private, &crypto.Bytes.of(server_share), &secret) != crypto.CRYPTOERR_OK) {
            return t.disconnect(msg.reason_key_exchange_failed, "no shared secret");
        }
        if (t.hybrid and cb.Decapsulate(crypto.KEM_MLKEM768, &client.kem_private, &crypto.Bytes.of(server_blob[0..crypto.MLKEM768_CIPHERTEXT]), &kem_secret) != crypto.CRYPTOERR_OK) {
            return t.disconnect(msg.reason_key_exchange_failed, "bad ML-KEM ciphertext");
        }
        var shared_bytes: [37]u8 = undefined;
        defer transport_file.wipe(&shared_bytes);
        var shared = Writer{ .bytes = &shared_bytes };
        t.encodeShared(if (t.hybrid) &kem_secret else null, &secret, &shared);
        const exchange_hash = t.exchangeHash(host_blob, client.client_blob[0..client.client_blob_length], server_blob, shared.written());
        const host_key: crypto.PublicKey = .{ .point = crypto.Bytes.of(&host_public) };
        if (cb.VerifySignature(crypto.SIG_ED25519, &host_key, &crypto.Bytes.of(&exchange_hash), &crypto.Bytes.of(signature)) != crypto.CRYPTOERR_OK) {
            return t.disconnect(msg.reason_key_exchange_failed, "host signature does not verify");
        }
        client.host_public = host_public;
        client.client_blob_length = 0;
        t.newKeys(shared.written(), &exchange_hash);
    }

    // --- the login ---------------------------------------------------------

    /// A login with what `given` holds: ssh-userauth asked for first, if
    /// it has not been; then each way in turn.
    pub fn login(client: *Client, given: *const ssh.SshLogin) void {
        const t = &client.transport;
        client.user_length = 0;
        while (client.user_length < given.user.len and given.user[client.user_length] != 0) client.user_length += 1;
        client.user_length = @min(client.user_length, client.user.len);
        @memcpy(client.user[0..client.user_length], given.user[0..client.user_length]);
        client.key_given = given.key_given != 0;
        client.key_seed = given.key_seed;
        client.key_public = given.key_public;
        client.key_tried = false;
        client.password_length = @min(given.password_length, ssh.SSH_PASSWORD_MAX);
        @memcpy(client.password[0..client.password_length], given.password[0..client.password_length]);
        client.password_tried = false;
        client.none_tried = false;
        if (client.service_accepted) return client.tryNext();
        var bytes: [32]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(msg.msg_service_request);
        writer.string("ssh-userauth");
        t.send(writer.written());
        client.step = .service;
    }

    fn serviceAccept(client: *Client) void {
        if (client.step != .service) return client.transport.disconnect(msg.reason_protocol_error, "unexpected SERVICE_ACCEPT");
        client.service_accepted = true;
        client.tryNext();
    }

    /// Whether the server's last refusal still lists `method`; any, before
    /// a refusal.
    fn takes(client: *const Client, method: []const u8) bool {
        if (client.methods_length == 0) return true;
        return wire.hasName(client.methods[0..client.methods_length], method);
    }

    /// The next way to log in sent: the key, then the password - or
    /// `none` when neither is given; refused when no way is left.
    fn tryNext(client: *Client) void {
        if (!client.key_given and client.password_length == 0 and !client.none_tried) {
            client.none_tried = true;
            return client.sendNone();
        }
        if (client.key_given and !client.key_tried and client.takes("publickey")) {
            client.key_tried = true;
            return client.sendKey();
        }
        if (client.password_length > 0 and !client.password_tried and client.takes("password")) {
            client.password_tried = true;
            return client.sendPassword();
        }
        client.forget();
        client.step = .refused;
    }

    /// The request's first fields, the same for every way.
    fn requestHead(client: *const Client, writer: *Writer, method: []const u8) void {
        writer.byte(msg.msg_userauth_request);
        writer.string(client.user[0..client.user_length]);
        writer.string("ssh-connection");
        writer.string(method);
    }

    fn sendKey(client: *Client) void {
        const t = &client.transport;
        var data_bytes: [512]u8 = undefined;
        const data = connection_file.signedData(&data_bytes, &t.session_id, client.user[0..client.user_length], &client.key_public) orelse return client.tryNext();
        var signature: [crypto.SIGNATURE_ED25519]u8 = undefined;
        if (t.cb.Sign(crypto.SIG_ED25519, &client.key_seed, &crypto.Bytes.of(data), &signature) != crypto.CRYPTOERR_OK) return client.tryNext();
        var bytes: [512]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        client.requestHead(&writer, "publickey");
        writer.boolean(true);
        writer.string(ssh_keys.key_type);
        writer.string(&ssh_keys.blob(&client.key_public));
        var signature_bytes: [4 + ssh_keys.key_type.len + 4 + crypto.SIGNATURE_ED25519]u8 = undefined;
        var signature_blob = Writer{ .bytes = &signature_bytes };
        signature_blob.string(ssh_keys.key_type);
        signature_blob.string(&signature);
        writer.string(signature_blob.written());
        t.send(writer.written());
        client.step = .authenticating;
    }

    /// A request that logs in with nothing: what the server answers says
    /// what it takes - or lets us in.
    fn sendNone(client: *Client) void {
        var bytes: [128]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        client.requestHead(&writer, "none");
        client.transport.send(writer.written());
        client.step = .authenticating;
    }

    fn sendPassword(client: *Client) void {
        var bytes: [256]u8 = undefined;
        defer transport_file.wipe(&bytes);
        var writer = Writer{ .bytes = &bytes };
        client.requestHead(&writer, "password");
        writer.boolean(false);
        writer.string(client.password[0..client.password_length]);
        client.transport.send(writer.written());
        client.step = .authenticating;
    }

    fn loginFailure(client: *Client, reader: *Reader) void {
        if (client.step != .authenticating) return client.transport.disconnect(msg.reason_protocol_error, "unexpected USERAUTH_FAILURE");
        const methods = reader.string();
        _ = reader.boolean();
        if (reader.bad) return client.transport.disconnect(msg.reason_protocol_error, "bad USERAUTH_FAILURE");
        client.methods_length = @min(methods.len, client.methods.len - 1);
        @memcpy(client.methods[0..client.methods_length], methods[0..client.methods_length]);
        client.tryNext();
    }

    fn loginSuccess(client: *Client) void {
        if (client.step != .authenticating) return client.transport.disconnect(msg.reason_protocol_error, "unexpected USERAUTH_SUCCESS");
        client.forget();
        client.step = .logged_in;
    }

    /// The password and the key's private half, gone once the login is
    /// over.
    fn forget(client: *Client) void {
        transport_file.wipe(&client.password);
        client.password_length = 0;
        transport_file.wipe(&client.key_seed);
    }

    /// A banner (RFC 4252, 5.4), kept: only while the login runs.
    fn keepBanner(client: *Client, reader: *Reader) void {
        const text = reader.string();
        _ = reader.string();
        if (reader.bad or (client.step != .service and client.step != .authenticating)) return;
        const room = client.banner.len - 1 - client.banner_length;
        const count = @min(text.len, room);
        @memcpy(client.banner[client.banner_length..][0..count], text[0..count]);
        client.banner_length += count;
    }

    /// The banners kept, NUL-terminated, into `into`, and forgotten.
    pub fn takeBanner(client: *Client, into: []u8) void {
        const length = @min(client.banner_length, into.len - 1);
        @memcpy(into[0..length], client.banner[0..length]);
        into[length] = 0;
        client.banner_length = 0;
    }

    /// The methods the server still takes, NUL-terminated, into `into`.
    pub fn methodsLeft(client: *const Client, into: []u8) void {
        const length = @min(client.methods_length, into.len - 1);
        @memcpy(into[0..length], client.methods[0..length]);
        into[length] = 0;
    }

    // --- the session -------------------------------------------------------

    /// The session asked for: the channel opened, then the terminal and
    /// the shell or the command.
    pub fn session(client: *Client, given: *const ssh.SshSession) void {
        const t = &client.transport;
        client.command_length = textLength(&given.command);
        @memcpy(client.command[0..client.command_length], given.command[0..client.command_length]);
        client.terminal_length = textLength(&given.terminal);
        @memcpy(client.terminal[0..client.terminal_length], given.terminal[0..client.terminal_length]);
        client.columns = given.columns;
        client.rows = given.rows;
        client.subsystem = given.subsystem != 0 and client.command_length > 0;
        var bytes: [64]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(msg.msg_channel_open);
        writer.string("session");
        writer.uint32(0);
        writer.uint32(channel_file.ring_bytes);
        writer.uint32(channel_file.our_max_packet);
        t.send(writer.written());
        client.step = .opening;
    }

    /// A channel the server would open to us: there is none to have.
    fn refuseChannel(client: *Client, reader: *Reader) void {
        _ = reader.string();
        const sender = reader.uint32();
        if (reader.bad) return client.transport.disconnect(msg.reason_protocol_error, "bad CHANNEL_OPEN");
        var bytes: [32]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(msg.msg_channel_open_failure);
        writer.uint32(sender);
        writer.uint32(1); // administratively prohibited
        writer.string("");
        writer.string("");
        client.transport.send(writer.written());
    }

    fn channelMessage(client: *Client, kind: u8, reader: *Reader) void {
        const t = &client.transport;
        const recipient = reader.uint32();
        if (reader.bad or recipient != 0 or client.step == .connecting or client.step == .connected) return t.disconnect(msg.reason_protocol_error, "no such channel");
        switch (kind) {
            msg.msg_channel_open_confirmation => {
                const sender = reader.uint32();
                const window = reader.uint32();
                const max_packet = reader.uint32();
                if (reader.bad or client.step != .opening) return t.disconnect(msg.reason_protocol_error, "unexpected CHANNEL_OPEN_CONFIRMATION");
                client.channel.opened(sender, window, max_packet);
                if (client.terminal_length > 0) return client.askTerminal();
                client.askStart();
            },
            msg.msg_channel_open_failure => {
                if (client.step != .opening) return t.disconnect(msg.reason_protocol_error, "unexpected CHANNEL_OPEN_FAILURE");
                client.step = .failed;
            },
            msg.msg_channel_success, msg.msg_channel_failure => {
                const ok = kind == msg.msg_channel_success;
                switch (client.step) {
                    .terminal => {
                        client.has_terminal = ok;
                        client.askStart();
                    },
                    .starting => client.step = if (ok) .running else .failed,
                    else => {},
                }
            },
            msg.msg_channel_request => client.channelRequest(reader),
            else => if (!client.channel.open or !client.channel.handle(t, kind, reader)) {
                t.disconnect(msg.reason_protocol_error, "no such channel");
            },
        }
    }

    fn askTerminal(client: *Client) void {
        var bytes: [128]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        client.requestHeadChannel(&writer, "pty-req", true);
        writer.string(client.terminal[0..client.terminal_length]);
        writer.uint32(client.columns);
        writer.uint32(client.rows);
        writer.uint32(0);
        writer.uint32(0);
        var modes: [6]u8 = undefined;
        modes[0] = mode_verase;
        wire.put32(modes[1..5], 0x7F);
        modes[5] = mode_end;
        writer.string(&modes);
        client.transport.send(writer.written());
        client.step = .terminal;
    }

    fn askStart(client: *Client) void {
        var bytes: [600]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        if (client.command_length > 0) {
            client.requestHeadChannel(&writer, if (client.subsystem) "subsystem" else "exec", true);
            writer.string(client.command[0..client.command_length]);
        } else {
            client.requestHeadChannel(&writer, "shell", true);
        }
        client.transport.send(writer.written());
        client.step = .starting;
    }

    fn requestHeadChannel(client: *const Client, writer: *Writer, request: []const u8, want_reply: bool) void {
        writer.byte(msg.msg_channel_request);
        writer.uint32(client.channel.peer_channel);
        writer.string(request);
        writer.boolean(want_reply);
    }

    /// The server's requests: the exit status kept, the rest refused.
    fn channelRequest(client: *Client, reader: *Reader) void {
        const t = &client.transport;
        const request = reader.string();
        const want_reply = reader.boolean();
        if (reader.bad) return t.disconnect(msg.reason_protocol_error, "bad CHANNEL_REQUEST");
        if (wire.same(request, "exit-status")) {
            const status = reader.uint32();
            if (!reader.bad) {
                client.exit_status = status;
                client.status_given = true;
            }
        } else if (wire.same(request, "exit-signal")) {
            client.exit_status = status_none;
            client.status_given = true;
        } else if (want_reply) {
            client.channel.reply(t, msg.msg_channel_failure);
        }
    }

    // --- the unit's side ---------------------------------------------------

    /// The terminal's new size told.
    pub fn windowChange(client: *Client, columns: u32, rows: u32) void {
        if (client.step != .running or !client.has_terminal or client.channel.closed) return;
        client.columns = columns;
        client.rows = rows;
        var bytes: [48]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        client.requestHeadChannel(&writer, "window-change", false);
        writer.uint32(columns);
        writer.uint32(rows);
        writer.uint32(0);
        writer.uint32(0);
        client.transport.send(writer.written());
    }

    /// Our input over: EOF to the server.
    pub fn endInput(client: *Client) void {
        client.channel.endOutput(&client.transport);
    }

    /// Whether the session is over: the server closed the channel, or the
    /// connection is gone.
    pub fn sessionEnded(client: *const Client) bool {
        return client.channel.peer_closed or client.transport.ended();
    }

    /// What the server sent - its output and its errors - into `into`.
    pub fn read(client: *Client, into: []u8) usize {
        return client.channel.read(&client.transport, into);
    }

    pub fn write(client: *Client, data: []const u8) usize {
        return client.channel.write(&client.transport, data);
    }

    pub fn inputEnded(client: *const Client) bool {
        return client.channel.inputEnded(&client.transport);
    }
};

fn textLength(text: []const u8) usize {
    var length: usize = 0;
    while (length < text.len and text[length] != 0) length += 1;
    return length;
}

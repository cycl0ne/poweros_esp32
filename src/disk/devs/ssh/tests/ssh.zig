// SPDX-License-Identifier: MIT
//! Host tests of ssh.device's protocol (`connection.zig`), with the test
//! as the client: the version lines, the key exchange - the client works
//! out K and H itself, checks the host's signature and makes its own
//! keys - the login by password and by key, the session channel both
//! ways, a second key exchange, and a packet tampered with. Then the
//! client's end (`client.zig`) against the server's, back to back: both
//! logins, a shell and a command, the window, the exit status, keys the
//! server renews and a host key that changes. Beside them SSH's wire
//! types, and the key text checked against what OpenSSH's ssh-keygen
//! wrote for a key of its own.

const std = @import("std");
const sdk = @import("sdk");
const crypto = sdk.crypto;
const ssh = sdk.devices.ssh;
const ssh_keys = sdk.devices.ssh.keys;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const crypto_init = @import("../../../libs/crypto/crypto_init.zig");
const kexec = @import("host_rom").exec;
const connection = @import("../connection.zig");
const transport = @import("../transport.zig");
const channel_file = @import("../channel.zig");
const Connection = connection.Connection;
const Direction = transport.Direction;
const wire = @import("../wire.zig");

const testing = std.testing;
const Sha256 = std.crypto.hash.sha2.Sha256;

// --- the wire types and the keys' text ----------------------------------------

test "mpints as RFC 4251 writes them, and name-lists" {
    var bytes: [32]u8 = undefined;
    var writer = wire.Writer{ .bytes = &bytes };
    writer.mpint(&.{ 0, 0 });
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, writer.written());
    writer = .{ .bytes = &bytes };
    writer.mpint(&.{ 0x09, 0xa3, 0x78, 0xf9, 0xb2, 0xe3, 0x32, 0xa7 });
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 8, 0x09, 0xa3, 0x78, 0xf9, 0xb2, 0xe3, 0x32, 0xa7 }, writer.written());
    writer = .{ .bytes = &bytes };
    writer.mpint(&.{ 0, 0x80 });
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 2, 0, 0x80 }, writer.written());

    try testing.expectEqualStrings("mlkem768x25519-sha256", wire.choose("mlkem768x25519-sha256,curve25519-sha256,ext-info-c", transport.kex_names).?);
    try testing.expectEqualStrings("curve25519-sha256", wire.choose("sntrup761x25519-sha512,curve25519-sha256", transport.kex_names).?);
    try testing.expect(wire.choose("diffie-hellman-group14-sha256", transport.kex_names) == null);
    try testing.expect(wire.hasName("a,kex-strict-c-v00@openssh.com", "kex-strict-c-v00@openssh.com"));
    try testing.expect(!wire.hasName("kex-strict-c-v00@openssh.comx", "kex-strict-c-v00@openssh.com"));

    var reader = wire.Reader{ .bytes = &.{ 0, 0, 0, 9, 'a' } };
    _ = reader.string();
    try testing.expect(reader.bad);
}

/// A key ssh-keygen made, its line and the fingerprint `ssh-keygen -l`
/// showed for it.
const openssh_line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKtKWksd1TVXlSNGBjRoTOWHTqPzprPwXWZo8gxarWZV test@host";
const openssh_fingerprint = "SHA256:DGNAlDCe8LaIQAaUdDVD0QycthURTOF2yUc0PvPJOJI";

test "keys as OpenSSH writes them: a line, authorized_keys, the fingerprint" {
    try kexec.setUp();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const made = kexec.InitResident(kexec.SysBase, &crypto_init.crypto_library_tag, null) orelse return error.NoLibrary;
    const cb: *CryptoBase = @ptrCast(sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse return error.NoBase);
    defer {
        sys.CloseLibrary(cb.lib());
        _ = sys.RemLibrary(@ptrCast(@alignCast(made)));
    }

    const key = ssh_keys.authorizedKey(openssh_line).?;
    var line: [128]u8 = undefined;
    const length = ssh_keys.publicLine(&key, "test@host", &line);
    try testing.expectEqualStrings(openssh_line ++ "\n", line[0..length]);
    var print: [ssh_keys.fingerprint_bytes]u8 = undefined;
    try testing.expect(ssh_keys.fingerprint(cb, &key, &print));
    try testing.expectEqualStrings(openssh_fingerprint, &print);
    // Options in front, comments and other types.
    try testing.expectEqual(key, ssh_keys.authorizedKey("from=\"10.0.0.0/8\",no-pty " ++ openssh_line).?);
    try testing.expect(ssh_keys.authorizedKey("# " ++ openssh_line) == null);
    try testing.expect(ssh_keys.authorizedKey("ssh-rsa AAAAB3NzaC1yc2E= someone") == null);
    try testing.expect(ssh_keys.authorizedKey("") == null);
}

// --- the client -----------------------------------------------------------------

const client_version = "SSH-2.0-TestClient_1.0";
const password = "open sesame";

const Rig = struct {
    sys: *ExecBase,
    library: *sdk.exec.Library,
    cb: *CryptoBase,
    server: *Connection,
    accept: ssh.SshAccept,
    /// The client's login key.
    user_seed: [32]u8,
    user_public: [32]u8,

    fn init() !*Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const made = kexec.InitResident(kexec.SysBase, &crypto_init.crypto_library_tag, null) orelse return error.NoLibrary;
        const cb: *CryptoBase = @ptrCast(sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse return error.NoBase);
        const rig = try testing.allocator.create(Rig);
        rig.* = .{ .sys = sys, .library = @ptrCast(@alignCast(made)), .cb = cb, .server = try testing.allocator.create(Connection), .accept = .{}, .user_seed = undefined, .user_public = undefined };
        rig.server.init(cb);
        var length: u32 = 32;
        _ = cb.MakeKeyPair(crypto.CURVE_ED25519, &rig.accept.host_seed, &rig.accept.host_public, &length);
        _ = cb.MakeKeyPair(crypto.CURVE_ED25519, &rig.user_seed, &rig.user_public, &length);
        @memcpy(rig.accept.password[0..password.len], password);
        rig.accept.password_length = password.len;
        rig.accept.keys[0] = rig.user_public;
        rig.accept.key_count = 1;
        return rig;
    }

    fn deinit(rig: *Rig) void {
        const sys = rig.sys;
        testing.allocator.destroy(rig.server);
        sys.CloseLibrary(rig.cb.lib());
        _ = sys.RemLibrary(rig.library);
        testing.allocator.destroy(rig);
        kexec.deinit();
    }
};

/// The test's end of the connection: its packets, sealed and opened as
/// the server's are, and the key exchange done the client's way.
const Client = struct {
    rig: *Rig,
    sending: Direction = .{},
    receiving: Direction = .{},
    received: [64 * 1024]u8 = undefined,
    received_length: usize = 0,
    payload: [40000]u8 = undefined,
    session_id: [32]u8 = undefined,
    server_kexinit: [1024]u8 = undefined,
    server_kexinit_length: usize = 0,
    /// The exchange it offers: ML-KEM-768 with X25519, or X25519 alone.
    hybrid: bool = true,

    /// What the server has to send, moved over, after it took what it
    /// was given.
    fn pump(client: *Client) void {
        const server = client.rig.server;
        while (true) {
            server.process();
            const bytes = server.transport.pending();
            if (bytes.len == 0) break;
            @memcpy(client.received[client.received_length..][0..bytes.len], bytes);
            client.received_length += bytes.len;
            server.transport.sent(bytes.len);
            if (!server.transport.processable()) break;
        }
    }

    fn send(client: *Client, payload: []const u8) void {
        var packet: [40000]u8 = undefined;
        const sealed = client.sending.on;
        const block: usize = if (sealed) 16 else 8;
        const counted = if (sealed) 1 + payload.len else 5 + payload.len;
        var padding = block - counted % block;
        if (padding < 4) padding += block;
        const length = 1 + payload.len + padding;
        wire.put32(packet[0..4], @intCast(length));
        packet[4] = @intCast(padding);
        @memcpy(packet[5..][0..payload.len], payload);
        @memset(packet[5 + payload.len ..][0..padding], 0x5A);
        var total = 4 + length;
        if (sealed) {
            const message: crypto.GcmMessage = .{
                .key = &client.sending.key,
                .key_length = client.sending.key_length,
                .nonce = &client.sending.nonce,
                .nonce_length = 12,
                .aad = &packet,
                .aad_length = 4,
                .input = packet[4..].ptr,
                .output = packet[4..].ptr,
                .length = @intCast(length),
                .tag = packet[4 + length ..][0..16],
            };
            _ = client.rig.cb.SealGcm(&message);
            advance(&client.sending);
            total += 16;
        }
        client.rig.server.transport.feed(packet[0..total]);
        client.pump();
    }

    /// The next message from the server, opened; null when none is whole.
    fn next(client: *Client) !?[]const u8 {
        if (client.received_length < 4) return null;
        const length = wire.get32(client.received[0..4]);
        const sealed = client.receiving.on;
        const total = 4 + length + @as(usize, if (sealed) 16 else 0);
        if (client.received_length < total) return null;
        if (sealed) {
            const message: crypto.GcmMessage = .{
                .key = &client.receiving.key,
                .key_length = client.receiving.key_length,
                .nonce = &client.receiving.nonce,
                .nonce_length = 12,
                .aad = &client.received,
                .aad_length = 4,
                .input = client.received[4..].ptr,
                .output = client.received[4..].ptr,
                .length = length,
                .tag = client.received[4 + length ..][0..16],
            };
            if (client.rig.cb.OpenGcm(&message) != crypto.CRYPTOERR_OK) return error.BadTag;
            advance(&client.receiving);
        }
        const padding = client.received[4];
        const payload_length = length - 1 - padding;
        @memcpy(client.payload[0..payload_length], client.received[5..][0..payload_length]);
        std.mem.copyForwards(u8, client.received[0 .. client.received_length - total], client.received[total..client.received_length]);
        client.received_length -= total;
        return client.payload[0..payload_length];
    }

    fn expect(client: *Client, kind: u8) ![]const u8 {
        const payload = (try client.next()) orelse return error.NothingCame;
        if (payload[0] != kind) {
            std.debug.print("expected message {d}, got {d}\n", .{ kind, payload[0] });
            return error.WrongMessage;
        }
        return payload;
    }

    /// A key exchange, the client's way: KEXINIT, its share, the server's
    /// reply checked, K and H, the keys, NEWKEYS both ways.
    fn exchange(client: *Client, first: bool) !void {
        const cb = client.rig.cb;
        var bytes: [512]u8 = undefined;
        var kexinit = wire.Writer{ .bytes = &bytes };
        kexinit.byte(transport.msg_kexinit);
        kexinit.raw(&([_]u8{7} ** 16));
        kexinit.string(if (client.hybrid) "mlkem768x25519-sha256,curve25519-sha256,ext-info-c,kex-strict-c-v00@openssh.com" else "curve25519-sha256,ext-info-c,kex-strict-c-v00@openssh.com");
        kexinit.string("ssh-ed25519");
        kexinit.string("chacha20-poly1305@openssh.com,aes128-gcm@openssh.com");
        kexinit.string("aes256-gcm@openssh.com");
        kexinit.string("hmac-sha2-256");
        kexinit.string("hmac-sha2-256");
        kexinit.string("none");
        kexinit.string("none");
        kexinit.string("");
        kexinit.string("");
        kexinit.boolean(false);
        kexinit.uint32(0);
        client.send(kexinit.written());
        if (!first) {
            const theirs = try client.expect(transport.msg_kexinit);
            @memcpy(client.server_kexinit[0..theirs.len], theirs);
            client.server_kexinit_length = theirs.len;
        }

        var private: [32]u8 = undefined;
        var public: [32]u8 = undefined;
        var length: u32 = 32;
        _ = cb.MakeKeyPair(crypto.CURVE_X25519, &private, &public, &length);
        // Hybrid: the ML-KEM encapsulation key in front of the share.
        var kem_private: [crypto.MLKEM768_PRIVATE]u8 = undefined;
        var client_bytes: [crypto.MLKEM768_PUBLIC + 32]u8 = undefined;
        var client_blob: []const u8 = &public;
        if (client.hybrid) {
            try testing.expectEqual(crypto.CRYPTOERR_OK, cb.KemKeyPair(crypto.KEM_MLKEM768, client_bytes[0..crypto.MLKEM768_PUBLIC], &kem_private));
            client_bytes[crypto.MLKEM768_PUBLIC..].* = public;
            client_blob = &client_bytes;
        }
        var init_bytes: [1300]u8 = undefined;
        var init = wire.Writer{ .bytes = &init_bytes };
        init.byte(transport.msg_kex_ecdh_init);
        init.string(client_blob);
        client.send(init.written());

        var reply = wire.Reader{ .bytes = try client.expect(transport.msg_kex_ecdh_reply), .at = 1 };
        const host_blob = reply.string();
        const server_blob = reply.string();
        const server_share = server_blob[server_blob.len - 32 ..];
        var signature_blob = wire.Reader{ .bytes = reply.string() };
        try testing.expect(!reply.bad);
        try testing.expectEqualSlices(u8, &ssh_keys.blob(&client.rig.accept.host_public), host_blob);
        try testing.expectEqualStrings("ssh-ed25519", signature_blob.string());
        const signature = signature_blob.string();
        try testing.expectEqual(@as(usize, 64), signature.len);

        var secret: [32]u8 = undefined;
        try testing.expectEqual(crypto.CRYPTOERR_OK, cb.SharedSecret(crypto.CURVE_X25519, &private, &crypto.Bytes.of(server_share), &secret));
        var shared_bytes: [37]u8 = undefined;
        var shared = wire.Writer{ .bytes = &shared_bytes };
        if (client.hybrid) {
            try testing.expectEqual(@as(usize, crypto.MLKEM768_CIPHERTEXT + 32), server_blob.len);
            var kem_secret: [32]u8 = undefined;
            try testing.expectEqual(crypto.CRYPTOERR_OK, cb.Decapsulate(crypto.KEM_MLKEM768, &kem_private, &crypto.Bytes.of(server_blob[0..crypto.MLKEM768_CIPHERTEXT]), &kem_secret));
            var combined: [32]u8 = undefined;
            var both = Sha256.init(.{});
            both.update(&kem_secret);
            both.update(&secret);
            both.final(&combined);
            shared.string(&combined);
        } else {
            shared.mpint(&secret);
        }

        var hash = Sha256.init(.{});
        hashString(&hash, client_version);
        hashString(&hash, transport.version);
        hashString(&hash, kexinit.written());
        hashString(&hash, client.server_kexinit[0..client.server_kexinit_length]);
        hashString(&hash, host_blob);
        hashString(&hash, client_blob);
        hashString(&hash, server_blob);
        hash.update(shared.written());
        var exchange_hash: [32]u8 = undefined;
        hash.final(&exchange_hash);
        if (first) client.session_id = exchange_hash;
        const host_key: crypto.PublicKey = .{ .point = crypto.Bytes.of(&client.rig.accept.host_public) };
        try testing.expectEqual(crypto.CRYPTOERR_OK, cb.VerifySignature(crypto.SIG_ED25519, &host_key, &crypto.Bytes.of(&exchange_hash), &crypto.Bytes.of(signature)));

        _ = try client.expect(transport.msg_newkeys);
        var sending: Direction = .{ .on = true, .key_length = 16 };
        var receiving: Direction = .{ .on = true, .key_length = 32 };
        derive(shared.written(), &exchange_hash, 'A', &client.session_id, &sending.nonce);
        derive(shared.written(), &exchange_hash, 'C', &client.session_id, sending.key[0..16]);
        derive(shared.written(), &exchange_hash, 'B', &client.session_id, &receiving.nonce);
        derive(shared.written(), &exchange_hash, 'D', &client.session_id, &receiving.key);
        client.receiving = receiving;
        client.send(&.{transport.msg_newkeys});
        client.sending = sending;
    }

    /// The handshake to a logged-in connection: version lines, the key
    /// exchange, ssh-userauth.
    fn connect(client: *Client) !void {
        const server = client.rig.server;
        server.start(&client.rig.accept);
        client.pump();
        const banner = transport.version ++ "\r\n";
        try testing.expectEqualStrings(banner, client.received[0..banner.len]);
        std.mem.copyForwards(u8, client.received[0 .. client.received_length - banner.len], client.received[banner.len..client.received_length]);
        client.received_length -= banner.len;
        const theirs = try client.expect(transport.msg_kexinit);
        @memcpy(client.server_kexinit[0..theirs.len], theirs);
        client.server_kexinit_length = theirs.len;
        server.transport.feed(client_version ++ "\r\n");
        try client.exchange(true);
        try testing.expect(server.transport.strict);

        var bytes: [64]u8 = undefined;
        var request = wire.Writer{ .bytes = &bytes };
        request.byte(transport.msg_service_request);
        request.string("ssh-userauth");
        client.send(request.written());
        _ = try client.expect(transport.msg_service_accept);
    }

    fn passwordLogin(client: *Client, given: []const u8) void {
        var bytes: [128]u8 = undefined;
        var writer = wire.Writer{ .bytes = &bytes };
        writer.byte(transport.msg_userauth_request);
        writer.string("claus");
        writer.string("ssh-connection");
        writer.string("password");
        writer.boolean(false);
        writer.string(given);
        client.send(writer.written());
    }

    /// The session channel opened, a terminal asked for, and `request`
    /// ("shell", or "exec" with `command`).
    fn session(client: *Client, request: []const u8, command: []const u8) !void {
        var bytes: [256]u8 = undefined;
        var writer = wire.Writer{ .bytes = &bytes };
        writer.byte(transport.msg_channel_open);
        writer.string("session");
        writer.uint32(7);
        writer.uint32(1 << 20);
        writer.uint32(32768);
        client.send(writer.written());
        var confirmation = wire.Reader{ .bytes = try client.expect(transport.msg_channel_open_confirmation), .at = 1 };
        try testing.expectEqual(@as(u32, 7), confirmation.uint32());

        writer = .{ .bytes = &bytes };
        writer.byte(transport.msg_channel_request);
        writer.uint32(0);
        writer.string("pty-req");
        writer.boolean(true);
        writer.string("xterm-256color");
        writer.uint32(132);
        writer.uint32(43);
        writer.uint32(0);
        writer.uint32(0);
        writer.string("");
        client.send(writer.written());
        _ = try client.expect(transport.msg_channel_success);

        writer = .{ .bytes = &bytes };
        writer.byte(transport.msg_channel_request);
        writer.uint32(0);
        writer.string(request);
        writer.boolean(true);
        if (command.len > 0) writer.string(command);
        client.send(writer.written());
        _ = try client.expect(transport.msg_channel_success);
    }

    fn data(client: *Client, text: []const u8) void {
        var bytes: [256]u8 = undefined;
        var writer = wire.Writer{ .bytes = &bytes };
        writer.byte(transport.msg_channel_data);
        writer.uint32(0);
        writer.string(text);
        client.send(writer.written());
    }
};

fn advance(direction: *Direction) void {
    var at: usize = 12;
    while (at > 4) {
        at -= 1;
        direction.nonce[at] +%= 1;
        if (direction.nonce[at] != 0) break;
    }
}

fn hashString(hash: *Sha256, bytes: []const u8) void {
    var length: [4]u8 = undefined;
    wire.put32(&length, @intCast(bytes.len));
    hash.update(&length);
    hash.update(bytes);
}

fn derive(shared: []const u8, exchange_hash: *const [32]u8, letter: u8, session_id: *const [32]u8, into: []u8) void {
    var hash = Sha256.init(.{});
    hash.update(shared);
    hash.update(exchange_hash);
    hash.update(&.{letter});
    hash.update(session_id);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    @memcpy(into, digest[0..into.len]);
}

fn newClient(rig: *Rig) !*Client {
    const client = try testing.allocator.create(Client);
    client.* = .{ .rig = rig };
    return client;
}

// --- the protocol -----------------------------------------------------------------

test "a login by password, a shell, data both ways, an interrupt, the exit" {
    const rig = try Rig.init();
    defer rig.deinit();
    const client = try newClient(rig);
    defer testing.allocator.destroy(client);
    const server = rig.server;
    try client.connect();

    // "none" says what there is; a wrong password fails; the right one
    // logs in.
    var bytes: [128]u8 = undefined;
    var none = wire.Writer{ .bytes = &bytes };
    none.byte(transport.msg_userauth_request);
    none.string("claus");
    none.string("ssh-connection");
    none.string("none");
    client.send(none.written());
    var failure = wire.Reader{ .bytes = try client.expect(transport.msg_userauth_failure), .at = 1 };
    try testing.expectEqualStrings("publickey,password", failure.string());
    client.passwordLogin("guess");
    _ = try client.expect(transport.msg_userauth_failure);
    try testing.expect(!server.authenticated);
    client.passwordLogin(password);
    _ = try client.expect(transport.msg_userauth_success);
    try testing.expectEqualStrings("claus", std.mem.sliceTo(&server.user, 0));

    try client.session("shell", "");
    try testing.expect(server.session_ready);
    try testing.expectEqual(ssh.SSHSESSION_SHELL, server.kind);
    try testing.expectEqual(@as(u32, 132), server.columns);
    try testing.expectEqualStrings("xterm-256color", std.mem.sliceTo(&server.terminal, 0));

    // In: what was typed; an interrupt as Ctrl-C.
    client.data("dir\r");
    var typed: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), server.read(&typed));
    try testing.expectEqualStrings("dir\r", typed[0..4]);
    var signal = wire.Writer{ .bytes = &bytes };
    signal.byte(transport.msg_channel_request);
    signal.uint32(0);
    signal.string("signal");
    signal.boolean(false);
    signal.string("INT");
    client.send(signal.written());
    try testing.expectEqual(@as(usize, 1), server.read(&typed));
    try testing.expectEqual(@as(u8, 3), typed[0]);

    // Out: what the shell writes, as channel data to the client's channel.
    try testing.expectEqual(@as(usize, 5), server.write("hello"));
    client.pump();
    var output = wire.Reader{ .bytes = try client.expect(transport.msg_channel_data), .at = 1 };
    try testing.expectEqual(@as(u32, 7), output.uint32());
    try testing.expectEqualStrings("hello", output.string());

    // Reading a ring's half gives the window back.
    var many: [channel_file.ring_bytes / 2]u8 = @splat('x');
    var at: usize = 0;
    while (at < many.len) : (at += 200) client.data(many[at..@min(many.len, at + 200)]);
    var drained: [channel_file.ring_bytes]u8 = undefined;
    try testing.expectEqual(many.len, server.read(&drained));
    client.pump();
    var adjust = wire.Reader{ .bytes = try client.expect(transport.msg_channel_window_adjust), .at = 1 };
    _ = adjust.uint32();
    try testing.expect(adjust.uint32() >= many.len);

    // The end: the exit status, EOF, CLOSE; the client's CLOSE ends the
    // input.
    server.exit(5);
    client.pump();
    var status = wire.Reader{ .bytes = try client.expect(transport.msg_channel_request), .at = 1 };
    _ = status.uint32();
    try testing.expectEqualStrings("exit-status", status.string());
    _ = status.boolean();
    try testing.expectEqual(@as(u32, 5), status.uint32());
    _ = try client.expect(transport.msg_channel_eof);
    _ = try client.expect(transport.msg_channel_close);
    try testing.expectEqual(@as(usize, 0), server.write("late"));
    var close = [_]u8{ transport.msg_channel_close, 0, 0, 0, 0 };
    client.send(&close);
    try testing.expect(server.inputEnded());
}

test "a login by key: asked about, then signed; a command" {
    const rig = try Rig.init();
    defer rig.deinit();
    const client = try newClient(rig);
    defer testing.allocator.destroy(client);
    const server = rig.server;
    try client.connect();

    const key_blob = ssh_keys.blob(&rig.user_public);
    var bytes: [512]u8 = undefined;
    // Asked about: PK_OK. A key nobody gave: failure.
    var query = wire.Writer{ .bytes = &bytes };
    query.byte(transport.msg_userauth_request);
    query.string("claus");
    query.string("ssh-connection");
    query.string("publickey");
    query.boolean(false);
    query.string("ssh-ed25519");
    query.string(&key_blob);
    client.send(query.written());
    _ = try client.expect(transport.msg_userauth_pk_ok);

    // Signed, over the session id and the request.
    var signed_bytes: [512]u8 = undefined;
    var signed = wire.Writer{ .bytes = &signed_bytes };
    signed.string(&client.session_id);
    signed.byte(transport.msg_userauth_request);
    signed.string("claus");
    signed.string("ssh-connection");
    signed.string("publickey");
    signed.boolean(true);
    signed.string("ssh-ed25519");
    signed.string(&key_blob);
    var signature: [64]u8 = undefined;
    _ = rig.cb.Sign(crypto.SIG_ED25519, &rig.user_seed, &crypto.Bytes.of(signed.written()), &signature);
    // A signature of the wrong data first: refused.
    var wrong = signature;
    wrong[0] ^= 1;
    for ([_]*const [64]u8{ &wrong, &signature }, 0..) |each, round| {
        var request = wire.Writer{ .bytes = &bytes };
        request.byte(transport.msg_userauth_request);
        request.string("claus");
        request.string("ssh-connection");
        request.string("publickey");
        request.boolean(true);
        request.string("ssh-ed25519");
        request.string(&key_blob);
        var blob_bytes: [128]u8 = undefined;
        var blob = wire.Writer{ .bytes = &blob_bytes };
        blob.string("ssh-ed25519");
        blob.string(each);
        request.string(blob.written());
        client.send(request.written());
        _ = try client.expect(if (round == 0) transport.msg_userauth_failure else transport.msg_userauth_success);
    }
    try testing.expect(server.authenticated);

    try client.session("exec", "list sys:");
    try testing.expectEqual(ssh.SSHSESSION_EXEC, server.kind);
    try testing.expectEqualStrings("list sys:", std.mem.sliceTo(&server.command, 0));
}

test "a client without ML-KEM gets curve25519-sha256" {
    const rig = try Rig.init();
    defer rig.deinit();
    const client = try newClient(rig);
    defer testing.allocator.destroy(client);
    client.hybrid = false;
    try client.connect();
    try testing.expect(!rig.server.transport.hybrid);
    client.passwordLogin(password);
    _ = try client.expect(transport.msg_userauth_success);
}

test "six failed logins end the connection" {
    const rig = try Rig.init();
    defer rig.deinit();
    const client = try newClient(rig);
    defer testing.allocator.destroy(client);
    try client.connect();
    for (0..connection.tries_max) |_| client.passwordLogin("wrong");
    try testing.expect(rig.server.transport.ended());
    try testing.expectEqual(transport.reason_no_more_auth_methods, rig.server.transport.reason);
}

test "the client exchanges keys again in the middle; a packet tampered with ends it" {
    const rig = try Rig.init();
    defer rig.deinit();
    const client = try newClient(rig);
    defer testing.allocator.destroy(client);
    const server = rig.server;
    try client.connect();
    try testing.expect(server.transport.hybrid);
    client.passwordLogin(password);
    _ = try client.expect(transport.msg_userauth_success);
    try client.session("shell", "");
    const first_id = server.transport.session_id;

    // Again: the session id stays, the keys change, data goes on.
    try client.exchange(false);
    try testing.expectEqualSlices(u8, &first_id, &server.transport.session_id);
    client.data("after");
    var typed: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), server.read(&typed));
    try testing.expectEqual(@as(usize, 2), server.write("ok"));
    client.pump();
    _ = try client.expect(transport.msg_channel_data);

    // One bit of a sealed packet turned: the tag does not match.
    var bytes: [32]u8 = undefined;
    var writer = wire.Writer{ .bytes = &bytes };
    writer.byte(transport.msg_channel_data);
    writer.uint32(0);
    writer.string("x");
    const before = client.sending;
    client.sending.key[0] ^= 1;
    client.send(writer.written());
    client.sending = before;
    try testing.expect(server.transport.ended());
    try testing.expectEqual(transport.reason_mac_error, server.transport.reason);
}

// --- the client against the server -----------------------------------------------

const client_file = @import("../client.zig");
const SshClient = client_file.Client;

/// Both ends of ssh.device, joined.
const Pair = struct {
    rig: *Rig,
    client: *SshClient,

    fn init(rig: *Rig) !Pair {
        const client = try testing.allocator.create(SshClient);
        client.init(rig.cb);
        rig.server.start(&rig.accept);
        client.start();
        return .{ .rig = rig, .client = client };
    }

    fn deinit(pair: *Pair) void {
        testing.allocator.destroy(pair.client);
    }

    /// What each end has to say moved to the other, until neither has
    /// more.
    fn pump(pair: *Pair) void {
        const server = &pair.rig.server.transport;
        const client = &pair.client.transport;
        while (true) {
            pair.rig.server.process();
            pair.client.process();
            var moved = false;
            for ([_][2]*transport.Transport{ .{ server, client }, .{ client, server } }) |ends| {
                const bytes = ends[0].pending();
                const count = @min(bytes.len, ends[1].inRoom());
                if (count == 0) continue;
                ends[1].feed(bytes[0..count]);
                ends[0].sent(count);
                moved = true;
            }
            if (!moved) break;
        }
    }

    fn login(pair: *Pair, with_key: bool, given_password: []const u8) void {
        var request: ssh.SshLogin = .{};
        @memcpy(request.user[0..5], "claus");
        if (with_key) {
            request.key_seed = pair.rig.user_seed;
            request.key_public = pair.rig.user_public;
            request.key_given = 1;
        }
        @memcpy(request.password[0..given_password.len], given_password);
        request.password_length = @intCast(given_password.len);
        pair.client.login(&request);
        pair.pump();
    }

    fn session(pair: *Pair, command: []const u8, terminal: []const u8) void {
        var request: ssh.SshSession = .{ .columns = 100, .rows = 30 };
        @memcpy(request.command[0..command.len], command);
        @memcpy(request.terminal[0..terminal.len], terminal);
        pair.client.session(&request);
        pair.pump();
    }
};

test "the client: the hybrid exchange, a key login, a shell, data both ways, the window, the exit status" {
    const rig = try Rig.init();
    defer rig.deinit();
    var pair = try Pair.init(rig);
    defer pair.deinit();
    const server = rig.server;
    const client = pair.client;
    pair.pump();
    try testing.expectEqual(client_file.Step.connected, client.step);
    try testing.expectEqual(rig.accept.host_public, client.host_public);
    try testing.expect(client.transport.hybrid and server.transport.hybrid);
    try testing.expect(client.transport.strict and server.transport.strict);
    try testing.expectEqualSlices(u8, &server.transport.session_id, &client.transport.session_id);

    pair.login(true, "");
    try testing.expectEqual(client_file.Step.logged_in, client.step);
    try testing.expect(server.authenticated);
    try testing.expectEqualStrings("claus", std.mem.sliceTo(&server.user, 0));

    pair.session("", "xterm-256color");
    try testing.expectEqual(client_file.Step.running, client.step);
    try testing.expect(client.has_terminal);
    try testing.expectEqual(ssh.SSHSESSION_SHELL, server.kind);
    try testing.expectEqual(@as(u32, 100), server.columns);
    try testing.expectEqualStrings("xterm-256color", std.mem.sliceTo(&server.terminal, 0));

    try testing.expectEqual(@as(usize, 4), client.write("dir\r"));
    pair.pump();
    var typed: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), server.read(&typed));
    try testing.expectEqualStrings("dir\r", typed[0..4]);
    try testing.expectEqual(@as(usize, 5), server.write("hello"));
    pair.pump();
    try testing.expectEqual(@as(usize, 5), client.read(&typed));
    try testing.expectEqualStrings("hello", typed[0..5]);

    // More than a window's worth goes, as the reader gives it back.
    var sent: usize = 0;
    var got: usize = 0;
    var many: [3 * channel_file.ring_bytes]u8 = undefined;
    for (&many, 0..) |*byte, index| byte.* = @truncate(index * 7);
    var back: [3 * channel_file.ring_bytes]u8 = undefined;
    while (got < many.len) {
        if (sent < many.len) sent += server.write(many[sent..]);
        pair.pump();
        got += client.read(back[got..]);
    }
    try testing.expectEqualSlices(u8, &many, &back);

    client.windowChange(120, 40);
    pair.pump();
    try testing.expectEqual(@as(u32, 120), server.columns);
    try testing.expectEqual(@as(u32, 40), server.rows);

    client.endInput();
    pair.pump();
    try testing.expect(server.inputEnded());
    try testing.expect(!client.sessionEnded());
    server.exit(7);
    pair.pump();
    try testing.expect(client.sessionEnded());
    try testing.expect(client.inputEnded());
    try testing.expect(client.status_given);
    try testing.expectEqual(@as(u32, 7), client.exit_status);
}

test "the client: a key refused, then the password; a command without a terminal" {
    const rig = try Rig.init();
    defer rig.deinit();
    // Only the password will do.
    rig.accept.key_count = 0;
    var pair = try Pair.init(rig);
    defer pair.deinit();
    const client = pair.client;
    pair.pump();

    pair.login(true, "guess");
    try testing.expectEqual(client_file.Step.refused, client.step);
    var methods: [32]u8 = undefined;
    client.methodsLeft(&methods);
    try testing.expectEqualStrings("password", std.mem.sliceTo(&methods, 0));
    try testing.expectEqual(@as(u32, 2), rig.server.failures);

    pair.login(false, password);
    try testing.expectEqual(client_file.Step.logged_in, client.step);
    // The password is not kept.
    try testing.expectEqual(@as(usize, 0), client.password_length);

    pair.session("list sys:", "");
    try testing.expectEqual(client_file.Step.running, client.step);
    try testing.expect(!client.has_terminal);
    try testing.expectEqual(ssh.SSHSESSION_EXEC, rig.server.kind);
    try testing.expectEqualStrings("list sys:", std.mem.sliceTo(&rig.server.command, 0));
    try testing.expectEqual(@as(u32, 0), rig.server.columns);
}

test "the client: with neither key nor password it asks what the server takes; a banner comes back once" {
    const rig = try Rig.init();
    defer rig.deinit();
    var pair = try Pair.init(rig);
    defer pair.deinit();
    const client = pair.client;
    pair.pump();

    var request: ssh.SshLogin = .{};
    @memcpy(request.user[0..5], "claus");
    client.login(&request);
    // The server's banner, ahead of its answer.
    const text = "Authorised users only.\r\n\x1b[2Jbye\r\n";
    var bytes: [128]u8 = undefined;
    var banner = wire.Writer{ .bytes = &bytes };
    banner.byte(transport.msg_userauth_banner);
    banner.string(text);
    banner.string("");
    rig.server.transport.send(banner.written());
    pair.pump();
    try testing.expectEqual(client_file.Step.refused, client.step);
    var methods: [32]u8 = undefined;
    client.methodsLeft(&methods);
    try testing.expectEqualStrings("publickey,password", std.mem.sliceTo(&methods, 0));
    // Asking is no failed try.
    try testing.expectEqual(@as(u32, 0), rig.server.failures);
    var kept: [ssh.SSH_BANNER_MAX]u8 = undefined;
    client.takeBanner(&kept);
    try testing.expectEqualStrings(text, std.mem.sliceTo(&kept, 0));
    client.takeBanner(&kept);
    try testing.expectEqual(@as(u8, 0), kept[0]);

    pair.login(false, password);
    try testing.expectEqual(client_file.Step.logged_in, client.step);
}

test "the client: the server renews the keys; a message held meanwhile; a changed host key ends it" {
    const rig = try Rig.init();
    defer rig.deinit();
    var pair = try Pair.init(rig);
    defer pair.deinit();
    const server = rig.server;
    const client = pair.client;
    pair.pump();
    pair.login(true, "");
    pair.session("", "vt100");
    try testing.expectEqual(client_file.Step.running, client.step);
    const first_id = client.transport.session_id;

    // The server begins; the client answers, and while the exchange runs
    // the window's change waits.
    server.transport.renew();
    const kexinit = server.transport.pending();
    client.transport.feed(kexinit);
    server.transport.sent(kexinit.len);
    client.process();
    try testing.expectEqual(transport.KexState.exchanging, client.transport.kex);
    client.windowChange(90, 20);
    try testing.expect(client.transport.held_length > 0);
    pair.pump();
    try testing.expectEqual(transport.KexState.idle, client.transport.kex);
    try testing.expectEqual(@as(u32, 90), server.columns);
    try testing.expectEqualSlices(u8, &first_id, &client.transport.session_id);
    try testing.expectEqual(@as(usize, 2), server.write("ok"));
    pair.pump();
    var typed: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), client.read(&typed));

    // Again, with another host key: the client will not have it.
    var length: u32 = 32;
    _ = rig.cb.MakeKeyPair(crypto.CURVE_ED25519, &server.host_seed, &server.host_public, &length);
    server.transport.renew();
    pair.pump();
    try testing.expect(client.transport.ended());
    try testing.expectEqual(transport.reason_host_key_not_verifiable, client.transport.reason);
    try testing.expect(client.sessionEnded());
}

test "the client asks for a subsystem: the server's opener is told its name" {
    const rig = try Rig.init();
    defer rig.deinit();
    var pair = try Pair.init(rig);
    defer pair.deinit();
    pair.pump();
    pair.login(true, "");
    var request: ssh.SshSession = .{ .subsystem = 1 };
    @memcpy(request.command[0..4], "sftp");
    pair.client.session(&request);
    pair.pump();
    try testing.expectEqual(client_file.Step.running, pair.client.step);
    try testing.expectEqual(ssh.SSHSESSION_SUBSYSTEM, rig.server.kind);
    try testing.expectEqualStrings("sftp", std.mem.sliceTo(&rig.server.command, 0));
    try testing.expectEqual(@as(u32, 0), rig.server.columns);
}

test "the client: much more than a window to the server, small answers back in between" {
    const rig = try Rig.init();
    defer rig.deinit();
    var pair = try Pair.init(rig);
    defer pair.deinit();
    const server = rig.server;
    const client = pair.client;
    pair.pump();
    pair.login(true, "");
    var request: ssh.SshSession = .{ .subsystem = 1 };
    @memcpy(request.command[0..4], "sftp");
    client.session(&request);
    pair.pump();

    const total = 300 * 1024;
    const many = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(many);
    for (many, 0..) |*byte, index| byte.* = @truncate(index * 13 + index / 251);
    const back = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(back);
    var sent: usize = 0;
    var got: usize = 0;
    var answered: usize = 0;
    var answers: [64]u8 = undefined;
    var rounds: usize = 0;
    while (got < total) : (rounds += 1) {
        try testing.expect(rounds < 100_000);
        if (sent < total) sent += client.write(many[sent..@min(sent + 33 * 1024, total)]);
        pair.pump();
        const count = server.read(back[got..@min(got + 34 * 1024, total)]);
        got += count;
        // An answer for every 32 KiB taken.
        while (answered + 32 * 1024 <= got) : (answered += 32 * 1024) _ = server.write("status: 28 bytes of answer.");
        pair.pump();
        _ = client.read(&answers);
    }
    try testing.expectEqualSlices(u8, many, back);
}

test "a packet come in part waits for the rest: nothing to process until it is whole" {
    const rig = try Rig.init();
    defer rig.deinit();
    var pair = try Pair.init(rig);
    defer pair.deinit();
    const server = rig.server;
    const client = pair.client;
    pair.pump();
    pair.login(true, "");
    pair.session("", "");
    try testing.expect(!server.transport.processable());

    var text: [100]u8 = undefined;
    for (&text, 0..) |*byte, index| byte.* = @truncate('a' + index % 26);
    try testing.expectEqual(text.len, client.write(&text));
    const bytes = client.transport.pending();
    try testing.expect(bytes.len > 10);
    // Ten bytes of the packet: in the input, but not a packet yet.
    server.transport.feed(bytes[0..10]);
    client.transport.sent(10);
    try testing.expect(!server.transport.processable());
    server.process();
    try testing.expectEqual(@as(usize, 0), server.read(&text));
    // The rest: whole now.
    const rest = client.transport.pending();
    server.transport.feed(rest);
    client.transport.sent(rest.len);
    try testing.expect(server.transport.processable());
    pair.pump();
    var back: [100]u8 = undefined;
    try testing.expectEqual(back.len, server.read(&back));
    try testing.expectEqualSlices(u8, &text, &back);
}

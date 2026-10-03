// SPDX-License-Identifier: MIT
//! Host tests of TLS 1.3 (`protocol/`) against RFC 8448's handshake,
//! byte for byte, with crypto.library made from its ROM tag.

const std = @import("std");
const sdk = @import("sdk");
const crypto = sdk.crypto;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const crypto_init = @import("../../crypto/crypto_init.zig");
const kexec = @import("host_rom").exec;
const schedule = @import("../protocol/schedule.zig");
const record = @import("../protocol/record.zig");
const rfc = @import("rfc8448.zig");

const testing = std.testing;

const Rig = struct {
    sys: *ExecBase,
    library: *sdk.exec.Library,
    cb: *CryptoBase,

    fn init() !Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const made = kexec.InitResident(kexec.SysBase, &crypto_init.crypto_library_tag, null) orelse return error.NoLibrary;
        const opened = sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse return error.NoBase;
        return .{ .sys = sys, .library = @ptrCast(@alignCast(made)), .cb = @ptrCast(opened) };
    }

    fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.cb.lib());
        _ = rig.sys.RemLibrary(rig.library);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }
};

/// The server's X25519 share, from its ServerHello.
fn serverShare() []const u8 {
    const hello = &rfc.server_hello;
    const marker = [_]u8{ 0x00, 0x1d, 0x00, 0x20 };
    const at = std.mem.indexOf(u8, hello, &marker).?;
    return hello[at + 4 ..][0..32];
}

test "the key schedule and the record layer: RFC 8448's secrets, keys and records" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    const suite = schedule.TLS_AES_128_GCM_SHA256;

    var shared: [32]u8 = undefined;
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.SharedSecret(crypto.CURVE_X25519, &rfc.client_private, &crypto.Bytes.of(serverShare()), &shared));
    var handshake: schedule.Secret = undefined;
    schedule.handshakeSecret(cb, suite, &shared, &handshake);
    try testing.expectEqualSlices(u8, &rfc.handshake_secret, handshake[0..32]);

    var digest: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&rfc.client_hello);
    hash.update(&rfc.server_hello);
    hash.final(&digest);
    var client_traffic: schedule.Secret = undefined;
    var server_traffic: schedule.Secret = undefined;
    schedule.deriveSecret(cb, suite, handshake[0..32], "c hs traffic", &digest, &client_traffic);
    schedule.deriveSecret(cb, suite, handshake[0..32], "s hs traffic", &digest, &server_traffic);
    try testing.expectEqualSlices(u8, &rfc.client_hs_traffic, client_traffic[0..32]);
    try testing.expectEqualSlices(u8, &rfc.server_hs_traffic, server_traffic[0..32]);

    var keys = schedule.trafficKeys(cb, suite, server_traffic[0..32]);
    try testing.expectEqualSlices(u8, &rfc.server_hs_key, keys.key[0..16]);
    try testing.expectEqualSlices(u8, &rfc.server_hs_iv, &keys.iv);

    var master: schedule.Secret = undefined;
    schedule.masterSecret(cb, suite, handshake[0..32], &master);
    try testing.expectEqualSlices(u8, &rfc.master_secret, master[0..32]);

    // The server's encrypted flight, opened; and sealed again, the same.
    var flight = rfc.server_flight_record;
    const opened = record.open(cb, &keys, &flight) orelse return error.NotOpened;
    try testing.expectEqual(record.HANDSHAKE, opened.content_type);
    try testing.expectEqualSlices(u8, &rfc.server_flight, opened.content);
    var again = schedule.trafficKeys(cb, suite, server_traffic[0..32]);
    var sealed: [rfc.server_flight_record.len]u8 = undefined;
    const length = record.seal(cb, &again, record.HANDSHAKE, &rfc.server_flight, &sealed);
    try testing.expectEqualSlices(u8, &rfc.server_flight_record, sealed[0..length]);
}

const client_module = @import("../protocol/client.zig");
const Client = client_module.Client;

test "a whole handshake: RFC 8448's server, and the client answers with its very bytes" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    const client = try testing.allocator.create(Client);
    defer testing.allocator.destroy(client);
    // The RFC's certificate is self-signed and names no host: only its
    // CertificateVerify and the Finished messages are checked here.
    client.init(cb, .{ .host = "server", .now = 1500000000, .verify = false });
    client.private_key[0..32].* = rfc.client_private;
    client.public_length = 32;

    var buffer: [4096]u8 = undefined;
    var output: client_module.Output = .{ .buffer = &buffer };
    client.startWith(&rfc.client_hello, &output);
    try testing.expectEqualSlices(u8, &rfc.client_hello_record, output.buffer[0..output.length]);

    output.length = 0;
    var server_hello = rfc.server_hello_record;
    try testing.expectEqual(client_module.Event.more, client.receive(&server_hello, &output));
    try testing.expectEqual(@as(usize, 0), output.length);
    var flight = rfc.server_flight_record;
    try testing.expectEqual(client_module.Event.connected, client.receive(&flight, &output));
    try testing.expectEqualSlices(u8, &rfc.client_finished_record, output.buffer[0..output.length]);

    output.length = 0;
    var ticket = rfc.new_session_ticket_record;
    try testing.expectEqual(client_module.Event.more, client.receive(&ticket, &output));
    var incoming = rfc.server_application_record;
    switch (client.receive(&incoming, &output)) {
        .data => |data| try testing.expectEqualSlices(u8, &rfc.application_payload, data),
        else => return error.NoData,
    }
    client.send(&rfc.application_payload, &output);
    try testing.expectEqualSlices(u8, &rfc.client_application_record, output.buffer[0..output.length]);

    output.length = 0;
    var alert = rfc.server_alert_record;
    try testing.expectEqual(client_module.Event.closed, client.receive(&alert, &output));
}

test "a whole handshake, the RFC's client closing first; and a server whose Finished is wrong" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    const client = try testing.allocator.create(Client);
    defer testing.allocator.destroy(client);
    var buffer: [4096]u8 = undefined;
    var output: client_module.Output = .{ .buffer = &buffer };

    client.init(cb, .{ .host = "server", .now = 1500000000, .verify = false });
    client.private_key[0..32].* = rfc.client_private;
    client.public_length = 32;
    client.startWith(&rfc.client_hello, &output);
    var server_hello = rfc.server_hello_record;
    _ = client.receive(&server_hello, &output);
    var flight = rfc.server_flight_record;
    _ = client.receive(&flight, &output);
    var ticket = rfc.new_session_ticket_record;
    _ = client.receive(&ticket, &output);
    output.length = 0;
    client.send(&rfc.application_payload, &output);
    output.length = 0;
    client.close(&output);
    try testing.expectEqualSlices(u8, &rfc.client_alert_record, output.buffer[0..output.length]);

    // The flight with one byte of its ciphertext changed: it does not open.
    client.init(cb, .{ .host = "server", .now = 1500000000, .verify = false });
    client.private_key[0..32].* = rfc.client_private;
    client.public_length = 32;
    output.length = 0;
    client.startWith(&rfc.client_hello, &output);
    server_hello = rfc.server_hello_record;
    _ = client.receive(&server_hello, &output);
    flight = rfc.server_flight_record;
    flight[100] ^= 1;
    try testing.expectEqual(client_module.Event.failed, client.receive(&flight, &output));
    try testing.expectEqual(client_module.Failure.record, client.failure);

    // Checked against a trust store, the RFC's certificate is not trusted.
    client.init(cb, .{ .host = "server", .now = 1500000000, .verify = true });
    client.private_key[0..32].* = rfc.client_private;
    client.public_length = 32;
    output.length = 0;
    client.startWith(&rfc.client_hello, &output);
    server_hello = rfc.server_hello_record;
    _ = client.receive(&server_hello, &output);
    flight = rfc.server_flight_record;
    try testing.expectEqual(client_module.Event.failed, client.receive(&flight, &output));
    try testing.expectEqual(client_module.Failure.certificate, client.failure);
}

test "KeyUpdate: the server's next keys taken, and ours updated when it asks" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    const suite = schedule.TLS_AES_128_GCM_SHA256;
    const client = try testing.allocator.create(Client);
    defer testing.allocator.destroy(client);
    var buffer: [4096]u8 = undefined;
    var output: client_module.Output = .{ .buffer = &buffer };

    client.init(cb, .{ .host = "server", .now = 1500000000, .verify = false });
    client.private_key[0..32].* = rfc.client_private;
    client.public_length = 32;
    client.startWith(&rfc.client_hello, &output);
    var server_hello = rfc.server_hello_record;
    _ = client.receive(&server_hello, &output);
    var flight = rfc.server_flight_record;
    try testing.expectEqual(client_module.Event.connected, client.receive(&flight, &output));
    var ticket = rfc.new_session_ticket_record;
    _ = client.receive(&ticket, &output);

    // The server, with its application keys after the ticket: a KeyUpdate
    // that asks for ours too.
    var server_keys = schedule.trafficKeys(cb, suite, &rfc.server_ap_traffic);
    server_keys.sequence = 1;
    var sent: [64]u8 = undefined;
    var length = record.seal(cb, &server_keys, record.HANDSHAKE, &.{ 24, 0, 0, 1, 1 }, &sent);
    output.length = 0;
    try testing.expectEqual(client_module.Event.more, client.receive(sent[0..length], &output));

    // The client's answer, under its old keys: a KeyUpdate asking nothing.
    var client_keys = schedule.trafficKeys(cb, suite, &rfc.client_ap_traffic);
    var answer: [64]u8 = undefined;
    @memcpy(answer[0..output.length], output.buffer[0..output.length]);
    const opened = record.open(cb, &client_keys, answer[0..output.length]) orelse return error.NotOpened;
    try testing.expectEqual(record.HANDSHAKE, opened.content_type);
    try testing.expectEqualSlices(u8, &.{ 24, 0, 0, 1, 0 }, opened.content);

    // Both sides on their next keys.
    var next: schedule.Secret = undefined;
    schedule.nextSecret(cb, suite, &rfc.server_ap_traffic, &next);
    var server_next = schedule.trafficKeys(cb, suite, next[0..32]);
    length = record.seal(cb, &server_next, record.APPLICATION_DATA, "after the update", &sent);
    switch (client.receive(sent[0..length], &output)) {
        .data => |data| try testing.expectEqualSlices(u8, "after the update", data),
        else => return error.NoData,
    }
    output.length = 0;
    client.send("ours too", &output);
    schedule.nextSecret(cb, suite, &rfc.client_ap_traffic, &next);
    var client_next = schedule.trafficKeys(cb, suite, next[0..32]);
    const ours = record.open(cb, &client_next, output.buffer[0..output.length]) orelse return error.NotOpened;
    try testing.expectEqualSlices(u8, "ours too", ours.content);
}

// --- TLS 1.2 -------------------------------------------------------------------

const prf = @import("../protocol/prf.zig");

fn hexBytes(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

test "TLS 1.2's PRF: the published SHA-256 vector, and SHA-384 against Python's hmac" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    var out: [100]u8 = undefined;
    prf.prf(cb, crypto.HASH_SHA256, &hexBytes("9bbe436ba940f017b17652849a71db35"), "test label", &.{&hexBytes("a0ba9f936cda311827a6f796ffd5198c")}, &out);
    try testing.expectEqualSlices(u8, &hexBytes("e3f229ba727be17b8d122620557cd453c2aab21d07c3d495329b52d4e61edb5a6b301791e90d35c9c9a46b4e14baf9af0fa022f7077def17abfd3797c0564bab4fbc91666e9def9b97fce34f796789baa48082d122ee42c5a72e5a5110fff70187347b66"), &out);
    var secret: [48]u8 = undefined;
    var seed: [64]u8 = undefined;
    for (&secret, 0..) |*byte, index| byte.* = @intCast(index);
    for (&seed, 0..) |*byte, index| byte.* = @intCast(index);
    var master: [48]u8 = undefined;
    prf.prf(cb, crypto.HASH_SHA384, &secret, "master secret", &.{ seed[0..32], seed[32..64] }, &master);
    try testing.expectEqualSlices(u8, &hexBytes("c3e5ef7d93496e7ae5d17c26eec119de636b637b6bfc8634c61f384921e594ed89a57cff6f23beccc8af5d02d2e8ea2a"), &master);
}

test "TLS 1.2's records: AES-GCM with the explicit nonce and the sequence in the header, as std has it" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    var keys: schedule.TrafficKeys = .{ .key_length = 16, .sequence = 5 };
    for (keys.key[0..16], 0..) |*byte, index| byte.* = @intCast(index + 1);
    keys.iv[0..4].* = .{ 0xa0, 0xa1, 0xa2, 0xa3 };
    const content = "a record's worth of application data";
    var sealed: [128]u8 = undefined;
    const length = record.seal12(cb, &keys, record.APPLICATION_DATA, content, &sealed);
    try testing.expectEqual(@as(usize, 5 + 8 + content.len + 16), length);

    // The same by std: nonce = salt | sequence, header = sequence | type |
    // version | plain length.
    const Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
    var nonce: [12]u8 = .{ 0xa0, 0xa1, 0xa2, 0xa3, 0, 0, 0, 0, 0, 0, 0, 5 };
    const aad = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 5, 23, 3, 3, 0, content.len };
    var expected: [content.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    Gcm.encrypt(&expected, &tag, content, &aad, nonce, keys.key[0..16].*);
    try testing.expectEqualSlices(u8, nonce[4..12], sealed[5..13]);
    try testing.expectEqualSlices(u8, &expected, sealed[13..][0..content.len]);
    try testing.expectEqualSlices(u8, &tag, sealed[13 + content.len ..][0..16]);

    // Opened again by a reader at the same sequence.
    var reader: schedule.TrafficKeys = keys;
    reader.sequence = 5;
    const opened = record.open12(cb, &reader, sealed[0..length]) orelse return error.NotOpened;
    try testing.expectEqualSlices(u8, content, opened.content);
    try testing.expectEqual(@as(u64, 6), reader.sequence);
    // At another sequence the header differs, and it does not open.
    var wrong: [128]u8 = undefined;
    _ = record.seal12(cb, &keys, record.APPLICATION_DATA, content, &wrong);
    reader.sequence = 9;
    try testing.expect(record.open12(cb, &reader, wrong[0..length]) == null);
    _ = &nonce;
}

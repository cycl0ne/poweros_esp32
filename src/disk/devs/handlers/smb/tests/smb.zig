// SPDX-License-Identifier: MIT
//! Host tests of smb-handler's protocol code that needs crypto.library:
//! NTLMv2 against [MS-NLMP] 4.2.4's worked example, RC4, AES-CMAC against
//! RFC 4493, the three signatures, SP800-108's KDF and the transform
//! header against values from another implementation (Python's
//! `hmac` and `cryptography`), and the round trips of signing and sealing.
//! Also which lost session a logon after a reconnection names.

const std = @import("std");
const sdk = @import("sdk");
const crypto = sdk.crypto;
const smb = sdk.dos.smb;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const crypto_init = @import("../../../../libs/crypto/crypto_init.zig");
const kexec = @import("host_rom").exec;
const wire = @import("../wire.zig");
const ntlm = @import("../ntlm.zig");
const signing = @import("../signing.zig");
const crypt = @import("../crypt.zig");
const session_area = @import("../session.zig");

const testing = std.testing;

/// exec and crypto.library; the base the tests open is theirs.
const Rig = struct {
    sys: *ExecBase,
    library: *sdk.exec.Library,
    cb: *CryptoBase,

    fn init() !Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const made = kexec.InitResident(kexec.SysBase, &crypto_init.crypto_library_tag, null) orelse return error.NoLibrary;
        const library: *sdk.exec.Library = @ptrCast(@alignCast(made));
        const opened = sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse return error.NoBase;
        return .{ .sys = sys, .library = library, .cb = @ptrCast(opened) };
    }

    fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.cb.lib());
        _ = rig.sys.RemLibrary(rig.library);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }
};

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

// --- NTLMv2 ----------------------------------------------------------------------

/// [MS-NLMP] 4.2.4's CHALLENGE: its flags, the server's challenge, and a
/// target info of the domain's and the server's NetBIOS names - no time,
/// so the LM response is LMv2.
fn exampleChallenge(into: []u8) []const u8 {
    var writer: wire.Writer = .{ .bytes = into };
    const target_info = hex("02000c0044006f006d00610069006e0001000c005300650072007600650072000000" ++ "0000");
    writer.raw("NTLMSSP\x00");
    writer.uint32(2);
    writer.zeros(8); // TargetName: none
    writer.uint32(0xE28A8233);
    writer.raw(&hex("0123456789abcdef"));
    writer.zeros(8);
    writer.uint16(target_info.len);
    writer.uint16(target_info.len);
    writer.uint32(56);
    writer.zeros(8); // Version
    writer.raw(&target_info);
    return writer.written();
}

/// A field of an AUTHENTICATE message: its bytes in the payload.
fn fieldOf(message: []const u8, at: usize) []const u8 {
    const length = wire.u16At(message, at);
    const offset = wire.u32At(message, at + 4);
    return message[offset..][0..length];
}

test "NTLMv2: MS-NLMP 4.2.4's keys and responses" {
    var rig = try Rig.init();
    defer rig.deinit() catch {};
    const cb = rig.cb;

    const nt_hash = ntlm.ntHash(cb, "Password");
    try testing.expectEqualSlices(u8, &hex("a4f49c406510bdcab6824ee7c30fd852"), &nt_hash);
    const key = ntlm.responseKey(cb, nt_hash, "USER", "Domain");
    try testing.expectEqualSlices(u8, &hex("0c868a403bfd7a93a3001ef22ef02e3f"), &key);

    var challenge_bytes: [128]u8 = undefined;
    const challenge = ntlm.Challenge.parse(exampleChallenge(&challenge_bytes)).?;
    try testing.expectEqual(@as(?u64, null), challenge.timestamp);
    const identity: ntlm.Identity = .{ .user = "User", .user_upper = "USER", .domain = "Domain", .workstation = "COMPUTER", .nt_hash = nt_hash };
    const inventions: ntlm.Inventions = .{
        .client_challenge = @splat(0xAA),
        .random_session_key = @splat(0x55),
        .time = 0,
    };
    var room: [512]u8 = undefined;
    var writer: wire.Writer = .{ .bytes = &room };
    const session_key = ntlm.authenticate(cb, &writer, &identity, &challenge, &inventions).?;
    try testing.expectEqualSlices(u8, &([_]u8{0x55} ** 16), &session_key);

    const message = writer.written();
    try testing.expectEqualSlices(u8, "NTLMSSP\x00", message[0..8]);
    try testing.expectEqual(@as(u32, 3), wire.u32At(message, 8));
    try testing.expectEqualSlices(u8, &hex("86c35097ac9cec102554764a57cccc19aaaaaaaaaaaaaaaa"), fieldOf(message, 12));
    const nt = fieldOf(message, 20);
    try testing.expectEqualSlices(u8, &hex("68cd0ab851e51c96aabc927bebef6a1c"), nt[0..16]);
    try testing.expectEqualSlices(u8, &hex("0101000000000000" ++ "0000000000000000" ++ "aaaaaaaaaaaaaaaa" ++ "00000000"), nt[16..44]);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(std.unicode.utf8ToUtf16LeStringLiteral("Domain")), fieldOf(message, 28));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(std.unicode.utf8ToUtf16LeStringLiteral("User")), fieldOf(message, 36));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(std.unicode.utf8ToUtf16LeStringLiteral("COMPUTER")), fieldOf(message, 44));
    try testing.expectEqualSlices(u8, &hex("c5dad2544fc9799094ce1ce90bc9d03e"), fieldOf(message, 52));
    // The payload starts after the version and the MIC's room.
    try testing.expectEqual(@as(u32, 88), wire.u32At(message, 28 + 4));
}

test "NTLMv2: a server's time in the target info, and an anonymous logon" {
    var rig = try Rig.init();
    defer rig.deinit() catch {};
    const cb = rig.cb;

    // The example's target info with a time before its end.
    var bytes: [160]u8 = undefined;
    var writer: wire.Writer = .{ .bytes = &bytes };
    const target_info = hex("02000c0044006f006d00610069006e00" ++ "07000800" ++ "0102030405060708" ++ "00000000");
    writer.raw("NTLMSSP\x00");
    writer.uint32(2);
    writer.zeros(8);
    writer.uint32(0xE28A8233);
    writer.raw(&hex("0123456789abcdef"));
    writer.zeros(8);
    writer.uint16(target_info.len);
    writer.uint16(target_info.len);
    writer.uint32(56);
    writer.zeros(8);
    writer.raw(&target_info);
    const challenge = ntlm.Challenge.parse(writer.written()).?;
    try testing.expectEqual(@as(?u64, 0x0807060504030201), challenge.timestamp);

    const inventions: ntlm.Inventions = .{ .client_challenge = @splat(0xAA), .random_session_key = @splat(0x55), .time = 0 };
    var room: [512]u8 = undefined;
    var out: wire.Writer = .{ .bytes = &room };
    const identity: ntlm.Identity = .{ .user = "User", .user_upper = "USER", .domain = "Domain", .nt_hash = ntlm.ntHash(cb, "Password") };
    _ = ntlm.authenticate(cb, &out, &identity, &challenge, &inventions).?;
    // With the server's time, LM is 24 zeros and the blob has that time.
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 24), fieldOf(out.written(), 12));
    try testing.expectEqualSlices(u8, &hex("0102030405060708"), fieldOf(out.written(), 20)[24..32]);

    out = .{ .bytes = &room };
    const nobody: ntlm.Identity = .{};
    try testing.expect(ntlm.authenticate(cb, &out, &nobody, &challenge, &inventions) == null);
    const anonymous = out.written();
    try testing.expectEqualSlices(u8, &.{0}, fieldOf(anonymous, 12));
    try testing.expectEqual(@as(usize, 0), fieldOf(anonymous, 20).len);
    try testing.expect(wire.u32At(anonymous, 60) & ntlm.NEGOTIATE_ANONYMOUS != 0);
    // Under KEY_EXCH the random key goes RC4'd with the anonymous base
    // key, sixteen zeros.
    try testing.expectEqualSlices(u8, &hex("8b4ddc14f662086fdf534b32023bc738"), fieldOf(anonymous, 52));
}

test "RC4's known answers" {
    const cases = [_]struct { key: []const u8, plain: []const u8, sealed: []const u8 }{
        .{ .key = "Key", .plain = "Plaintext", .sealed = &hex("BBF316E8D940AF0AD3") },
        .{ .key = "Wiki", .plain = "pedia", .sealed = &hex("1021BF0420") },
        .{ .key = "Secret", .plain = "Attack at dawn", .sealed = &hex("45A01F645FC35B383552544B9BF5") },
    };
    for (cases) |case| {
        var bytes: [32]u8 = undefined;
        @memcpy(bytes[0..case.plain.len], case.plain);
        var cipher = ntlm.Rc4.init(case.key);
        cipher.apply(bytes[0..case.plain.len]);
        try testing.expectEqualSlices(u8, case.sealed, bytes[0..case.plain.len]);
    }
}

// --- signing ---------------------------------------------------------------------

test "AES-CMAC: RFC 4493's four examples" {
    var rig = try Rig.init();
    defer rig.deinit() catch {};
    const key = hex("2b7e151628aed2a6abf7158809cf4f3c");
    const message = hex("6bc1bee22e409f96e93d7e117393172a" ++ "ae2d8a571e03ac9c9eb76fac45af8e51" ++
        "30c81c46a35ce411e5fbc1191a0a52ef" ++ "f69f2445df4f9b17ad2b417be66c3710");
    try testing.expectEqualSlices(u8, &hex("bb1d6929e95937287fa37d129b756746"), &signing.cmac(rig.cb, &key, message[0..0]));
    try testing.expectEqualSlices(u8, &hex("070a16b46b4d4144f79bdd9dd04a287c"), &signing.cmac(rig.cb, &key, message[0..16]));
    try testing.expectEqualSlices(u8, &hex("dfa66747de9ae63030ca32611497c827"), &signing.cmac(rig.cb, &key, message[0..40]));
    try testing.expectEqualSlices(u8, &hex("51f0bebf7e3b9d92fc49741779363cfe"), &signing.cmac(rig.cb, &key, message[0..64]));
}

test "SP800-108's KDF, as 3.0 and 3.1.1 make their keys" {
    var rig = try Rig.init();
    defer rig.deinit() catch {};
    var key: [16]u8 = undefined;
    for (&key, 0..) |*byte, at| byte.* = @intCast(at);
    var preauth: [64]u8 = undefined;
    for (&preauth, 0..) |*byte, at| byte.* = @intCast(at);
    var out: [32]u8 = undefined;
    signing.derive(rig.cb, &key, signing.label_cmac_30, signing.context_sign_30, out[0..16]);
    try testing.expectEqualSlices(u8, &hex("6234814cbb8ea9227440ebfeb5eacbe1"), out[0..16]);
    signing.derive(rig.cb, &key, signing.label_sign_311, &preauth, out[0..16]);
    try testing.expectEqualSlices(u8, &hex("f7e5401ecc6e79ef9eab401b05004e4f"), out[0..16]);
    signing.derive(rig.cb, &key, signing.label_c2s_311, &preauth, &out);
    try testing.expectEqualSlices(u8, &hex("d09c44a545f554240ddf8ac2777570de0f590e402196d1006261f7448076384d"), &out);
}

/// A message to sign: a pattern, then the header fields a signature
/// depends on - an answer (to message 5, a READ).
fn patterned() [100]u8 {
    var message: [100]u8 = undefined;
    for (&message, 0..) |*byte, at| byte.* = @truncate(at * 7);
    wire.put16(&message, 12, @intFromEnum(wire.Command.read));
    wire.put32(&message, 16, wire.FLAGS_SERVER_TO_REDIR);
    wire.put64(&message, 24, 5);
    return message;
}

test "the three signatures, and a message changed after signing" {
    var rig = try Rig.init();
    defer rig.deinit() catch {};
    var key: [16]u8 = undefined;
    for (&key, 0..) |*byte, at| byte.* = @intCast(at);
    const cases = [_]struct { algorithm: u16, signature: [16]u8 }{
        .{ .algorithm = smb.SMB2_SIGNING_HMAC_SHA256, .signature = hex("3d8541187aa0d5ebf1fd36bf5a8470be") },
        .{ .algorithm = smb.SMB2_SIGNING_AES_CMAC, .signature = hex("456ce2ce1e313ff6012db28e8c72cd31") },
        .{ .algorithm = smb.SMB2_SIGNING_AES_GMAC, .signature = hex("d0b1880cb2057a0edfe75c2ce27b7ae6") },
    };
    for (cases) |case| {
        const signer: signing.Signer = .{ .algorithm = case.algorithm, .key = key };
        var message = patterned();
        signer.sign(rig.cb, &message);
        try testing.expect(wire.u32At(&message, 16) & wire.FLAGS_SIGNED != 0);
        try testing.expectEqualSlices(u8, &case.signature, message[wire.signature_at..][0..16]);
        var copy = message;
        try testing.expect(signer.verify(rig.cb, &copy));
        copy = message;
        copy[80] ^= 1;
        try testing.expect(!signer.verify(rig.cb, &copy));
    }
}

test "a message sealed, as another implementation seals it, and opened again" {
    var rig = try Rig.init();
    defer rig.deinit() catch {};
    var keys: crypt.Keys = .{ .cipher = smb.SMB2_CIPHER_AES_256_GCM, .length = 32, .salt = .{ 9, 8, 7, 6 } };
    for (&keys.seal, 0..) |*byte, at| byte.* = @intCast(at);
    keys.open = keys.seal;
    var frame: [crypt.header_size + 5]u8 = undefined;
    @memcpy(frame[crypt.header_size..], "hello");
    const sealed = crypt.seal(rig.cb, &keys, 0x1122334455667788, &frame, 5);
    try testing.expectEqual(@as(usize, crypt.header_size + 5), sealed.len);
    try testing.expectEqualSlices(u8, &wire.transform_id, sealed[0..4]);
    try testing.expectEqualSlices(u8, &hex("fadaa1f056"), sealed[crypt.header_size..]);
    try testing.expectEqualSlices(u8, &hex("560f0f411eebd7904a817ba38d5070c9"), sealed[4..20]);

    var copy = frame;
    try testing.expectEqualStrings("hello", crypt.open(rig.cb, &keys, 0x1122334455667788, &copy).?);
    copy = frame;
    try testing.expect(crypt.open(rig.cb, &keys, 0x1122334455667789, &copy) == null);
    copy = frame;
    copy[40] ^= 1; // the additional data
    try testing.expect(crypt.open(rig.cb, &keys, 0x1122334455667788, &copy) == null);
    // The next message has the next nonce.
    _ = crypt.seal(rig.cb, &keys, 0x1122334455667788, &frame, 5);
    try testing.expectEqual(@as(u64, 2), wire.u64At(&frame, 20));
}

// --- a connection made again ---------------------------------------------------------

test "a reconnection's logon names the first session lost, until a logon has named it" {
    var rig = try Rig.init();
    defer rig.deinit() catch {};
    var send: [16]u8 = undefined;
    var receive: [16]u8 = undefined;
    var session: session_area.Session = .{
        .cb = rig.cb,
        .connection = .{ .sb = undefined },
        .send_buffer = &send,
        .receive_buffer = &receive,
        .client_guid = @splat(7),
    };
    session.session_id = 0x11;
    session.tree_id = 3;
    session.reset();
    try testing.expectEqual(@as(u64, 0x11), session.previous_id);
    try testing.expectEqual(@as(u64, 0), session.session_id);
    try testing.expectEqual(@as(u32, 0), session.tree_id);
    try testing.expectEqual(@as(u8, 7), session.client_guid[0]);
    // A logon that got a session but failed: the one lost first is named
    // again.
    session.session_id = 0x22;
    session.reset();
    try testing.expectEqual(@as(u64, 0x11), session.previous_id);
    // Once a logon has named it, the next loss names the session that
    // logon made.
    session.previous_id = 0;
    session.session_id = 0x33;
    session.reset();
    try testing.expectEqual(@as(u64, 0x33), session.previous_id);
}

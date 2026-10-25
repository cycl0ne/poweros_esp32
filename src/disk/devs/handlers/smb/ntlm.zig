// SPDX-License-Identifier: MIT
//! NTLMv2 ([MS-NLMP]), the logon's three messages: NEGOTIATE says what
//! the client can do, the server's CHALLENGE gives eight random bytes and
//! what it knows about itself (the target info), and AUTHENTICATE proves
//! the password without sending it.
//!
//! **The proof.** The response key is HMAC-MD5 over the user's name in
//! capitals and the domain, keyed with the password's NT hash (MD4 over
//! its UTF-16). The proof is HMAC-MD5 over the server's challenge and a
//! blob of the client's own - a time, eight random bytes and the server's
//! target info - keyed with the response key; the session's base key is
//! HMAC-MD5 over the proof with the same key.
//!
//! **The session key.** With KEY_EXCH, which both sides offer, the
//! session's key is sixteen random bytes of the client's, sent RC4'd with
//! the base key; without it the base key is the session's. Either way it
//! is what SMB signs and encrypts with.
//!
//! **Anonymous** is no user and no password: no proof and a one-byte LM
//! response of zero. Its base key is sixteen zeros, so under KEY_EXCH the
//! random key goes RC4'd with that, as the message's form asks; the
//! session is IS_NULL and nothing is signed with it.
//!
//! No MIC is sent, and so none of the target info's flags claims one:
//! a server then asks for no MIC over the SPNEGO exchange either.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const wire = @import("wire.zig");
const Writer = wire.Writer;

const signature = "NTLMSSP\x00";

pub const NEGOTIATE_UNICODE: u32 = 0x0000_0001;
pub const REQUEST_TARGET: u32 = 0x0000_0004;
pub const NEGOTIATE_SIGN: u32 = 0x0000_0010;
pub const NEGOTIATE_NTLM: u32 = 0x0000_0200;
pub const NEGOTIATE_ANONYMOUS: u32 = 0x0000_0800;
pub const NEGOTIATE_ALWAYS_SIGN: u32 = 0x0000_8000;
pub const NEGOTIATE_EXTENDED_SESSIONSECURITY: u32 = 0x0008_0000;
pub const NEGOTIATE_TARGET_INFO: u32 = 0x0080_0000;
pub const NEGOTIATE_VERSION: u32 = 0x0200_0000;
pub const NEGOTIATE_128: u32 = 0x2000_0000;
pub const NEGOTIATE_KEY_EXCH: u32 = 0x4000_0000;
pub const NEGOTIATE_56: u32 = 0x8000_0000;

/// What the client offers.
pub const offered: u32 = NEGOTIATE_UNICODE | REQUEST_TARGET | NEGOTIATE_SIGN | NEGOTIATE_NTLM |
    NEGOTIATE_ALWAYS_SIGN | NEGOTIATE_EXTENDED_SESSIONSECURITY | NEGOTIATE_VERSION |
    NEGOTIATE_128 | NEGOTIATE_KEY_EXCH | NEGOTIATE_56;

/// The version a message carries: 0.2, build 0, NTLM revision 15. It is
/// for a server's logs; nothing depends on it.
const version = [8]u8{ 0, 2, 0, 0, 0, 0, 0, 0x0F };

/// The target info's entries this side reads: the end, and the server's
/// time.
const av_eol: u16 = 0;
const av_timestamp: u16 = 7;

/// NEGOTIATE: the flags, no domain, no workstation, the version.
pub fn negotiate(writer: *Writer) void {
    writer.raw(signature);
    writer.uint32(1);
    writer.uint32(offered);
    writer.zeros(8); // the domain: none
    writer.zeros(8); // the workstation: none
    writer.raw(&version);
}

/// The server's CHALLENGE, as far as AUTHENTICATE needs it.
pub const Challenge = struct {
    flags: u32,
    server_challenge: [8]u8,
    /// The target info as the server sent it: AV pairs, ending in EOL.
    target_info: []const u8,
    /// The server's time from the target info, as a FILETIME.
    timestamp: ?u64,

    /// The challenge in `bytes`, or null when they are none.
    pub fn parse(bytes: []const u8) ?Challenge {
        if (bytes.len < 48 or !wire.same(bytes[0..8], signature) or wire.u32At(bytes, 8) != 2) return null;
        var challenge: Challenge = .{
            .flags = wire.u32At(bytes, 20),
            .server_challenge = bytes[24..32].*,
            .target_info = &.{},
            .timestamp = null,
        };
        const length = wire.u16At(bytes, 40);
        const offset = wire.u32At(bytes, 44);
        if (length != 0) {
            if (offset > bytes.len or bytes.len - offset < length) return null;
            challenge.target_info = bytes[offset..][0..length];
        }
        // The pairs, for the time.
        var at: usize = 0;
        const info = challenge.target_info;
        while (info.len - at >= 4) {
            const id = wire.u16At(info, at);
            const pair_length = wire.u16At(info, at + 2);
            if (id == av_eol or info.len - at - 4 < pair_length) break;
            if (id == av_timestamp and pair_length == 8) challenge.timestamp = wire.u64At(info, at + 4);
            at += 4 + pair_length;
        }
        return challenge;
    }
};

/// Who logs on.
pub const Identity = struct {
    /// The user as given, and in capitals; both empty for anonymous.
    user: []const u8 = &.{},
    user_upper: []const u8 = &.{},
    domain: []const u8 = &.{},
    workstation: []const u8 = &.{},
    /// The password's NT hash; null with no user is anonymous.
    nt_hash: ?[16]u8 = null,

    fn anonymous(identity: *const Identity) bool {
        return identity.user.len == 0 and identity.nt_hash == null;
    }
};

/// What the client makes up for one logon: random bytes, and the time to
/// use when the server's target info has none.
pub const Inventions = struct {
    client_challenge: [8]u8,
    random_session_key: [16]u8,
    /// A FILETIME: the server's own, from its NEGOTIATE answer.
    time: u64,
};

/// AUTHENTICATE for `challenge`, written to `writer`: the session key it
/// makes, or null for an anonymous logon, which has none.
///
/// INPUTS:
/// - `cb` - crypto.library, for HMAC-MD5.
/// - `writer` - where the message goes.
/// - `identity` - who logs on.
/// - `challenge` - the server's.
/// - `inventions` - the client's random bytes and its time.
pub fn authenticate(cb: *CryptoBase, writer: *Writer, identity: *const Identity, challenge: *const Challenge, inventions: *const Inventions) ?[16]u8 {
    const flags = (offered & challenge.flags) | (if (identity.anonymous()) NEGOTIATE_ANONYMOUS else 0);
    const start = writer.at;
    writer.raw(signature);
    writer.uint32(3);
    // The six fields' places, filled in as their payloads are written.
    const fields_at = writer.at;
    writer.zeros(6 * 8);
    writer.uint32(flags);
    writer.raw(&version);
    writer.zeros(16); // the MIC: none

    const Field = enum(usize) { lm = 0, nt = 1, domain = 2, user = 3, workstation = 4, session_key = 5 };
    const Payload = struct {
        fn begin(into: *Writer) usize {
            return into.at;
        }
        fn end(into: *Writer, base: usize, places: usize, field: Field, from: usize) void {
            const at = places + 8 * @intFromEnum(field);
            const length: u16 = @intCast(into.at - from);
            into.patch16(at, length);
            into.patch16(at + 2, length);
            into.patch32(at + 4, @intCast(from - base));
        }
    };

    var from = Payload.begin(writer);
    wire.latin1(writer, identity.domain);
    Payload.end(writer, start, fields_at, .domain, from);
    from = Payload.begin(writer);
    wire.latin1(writer, identity.user);
    Payload.end(writer, start, fields_at, .user, from);
    from = Payload.begin(writer);
    wire.latin1(writer, identity.workstation);
    Payload.end(writer, start, fields_at, .workstation, from);

    if (identity.anonymous()) {
        from = Payload.begin(writer);
        writer.byte(0);
        Payload.end(writer, start, fields_at, .lm, from);
        from = Payload.begin(writer);
        Payload.end(writer, start, fields_at, .nt, from);
        from = Payload.begin(writer);
        if (flags & NEGOTIATE_KEY_EXCH != 0) {
            var sealed = inventions.random_session_key;
            var cipher = Rc4.init(&@as([16]u8, @splat(0)));
            cipher.apply(&sealed);
            writer.raw(&sealed);
        }
        Payload.end(writer, start, fields_at, .session_key, from);
        return null;
    }

    const response_key = responseKey(cb, identity.nt_hash orelse emptyPassword(cb), identity.user_upper, identity.domain);
    const time = challenge.timestamp orelse inventions.time;

    // LM: 24 zeros when the server sent its time, else LMv2.
    from = Payload.begin(writer);
    if (challenge.timestamp != null) {
        writer.zeros(24);
    } else {
        writer.raw(&hmacMd5(cb, &response_key, &.{ &challenge.server_challenge, &inventions.client_challenge }));
        writer.raw(&inventions.client_challenge);
    }
    Payload.end(writer, start, fields_at, .lm, from);

    // NT: the proof, then the blob it was made over.
    from = Payload.begin(writer);
    writer.zeros(16);
    const blob_at = writer.at;
    writeBlob(writer, time, &inventions.client_challenge, challenge.target_info);
    if (writer.full) return null;
    const blob = writer.bytes[blob_at..writer.at];
    const proof = hmacMd5(cb, &response_key, &.{ &challenge.server_challenge, blob });
    @memcpy(writer.bytes[from..][0..16], &proof);
    Payload.end(writer, start, fields_at, .nt, from);

    const base_key = hmacMd5(cb, &response_key, &.{&proof});
    from = Payload.begin(writer);
    if (flags & NEGOTIATE_KEY_EXCH != 0) {
        var sealed = inventions.random_session_key;
        var cipher = Rc4.init(&base_key);
        cipher.apply(&sealed);
        writer.raw(&sealed);
        Payload.end(writer, start, fields_at, .session_key, from);
        return inventions.random_session_key;
    }
    Payload.end(writer, start, fields_at, .session_key, from);
    return base_key;
}

/// The blob the proof is made over: its two version bytes, the time, the
/// client's challenge and the server's target info.
fn writeBlob(writer: *Writer, time: u64, client_challenge: *const [8]u8, target_info: []const u8) void {
    writer.byte(1);
    writer.byte(1);
    writer.zeros(6);
    writer.uint64(time);
    writer.raw(client_challenge);
    writer.zeros(4);
    writer.raw(target_info);
    writer.zeros(4);
}

/// NTOWFv2: HMAC-MD5 over the user in capitals and the domain, in
/// UTF-16, keyed with the password's NT hash.
///
/// INPUTS:
/// - `cb` - crypto.library.
/// - `nt_hash` - the password's.
/// - `user_upper` - the user's name in capitals, Latin-1.
/// - `domain` - the domain as given, Latin-1.
pub fn responseKey(cb: *CryptoBase, nt_hash: [16]u8, user_upper: []const u8, domain: []const u8) [16]u8 {
    var text: [2 * (sdk.dos.smb.SMB_USER_MAX + sdk.dos.smb.SMB_DOMAIN_MAX)]u8 = undefined;
    var writer: Writer = .{ .bytes = &text };
    wire.latin1(&writer, user_upper);
    wire.latin1(&writer, domain);
    return hmacMd5(cb, &nt_hash, &.{writer.written()});
}

/// The NT hash of a password: MD4 over its UTF-16.
///
/// INPUTS:
/// - `cb` - crypto.library.
/// - `password` - Latin-1.
pub fn ntHash(cb: *CryptoBase, password: []const u8) [16]u8 {
    var context: crypto.HashContext = .{};
    _ = cb.InitHash(&context, crypto.HASH_MD4);
    for (password) |char| cb.UpdateHash(&context, &[2]u8{ char, 0 }, 2);
    var digest: [crypto.DIGEST_MAX]u8 = undefined;
    _ = cb.FinishHash(&context, &digest);
    return digest[0..16].*;
}

/// The empty password's hash: a user named without a password.
fn emptyPassword(cb: *CryptoBase) [16]u8 {
    return ntHash(cb, "");
}

/// HMAC-MD5 over `parts` in turn.
///
/// INPUTS:
/// - `cb` - crypto.library.
/// - `key` - the key.
/// - `parts` - the message, in pieces.
pub fn hmacMd5(cb: *CryptoBase, key: []const u8, parts: []const []const u8) [16]u8 {
    var context: crypto.HmacContext = .{};
    _ = cb.InitHmac(&context, crypto.HASH_MD5, key.ptr, @intCast(key.len));
    for (parts) |part| cb.UpdateHmac(&context, part.ptr, @intCast(part.len));
    var mac: [crypto.DIGEST_MAX]u8 = undefined;
    _ = cb.FinishHmac(&context, &mac);
    return mac[0..16].*;
}

/// RC4, which seals the random session key under KEY_EXCH and nothing
/// else.
pub const Rc4 = struct {
    state: [256]u8,
    i: u8 = 0,
    j: u8 = 0,

    pub fn init(key: []const u8) Rc4 {
        var cipher: Rc4 = .{ .state = undefined };
        for (&cipher.state, 0..) |*byte, index| byte.* = @intCast(index);
        var j: u8 = 0;
        for (0..256) |index| {
            j +%= cipher.state[index] +% key[index % key.len];
            const held = cipher.state[index];
            cipher.state[index] = cipher.state[j];
            cipher.state[j] = held;
        }
        return cipher;
    }

    /// `bytes` XORed with the key stream, in place.
    pub fn apply(cipher: *Rc4, bytes: []u8) void {
        for (bytes) |*byte| {
            cipher.i +%= 1;
            cipher.j +%= cipher.state[cipher.i];
            const held = cipher.state[cipher.i];
            cipher.state[cipher.i] = cipher.state[cipher.j];
            cipher.state[cipher.j] = held;
            byte.* ^= cipher.state[cipher.state[cipher.i] +% cipher.state[cipher.j]];
        }
    }
};

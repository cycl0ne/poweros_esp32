// SPDX-License-Identifier: MIT
//! TLS 1.3's key schedule (RFC 8446, 7.1): every secret of a connection
//! from the shared secret and the hash of the messages so far.
//!
//!   early     = HKDF-Extract(0, 0)
//!   handshake = HKDF-Extract(Derive-Secret(early, "derived", ""), ECDHE)
//!   master    = HKDF-Extract(Derive-Secret(handshake, "derived", ""), 0)
//!
//! and from the handshake and master secrets each side's traffic secret,
//! from a traffic secret its key and IV, and from a handshake traffic
//! secret the key a Finished message is an HMAC with. Each step is
//! crypto.library's HKDF or HMAC, through its jump table.
//!
//! A cipher suite decides the hash all of it is made with, and the AEAD
//! key's length; the two suites taken are AES-128-GCM with SHA-256 and
//! AES-256-GCM with SHA-384, both the AES engine's.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const CryptoBase = sdk.interface.crypto.CryptoBase;

/// A cipher suite: its number, its hash, its key's length.
pub const Suite = struct {
    id: u16,
    hash: u32,
    hash_length: u32,
    key_length: u32,
};

pub const TLS_AES_128_GCM_SHA256: Suite = .{ .id = 0x1301, .hash = crypto.HASH_SHA256, .hash_length = 32, .key_length = 16 };
pub const TLS_AES_256_GCM_SHA384: Suite = .{ .id = 0x1302, .hash = crypto.HASH_SHA384, .hash_length = 48, .key_length = 32 };

/// The suite of that number, if it is one of ours.
pub fn suiteOf(id: u16) ?Suite {
    if (id == TLS_AES_128_GCM_SHA256.id) return TLS_AES_128_GCM_SHA256;
    if (id == TLS_AES_256_GCM_SHA384.id) return TLS_AES_256_GCM_SHA384;
    return null;
}

/// The longest secret: SHA-384's.
pub const secret_max = 48;
pub const Secret = [secret_max]u8;

/// HKDF-Expand-Label: `out` from `secret`, the label ("tls13 " before
/// it) and a context.
pub fn expandLabel(cb: *CryptoBase, suite: Suite, secret: []const u8, label: []const u8, context: []const u8, out: []u8) void {
    var info: [2 + 1 + 6 + 32 + 1 + secret_max]u8 = undefined;
    info[0] = @truncate(out.len >> 8);
    info[1] = @truncate(out.len);
    info[2] = @intCast(6 + label.len);
    @memcpy(info[3..9], "tls13 ");
    @memcpy(info[9..][0..label.len], label);
    var at: usize = 9 + label.len;
    info[at] = @intCast(context.len);
    at += 1;
    @memcpy(info[at..][0..context.len], context);
    at += context.len;
    _ = cb.HkdfExpand(suite.hash, &Bytes.of(secret), &Bytes.of(info[0..at]), out.ptr, @intCast(out.len));
}

/// Derive-Secret: a secret of the hash's length from a secret, a label
/// and the transcript's digest.
pub fn deriveSecret(cb: *CryptoBase, suite: Suite, secret: []const u8, label: []const u8, digest: []const u8, out: []u8) void {
    expandLabel(cb, suite, secret, label, digest, out[0..suite.hash_length]);
}

/// The digest of no messages at all, for the "derived" steps.
fn emptyDigest(cb: *CryptoBase, suite: Suite, out: []u8) void {
    var context: crypto.HashContext = .{};
    _ = cb.InitHash(&context, suite.hash);
    _ = cb.FinishHash(&context, out.ptr);
}

/// The handshake secret from the key exchange's shared secret.
pub fn handshakeSecret(cb: *CryptoBase, suite: Suite, shared: []const u8, out: []u8) void {
    const length = suite.hash_length;
    const zeroes: Secret = @splat(0);
    var early: Secret = undefined;
    _ = cb.HkdfExtract(suite.hash, &Bytes.of(zeroes[0..length]), &Bytes.of(zeroes[0..length]), &early);
    var empty: Secret = undefined;
    emptyDigest(cb, suite, &empty);
    var derived: Secret = undefined;
    deriveSecret(cb, suite, early[0..length], "derived", empty[0..length], &derived);
    _ = cb.HkdfExtract(suite.hash, &Bytes.of(derived[0..length]), &Bytes.of(shared), out.ptr);
    wipe(&early);
    wipe(&derived);
}

/// The master secret from the handshake secret.
pub fn masterSecret(cb: *CryptoBase, suite: Suite, handshake: []const u8, out: []u8) void {
    const length = suite.hash_length;
    const zeroes: Secret = @splat(0);
    var empty: Secret = undefined;
    emptyDigest(cb, suite, &empty);
    var derived: Secret = undefined;
    deriveSecret(cb, suite, handshake, "derived", empty[0..length], &derived);
    _ = cb.HkdfExtract(suite.hash, &Bytes.of(derived[0..length]), &Bytes.of(zeroes[0..length]), out.ptr);
    wipe(&derived);
}

/// A direction's key and IV, and how many records it has protected.
pub const TrafficKeys = struct {
    key: [32]u8 = @splat(0),
    key_length: u32 = 0,
    iv: [12]u8 = @splat(0),
    sequence: u64 = 0,
};

/// The key and IV a traffic secret stands for, sequence at zero.
pub fn trafficKeys(cb: *CryptoBase, suite: Suite, secret: []const u8) TrafficKeys {
    var keys: TrafficKeys = .{ .key_length = suite.key_length };
    expandLabel(cb, suite, secret, "key", "", keys.key[0..suite.key_length]);
    expandLabel(cb, suite, secret, "iv", "", &keys.iv);
    return keys;
}

/// The next traffic secret, for KeyUpdate.
pub fn nextSecret(cb: *CryptoBase, suite: Suite, secret: []const u8, out: []u8) void {
    expandLabel(cb, suite, secret, "traffic upd", "", out[0..suite.hash_length]);
}

/// A Finished message's verify_data: HMAC of the transcript's digest
/// with the key the handshake traffic secret gives.
pub fn finished(cb: *CryptoBase, suite: Suite, traffic: []const u8, digest: []const u8, out: []u8) void {
    var key: Secret = undefined;
    expandLabel(cb, suite, traffic, "finished", "", key[0..suite.hash_length]);
    var context: crypto.HmacContext = .{};
    _ = cb.InitHmac(&context, suite.hash, &key, suite.hash_length);
    cb.UpdateHmac(&context, digest.ptr, @intCast(digest.len));
    _ = cb.FinishHmac(&context, out.ptr);
    wipe(&key);
}

pub fn wipe(bytes: []u8) void {
    for (bytes) |*byte| @as(*volatile u8, byte).* = 0;
}

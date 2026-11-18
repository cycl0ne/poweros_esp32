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
//! and its key's length: AES-128-GCM with SHA-256, AES-256-GCM with
//! SHA-384, and ChaCha20-Poly1305 with SHA-256 - crypto.library's since
//! 2.13, and offered only by one that has it. Which comes first is
//! the machine's: AES-GCM where AES runs on hardware, ChaCha20-Poly1305
//! where it is software (`offer`).

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const CryptoBase = sdk.interface.crypto.CryptoBase;

/// A cipher suite: its number, its hash, its key's length; for TLS 1.2,
/// the kind of certificate key it signs its key exchange with.
pub const Suite = struct {
    id: u16,
    hash: u32,
    hash_length: u32,
    key_length: u32,
    tls12: bool = false,
    /// TLS 1.2's: the server's key is ECDSA's (or else RSA's).
    ecdsa: bool = false,
    /// The AEAD is ChaCha20-Poly1305 (or else AES-GCM).
    chacha: bool = false,
};

pub const TLS_AES_128_GCM_SHA256: Suite = .{ .id = 0x1301, .hash = crypto.HASH_SHA256, .hash_length = 32, .key_length = 16 };
pub const TLS_AES_256_GCM_SHA384: Suite = .{ .id = 0x1302, .hash = crypto.HASH_SHA384, .hash_length = 48, .key_length = 32 };
pub const TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256: Suite = .{ .id = 0xC02B, .hash = crypto.HASH_SHA256, .hash_length = 32, .key_length = 16, .tls12 = true, .ecdsa = true };
pub const TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256: Suite = .{ .id = 0xC02F, .hash = crypto.HASH_SHA256, .hash_length = 32, .key_length = 16, .tls12 = true };
pub const TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384: Suite = .{ .id = 0xC02C, .hash = crypto.HASH_SHA384, .hash_length = 48, .key_length = 32, .tls12 = true, .ecdsa = true };
pub const TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384: Suite = .{ .id = 0xC030, .hash = crypto.HASH_SHA384, .hash_length = 48, .key_length = 32, .tls12 = true };
pub const TLS_CHACHA20_POLY1305_SHA256: Suite = .{ .id = 0x1303, .hash = crypto.HASH_SHA256, .hash_length = 32, .key_length = 32, .chacha = true };
pub const TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256: Suite = .{ .id = 0xCCA9, .hash = crypto.HASH_SHA256, .hash_length = 32, .key_length = 32, .tls12 = true, .ecdsa = true, .chacha = true };
pub const TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256: Suite = .{ .id = 0xCCA8, .hash = crypto.HASH_SHA256, .hash_length = 32, .key_length = 32, .tls12 = true, .chacha = true };

/// Every suite there is here: TLS 1.3's, then TLS 1.2's, AES-GCM's
/// before ChaCha20-Poly1305's in each.
pub const suites = [_]Suite{
    TLS_AES_128_GCM_SHA256,
    TLS_AES_256_GCM_SHA384,
    TLS_CHACHA20_POLY1305_SHA256,
    TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
    TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
    TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
    TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
    TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
    TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
};

/// Whether crypto.library has ChaCha20-Poly1305 and CryptoEngines: 2.13
/// or later. An older one has neither call in its jump table.
pub fn hasChaCha(cb: *CryptoBase) bool {
    const lib = cb.lib();
    return lib.version > 2 or (lib.version == 2 and lib.revision >= 13);
}

/// The suites a ClientHello offers, in its order.
pub const Offer = struct {
    list: [suites.len]Suite = undefined,
    count: usize = 0,

    pub fn slice(offer_: *const Offer) []const Suite {
        return offer_.list[0..offer_.count];
    }

    /// The suite of that number, if it was offered: a server may pick
    /// no other.
    pub fn find(offer_: *const Offer, id: u16) ?Suite {
        for (offer_.slice()) |suite| if (suite.id == id) return suite;
        return null;
    }
};

/// What this machine offers: TLS 1.3's suites, then TLS 1.2's, and in
/// each ChaCha20-Poly1305's first where crypto.library's AES is software
/// (CryptoEngines without CRYPTOENG_AES) - there it is the faster, and
/// takes the same time whatever the key - and last where AES is the
/// core's or an engine's. None of ChaCha's with a crypto.library before
/// 2.13.
pub fn offer(cb: *CryptoBase) Offer {
    const chacha = hasChaCha(cb);
    const chacha_first = chacha and cb.CryptoEngines() & crypto.CRYPTOENG_AES == 0;
    var result: Offer = .{};
    for ([_]bool{ false, true }) |tls12| {
        for ([_]bool{ chacha_first, !chacha_first }) |want_chacha| {
            for (suites) |suite| {
                if (suite.tls12 != tls12 or suite.chacha != want_chacha or (suite.chacha and !chacha)) continue;
                result.list[result.count] = suite;
                result.count += 1;
            }
        }
    }
    return result;
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

/// A direction's key and IV, its AEAD, and how many records it has
/// protected.
pub const TrafficKeys = struct {
    key: [32]u8 = @splat(0),
    key_length: u32 = 0,
    iv: [12]u8 = @splat(0),
    sequence: u64 = 0,
    /// ChaCha20-Poly1305 (or else AES-GCM).
    chacha: bool = false,
};

/// The key and IV a traffic secret stands for, sequence at zero.
pub fn trafficKeys(cb: *CryptoBase, suite: Suite, secret: []const u8) TrafficKeys {
    var keys: TrafficKeys = .{ .key_length = suite.key_length, .chacha = suite.chacha };
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

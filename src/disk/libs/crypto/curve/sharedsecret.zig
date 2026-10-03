// SPDX-License-Identifier: MIT
//! SharedSecret: the secret a private key shares with a peer's public
//! key.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _cipher = @import("../cipher/_cipher.zig");
const weierstrass = @import("../math/weierstrass.zig");
const montgomery = @import("../math/montgomery.zig");
const _signature = @import("../signature/_signature.zig");

/// Works out the secret one's own private key shares with the owner of
/// a public key: Diffie-Hellman on a curve.
///
/// SYNOPSIS:
/// ```zig
/// fn SharedSecret(cb: *CryptoBase, curve: u32, private_key: *const anyopaque, peer: *const Bytes, secret: *anyopaque) i32
/// ```
///
/// SINCE: 1.1. LVO -80.
///
/// INPUTS:
/// - `curve`: CURVE_X25519, CURVE_P256 or CURVE_P384.
/// - `private_key`: one's own, `privateLength(curve)` bytes, from
///   MakeKeyPair.
/// - `peer`: the other side's public key, as it came - 32 bytes for
///   X25519, an uncompressed point for a P-curve.
/// - `secret`: room for `secretLength(curve)` bytes.
///
/// RESULT:
/// CRYPTOERR_OK, with the secret written; CRYPTOERR_ALGORITHM for a
/// curve with no key agreement (CURVE_ED25519) or none at all;
/// CRYPTOERR_KEY for a public key of the wrong length, a point not on
/// the curve, a private key out of range, or a result that is no secret
/// (X25519's all zeroes, a P-curve's point at infinity) - `secret` is
/// then zeroes.
///
/// BEHAVIOR:
/// The secret is the private key times the peer's point: for X25519 its
/// u-coordinate (RFC 7748), for a P-curve its x-coordinate (SEC 1), each
/// as its standard writes it. A peer's point is checked to be on the
/// curve before anything is multiplied by it, which is what stops a key
/// from being drawn out of a reply to a point that is not.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The secret is the caller's: feed it to HkdfExtract, then overwrite it.
///
/// NOTES:
/// The work takes the same steps whatever the private key.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MakeKeyPair`, `HkdfExtract`
///
/// EXAMPLES:
/// ```zig
/// var secret: [32]u8 = undefined;
/// if (cb.SharedSecret(crypto.CURVE_X25519, &private_key, &crypto.Bytes.of(server_share), &secret) != crypto.CRYPTOERR_OK) return error.Handshake;
/// ```
pub fn SharedSecret(_: *CryptoBase, curve: u32, private_key: *const anyopaque, peer: *const Bytes, secret: *anyopaque) i32 {
    const private_bytes: [*]const u8 = @ptrCast(private_key);
    const out: [*]u8 = @ptrCast(secret);
    const peer_bytes = _signature.slice(peer);
    switch (curve) {
        crypto.CURVE_X25519 => {
            const result = out[0..32];
            @memset(result, 0);
            if (peer_bytes.len != 32) return crypto.CRYPTOERR_KEY;
            montgomery.x25519(result, private_bytes[0..32], peer_bytes[0..32]);
            var any: u8 = 0;
            for (result) |byte| any |= byte;
            return if (any == 0) crypto.CRYPTOERR_KEY else crypto.CRYPTOERR_OK;
        },
        crypto.CURVE_P256 => return pointSecret(weierstrass.P256, private_bytes, peer_bytes, out),
        crypto.CURVE_P384 => return pointSecret(weierstrass.P384, private_bytes, peer_bytes, out),
        else => return crypto.CRYPTOERR_ALGORITHM,
    }
}

fn pointSecret(comptime C: type, private_bytes: [*]const u8, peer_bytes: []const u8, out: [*]u8) i32 {
    const result = out[0..C.bytes];
    @memset(result, 0);
    const key = private_bytes[0..C.bytes];
    var plain: C.Scalar.Number = C.Scalar.zero;
    for (0..C.bytes) |index| plain[index / 4] |= @as(u32, key[C.bytes - 1 - index]) << @intCast(8 * (index % 4));
    const usable = C.Scalar.below(&plain) and !C.Scalar.isZeroPlain(&plain);
    _cipher.wipe(@as([*]u8, @ptrCast(&plain))[0..@sizeOf(C.Scalar.Number)]);
    if (!usable) return crypto.CRYPTOERR_KEY;
    const q = C.decode(peer_bytes) orelse return crypto.CRYPTOERR_KEY;
    const shared = C.multiply(&q, key);
    if (C.isInfinity(&shared)) return crypto.CRYPTOERR_KEY;
    var x: C.Fe = undefined;
    var y: C.Fe = undefined;
    C.affine(&shared, &x, &y);
    C.Field.toBytesBig(&x, result);
    return crypto.CRYPTOERR_OK;
}

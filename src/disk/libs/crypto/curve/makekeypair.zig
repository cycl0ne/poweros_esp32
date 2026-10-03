// SPDX-License-Identifier: MIT
//! MakeKeyPair: a fresh private key on a curve, and its public key.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const _base = @import("../crypto_base.zig");
const CryptoBase = _base.CryptoBase;
const _cipher = @import("../cipher/_cipher.zig");
const weierstrass = @import("../math/weierstrass.zig");
const montgomery = @import("../math/montgomery.zig");
const _signature = @import("../signature/_signature.zig");

/// Makes a key pair on a curve: a private key from the chip's random
/// number generator, and the public key that goes with it.
///
/// SYNOPSIS:
/// ```zig
/// fn MakeKeyPair(cb: *CryptoBase, curve: u32, private_key: *anyopaque, public_key: *anyopaque, public_length: *u32) i32
/// ```
///
/// SINCE: 1.1. LVO -76.
///
/// INPUTS:
/// - `curve`: CURVE_X25519, CURVE_P256, CURVE_P384 or CURVE_ED25519.
/// - `private_key`: room for `privateLength(curve)` bytes.
/// - `public_key`: room for `publicLength(curve)` bytes
///   (CURVE_PUBLIC_MAX takes any).
/// - `public_length`: where the public key's length goes.
///
/// RESULT:
/// CRYPTOERR_OK, with both keys written; CRYPTOERR_ALGORITHM for a curve
/// there is not, with nothing written.
///
/// BEHAVIOR:
/// Each key is in the form its standard gives it (`sdk.crypto`'s
/// CURVE_*). X25519's private key is 32 random bytes, clamped when it is
/// used; a P-curve's is a random number from 1 to the order less one,
/// drawn again until it is one; Ed25519's is a random seed, from which
/// the signing key is derived by SHA-512 as RFC 8032 has it. The public
/// key is the private key times the curve's base point, worked out in the
/// same steps for every private key.
///
/// CONTEXT:
/// - Waits: for the SHA engine (Ed25519 only), while another task has it.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The private key is the caller's, to use and then to overwrite; the
/// library keeps no copy.
///
/// NOTES:
/// A key for one handshake is made, used once with SharedSecret and
/// wiped: what TLS 1.3 calls an ephemeral key. A P-256 key pair takes
/// one scalar multiplication, X25519 one, Ed25519 one and a hash.
///
/// BUGS:
/// The keys are as good as `RandomBytes`, which is only random while the
/// chip's generator has a noise source running.
///
/// SEE ALSO:
/// `SharedSecret`, `Sign`, `RandomBytes`
///
/// EXAMPLES:
/// ```zig
/// var private_key: [32]u8 = undefined;
/// var public_key: [crypto.CURVE_PUBLIC_MAX]u8 = undefined;
/// var length: u32 = 0;
/// _ = cb.MakeKeyPair(crypto.CURVE_X25519, &private_key, &public_key, &length);
/// ```
pub fn MakeKeyPair(cb: *CryptoBase, curve: u32, private_key: *anyopaque, public_key: *anyopaque, public_length: *u32) i32 {
    const private_bytes: [*]u8 = @ptrCast(private_key);
    const public_bytes: [*]u8 = @ptrCast(public_key);
    const lib = _base.iface(cb);
    switch (curve) {
        crypto.CURVE_X25519 => {
            lib.RandomBytes(private_bytes, 32);
            montgomery.x25519(public_bytes[0..32], private_bytes[0..32], &montgomery.base_point);
        },
        crypto.CURVE_P256 => pointKeys(weierstrass.P256, cb, private_bytes, public_bytes),
        crypto.CURVE_P384 => pointKeys(weierstrass.P384, cb, private_bytes, public_bytes),
        crypto.CURVE_ED25519 => {
            lib.RandomBytes(private_bytes, 32);
            var scalar: [32]u8 = undefined;
            var prefix: [32]u8 = undefined;
            _signature.ed25519Expand(cb, private_bytes[0..32], &scalar, &prefix, public_bytes[0..32]);
            _cipher.wipe(&scalar);
            _cipher.wipe(&prefix);
        },
        else => return crypto.CRYPTOERR_ALGORITHM,
    }
    public_length.* = crypto.publicLength(curve);
    return crypto.CRYPTOERR_OK;
}

/// A random number from 1 to the order less one, and its multiple of the
/// generator.
fn pointKeys(comptime C: type, cb: *CryptoBase, private_bytes: [*]u8, public_bytes: [*]u8) void {
    const lib = _base.iface(cb);
    const key = private_bytes[0..C.bytes];
    while (true) {
        lib.RandomBytes(key, C.bytes);
        var plain: C.Scalar.Number = C.Scalar.zero;
        for (0..C.bytes) |index| plain[index / 4] |= @as(u32, key[C.bytes - 1 - index]) << @intCast(8 * (index % 4));
        const usable = C.Scalar.below(&plain) and !C.Scalar.isZeroPlain(&plain);
        _cipher.wipe(@as([*]u8, @ptrCast(&plain))[0..@sizeOf(C.Scalar.Number)]);
        if (usable) break;
    }
    C.encode(&C.multiply(&C.generator, key), public_bytes[0..C.point_bytes]);
}

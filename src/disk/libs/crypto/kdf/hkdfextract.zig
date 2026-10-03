// SPDX-License-Identifier: MIT
//! HkdfExtract: HKDF's first half, a pseudorandom key from keying
//! material.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const _base = @import("../crypto_base.zig");
const CryptoBase = _base.CryptoBase;

/// Extracts a pseudorandom key from input keying material and a salt
/// (HKDF-Extract, RFC 5869).
///
/// SYNOPSIS:
/// ```zig
/// fn HkdfExtract(cb: *CryptoBase, algorithm: u32, salt: *const Bytes, material: *const Bytes, prk: *anyopaque) i32
/// ```
///
/// SINCE: 1.1. LVO -68.
///
/// INPUTS:
/// - `algorithm`: the hash, HASH_SHA1 to HASH_SHA512.
/// - `salt`: any length, none at all included.
/// - `material`: the input keying material - a shared secret, say.
/// - `prk`: room for the digest's length (`digestLength(algorithm)`).
///
/// RESULT:
/// CRYPTOERR_OK, with the key in `prk`; CRYPTOERR_ALGORITHM for a hash
/// there is not, with nothing written.
///
/// BEHAVIOR:
/// The key is HMAC(salt, material). A salt of no bytes is a salt of the
/// digest's length in zeroes, as the RFC has it - for HMAC the two are
/// the same key.
///
/// CONTEXT:
/// - Waits: for the SHA engine, while another task has it.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is kept; the HMAC context used is wiped by FinishHmac.
///
/// NOTES:
/// TLS 1.3's key schedule is this and HkdfExpand, the latter with the
/// protocol's own labels in `info`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `HkdfExpand`, `InitHmac`
///
/// EXAMPLES:
/// ```zig
/// var prk: [32]u8 = undefined;
/// _ = cb.HkdfExtract(crypto.HASH_SHA256, &crypto.Bytes.of(&salt), &crypto.Bytes.of(&secret), &prk);
/// ```
pub fn HkdfExtract(cb: *CryptoBase, algorithm: u32, salt: *const Bytes, material: *const Bytes, prk: *anyopaque) i32 {
    if (crypto.digestLength(algorithm) == 0) return crypto.CRYPTOERR_ALGORITHM;
    const lib = _base.iface(cb);
    var context: crypto.HmacContext = .{};
    const result = lib.InitHmac(&context, algorithm, salt.bytes, salt.length);
    if (result != crypto.CRYPTOERR_OK) return result;
    lib.UpdateHmac(&context, material.bytes, material.length);
    _ = lib.FinishHmac(&context, prk);
    return crypto.CRYPTOERR_OK;
}

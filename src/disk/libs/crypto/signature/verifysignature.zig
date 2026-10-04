// SPDX-License-Identifier: MIT
//! VerifySignature: whether a signature is a public key's over a digest.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const PublicKey = crypto.PublicKey;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const weierstrass = @import("../math/weierstrass.zig");
const _signature = @import("_signature.zig");

/// Checks a signature with a public key: RSA in both its encodings,
/// ECDSA on P-256 and P-384, and Ed25519.
///
/// SYNOPSIS:
/// ```zig
/// fn VerifySignature(cb: *CryptoBase, algorithm: u32, key: *const PublicKey, digest: *const Bytes, signature: *const Bytes) i32
/// ```
///
/// SINCE: 1.1. LVO -84.
///
/// INPUTS:
/// - `algorithm`: a SIG_* - SIG_RSA_PKCS1_SHA256/384/512,
///   SIG_RSA_PSS_SHA256/384/512, SIG_ECDSA_P256, SIG_ECDSA_P384,
///   SIG_ED25519.
/// - `key`: for RSA its `modulus` and `exponent`, for the curves its
///   `point` (an uncompressed point, or Ed25519's 32 bytes).
/// - `digest`: the hash of what was signed, made by the caller - of the
///   algorithm's hash for RSA, of any hash for ECDSA. For SIG_ED25519 it
///   is the whole message, which Ed25519 hashes itself.
/// - `signature`: as it came - RSA's as long as its modulus, ECDSA's
///   DER-encoded, Ed25519's 64 bytes.
///
/// RESULT:
/// CRYPTOERR_OK when the signature is good. CRYPTOERR_SIGNATURE when it
/// is not, or is not a signature at all (the wrong length, broken DER, a
/// number out of range). CRYPTOERR_KEY for a key that is none - an even
/// or empty modulus, a point not on the curve. CRYPTOERR_LENGTH for an
/// RSA digest whose length is not its hash's. CRYPTOERR_ALGORITHM for an
/// algorithm there is not.
///
/// BEHAVIOR:
/// RSA raises the signature to the exponent with ModExp, through the
/// jump table, and checks the encoding: PKCS #1 v1.5's by building the
/// one the digest must have and comparing every byte; PSS's by undoing
/// the mask with MGF1 and checking the hash over its salt, of any
/// length. ECDSA takes the DER strictly (positive, minimal, nothing
/// after it), holds r and s to 1 to n - 1, cuts a digest longer than the
/// curve to the curve's size, and compares the x of u1 G + u2 Q with r
/// modulo n. Ed25519 refuses an S not below the group order, and checks
/// S B = R + k A with k = SHA-512(R, A, message).
///
/// SHA-1 is offered by none of them: it no longer stands for anything
/// signed.
///
/// CONTEXT:
/// - Waits: for the RSA or SHA engine, while another task has it.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// Everything here is public, so it is not made to take the same time
/// for every input: a bad signature fails as soon as it is seen to be
/// bad. An RSA-2048 check is one short exponentiation on the engine; an
/// ECDSA check two scalar multiplications in software.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Sign`, `ModExp`, `InitHash`
///
/// EXAMPLES:
/// ```zig
/// const key: crypto.PublicKey = .{ .point = crypto.Bytes.of(&server_point) };
/// const good = cb.VerifySignature(crypto.SIG_ECDSA_P256, &key, &crypto.Bytes.of(&digest), &crypto.Bytes.of(der)) == crypto.CRYPTOERR_OK;
/// ```
pub fn VerifySignature(cb: *CryptoBase, algorithm: u32, key: *const PublicKey, digest: *const Bytes, signature: *const Bytes) i32 {
    const signed = _signature.slice(digest);
    return switch (algorithm) {
        crypto.SIG_RSA_PKCS1_SHA256 => _signature.verifyPkcs1(cb, crypto.HASH_SHA256, key, signed, signature),
        crypto.SIG_RSA_PKCS1_SHA384 => _signature.verifyPkcs1(cb, crypto.HASH_SHA384, key, signed, signature),
        crypto.SIG_RSA_PKCS1_SHA512 => _signature.verifyPkcs1(cb, crypto.HASH_SHA512, key, signed, signature),
        crypto.SIG_RSA_PSS_SHA256 => _signature.verifyPss(cb, crypto.HASH_SHA256, key, signed, signature),
        crypto.SIG_RSA_PSS_SHA384 => _signature.verifyPss(cb, crypto.HASH_SHA384, key, signed, signature),
        crypto.SIG_RSA_PSS_SHA512 => _signature.verifyPss(cb, crypto.HASH_SHA512, key, signed, signature),
        crypto.SIG_ECDSA_P256 => _signature.verifyEcdsa(weierstrass.P256, key, signed, signature),
        crypto.SIG_ECDSA_P384 => _signature.verifyEcdsa(weierstrass.P384, key, signed, signature),
        crypto.SIG_ED25519 => _signature.ed25519Verify(cb, key, signed, signature),
        else => crypto.CRYPTOERR_ALGORITHM,
    };
}

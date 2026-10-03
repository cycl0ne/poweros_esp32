// SPDX-License-Identifier: MIT
//! Sign: a message signed with a private key.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _signature = @import("_signature.zig");

/// Signs a message with a private key: Ed25519.
///
/// SYNOPSIS:
/// ```zig
/// fn Sign(cb: *CryptoBase, algorithm: u32, private_key: *const anyopaque, message: *const Bytes, signature: *anyopaque) i32
/// ```
///
/// SINCE: 1.1. LVO -88.
///
/// INPUTS:
/// - `algorithm`: SIG_ED25519.
/// - `private_key`: the 32-byte seed, from MakeKeyPair(CURVE_ED25519).
/// - `message`: the whole message, any length.
/// - `signature`: room for SIGNATURE_ED25519 (64) bytes.
///
/// RESULT:
/// CRYPTOERR_OK, with the signature written; CRYPTOERR_ALGORITHM for any
/// other algorithm, with nothing written.
///
/// BEHAVIOR:
/// RFC 8032, 5.1.6: the seed hashed with SHA-512 into the secret scalar
/// and a prefix, the nonce r from the prefix and the message - so the
/// same message signed twice gives the same signature, and no random
/// number can give the key away - and S = r + k a modulo the group
/// order. The multiplications take the same steps whatever the key.
///
/// CONTEXT:
/// - Waits: for the SHA engine, while another task has it.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The key stays the caller's; what was derived from it is wiped before
/// the call returns.
///
/// NOTES:
/// The message is hashed twice, so it must be in memory whole.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `VerifySignature`, `MakeKeyPair`
///
/// EXAMPLES:
/// ```zig
/// var signature: [crypto.SIGNATURE_ED25519]u8 = undefined;
/// _ = cb.Sign(crypto.SIG_ED25519, &seed, &crypto.Bytes.of(message), &signature);
/// ```
pub fn Sign(cb: *CryptoBase, algorithm: u32, private_key: *const anyopaque, message: *const Bytes, signature: *anyopaque) i32 {
    if (algorithm != crypto.SIG_ED25519) return crypto.CRYPTOERR_ALGORITHM;
    const seed: *const [32]u8 = @ptrCast(private_key);
    const out: *[64]u8 = @ptrCast(signature);
    _signature.ed25519Sign(cb, seed, _signature.slice(message), out);
    return crypto.CRYPTOERR_OK;
}

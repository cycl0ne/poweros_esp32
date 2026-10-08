// SPDX-License-Identifier: MIT
//! Decapsulate: the secret a ciphertext carries, taken out with the
//! private key.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _signature = @import("../signature/_signature.zig");
const _kem = @import("_kem.zig");

/// Takes the secret out of a ciphertext Encapsulate made for one's own
/// public key.
///
/// SYNOPSIS:
/// ```zig
/// fn Decapsulate(cb: *CryptoBase, kem: u32, private_key: *const anyopaque, ciphertext: *const Bytes, secret: *anyopaque) i32
/// ```
///
/// SINCE: 1.2. LVO -100.
///
/// INPUTS:
/// - `kem`: KEM_MLKEM768.
/// - `private_key`: one's own, MLKEM768_PRIVATE bytes, from KemKeyPair.
/// - `ciphertext`: as it came: MLKEM768_CIPHERTEXT bytes.
/// - `secret`: room for KEM_SECRET bytes (32).
///
/// RESULT:
/// CRYPTOERR_OK, with the secret written; CRYPTOERR_ALGORITHM for another
/// `kem`; CRYPTOERR_LENGTH for a ciphertext of the wrong length;
/// CRYPTOERR_KEY for a private key whose stored hash is not that of its
/// public key - nothing written for these.
///
/// BEHAVIOR:
/// ML-KEM-768 (FIPS 203), ML-KEM.Decaps_internal: the message decrypted,
/// encrypted again, and the secret it gives answered when the ciphertext
/// is the same; when it is not - a ciphertext that was tampered with - a
/// secret from z and the ciphertext instead, which the other side does
/// not have (implicit rejection). Which of the two it was takes the same
/// time either way, and is not told: a wrong ciphertext shows only in
/// what the secret then fails to open.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do; it takes about 5 KiB of the caller's stack.
///
/// OWNERSHIP:
/// The secret is the caller's: use it, then overwrite it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `KemKeyPair`, `Encapsulate`
///
/// EXAMPLES:
/// ```zig
/// var secret: [crypto.KEM_SECRET]u8 = undefined;
/// _ = cb.Decapsulate(crypto.KEM_MLKEM768, &private_key, &crypto.Bytes.of(ciphertext), &secret);
/// ```
pub fn Decapsulate(_: *CryptoBase, kem: u32, private_key: *const anyopaque, ciphertext: *const Bytes, secret: *anyopaque) i32 {
    if (kem != crypto.KEM_MLKEM768) return crypto.CRYPTOERR_ALGORITHM;
    const text = _signature.slice(ciphertext);
    if (text.len != _kem.ciphertext_bytes) return crypto.CRYPTOERR_LENGTH;
    const dk: *const [_kem.private_bytes]u8 = @ptrCast(private_key);
    if (!_kem.privateValid(dk)) return crypto.CRYPTOERR_KEY;
    _kem.decapsulate(dk, text[0.._kem.ciphertext_bytes], @ptrCast(secret));
    return crypto.CRYPTOERR_OK;
}

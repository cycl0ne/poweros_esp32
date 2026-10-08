// SPDX-License-Identifier: MIT
//! Encapsulate: a new secret, and the ciphertext that carries it to the
//! owner of a public key.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _base = @import("../crypto_base.zig");
const _cipher = @import("../cipher/_cipher.zig");
const _signature = @import("../signature/_signature.zig");
const _kem = @import("_kem.zig");

/// Makes a secret for the owner of a public key, and the ciphertext that
/// gives it to them: they take it out with Decapsulate, and nobody else
/// can.
///
/// SYNOPSIS:
/// ```zig
/// fn Encapsulate(cb: *CryptoBase, kem: u32, public_key: *const Bytes, ciphertext: *anyopaque, secret: *anyopaque) i32
/// ```
///
/// SINCE: 1.2. LVO -96.
///
/// INPUTS:
/// - `kem`: KEM_MLKEM768.
/// - `public_key`: the owner's, as it came: MLKEM768_PUBLIC bytes.
/// - `ciphertext`: room for MLKEM768_CIPHERTEXT bytes (1088).
/// - `secret`: room for KEM_SECRET bytes (32).
///
/// RESULT:
/// CRYPTOERR_OK, with both written; CRYPTOERR_ALGORITHM for another
/// `kem`; CRYPTOERR_KEY for a public key of the wrong length or one that
/// is no key - a coefficient of its encoding not below q - with nothing
/// written.
///
/// BEHAVIOR:
/// ML-KEM-768 (FIPS 203): the key is checked (7.2), the message m comes
/// from RandomBytes, and the secret and the ciphertext from it as
/// ML-KEM.Encaps_internal makes them.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do; it takes about 4 KiB of the caller's stack.
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
/// `KemKeyPair`, `Decapsulate`
///
/// EXAMPLES:
/// ```zig
/// var ciphertext: [crypto.MLKEM768_CIPHERTEXT]u8 = undefined;
/// var secret: [crypto.KEM_SECRET]u8 = undefined;
/// if (cb.Encapsulate(crypto.KEM_MLKEM768, &crypto.Bytes.of(their_key), &ciphertext, &secret) != crypto.CRYPTOERR_OK) return error.BadKey;
/// ```
pub fn Encapsulate(cb: *CryptoBase, kem: u32, public_key: *const Bytes, ciphertext: *anyopaque, secret: *anyopaque) i32 {
    if (kem != crypto.KEM_MLKEM768) return crypto.CRYPTOERR_ALGORITHM;
    const key = _signature.slice(public_key);
    if (key.len != _kem.public_bytes) return crypto.CRYPTOERR_KEY;
    const ek: *const [_kem.public_bytes]u8 = key[0.._kem.public_bytes];
    if (!_kem.keyValid(ek)) return crypto.CRYPTOERR_KEY;
    var m: [32]u8 = undefined;
    _base.iface(cb).RandomBytes(&m, m.len);
    _kem.encapsulate(ek, &m, @ptrCast(ciphertext), @ptrCast(secret));
    _cipher.wipe(&m);
    return crypto.CRYPTOERR_OK;
}

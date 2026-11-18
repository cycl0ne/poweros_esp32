// SPDX-License-Identifier: MIT
//! OpenChaChaPoly: a message's ChaCha20-Poly1305 tag checked, and the
//! message decrypted.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const AeadMessage = crypto.AeadMessage;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _chacha = @import("_chacha.zig");

/// Checks a message's ChaCha20-Poly1305 tag and, if it is right,
/// decrypts it.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenChaChaPoly(cb: *CryptoBase, message: *const AeadMessage) i32
/// ```
///
/// SINCE: 2.13. LVO -128.
///
/// INPUTS:
/// - `message`: the key (32 bytes) and the nonce (12 bytes) it was
///   sealed with, the header (`aad`, may be none), the ciphertext
///   (`input`, `length` bytes, may be none), where the plaintext goes
///   (`output`, `length` bytes; may be `input` itself) and the 16-byte
///   tag that came with it.
///
/// RESULT:
/// CRYPTOERR_OK; CRYPTOERR_TAG when the tag does not match the key,
/// nonce, header and ciphertext; CRYPTOERR_KEY for a key of another
/// length; CRYPTOERR_LENGTH for a nonce of another length, or a null
/// buffer with a length that is not 0.
///
/// BEHAVIOR:
/// The tag is worked out over the header and the ciphertext and compared
/// with the one given, every byte of it whatever the first difference.
/// Only a message whose tag matches is decrypted: on CRYPTOERR_TAG the
/// output has not been written, so nothing forged is ever there to be
/// used by mistake.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated; the message stays the caller's.
///
/// NOTES:
/// As in SealChaChaPoly: software on every chip, four blocks at a time
/// where the core has 128-bit vectors.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SealChaChaPoly`, `OpenGcm`
///
/// EXAMPLES:
/// ```zig
/// switch (cb.OpenChaChaPoly(&message)) {
///     crypto.CRYPTOERR_OK => {},
///     crypto.CRYPTOERR_TAG => return error.Forged,
///     else => return error.Open,
/// }
/// ```
pub fn OpenChaChaPoly(_: *CryptoBase, message: *const AeadMessage) i32 {
    return _chacha.run(message, false);
}

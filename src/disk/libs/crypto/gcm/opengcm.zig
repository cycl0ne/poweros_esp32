// SPDX-License-Identifier: MIT
//! OpenGcm: a message's AES-GCM tag checked, and the message decrypted.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const GcmMessage = crypto.GcmMessage;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _gcm = @import("_gcm.zig");

/// Checks a message's AES-GCM tag and, if it is right, decrypts it.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenGcm(cb: *CryptoBase, message: *const GcmMessage) i32
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `message`: the key and the nonce it was sealed with, the header
///   (`aad`, may be none), the ciphertext (`input`, `length` bytes, may
///   be none), where the plaintext goes (`output`, `length` bytes; may be
///   `input` itself) and the 16-byte tag that came with it.
///
/// RESULT:
/// CRYPTOERR_OK; CRYPTOERR_TAG when the tag does not match the key,
/// nonce, header and ciphertext; CRYPTOERR_KEY for another key length;
/// CRYPTOERR_LENGTH for a nonce of no bytes, or a null buffer with a
/// length that is not 0.
///
/// BEHAVIOR:
/// The tag is worked out over the header and the ciphertext and compared
/// with the one given, every byte of it whatever the first difference.
/// Only a message whose tag matches is decrypted: on CRYPTOERR_TAG the
/// output has not been written, so nothing forged is ever there to be
/// used by mistake.
///
/// CONTEXT:
/// - Waits: yes, for the AES engine while another task has it; the
///   engine is held for the whole message.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated; the message stays the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// GHASH runs in software, as in SealGcm.
///
/// SEE ALSO:
/// `SealGcm`
///
/// EXAMPLES:
/// ```zig
/// switch (cb.OpenGcm(&message)) {
///     crypto.CRYPTOERR_OK => {},
///     crypto.CRYPTOERR_TAG => return error.Forged,
///     else => return error.Open,
/// }
/// ```
pub fn OpenGcm(cb: *CryptoBase, message: *const GcmMessage) i32 {
    return _gcm.run(cb, message, false);
}

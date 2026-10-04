// SPDX-License-Identifier: MIT
//! SealGcm: a message encrypted and authenticated with AES-GCM.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const GcmMessage = crypto.GcmMessage;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _gcm = @import("_gcm.zig");

/// Encrypts a message with AES-GCM and writes its tag.
///
/// SYNOPSIS:
/// ```zig
/// fn SealGcm(cb: *CryptoBase, message: *const GcmMessage) i32
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `message`: the key (16 or 32 bytes), the nonce (12 bytes is what
///   GCM is made for; any length but 0 is taken), the header to
///   authenticate (`aad`, may be none), the plaintext (`input`,
///   `length` bytes, may be none), where the ciphertext goes (`output`,
///   `length` bytes; may be `input` itself) and where the 16-byte tag
///   goes.
///
/// RESULT:
/// CRYPTOERR_OK; CRYPTOERR_KEY for another key length; CRYPTOERR_LENGTH
/// for a nonce of no bytes, or a null buffer with a length that is not
/// 0. Nothing is written on an error.
///
/// BEHAVIOR:
/// The ciphertext is as long as the plaintext; the tag authenticates
/// the header and the ciphertext together, so neither can be changed, cut
/// or moved without OpenGcm noticing. The whole message is one call:
/// GCM's tag is over all of it.
///
/// CONTEXT:
/// - Waits: yes, for the AES engine while another task has it; the
///   engine is held for the whole message.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated; the message stays the caller's.
///
/// NOTES:
/// A nonce is never used twice with the same key: two messages under one
/// nonce give away the exclusive-or of their plaintexts and let the tags
/// be forged. A counter kept for the key, or 12 bytes from RandomBytes,
/// is how a nonce is made.
///
/// BUGS:
/// GHASH runs in software, bit by bit, and is slower than the engine:
/// it, not AES, sets the pace of a long message.
///
/// SEE ALSO:
/// `OpenGcm`, `InitCipher`, `RandomBytes`
///
/// EXAMPLES:
/// ```zig
/// var tag: [crypto.GCM_TAG]u8 = undefined;
/// const message: crypto.GcmMessage = .{
///     .key = &key, .key_length = 16, .nonce = &nonce, .nonce_length = 12,
///     .aad = &header, .aad_length = header.len,
///     .input = record.ptr, .output = record.ptr, .length = record.len,
///     .tag = &tag,
/// };
/// if (cb.SealGcm(&message) != crypto.CRYPTOERR_OK) return error.Seal;
/// ```
pub fn SealGcm(cb: *CryptoBase, message: *const GcmMessage) i32 {
    return _gcm.run(cb, message, true);
}

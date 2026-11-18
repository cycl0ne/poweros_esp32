// SPDX-License-Identifier: MIT
//! SealChaChaPoly: a message encrypted and authenticated with
//! ChaCha20-Poly1305.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const AeadMessage = crypto.AeadMessage;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _chacha = @import("_chacha.zig");

/// Encrypts a message with ChaCha20-Poly1305 (RFC 8439) and writes its
/// tag.
///
/// SYNOPSIS:
/// ```zig
/// fn SealChaChaPoly(cb: *CryptoBase, message: *const AeadMessage) i32
/// ```
///
/// SINCE: 2.13. LVO -124.
///
/// INPUTS:
/// - `message`: the key (CHACHA_KEY, 32 bytes), the nonce (CHACHA_NONCE,
///   12 bytes), the header to authenticate (`aad`, may be none), the
///   plaintext (`input`, `length` bytes, may be none), where the
///   ciphertext goes (`output`, `length` bytes; may be `input` itself)
///   and where the 16-byte tag goes. The same message as SealGcm's.
///
/// RESULT:
/// CRYPTOERR_OK; CRYPTOERR_KEY for a key of another length;
/// CRYPTOERR_LENGTH for a nonce of another length, or a null buffer with
/// a length that is not 0. Nothing is written on an error.
///
/// BEHAVIOR:
/// RFC 8439's AEAD: Poly1305's one-time key is the first 32 bytes of
/// ChaCha20's block 0 under the key and nonce, the plaintext is
/// encrypted from block 1 on, and the tag is Poly1305 over the header and
/// the ciphertext, each padded with zeroes to 16 bytes, and their lengths.
/// So neither the header nor the ciphertext can be changed, cut or moved
/// without OpenChaChaPoly noticing. The whole message is one call. It is
/// the AEAD of TLS's TLS_CHACHA20_POLY1305_SHA256 and of the TLS 1.2
/// suites ending in _WITH_CHACHA20_POLY1305_SHA256.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated; the message stays the caller's. What the call
/// made of the key on its stack is cleared before it returns.
///
/// NOTES:
/// A nonce is never used twice with the same key: two messages under one
/// nonce give away the exclusive-or of their plaintexts and the
/// one-time key, with which tags can be forged. A counter kept for the
/// key, as TLS's sequence number is, is how a nonce is made.
///
/// Software on every chip, taking the same steps whatever the key and
/// the data. Four blocks at a time where the core has 128-bit vectors -
/// NEON on the AArch64 machines, SSE on x86-64 - and one at a time on
/// the others. Where CryptoEngines has CRYPTOENG_AES clear it is faster
/// than AES-GCM.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenChaChaPoly`, `SealGcm`, `CryptoEngines`, `Poly1305Pieces`
///
/// EXAMPLES:
/// ```zig
/// var tag: [crypto.POLY1305_TAG]u8 = undefined;
/// const message: crypto.AeadMessage = .{
///     .key = &key, .key_length = crypto.CHACHA_KEY,
///     .nonce = &nonce, .nonce_length = crypto.CHACHA_NONCE,
///     .aad = &header, .aad_length = header.len,
///     .input = record.ptr, .output = record.ptr, .length = record.len,
///     .tag = &tag,
/// };
/// if (cb.SealChaChaPoly(&message) != crypto.CRYPTOERR_OK) return error.Seal;
/// ```
pub fn SealChaChaPoly(_: *CryptoBase, message: *const AeadMessage) i32 {
    return _chacha.run(message, true);
}

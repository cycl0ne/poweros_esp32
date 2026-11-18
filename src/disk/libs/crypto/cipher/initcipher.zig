// SPDX-License-Identifier: MIT
//! InitCipher: a cipher context set up with its mode, key and IV.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const CipherContext = crypto.CipherContext;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _cipher = @import("_cipher.zig");

/// Sets up a context for AES in one mode, or for ChaCha20, with a key
/// and an IV.
///
/// SYNOPSIS:
/// ```zig
/// fn InitCipher(cb: *CryptoBase, context: *CipherContext, mode: u32, key: *const anyopaque, key_length: u32, iv: ?*const anyopaque) i32
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `context`: the caller's, made with `.{}` so that its `size` is
///   right; whatever it held before is dropped.
/// - `mode`: CIPHER_AES_ECB, CIPHER_AES_CBC or CIPHER_AES_CTR, with
///   CIPHERF_DECRYPT or-ed in to decrypt; or CIPHER_CHACHA20 (since
///   2.13).
/// - `key`: `key_length` bytes.
/// - `key_length`: 16 (AES-128) or 32 (AES-256); 32 for ChaCha20.
/// - `iv`: 16 bytes - CBC's IV, CTR's first counter block, ChaCha20's
///   block counter (4 bytes, little-endian) and nonce (12 bytes). Not
///   read for ECB, which may pass null.
///
/// RESULT:
/// CRYPTOERR_OK; CRYPTOERR_ALGORITHM for a mode or a flag there is not;
/// CRYPTOERR_KEY for another key length; CRYPTOERR_LENGTH for CBC or CTR
/// without an IV. On an error the context is left empty and UpdateCipher
/// refuses it. CRYPTOERR_CONTEXT for a context whose `size` is less than
/// `@sizeOf(CipherContext)`, which is not written to at all.
///
/// BEHAVIOR:
/// The key and the IV are copied into the context, which from here on
/// is all the cipher is: UpdateCipher takes the data in any number of
/// calls. A CBC context goes one way only - it encrypts, or with
/// CIPHERF_DECRYPT it decrypts. CTR and ChaCha20 do both alike and ignore
/// the flag.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The context holds a copy of the key: the caller
/// clears it when it is done, as it would the key.
///
/// NOTES:
/// A CTR counter block, or a ChaCha20 nonce, must never be used twice
/// with the same key, and
/// ECB shows equal plaintext blocks as equal ciphertext blocks; ECB is
/// here to build other modes on, not to encrypt data with.
///
/// BUGS:
/// AES-192 is not there: the engine takes 128- and 256-bit keys. ChaCha20
/// takes no 128-bit key, which RFC 8439 does not have either.
///
/// SEE ALSO:
/// `UpdateCipher`, `SealGcm`
///
/// EXAMPLES:
/// ```zig
/// var context: crypto.CipherContext = .{};
/// if (cb.InitCipher(&context, crypto.CIPHER_AES_CBC | crypto.CIPHERF_DECRYPT, &key, 32, &iv) != crypto.CRYPTOERR_OK) return;
/// defer context = .{};
/// _ = cb.UpdateCipher(&context, data.ptr, data.ptr, data.len);
/// ```
pub fn InitCipher(_: *CryptoBase, context: *CipherContext, mode: u32, key: *const anyopaque, key_length: u32, iv: ?*const anyopaque) i32 {
    if (context.size < @sizeOf(CipherContext)) return crypto.CRYPTOERR_CONTEXT;
    const size = context.size;
    context.* = .{ .size = size };
    const cipher = mode & ~crypto.CIPHERF_DECRYPT;
    if (cipher != crypto.CIPHER_AES_ECB and cipher != crypto.CIPHER_AES_CBC and cipher != crypto.CIPHER_AES_CTR and cipher != crypto.CIPHER_CHACHA20) {
        return crypto.CRYPTOERR_ALGORITHM;
    }
    if (if (cipher == crypto.CIPHER_CHACHA20) key_length != crypto.CHACHA_KEY else !_cipher.keyLength(key_length)) return crypto.CRYPTOERR_KEY;
    if (cipher != crypto.CIPHER_AES_ECB) {
        const bytes: [*]const u8 = @ptrCast(iv orelse return crypto.CRYPTOERR_LENGTH);
        for (&context.chain, 0..) |*byte, index| byte.* = bytes[index];
    }
    const key_bytes: [*]const u8 = @ptrCast(key);
    for (0..key_length) |index| context.key[index] = key_bytes[index];
    context.key_length = key_length;
    context.mode = mode;
    // ChaCha20 counts the bytes of its block under way.
    if (cipher == crypto.CIPHER_CHACHA20) context.stream_used = 0;
    return crypto.CRYPTOERR_OK;
}

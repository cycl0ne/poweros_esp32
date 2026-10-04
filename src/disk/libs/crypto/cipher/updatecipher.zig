// SPDX-License-Identifier: MIT
//! UpdateCipher: data through a cipher.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const CipherContext = crypto.CipherContext;
const AES_BLOCK = crypto.AES_BLOCK;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _cipher = @import("_cipher.zig");
const aes = @import("../engine/aes.zig");

/// Encrypts or decrypts data with the context's cipher.
///
/// SYNOPSIS:
/// ```zig
/// fn UpdateCipher(cb: *CryptoBase, context: *CipherContext, input: ?*const anyopaque, output: ?*anyopaque, length: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `context`: set up by InitCipher.
/// - `input`: `length` bytes; may be null when `length` is 0.
/// - `output`: room for `length` bytes. It may be `input` itself, for
///   the data in place; it may not overlap it any other way.
/// - `length`: ECB and CBC: a multiple of 16. CTR: any.
///
/// RESULT:
/// CRYPTOERR_OK; CRYPTOERR_ALGORITHM for a context InitCipher did not set
/// up; CRYPTOERR_LENGTH for ECB or CBC data that is not whole blocks, or
/// a null buffer. Nothing is written on an error.
///
/// BEHAVIOR:
/// The data continues from where the last call left off: a CBC chain
/// runs on from the last block, a CTR counter from the last counter
/// block, and a CTR call that ended inside a block starts the next with
/// the rest of that block's key stream. So a message may be given in any
/// number of pieces, and comes out as one call with all of it would.
///
/// CONTEXT:
/// - Waits: yes, for the AES engine while another task has it.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// CBC does not pad: a message that is not whole blocks is padded by the
/// caller, as its format says (PKCS #7, TLS).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitCipher`, `SealGcm`, `OpenGcm`
///
/// EXAMPLES:
/// ```zig
/// if (cb.UpdateCipher(&context, packet.ptr, packet.ptr, packet.len) != crypto.CRYPTOERR_OK) return error.Cipher;
/// ```
pub fn UpdateCipher(cb: *CryptoBase, context: *CipherContext, input: ?*const anyopaque, output: ?*anyopaque, length: u32) i32 {
    const cipher = context.mode & ~crypto.CIPHERF_DECRYPT;
    const decrypt = context.mode & crypto.CIPHERF_DECRYPT != 0;
    if (!_cipher.keyLength(context.key_length)) return crypto.CRYPTOERR_ALGORITHM;
    if (cipher != crypto.CIPHER_AES_CTR and length % AES_BLOCK != 0) return crypto.CRYPTOERR_LENGTH;
    if (length == 0) return crypto.CRYPTOERR_OK;
    const from: [*]const u8 = @ptrCast(input orelse return crypto.CRYPTOERR_LENGTH);
    const to: [*]u8 = @ptrCast(output orelse return crypto.CRYPTOERR_LENGTH);
    // CTR encrypts its counter blocks whichever way the data goes.
    var session = aes.begin(cb, &context.key, context.key_length, decrypt and cipher != crypto.CIPHER_AES_CTR);
    defer session.end();
    var at: u32 = 0;
    switch (cipher) {
        crypto.CIPHER_AES_ECB => while (at < length) : (at += AES_BLOCK) {
            var block: [AES_BLOCK]u8 = from[at..][0..AES_BLOCK].*;
            session.block(&block, &block);
            to[at..][0..AES_BLOCK].* = block;
        },
        crypto.CIPHER_AES_CBC => while (at < length) : (at += AES_BLOCK) {
            var block: [AES_BLOCK]u8 = from[at..][0..AES_BLOCK].*;
            if (decrypt) {
                const received = block;
                session.block(&block, &block);
                _cipher.xorBlock(&block, &context.chain);
                context.chain = received;
            } else {
                _cipher.xorBlock(&block, &context.chain);
                session.block(&block, &block);
                context.chain = block;
            }
            to[at..][0..AES_BLOCK].* = block;
        },
        else => while (at < length) : (at += 1) {
            if (context.stream_used == AES_BLOCK) {
                session.block(&context.chain, &context.stream);
                _cipher.increment(&context.chain);
                context.stream_used = 0;
            }
            to[at] = from[at] ^ context.stream[context.stream_used];
            context.stream_used += 1;
        },
    }
    return crypto.CRYPTOERR_OK;
}

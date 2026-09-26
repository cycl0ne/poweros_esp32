// SPDX-License-Identifier: MIT
//! InitHmac: an HMAC context set up with its algorithm and key.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const HmacContext = crypto.HmacContext;
const HashContext = crypto.HashContext;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _hash = @import("../hash/_hash.zig");

/// Sets up a context for a new HMAC with one hash algorithm and a key.
///
/// SYNOPSIS:
/// ```zig
/// fn InitHmac(cb: *CryptoBase, context: *HmacContext, algorithm: u32, key: ?*const anyopaque, key_length: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `context`: the caller's; whatever it held before is dropped.
/// - `algorithm`: HASH_SHA1, HASH_SHA224, HASH_SHA256, HASH_SHA384 or
///   HASH_SHA512.
/// - `key`: the key's bytes; may be null when `key_length` is 0.
/// - `key_length`: any length. A key longer than the hash's block is
///   hashed first, as RFC 2104 says.
///
/// RESULT:
/// CRYPTOERR_OK, or CRYPTOERR_ALGORITHM for an algorithm there is not;
/// the context is then left empty, and UpdateHmac and FinishHmac do
/// nothing with it.
///
/// BEHAVIOR:
/// RFC 2104's HMAC: the key, padded to a block, is exclusive-ored with
/// 0x36 and hashed ahead of the message in the inner hash, and with 0x5C
/// ahead of the inner digest in the outer. Both key blocks go through
/// the engine here, so the context holds no key, only the two hashes'
/// states; the copies made on the way are wiped.
///
/// CONTEXT:
/// - Waits: yes, for the SHA engine while another task has it.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated; the key is only read.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UpdateHmac`, `FinishHmac`, `InitHash`
///
/// EXAMPLES:
/// ```zig
/// var context: crypto.HmacContext = .{};
/// var mac: [crypto.DIGEST_MAX]u8 = undefined;
/// _ = cb.InitHmac(&context, crypto.HASH_SHA256, key.ptr, key.len);
/// cb.UpdateHmac(&context, message.ptr, message.len);
/// const length = cb.FinishHmac(&context, &mac);
/// ```
pub fn InitHmac(cb: *CryptoBase, context: *HmacContext, algorithm: u32, key: ?*const anyopaque, key_length: u32) i32 {
    context.* = .{};
    if (!_hash.known(algorithm)) return crypto.CRYPTOERR_ALGORITHM;
    const block = crypto.blockLength(algorithm);
    var padded: [crypto.HASH_BLOCK_MAX]u8 = @splat(0);
    if (key_length > block) {
        var hashed: HashContext = .{};
        _hash.begin(&hashed, algorithm);
        _hash.absorb(cb, &hashed, @ptrCast(key.?), key_length);
        _ = _hash.finish(cb, &hashed, &padded);
    } else if (key_length != 0) {
        const bytes: [*]const u8 = @ptrCast(key.?);
        for (0..key_length) |index| padded[index] = bytes[index];
    }
    for (padded[0..block]) |*byte| byte.* ^= 0x36;
    _hash.begin(&context.inner, algorithm);
    _hash.absorb(cb, &context.inner, &padded, block);
    // 0x36 ^ 0x5C: from the inner pad to the outer.
    for (padded[0..block]) |*byte| byte.* ^= 0x36 ^ 0x5C;
    _hash.begin(&context.outer, algorithm);
    _hash.absorb(cb, &context.outer, &padded, block);
    for (&padded) |*byte| @as(*volatile u8, byte).* = 0;
    return crypto.CRYPTOERR_OK;
}

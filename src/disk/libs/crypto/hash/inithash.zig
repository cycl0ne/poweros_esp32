// SPDX-License-Identifier: MIT
//! InitHash: a hash context set up for one algorithm.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const HashContext = crypto.HashContext;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _hash = @import("_hash.zig");

/// Sets up a context for a new hash of one algorithm.
///
/// SYNOPSIS:
/// ```zig
/// fn InitHash(cb: *CryptoBase, context: *HashContext, algorithm: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `context`: the caller's, made with `.{}` so that its `size` is
///   right; whatever it held before is dropped.
/// - `algorithm`: HASH_SHA1, HASH_SHA224, HASH_SHA256, HASH_SHA384 or
///   HASH_SHA512.
///
/// RESULT:
/// CRYPTOERR_OK, or CRYPTOERR_ALGORITHM for an algorithm there is not;
/// the context is then left empty, and UpdateHash and FinishHash do
/// nothing with it. CRYPTOERR_CONTEXT for a context whose `size` is
/// less than `@sizeOf(HashContext)`, which is not written to at all.
///
/// BEHAVIOR:
/// The context holds the whole hash from here to FinishHash: the bytes
/// that do not yet make a block, the state between blocks and the length
/// so far. Nothing is taken from the library, so any number of hashes
/// may be under way at once, by any number of tasks, each in its own
/// context.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated; the context stays the caller's.
///
/// NOTES:
/// SHA-1 is here for the formats that still name it; nothing new should
/// rest on it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UpdateHash`, `FinishHash`, `InitHmac`
///
/// EXAMPLES:
/// ```zig
/// var context: crypto.HashContext = .{};
/// var digest: [crypto.DIGEST_MAX]u8 = undefined;
/// if (cb.InitHash(&context, crypto.HASH_SHA256) != crypto.CRYPTOERR_OK) return;
/// cb.UpdateHash(&context, text.ptr, text.len);
/// const length = cb.FinishHash(&context, &digest);
/// ```
pub fn InitHash(_: *CryptoBase, context: *HashContext, algorithm: u32) i32 {
    if (context.size < @sizeOf(HashContext)) return crypto.CRYPTOERR_CONTEXT;
    if (!_hash.known(algorithm)) {
        const size = context.size;
        context.* = .{ .size = size };
        return crypto.CRYPTOERR_ALGORITHM;
    }
    _hash.begin(context, algorithm);
    return crypto.CRYPTOERR_OK;
}

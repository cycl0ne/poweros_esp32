// SPDX-License-Identifier: MIT
//! FinishHash: a hash ended, and its digest.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const HashContext = crypto.HashContext;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _hash = @import("_hash.zig");

/// Ends a hash and writes its digest.
///
/// SYNOPSIS:
/// ```zig
/// fn FinishHash(cb: *CryptoBase, context: *HashContext, digest: *anyopaque) u32
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `context`: set up by InitHash, with the bytes given by UpdateHash.
/// - `digest`: room for the algorithm's digest - `digestLength`, or
///   DIGEST_MAX for any.
///
/// RESULT:
/// The digest's length in bytes: 20 for SHA-1, 28, 32, 48 or 64 for the
/// others. 0 for a context InitHash did not set up, and nothing written.
///
/// BEHAVIOR:
/// The hash is padded as FIPS 180-4 says and its last blocks run; the
/// digest is written most significant byte first, as it is printed and
/// sent. The context is wiped: to hash again it needs InitHash.
///
/// CONTEXT:
/// - Waits: yes, for the SHA engine while another task has it.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitHash`, `UpdateHash`, `FinishHmac`
///
/// EXAMPLES:
/// ```zig
/// var digest: [crypto.DIGEST_MAX]u8 = undefined;
/// const length = cb.FinishHash(&context, &digest);
/// for (digest[0..length]) |byte| _ = Printf(dl, "%02x", .{byte});
/// ```
pub fn FinishHash(cb: *CryptoBase, context: *HashContext, digest: *anyopaque) u32 {
    if (!_hash.known(context.algorithm)) return 0;
    return _hash.finish(cb, context, @ptrCast(digest));
}

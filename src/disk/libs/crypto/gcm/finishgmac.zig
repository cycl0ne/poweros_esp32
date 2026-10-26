// SPDX-License-Identifier: MIT
//! FinishGmac: a GMAC's tag.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const GmacContext = crypto.GmacContext;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _gcm = @import("_gcm.zig");

/// Ends a GMAC: its tag, and the context wiped.
///
/// SYNOPSIS:
/// ```zig
/// fn FinishGmac(cb: *CryptoBase, context: *GmacContext, tag: *anyopaque) i32
/// ```
///
/// SINCE: 2.2. LVO -120.
///
/// INPUTS:
/// - `context`: set up by InitGmac, and given its data by UpdateGmac.
/// - `tag`: room for GCM_TAG (16) bytes.
///
/// RESULT:
/// CRYPTOERR_OK, with the tag in `tag`; CRYPTOERR_CONTEXT for a context
/// InitGmac did not set up, and nothing is written.
///
/// BEHAVIOR:
/// The bytes short of a block are padded with zeroes, the lengths block
/// - the data's length as a header's, and no ciphertext - goes through
/// GHASH, and the result is masked with E(K, J0). The context is wiped,
/// the key with it, its `size` kept: InitGmac starts it again.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// The caller compares the tag with the one it was sent, every byte
/// whatever the first that differs, so that how long the comparison
/// takes says nothing about where they part.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitGmac`, `UpdateGmac`, `OpenGcm`
///
/// EXAMPLES:
/// ```zig
/// var tag: [crypto.GCM_TAG]u8 = undefined;
/// _ = cb.FinishGmac(&context, &tag);
/// var differ: u8 = 0;
/// for (tag, sent) |a, b| differ |= a ^ b;
/// if (differ != 0) return error.Forged;
/// ```
pub fn FinishGmac(_: *CryptoBase, context: *GmacContext, tag: *anyopaque) i32 {
    if (context.key_length == 0) return crypto.CRYPTOERR_CONTEXT;
    _gcm.gmacEnd(context, @ptrCast(tag));
    const size = context.size;
    const bytes: [*]u8 = @ptrCast(context);
    for (bytes[0..@sizeOf(GmacContext)]) |*byte| @as(*volatile u8, byte).* = 0;
    context.size = size;
    return crypto.CRYPTOERR_OK;
}

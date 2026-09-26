// SPDX-License-Identifier: MIT
//! FinishHmac: an HMAC ended, and its MAC.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const HmacContext = crypto.HmacContext;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _hash = @import("../hash/_hash.zig");

/// Ends an HMAC and writes the MAC.
///
/// SYNOPSIS:
/// ```zig
/// fn FinishHmac(cb: *CryptoBase, context: *HmacContext, mac: *anyopaque) u32
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `context`: set up by InitHmac, with the bytes given by UpdateHmac.
/// - `mac`: room for the hash's digest - `digestLength`, or DIGEST_MAX
///   for any.
///
/// RESULT:
/// The MAC's length in bytes, the hash's digest length. 0 for a context
/// InitHmac did not set up, and nothing written.
///
/// BEHAVIOR:
/// The inner hash is finished, its digest goes through the outer hash,
/// and the outer digest is the MAC. The context is wiped: another MAC
/// with the same key needs InitHmac again.
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
/// A MAC received is compared with the one computed in constant time -
/// every byte, not up to the first that differs - or the time taken
/// tells an attacker how much of a forgery was right.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitHmac`, `UpdateHmac`, `FinishHash`
///
/// EXAMPLES:
/// ```zig
/// var mac: [crypto.DIGEST_MAX]u8 = undefined;
/// const length = cb.FinishHmac(&context, &mac);
/// var differ: u8 = 0;
/// for (mac[0..length], received[0..length]) |a, b| differ |= a ^ b;
/// if (differ != 0) return error.Forged;
/// ```
pub fn FinishHmac(cb: *CryptoBase, context: *HmacContext, mac: *anyopaque) u32 {
    if (!_hash.known(context.inner.algorithm)) return 0;
    var inner: [crypto.DIGEST_MAX]u8 = undefined;
    const length = _hash.finish(cb, &context.inner, &inner);
    _hash.absorb(cb, &context.outer, &inner, length);
    for (&inner) |*byte| @as(*volatile u8, byte).* = 0;
    return _hash.finish(cb, &context.outer, @ptrCast(mac));
}

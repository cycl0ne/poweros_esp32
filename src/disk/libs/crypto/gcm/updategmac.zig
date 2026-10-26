// SPDX-License-Identifier: MIT
//! UpdateGmac: more data into a GMAC.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const GmacContext = crypto.GmacContext;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _gcm = @import("_gcm.zig");

/// Adds data to a GMAC under way.
///
/// SYNOPSIS:
/// ```zig
/// fn UpdateGmac(cb: *CryptoBase, context: *GmacContext, data: ?*const anyopaque, length: u32) void
/// ```
///
/// SINCE: 2.2. LVO -116.
///
/// INPUTS:
/// - `context`: set up by InitGmac.
/// - `data`: the bytes; may be null when `length` is 0.
/// - `length`: how many.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// How the data is divided between calls makes no difference to the
/// tag. Bytes short of a 16-byte block wait in the context for the next
/// call; whole blocks are hashed where they lie, nothing copied. A
/// context InitGmac did not set up takes nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands; `data` is only read.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitGmac`, `FinishGmac`
///
/// EXAMPLES:
/// ```zig
/// while (received < length) {
///     const got = receive(buffer[received..]);
///     cb.UpdateGmac(&context, buffer[received..].ptr, got);
///     received += got;
/// }
/// ```
pub fn UpdateGmac(_: *CryptoBase, context: *GmacContext, data: ?*const anyopaque, length: u32) void {
    if (context.key_length == 0 or length == 0) return;
    _gcm.gmacAbsorb(context, @ptrCast(data orelse return), length);
}

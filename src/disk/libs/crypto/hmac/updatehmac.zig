// SPDX-License-Identifier: MIT
//! UpdateHmac: more bytes into an HMAC.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const HmacContext = crypto.HmacContext;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _hash = @import("../hash/_hash.zig");

/// Adds bytes to an HMAC under way.
///
/// SYNOPSIS:
/// ```zig
/// fn UpdateHmac(cb: *CryptoBase, context: *HmacContext, data: ?*const anyopaque, length: u32) void
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `context`: set up by InitHmac.
/// - `data`: the bytes; may be null when `length` is 0.
/// - `length`: how many.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The bytes go into the inner hash, as UpdateHash would take them: how
/// they are divided between calls makes no difference to the MAC. A
/// context InitHmac did not set up takes nothing.
///
/// CONTEXT:
/// - Waits: yes, for the SHA engine while another task has it.
/// - Interrupts: no.
/// - Forbid: must not be held.
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
/// `InitHmac`, `FinishHmac`, `UpdateHash`
///
/// EXAMPLES:
/// ```zig
/// cb.UpdateHmac(&context, header.ptr, header.len);
/// cb.UpdateHmac(&context, body.ptr, body.len);
/// ```
pub fn UpdateHmac(cb: *CryptoBase, context: *HmacContext, data: ?*const anyopaque, length: u32) void {
    if (!_hash.known(context.inner.algorithm) or length == 0) return;
    const bytes: [*]const u8 = @ptrCast(data orelse return);
    _hash.absorb(cb, &context.inner, bytes, length);
}

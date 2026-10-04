// SPDX-License-Identifier: MIT
//! UpdateHash: more bytes into a hash.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const HashContext = crypto.HashContext;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _hash = @import("_hash.zig");

/// Adds bytes to a hash under way.
///
/// SYNOPSIS:
/// ```zig
/// fn UpdateHash(cb: *CryptoBase, context: *HashContext, data: ?*const anyopaque, length: u32) void
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `context`: set up by InitHash.
/// - `data`: the bytes; may be null when `length` is 0.
/// - `length`: how many.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The digest depends only on the bytes, not on how they were divided
/// between calls: one call with all of them and a thousand with one byte
/// each come to the same. Whole blocks go to the chip's SHA engine as
/// they are made up; the rest waits in the context for the next call.
/// A context InitHash did not set up, or one FinishHash has ended, takes
/// nothing.
///
/// CONTEXT:
/// - Waits: yes, for the SHA engine while another task has it.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
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
/// `InitHash`, `FinishHash`
///
/// EXAMPLES:
/// ```zig
/// while (true) {
///     const got = dl.Read(file, &chunk, chunk.len);
///     if (got <= 0) break;
///     cb.UpdateHash(&context, &chunk, @intCast(got));
/// }
/// ```
pub fn UpdateHash(cb: *CryptoBase, context: *HashContext, data: ?*const anyopaque, length: u32) void {
    if (!_hash.known(context.algorithm) or length == 0) return;
    const bytes: [*]const u8 = @ptrCast(data orelse return);
    _hash.absorb(cb, context, bytes, length);
}

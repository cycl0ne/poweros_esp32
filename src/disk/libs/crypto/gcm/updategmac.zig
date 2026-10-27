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
/// On the 64-bit chips, 64 KiB of whole blocks or more in one call are
/// cut into up to four parts, at least 16 KiB each, which exec's workers
/// hash at once on the other cores while the caller does the first
/// (`ShareWork`); the parts are then put together with powers of the hash
/// key. Where they are cut follows the length alone, and the data is
/// only read. When the workers are busy with another job, or the caller
/// may not wait for them, the caller hashes everything itself, as with
/// less data.
///
/// CONTEXT:
/// - Waits: for exec's workers, when it shares (see above); never where
///   the caller may not wait.
/// - Interrupts: no.
/// - Locks: none needed; the parts take none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands; `data` is only read, by the workers too, until
/// the call returns.
///
/// NOTES:
/// Shared between the cores since 2.7: on the VisionFive 2, 1 MiB in one
/// call at 415 MB/s against 106 on one core. The workers take the
/// caller's priority, so while they work, tasks of that priority wait
/// for a core; a caller whose own work of that priority must go on - a
/// network stack sending - calls it one below (smb-handler signs a WRITE
/// so while the one before it is sent).
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
pub fn UpdateGmac(cb: *CryptoBase, context: *GmacContext, data: ?*const anyopaque, length: u32) void {
    if (context.key_length == 0 or length == 0) return;
    _gcm.gmacAbsorb(cb.sys_base, context, @ptrCast(data orelse return), length);
}

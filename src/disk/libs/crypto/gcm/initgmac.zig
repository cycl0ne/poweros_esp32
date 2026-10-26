// SPDX-License-Identifier: MIT
//! InitGmac: a GMAC set up, to be given its data a piece at a time.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const GmacContext = crypto.GmacContext;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _cipher = @import("../cipher/_cipher.zig");
const _gcm = @import("_gcm.zig");

/// Sets up a context for a GMAC - GCM's tag over data it only
/// authenticates - whose data comes in pieces.
///
/// SYNOPSIS:
/// ```zig
/// fn InitGmac(cb: *CryptoBase, context: *GmacContext, key: *const anyopaque, key_length: u32, nonce: *const anyopaque, nonce_length: u32) i32
/// ```
///
/// SINCE: 2.2. LVO -112.
///
/// INPUTS:
/// - `context`: the caller's, made with `.{}` so that its `size` is
///   right; whatever it held before is dropped.
/// - `key`: the AES key, `key_length` bytes: 16 or 32.
/// - `nonce`: `nonce_length` bytes; 12 is what GCM is made for, and any
///   length but 0 is taken.
///
/// RESULT:
/// CRYPTOERR_OK; CRYPTOERR_KEY for another key length; CRYPTOERR_LENGTH
/// for a nonce of no bytes. The context is left empty on an error, and
/// UpdateGmac and FinishGmac do nothing with it. CRYPTOERR_CONTEXT for a
/// context whose `size` is less than `@sizeOf(GmacContext)`, which is
/// not written to at all.
///
/// BEHAVIOR:
/// The hash key H = E(K, 0) and the tag's mask E(K, J0) are worked out
/// here, two AES blocks, and kept in the context with the key. The tag
/// FinishGmac gives is the one SealGcm gives a message whose header is
/// all the data UpdateGmac was given, and which has no plaintext. Any
/// number of GMACs may be under way at once, each in its own context.
///
/// CONTEXT:
/// - Waits: yes, for the AES engine while another task has it.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated; the context stays the caller's. It holds the
/// key until FinishGmac wipes it: a context given up before then is the
/// caller's to clear.
///
/// NOTES:
/// What this is for: a message whose MAC is to be checked as it arrives
/// - SMB's signature over a READ's answer of up to 1 MiB, hashed as the
/// network delivers it, so that receiving and hashing go on together. A
/// message that is all at hand takes one SealGcm, with it as the header.
///
/// BUGS:
/// GHASH runs in software on every chip, about 72 MB/s on the
/// VisionFive 2.
///
/// SEE ALSO:
/// `UpdateGmac`, `FinishGmac`, `SealGcm`
///
/// EXAMPLES:
/// ```zig
/// var context: crypto.GmacContext = .{};
/// var tag: [crypto.GCM_TAG]u8 = undefined;
/// if (cb.InitGmac(&context, &key, 16, &nonce, 12) != crypto.CRYPTOERR_OK) return;
/// cb.UpdateGmac(&context, header.ptr, header.len);
/// cb.UpdateGmac(&context, body.ptr, body.len);
/// _ = cb.FinishGmac(&context, &tag);
/// ```
pub fn InitGmac(cb: *CryptoBase, context: *GmacContext, key: *const anyopaque, key_length: u32, nonce: *const anyopaque, nonce_length: u32) i32 {
    if (context.size < @sizeOf(GmacContext)) return crypto.CRYPTOERR_CONTEXT;
    const size = context.size;
    context.* = .{ .size = size };
    if (!_cipher.keyLength(key_length)) return crypto.CRYPTOERR_KEY;
    if (nonce_length == 0) return crypto.CRYPTOERR_LENGTH;
    _gcm.gmacBegin(cb, context, @ptrCast(key), key_length, @ptrCast(nonce), nonce_length);
    return crypto.CRYPTOERR_OK;
}

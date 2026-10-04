// SPDX-License-Identifier: MIT
//! HkdfExpand: HKDF's second half, keying material of any length from a
//! pseudorandom key.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const _base = @import("../crypto_base.zig");
const CryptoBase = _base.CryptoBase;
const _cipher = @import("../cipher/_cipher.zig");

/// Expands a pseudorandom key into keying material of a given length
/// (HKDF-Expand, RFC 5869).
///
/// SYNOPSIS:
/// ```zig
/// fn HkdfExpand(cb: *CryptoBase, algorithm: u32, prk: *const Bytes, info: *const Bytes, output: *anyopaque, length: u32) i32
/// ```
///
/// SINCE: 1.1. LVO -72.
///
/// INPUTS:
/// - `algorithm`: the hash, HASH_SHA1 to HASH_SHA512.
/// - `prk`: the pseudorandom key, from HkdfExtract or a protocol's own
///   secret; at least the digest's length, as the RFC asks.
/// - `info`: what the material is for; any length, none included.
/// - `output`: room for `length` bytes; it may not overlap `prk` or
///   `info`.
/// - `length`: at most 255 times the digest's length.
///
/// RESULT:
/// CRYPTOERR_OK, with the material in `output`; CRYPTOERR_ALGORITHM for
/// a hash there is not; CRYPTOERR_LENGTH for a `length` past 255 digests
/// or a `prk` shorter than one. Nothing is written on a failure.
///
/// BEHAVIOR:
/// T(1) = HMAC(prk, info | 1), T(n) = HMAC(prk, T(n-1) | info | n), and
/// the output is T(1) | T(2) | ... cut to `length`.
///
/// CONTEXT:
/// - Waits: for the SHA engine, while another task has it.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is kept: the last block's copy on the stack is wiped.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `HkdfExtract`, `InitHmac`
///
/// EXAMPLES:
/// ```zig
/// var key: [16]u8 = undefined;
/// _ = cb.HkdfExpand(crypto.HASH_SHA256, &crypto.Bytes.of(&prk), &crypto.Bytes.of(label), &key, key.len);
/// ```
pub fn HkdfExpand(cb: *CryptoBase, algorithm: u32, prk: *const Bytes, info: *const Bytes, output: *anyopaque, length: u32) i32 {
    const digest_length = crypto.digestLength(algorithm);
    if (digest_length == 0) return crypto.CRYPTOERR_ALGORITHM;
    if (length > 255 * digest_length or prk.length < digest_length) return crypto.CRYPTOERR_LENGTH;
    const lib = _base.iface(cb);
    const out: [*]u8 = @ptrCast(output);
    var block: [crypto.DIGEST_MAX]u8 = undefined;
    var written: u32 = 0;
    var counter: u8 = 1;
    while (written < length) : (counter +%= 1) {
        var context: crypto.HmacContext = .{};
        _ = lib.InitHmac(&context, algorithm, prk.bytes, prk.length);
        if (counter > 1) lib.UpdateHmac(&context, &block, digest_length);
        lib.UpdateHmac(&context, info.bytes, info.length);
        lib.UpdateHmac(&context, &counter, 1);
        _ = lib.FinishHmac(&context, &block);
        const take = @min(length - written, digest_length);
        for (0..take) |index| out[written + index] = block[index];
        written += take;
    }
    _cipher.wipe(&block);
    return crypto.CRYPTOERR_OK;
}

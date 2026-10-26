// SPDX-License-Identifier: MIT
//! HashPieces: the digest of a message given whole, in pieces.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _hash = @import("_hash.zig");

/// Hashes a message given whole, in any number of pieces, in one call.
///
/// SYNOPSIS:
/// ```zig
/// fn HashPieces(cb: *CryptoBase, algorithm: u32, pieces: ?[*]const Bytes, count: u32, digest: *anyopaque) u32
/// ```
///
/// SINCE: 2.0. LVO -104.
///
/// INPUTS:
/// - `algorithm`: HASH_SHA1, HASH_SHA224, HASH_SHA256, HASH_SHA384,
///   HASH_SHA512, HASH_MD5 or HASH_MD4.
/// - `pieces`: `count` pieces of the message, in order; null when
///   `count` is 0. A piece may be empty, its `bytes` then null.
/// - `count`: how many pieces; 0 for the empty message.
/// - `digest`: room for the digest's length (`digestLength(algorithm)`,
///   at most DIGEST_MAX).
///
/// RESULT:
/// The digest's length, with the digest in `digest`; 0 for a hash there
/// is not, for `pieces` null with `count` above 0, or for a piece with
/// bytes to read and `bytes` null - nothing is written then.
///
/// BEHAVIOR:
/// The digest is the one InitHash, an UpdateHash per piece and
/// FinishHash give: how the message is cut makes no difference. Only the
/// pieces' bytes are read, once each, and nothing is kept between
/// calls.
///
/// CONTEXT:
/// - Waits: yes, for the SHA engine, or the JH7110's, while another task
///   has it.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands; the pieces are only read. What the message
/// left in the library is wiped before the call returns.
///
/// NOTES:
/// On the JH7110 (the VisionFive 2) this is the call that can hash on
/// the crypto engine: SHA-224, SHA-256, SHA-384 and SHA-512 of a message
/// of 512 bytes or more go through it - SHA-256 at 40 MB/s against 28 in
/// software for 512 bytes, at 66 against 33 from 8 KiB. The engine has
/// no way to give back a hash half done, so the incremental calls, which
/// leave one between calls, hash in software. A message that is all at
/// hand - a file read whole, a packet in its headers and body - is
/// hashed with this call.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `HmacPieces`, `InitHash`, `UpdateHash`, `FinishHash`
///
/// EXAMPLES:
/// ```zig
/// var digest: [crypto.DIGEST_MAX]u8 = undefined;
/// const pieces = [_]crypto.Bytes{ .of(header), .of(body) };
/// const length = cb.HashPieces(crypto.HASH_SHA256, &pieces, pieces.len, &digest);
/// if (length == 0) return error.Hash;
/// ```
pub fn HashPieces(cb: *CryptoBase, algorithm: u32, pieces: ?[*]const Bytes, count: u32, digest: *anyopaque) u32 {
    if (!_hash.known(algorithm)) return 0;
    const given: []const Bytes = if (count == 0) &.{} else (pieces orelse return 0)[0..count];
    if (!_hash.readable(given)) return 0;
    const out: [*]u8 = @ptrCast(digest);
    if (_hash.byEngine(cb, algorithm, &.{}, given, out)) return crypto.digestLength(algorithm);
    return _hash.ofPieces(cb, algorithm, given, out);
}

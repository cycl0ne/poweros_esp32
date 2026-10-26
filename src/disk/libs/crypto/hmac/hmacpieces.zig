// SPDX-License-Identifier: MIT
//! HmacPieces: the HMAC of a message given whole, in pieces.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const _base = @import("../crypto_base.zig");
const CryptoBase = _base.CryptoBase;
const _hash = @import("../hash/_hash.zig");

/// Makes the HMAC of a message given whole, in any number of pieces, in
/// one call.
///
/// SYNOPSIS:
/// ```zig
/// fn HmacPieces(cb: *CryptoBase, algorithm: u32, key: ?*const anyopaque, key_length: u32, pieces: ?[*]const Bytes, count: u32, mac: *anyopaque) u32
/// ```
///
/// SINCE: 2.0. LVO -108.
///
/// INPUTS:
/// - `algorithm`: HASH_SHA1, HASH_SHA224, HASH_SHA256, HASH_SHA384,
///   HASH_SHA512, HASH_MD5 or HASH_MD4.
/// - `key`: the key's bytes; may be null when `key_length` is 0.
/// - `key_length`: any length. A key longer than the hash's block is
///   hashed first, as RFC 2104 says.
/// - `pieces`: `count` pieces of the message, in order; null when
///   `count` is 0. A piece may be empty, its `bytes` then null.
/// - `count`: how many pieces; 0 for the empty message.
/// - `mac`: room for the digest's length (`digestLength(algorithm)`, at
///   most DIGEST_MAX).
///
/// RESULT:
/// The MAC's length, with the MAC in `mac`; 0 for a hash there is not,
/// for `key` null with `key_length` above 0, for `pieces` null with
/// `count` above 0, or for a piece with bytes to read and `bytes` null -
/// nothing is written then.
///
/// BEHAVIOR:
/// The MAC is the one InitHmac, an UpdateHmac per piece and FinishHmac
/// give: how the message is cut makes no difference. Only the key's and
/// the pieces' bytes are read, and nothing is kept between calls.
///
/// CONTEXT:
/// - Waits: yes, for the SHA engine, or the JH7110's, while another task
///   has it.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands; the key and the pieces are only read. What
/// the key and the message left in the library is wiped before the call
/// returns.
///
/// NOTES:
/// On the JH7110 (the VisionFive 2) this is the call that can make an
/// HMAC on the crypto engine, key and all: SHA-224, SHA-256, SHA-384 and
/// SHA-512 over a message of 512 bytes or more go through it. An empty
/// key is left to software. The incremental calls, which leave an HMAC
/// half done between calls, run in software, as the engine cannot give
/// one back. SMB's signing, an HMAC-SHA-256 over each message, is what
/// this call is for.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `HashPieces`, `InitHmac`, `UpdateHmac`, `FinishHmac`
///
/// EXAMPLES:
/// ```zig
/// var mac: [crypto.DIGEST_MAX]u8 = undefined;
/// const pieces = [_]crypto.Bytes{ .of(header), .of(body) };
/// const length = cb.HmacPieces(crypto.HASH_SHA256, &key, key.len, &pieces, pieces.len, &mac);
/// if (length == 0) return error.Mac;
/// ```
pub fn HmacPieces(cb: *CryptoBase, algorithm: u32, key: ?*const anyopaque, key_length: u32, pieces: ?[*]const Bytes, count: u32, mac: *anyopaque) u32 {
    if (!_hash.known(algorithm)) return 0;
    if (key_length != 0 and key == null) return 0;
    const given: []const Bytes = if (count == 0) &.{} else (pieces orelse return 0)[0..count];
    if (!_hash.readable(given)) return 0;
    const out: [*]u8 = @ptrCast(mac);
    if (key_length != 0) {
        // The engine takes a key of a block at most: a longer one is its
        // digest, as RFC 2104 has it.
        const bytes: [*]const u8 = @ptrCast(key.?);
        var hashed: [crypto.DIGEST_MAX]u8 = undefined;
        defer {
            for (&hashed) |*byte| @as(*volatile u8, byte).* = 0;
        }
        const short = if (key_length <= crypto.blockLength(algorithm))
            bytes[0..key_length]
        else
            hashed[0.._hash.ofPieces(cb, algorithm, &.{.{ .bytes = bytes, .length = key_length }}, &hashed)];
        if (_hash.byEngine(cb, algorithm, short, given, out)) return crypto.digestLength(algorithm);
    }
    const lib = _base.iface(cb);
    var context: crypto.HmacContext = .{};
    _ = lib.InitHmac(&context, algorithm, key, key_length);
    for (given) |piece| lib.UpdateHmac(&context, piece.bytes, piece.length);
    return lib.FinishHmac(&context, mac);
}

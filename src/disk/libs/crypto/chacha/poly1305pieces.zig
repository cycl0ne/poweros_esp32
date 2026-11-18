// SPDX-License-Identifier: MIT
//! Poly1305Pieces: Poly1305 over a message given whole, in pieces.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _chacha = @import("_chacha.zig");

/// Poly1305 (RFC 8439, 2.5) with a one-time key over a message given in
/// any number of pieces.
///
/// SYNOPSIS:
/// ```zig
/// fn Poly1305Pieces(cb: *CryptoBase, key: *const [32]u8, pieces: ?[*]const Bytes, count: u32, tag: *[16]u8) i32
/// ```
///
/// SINCE: 2.13. LVO -132.
///
/// INPUTS:
/// - `key`: the one-time key (POLY1305_KEY bytes): r, which the call
///   clamps as the RFC says, then s.
/// - `pieces`: `count` pieces of the message, in order; null when
///   `count` is 0. A piece may be empty, its `bytes` then null.
/// - `count`: how many pieces; 0 for the empty message.
/// - `tag`: where the 16-byte tag goes.
///
/// RESULT:
/// CRYPTOERR_OK; CRYPTOERR_LENGTH for `pieces` null with `count` above 0,
/// or a piece with bytes to read and `bytes` null - nothing is written
/// then.
///
/// BEHAVIOR:
/// The tag is the RFC's over the pieces one after another: how the
/// message is cut makes no difference. Nothing is padded between them;
/// a protocol that pads (the RFC's AEAD does) gives the zeroes as pieces
/// of their own. The key is used once: a second message under the same
/// key lets its tags be forged.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated, and nothing of the key is kept.
///
/// NOTES:
/// For a protocol that builds its own AEAD from ChaCha20 and Poly1305:
/// SSH's chacha20-poly1305@openssh.com takes the one-time key from
/// ChaCha20's block 0 (InitCipher with CIPHER_CHACHA20, UpdateCipher
/// over 64 zero bytes, the first 32 of them), and the tag over the
/// encrypted length and the encrypted packet - two pieces. The tag is
/// compared by the caller, every byte of it, whatever the first
/// difference.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitCipher`, `SealChaChaPoly`, `HmacPieces`
///
/// EXAMPLES:
/// ```zig
/// const pieces = [_]crypto.Bytes{ .of(packet[0..4]), .of(packet[4..]) };
/// var tag: [crypto.POLY1305_TAG]u8 = undefined;
/// _ = cb.Poly1305Pieces(poly_key[0..32], &pieces, pieces.len, &tag);
/// ```
pub fn Poly1305Pieces(_: *CryptoBase, key: *const [32]u8, pieces: ?[*]const Bytes, count: u32, tag: *[16]u8) i32 {
    const list: []const Bytes = if (count == 0) &.{} else (pieces orelse return crypto.CRYPTOERR_LENGTH)[0..count];
    for (list) |piece| {
        if (piece.length != 0 and piece.bytes == null) return crypto.CRYPTOERR_LENGTH;
    }
    var poly = _chacha.Poly1305.init(key);
    for (list) |piece| {
        if (piece.length != 0) poly.update(piece.bytes.?[0..piece.length]);
    }
    poly.finish(tag);
    return crypto.CRYPTOERR_OK;
}

// SPDX-License-Identifier: MIT
//! What a session signs with and how ([MS-SMB2] 3.1.4.1, 3.1.4.2,
//! 3.2.5.3): the three signatures, the keys made from the logon's session
//! key, and the hash 3.1.1 makes them over.
//!
//! **The signature** is sixteen bytes in the header, over the whole
//! message with those sixteen bytes zero and FLAGS_SIGNED set. 2.0.2 and
//! 2.1 take HMAC-SHA256 with the session key itself, cut to sixteen
//! bytes; 3.0 and 3.0.2 AES-128-CMAC; 3.1.1 AES-128-CMAC or AES-128-GMAC,
//! as its negotiation chose. GMAC's nonce is the message's id and whether
//! it is an answer.
//!
//! **The keys** come from the session key through SP800-108's KDF in
//! counter mode with HMAC-SHA256: one round, since no key is longer than
//! the 32 bytes one HMAC gives. 3.0 and 3.0.2 make the signing key with
//! a fixed context; 3.1.1 makes it and the two cipher keys over the hash
//! of the negotiation and the logon (`Preauth`), so a key is of this one
//! connection and nobody between could have changed what led to it.
//!
//! CMAC is crypto.library's AES-CBC over every block but the last, which
//! goes through with a subkey mixed in (RFC 4493): the MAC is the last
//! block's ciphertext.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const smb = sdk.dos.smb;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const wire = @import("wire.zig");

/// How a session signs: the algorithm (SMB2_SIGNING_*) and its key.
pub const Signer = struct {
    algorithm: u16 = smb.SMB2_SIGNING_NONE,
    key: [16]u8 = @splat(0),

    /// Whether anything is signed.
    pub fn signs(signer: *const Signer) bool {
        return signer.algorithm != smb.SMB2_SIGNING_NONE;
    }

    /// `message` signed: FLAGS_SIGNED set and the signature written into
    /// its header. The message is one whole message, its header first.
    ///
    /// INPUTS:
    /// - `cb` - crypto.library.
    /// - `message` - the message, its signature field as it may be.
    pub fn sign(signer: *const Signer, cb: *CryptoBase, message: []u8) void {
        const flags = wire.u32At(message, 16);
        wire.put32(message, 16, flags | wire.FLAGS_SIGNED);
        @memset(message[wire.signature_at..][0..16], 0);
        const signature = signer.signatureOf(cb, message);
        @memcpy(message[wire.signature_at..][0..16], &signature);
    }

    /// Whether `message`'s signature is right. Its signature field is
    /// zero afterwards.
    ///
    /// INPUTS:
    /// - `cb` - crypto.library.
    /// - `message` - one whole message, as it came.
    pub fn verify(signer: *const Signer, cb: *CryptoBase, message: []u8) bool {
        var given: [16]u8 = undefined;
        @memcpy(&given, message[wire.signature_at..][0..16]);
        @memset(message[wire.signature_at..][0..16], 0);
        const signature = signer.signatureOf(cb, message);
        // Every byte compared, whatever the first that differs.
        var difference: u8 = 0;
        for (given, signature) |one, other| difference |= one ^ other;
        return difference == 0;
    }

    /// The signature of a message whose signature field is zero.
    fn signatureOf(signer: *const Signer, cb: *CryptoBase, message: []const u8) [16]u8 {
        return switch (signer.algorithm) {
            smb.SMB2_SIGNING_HMAC_SHA256 => blk: {
                const mac = hmacSha256(cb, &signer.key, &.{message});
                break :blk mac[0..16].*;
            },
            smb.SMB2_SIGNING_AES_CMAC => cmac(cb, &signer.key, message),
            else => gmac(cb, &signer.key, &gmacNonce(message), message),
        };
    }
};

/// GMAC's nonce for a message: its id, then bit 0 for an answer and bit 1
/// for CANCEL.
///
/// INPUTS:
/// - `message` - the message's header at least.
pub fn gmacNonce(message: []const u8) [12]u8 {
    var nonce: [12]u8 = @splat(0);
    wire.put64(&nonce, 0, wire.u64At(message, 24));
    const flags = wire.u32At(message, 16);
    var role: u32 = 0;
    if (flags & wire.FLAGS_SERVER_TO_REDIR != 0) role |= 1;
    if (wire.u16At(message, 12) == @intFromEnum(wire.Command.cancel)) role |= 2;
    wire.put32(&nonce, 8, role);
    return nonce;
}

/// HMAC-SHA256 over `parts` in turn, in one call: on the JH7110 a long
/// message's goes through the crypto engine.
///
/// INPUTS:
/// - `cb` - crypto.library.
/// - `key` - the key.
/// - `parts` - the message, in at most five pieces.
pub fn hmacSha256(cb: *CryptoBase, key: []const u8, parts: []const []const u8) [32]u8 {
    var pieces: [5]crypto.Bytes = undefined;
    for (parts, pieces[0..parts.len]) |part, *piece| piece.* = .of(part);
    var mac: [crypto.DIGEST_MAX]u8 = undefined;
    _ = cb.HmacPieces(crypto.HASH_SHA256, key.ptr, @intCast(key.len), &pieces, @intCast(parts.len), &mac);
    return mac[0..32].*;
}

/// AES-128-CMAC (RFC 4493) of `message`.
///
/// INPUTS:
/// - `cb` - crypto.library.
/// - `key` - the AES key.
/// - `message` - any length, 0 too.
pub fn cmac(cb: *CryptoBase, key: *const [16]u8, message: []const u8) [16]u8 {
    // The subkeys: AES of the zero block, doubled once and twice.
    var ecb: crypto.CipherContext = .{};
    _ = cb.InitCipher(&ecb, crypto.CIPHER_AES_ECB, key, 16, null);
    const zero: [16]u8 = @splat(0);
    var under: [16]u8 = undefined;
    _ = cb.UpdateCipher(&ecb, &zero, &under, 16);
    const first = double(under);
    const second = double(first);

    var cbc: crypto.CipherContext = .{};
    _ = cb.InitCipher(&cbc, crypto.CIPHER_AES_CBC, key, 16, &zero);
    // Every whole block but the last, through a piece of scratch: only
    // the chain matters, and the context keeps it.
    const lead: usize = if (message.len == 0) 0 else (message.len - 1) / 16 * 16;
    var scratch: [256]u8 = undefined;
    var at: usize = 0;
    while (at < lead) {
        const count: usize = @min(scratch.len, lead - at);
        _ = cb.UpdateCipher(&cbc, message[at..].ptr, &scratch, @intCast(count));
        at += count;
    }
    const rest = message[lead..];
    var last: [16]u8 = @splat(0);
    if (rest.len == 16) {
        for (&last, rest, first) |*byte, from, mix| byte.* = from ^ mix;
    } else {
        @memcpy(last[0..rest.len], rest);
        last[rest.len] = 0x80;
        for (&last, second) |*byte, mix| byte.* ^= mix;
    }
    var mac: [16]u8 = undefined;
    _ = cb.UpdateCipher(&cbc, &last, &mac, 16);
    return mac;
}

/// A block doubled in GF(2^128) as CMAC's subkeys are: shifted left one
/// bit, 0x87 mixed into the last byte when a bit fell off the top.
fn double(block: [16]u8) [16]u8 {
    var out: [16]u8 = undefined;
    var carry: u8 = 0;
    var at: usize = 16;
    while (at > 0) {
        at -= 1;
        out[at] = (block[at] << 1) | carry;
        carry = block[at] >> 7;
    }
    if (carry != 0) out[15] ^= 0x87;
    return out;
}

/// AES-128-GMAC: GCM's tag over `message` as additional data, nothing
/// encrypted - by UpdateGmac, which shares a long message's between the
/// cores.
///
/// INPUTS:
/// - `cb` - crypto.library.
/// - `key` - the AES key.
/// - `nonce` - twelve bytes, never used twice with the key.
/// - `message` - what is authenticated.
pub fn gmac(cb: *CryptoBase, key: *const [16]u8, nonce: *const [12]u8, message: []const u8) [16]u8 {
    var tag: [crypto.GCM_TAG]u8 = @splat(0);
    var context: crypto.GmacContext = .{};
    if (cb.InitGmac(&context, key, 16, nonce, nonce.len) != crypto.CRYPTOERR_OK) return tag;
    cb.UpdateGmac(&context, message.ptr, @intCast(message.len));
    _ = cb.FinishGmac(&context, &tag);
    return tag;
}

/// SP800-108's KDF in counter mode with HMAC-SHA256, one round:
/// HMAC(key, 1 || label || 0 || context || bits), its first `out.len`
/// bytes, `bits` being `out.len` in bits.
///
/// INPUTS:
/// - `cb` - crypto.library.
/// - `key` - the session key.
/// - `label` - the key's label, its NUL included.
/// - `context` - its context.
/// - `out` - 16 or 32 bytes.
pub fn derive(cb: *CryptoBase, key: []const u8, label: []const u8, context: []const u8, out: []u8) void {
    const counter = [4]u8{ 0, 0, 0, 1 };
    const bits: u32 = @intCast(out.len * 8);
    const length = [4]u8{ @truncate(bits >> 24), @truncate(bits >> 16), @truncate(bits >> 8), @truncate(bits) };
    const mac = hmacSha256(cb, key, &.{ &counter, label, &.{0}, context, &length });
    @memcpy(out, mac[0..out.len]);
}

/// 3.1.1's preauth integrity hash: SHA-512 over the hash so far and each
/// message of the negotiation and the logon in turn, from 64 zero bytes.
pub const Preauth = struct {
    value: [64]u8 = @splat(0),

    /// `message` - one whole message, header first - taken in.
    pub fn add(preauth: *Preauth, cb: *CryptoBase, message: []const u8) void {
        var context: crypto.HashContext = .{};
        _ = cb.InitHash(&context, crypto.HASH_SHA512);
        cb.UpdateHash(&context, &preauth.value, 64);
        cb.UpdateHash(&context, message.ptr, @intCast(message.len));
        var digest: [crypto.DIGEST_MAX]u8 = undefined;
        _ = cb.FinishHash(&context, &digest);
        preauth.value = digest[0..64].*;
    }
};

/// The labels and contexts of the keys a session derives.
pub const label_cmac_30 = "SMB2AESCMAC\x00";
pub const context_sign_30 = "SmbSign\x00";
pub const label_sign_311 = "SMBSigningKey\x00";
pub const label_c2s_311 = "SMBC2SCipherKey\x00";
pub const label_s2c_311 = "SMBS2CCipherKey\x00";

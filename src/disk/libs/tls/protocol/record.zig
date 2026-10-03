// SPDX-License-Identifier: MIT
//! The record layer (RFC 8446, 5): what goes over the connection is
//! records - a type, the version 03 03, a length and that many bytes.
//!
//! Before the keys are agreed a record's bytes are the plain handshake
//! message. After, every record is TLS 1.3's: type 23 outside, and
//! inside, AES-GCM over the content, its real type and any zero padding;
//! the record's five header bytes are the GCM header, and the nonce is
//! the IV with the record's sequence number laid over its last eight
//! bytes. Each direction counts its own records from zero, and from zero
//! again with every new key.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const schedule = @import("schedule.zig");
const TrafficKeys = schedule.TrafficKeys;

pub const CHANGE_CIPHER_SPEC: u8 = 20;
pub const ALERT: u8 = 21;
pub const HANDSHAKE: u8 = 22;
pub const APPLICATION_DATA: u8 = 23;

pub const header_length = 5;
/// The most a record carries before protection, and after it: 2^14,
/// and that and 256.
pub const max_plaintext = 16384;
pub const max_ciphertext = max_plaintext + 256;

/// A record's header: its type and its length.
pub const Header = struct {
    content_type: u8,
    length: u16,
};

/// The header of a record, from its first five bytes; null for a type
/// there is not or a length past what a record may have.
pub fn header(bytes: *const [header_length]u8) ?Header {
    const content_type = bytes[0];
    if (content_type < CHANGE_CIPHER_SPEC or content_type > APPLICATION_DATA) return null;
    if (bytes[1] != 3) return null;
    const length = @as(u16, bytes[3]) << 8 | bytes[4];
    if (length > max_ciphertext) return null;
    return .{ .content_type = content_type, .length = length };
}

/// A record of `content_type` around plain `content`, into `out`; its
/// length. The version is 03 01 on the very first, as RFC 8446 has a
/// ClientHello sent.
pub fn plain(content_type: u8, first: bool, content: []const u8, out: []u8) usize {
    out[0] = content_type;
    out[1] = 3;
    out[2] = if (first) 1 else 3;
    out[3] = @truncate(content.len >> 8);
    out[4] = @truncate(content.len);
    @memcpy(out[header_length..][0..content.len], content);
    return header_length + content.len;
}

fn nonceOf(keys: *const TrafficKeys) [12]u8 {
    var nonce = keys.iv;
    for (0..8) |index| nonce[4 + index] ^= @truncate(keys.sequence >> @intCast(56 - 8 * index));
    return nonce;
}

/// `content` of `content_type` protected into a record in `out`, which
/// has room for its length, a byte, the tag and the header; the
/// record's length.
pub fn seal(cb: *CryptoBase, keys: *TrafficKeys, content_type: u8, content: []const u8, out: []u8) usize {
    const inner_length = content.len + 1;
    const total = inner_length + crypto.GCM_TAG;
    out[0] = APPLICATION_DATA;
    out[1] = 3;
    out[2] = 3;
    out[3] = @truncate(total >> 8);
    out[4] = @truncate(total);
    const body = out[header_length..];
    @memcpy(body[0..content.len], content);
    body[content.len] = content_type;
    const nonce = nonceOf(keys);
    const message: crypto.GcmMessage = .{
        .key = &keys.key,
        .key_length = keys.key_length,
        .nonce = &nonce,
        .nonce_length = 12,
        .aad = out.ptr,
        .aad_length = header_length,
        .input = body.ptr,
        .output = body.ptr,
        .length = @intCast(inner_length),
        .tag = body[inner_length..][0..crypto.GCM_TAG],
    };
    _ = cb.SealGcm(&message);
    keys.sequence += 1;
    return header_length + total;
}

/// What a protected record held.
pub const Opened = struct {
    content_type: u8,
    content: []u8,
};

/// A protected record (header and all) opened in place; null when its
/// tag does not match or it holds no type - which ends the connection.
pub fn open(cb: *CryptoBase, keys: *TrafficKeys, record: []u8) ?Opened {
    if (record.len < header_length + crypto.GCM_TAG + 1) return null;
    if (record[0] != APPLICATION_DATA) return null;
    const body = record[header_length..];
    const inner_length = body.len - crypto.GCM_TAG;
    const nonce = nonceOf(keys);
    const message: crypto.GcmMessage = .{
        .key = &keys.key,
        .key_length = keys.key_length,
        .nonce = &nonce,
        .nonce_length = 12,
        .aad = record.ptr,
        .aad_length = header_length,
        .input = body.ptr,
        .output = body.ptr,
        .length = @intCast(inner_length),
        .tag = body[inner_length..][0..crypto.GCM_TAG],
    };
    if (cb.OpenGcm(&message) != crypto.CRYPTOERR_OK) return null;
    keys.sequence += 1;
    // The real type is the last byte that is not padding.
    var end = inner_length;
    while (end > 0 and body[end - 1] == 0) end -= 1;
    if (end == 0) return null;
    return .{ .content_type = body[end - 1], .content = body[0 .. end - 1] };
}

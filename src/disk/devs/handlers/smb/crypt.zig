// SPDX-License-Identifier: MIT
//! Encryption ([MS-SMB2] 2.2.41, 3.1.4.3): a message - or a compound of
//! them - sealed with AES-GCM behind a 52-byte transform header, which is
//! what goes on the wire in its place.
//!
//! The header holds the tag, the nonce, the message's length and the
//! session; the 32 bytes from the nonce on are the additional data the tag
//! covers, so none of them can be changed on the way. The client seals
//! with its client-to-server key and opens with the server-to-client one.
//!
//! **The nonce** is twelve bytes and never the same twice under a key: a
//! count of the messages sealed, then four random bytes the keys were made
//! with. A new logon makes new keys and a new count.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const smb = sdk.dos.smb;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const wire = @import("wire.zig");

/// The transform header's size: what goes in front of a sealed message.
pub const header_size: usize = 52;

/// Where the additional data begins (the nonce), and the flag that says
/// the message is encrypted.
const aad_at: usize = 20;
const flag_encrypted: u16 = 0x0001;

/// A session's two keys and the count its nonces are made from.
pub const Keys = struct {
    cipher: u16 = smb.SMB2_CIPHER_NONE,
    /// 16 or 32 bytes of each.
    length: u32 = 0,
    seal: [32]u8 = @splat(0),
    open: [32]u8 = @splat(0),
    count: u64 = 0,
    salt: [4]u8 = @splat(0),

    pub fn encrypts(keys: *const Keys) bool {
        return keys.cipher != smb.SMB2_CIPHER_NONE;
    }
};

/// The message in `frame[header_size..][0..length]` sealed in place, and
/// the transform header written in front of it: the frame to send.
///
/// INPUTS:
/// - `cb` - crypto.library.
/// - `keys` - the session's.
/// - `session_id` - the session it is sent in.
/// - `frame` - the header's room, then the message.
/// - `length` - the message's length.
pub fn seal(cb: *CryptoBase, keys: *Keys, session_id: u64, frame: []u8, length: usize) []u8 {
    const header = frame[0..header_size];
    @memcpy(header[0..4], &wire.transform_id);
    @memset(header[4..], 0);
    keys.count += 1;
    wire.put64(header, aad_at, keys.count);
    @memcpy(header[aad_at + 8 ..][0..4], &keys.salt);
    wire.put32(header, 36, @intCast(length));
    wire.put16(header, 42, flag_encrypted);
    wire.put64(header, 44, session_id);
    const body = frame[header_size..][0..length];
    var tag: [crypto.GCM_TAG]u8 = undefined;
    const message: crypto.GcmMessage = .{
        .key = &keys.seal,
        .key_length = keys.length,
        .nonce = header[aad_at..].ptr,
        .nonce_length = 12,
        .aad = header[aad_at..].ptr,
        .aad_length = header_size - aad_at,
        .input = body.ptr,
        .output = body.ptr,
        .length = @intCast(length),
        .tag = &tag,
    };
    _ = cb.SealGcm(&message);
    @memcpy(header[4..20], &tag);
    return frame[0 .. header_size + length];
}

/// The message inside a sealed frame, opened in place: null when it is no
/// transform for this session, or its tag is wrong - nothing of it is to
/// be believed then.
///
/// INPUTS:
/// - `cb` - crypto.library.
/// - `keys` - the session's.
/// - `session_id` - the session it must be for.
/// - `frame` - the frame as it came.
pub fn open(cb: *CryptoBase, keys: *const Keys, session_id: u64, frame: []u8) ?[]u8 {
    if (frame.len < header_size or !wire.same(frame[0..4], &wire.transform_id)) return null;
    const length = wire.u32At(frame, 36);
    if (wire.u16At(frame, 42) != flag_encrypted or wire.u64At(frame, 44) != session_id) return null;
    if (length > frame.len - header_size) return null;
    const body = frame[header_size..][0..length];
    var tag: [crypto.GCM_TAG]u8 = frame[4..20].*;
    const message: crypto.GcmMessage = .{
        .key = &keys.open,
        .key_length = keys.length,
        .nonce = frame[aad_at..].ptr,
        .nonce_length = 12,
        .aad = frame[aad_at..].ptr,
        .aad_length = header_size - aad_at,
        .input = body.ptr,
        .output = body.ptr,
        .length = length,
        .tag = &tag,
    };
    if (cb.OpenGcm(&message) != crypto.CRYPTOERR_OK) return null;
    return body;
}

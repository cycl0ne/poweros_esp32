// SPDX-License-Identifier: MIT
//! SSH's keys as files and text: the host key as ShellServer keeps it,
//! a public key as OpenSSH writes it, a line of `authorized_keys`, and the
//! fingerprint a client shows on its first connection.
//!
//! **The host key file** (`ENVARC:Sys/net/ssh_host_key`) is the Ed25519
//! seed and then its public half, 64 bytes, nothing else. **A public key
//! line** is `ssh-ed25519 <base64 of the key's blob> <comment>`, the blob
//! being SSH's string "ssh-ed25519" and the string of the 32 bytes (RFC
//! 8709). **A fingerprint** is `SHA256:` and the blob's SHA-256 in base64
//! without its padding, as OpenSSH shows it.

const crypto = @import("../../libs/crypto/crypto.zig");
const CryptoBase = @import("../../interface/crypto.zig").CryptoBase;

pub const key_type = "ssh-ed25519";
/// The blob of an Ed25519 public key: two strings.
pub const blob_bytes = 4 + key_type.len + 4 + 32;
/// The host key file's bytes.
pub const host_file_bytes = 64;
/// "SHA256:" and 43 characters.
pub const fingerprint_bytes = 7 + 43;

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// The base64 of `bytes` into `into`, padded with '=' when `pad`: its
/// length. `into` holds 4 for each 3 bytes, rounded up.
pub fn encode(bytes: []const u8, into: []u8, pad: bool) usize {
    var at: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) : (index += 3) {
        const left = bytes.len - index;
        const b0: u32 = bytes[index];
        const b1: u32 = if (left > 1) bytes[index + 1] else 0;
        const b2: u32 = if (left > 2) bytes[index + 2] else 0;
        const group = b0 << 16 | b1 << 8 | b2;
        const chars: usize = if (left >= 3) 4 else left + 1;
        for (0..4) |n| {
            if (n < chars) {
                into[at] = alphabet[(group >> @intCast(18 - 6 * n)) & 63];
                at += 1;
            } else if (pad) {
                into[at] = '=';
                at += 1;
            }
        }
    }
    return at;
}

fn value(char: u8) ?u32 {
    return switch (char) {
        'A'...'Z' => char - 'A',
        'a'...'z' => char - 'a' + 26,
        '0'...'9' => char - '0' + 52,
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

/// `text`, base64 with or without its padding, into `into`: the bytes,
/// or null when it is not base64 or does not fit.
pub fn decode(text: []const u8, into: []u8) ?[]u8 {
    var length = text.len;
    while (length > 0 and text[length - 1] == '=') length -= 1;
    var group: u32 = 0;
    var bits: u32 = 0;
    var at: usize = 0;
    for (text[0..length]) |char| {
        group = group << 6 | (value(char) orelse return null);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (at == into.len) return null;
            into[at] = @truncate(group >> @intCast(bits));
            at += 1;
        }
    }
    return into[0..at];
}

fn put32(into: []u8, value32: u32) void {
    into[0] = @truncate(value32 >> 24);
    into[1] = @truncate(value32 >> 16);
    into[2] = @truncate(value32 >> 8);
    into[3] = @truncate(value32);
}

/// The blob of the Ed25519 public key `public`.
pub fn blob(public: *const [32]u8) [blob_bytes]u8 {
    var made: [blob_bytes]u8 = undefined;
    put32(made[0..4], key_type.len);
    @memcpy(made[4..][0..key_type.len], key_type);
    put32(made[4 + key_type.len ..][0..4], 32);
    @memcpy(made[8 + key_type.len ..][0..32], public);
    return made;
}

/// The public key a blob holds, if it is an Ed25519 one.
pub fn fromBlob(bytes: []const u8) ?[32]u8 {
    if (bytes.len != blob_bytes) return null;
    const expected = blob(&@as([32]u8, bytes[8 + key_type.len ..][0..32].*));
    for (bytes, expected) |got, want| if (got != want) return null;
    return bytes[8 + key_type.len ..][0..32].*;
}

/// `public` as OpenSSH writes it, `ssh-ed25519 AAAA... <comment>` and a
/// line feed, into `into` (at least 81 bytes and the comment's): its
/// length.
pub fn publicLine(public: *const [32]u8, comment: []const u8, into: []u8) usize {
    var at: usize = 0;
    @memcpy(into[0..key_type.len], key_type);
    at += key_type.len;
    into[at] = ' ';
    at += 1;
    at += encode(&blob(public), into[at..], true);
    if (comment.len > 0) {
        into[at] = ' ';
        at += 1;
        @memcpy(into[at..][0..comment.len], comment);
        at += comment.len;
    }
    into[at] = '\n';
    return at + 1;
}

/// The fingerprint of `public`, `SHA256:...`, into `into`; false without
/// SHA-256.
pub fn fingerprint(cb: *CryptoBase, public: *const [32]u8, into: *[fingerprint_bytes]u8) bool {
    var context: crypto.HashContext = .{};
    if (cb.InitHash(&context, crypto.HASH_SHA256) != crypto.CRYPTOERR_OK) return false;
    const key_blob = blob(public);
    cb.UpdateHash(&context, &key_blob, key_blob.len);
    var digest: [32]u8 = undefined;
    _ = cb.FinishHash(&context, &digest);
    @memcpy(into[0..7], "SHA256:");
    _ = encode(&digest, into[7..], false);
    return true;
}

/// The Ed25519 key a line of `authorized_keys` names: `ssh-ed25519`, its
/// base64 and a comment, maybe behind options. Null for a comment, an
/// empty line, or a key of another type.
pub fn authorizedKey(line: []const u8) ?[32]u8 {
    var at: usize = 0;
    while (true) {
        while (at < line.len and (line[at] == ' ' or line[at] == '\t')) at += 1;
        if (at >= line.len or line[at] == '#') return null;
        const start = at;
        while (at < line.len and line[at] != ' ' and line[at] != '\t') at += 1;
        const word = line[start..at];
        if (!same(word, key_type)) continue;
        while (at < line.len and (line[at] == ' ' or line[at] == '\t')) at += 1;
        const text_start = at;
        while (at < line.len and line[at] != ' ' and line[at] != '\t' and line[at] != '\r' and line[at] != '\n') at += 1;
        var bytes: [blob_bytes + 3]u8 = undefined;
        const decoded = decode(line[text_start..at], &bytes) orelse return null;
        return fromBlob(decoded);
    }
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

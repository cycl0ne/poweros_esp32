// SPDX-License-Identifier: MIT
//! AES's modes of operation, as the cipher and GCM calls share them.
//!
//! The engine does one block with one key; a mode is what is done around
//! it. ECB is the engine alone. CBC exclusive-ors each plaintext block
//! with the ciphertext block before it (the IV for the first) on the way
//! in, and each decrypted block with the ciphertext before it on the way
//! out. CTR encrypts a counter block and exclusive-ors the result over
//! the data, so it encrypts and decrypts alike and takes any length; the
//! counter goes up by one, as a 128-bit number, per block. GCM counts in
//! the last 32 bits only (`increment32`).

const sdk = @import("sdk");
const crypto = sdk.crypto;

/// Whether `key_length` is one the engine takes: AES-128 or AES-256.
pub fn keyLength(key_length: u32) bool {
    return key_length == 16 or key_length == 32;
}

/// The counter block up by one, all 128 bits of it, most significant
/// byte first.
pub fn increment(counter: *[crypto.AES_BLOCK]u8) void {
    var index: usize = crypto.AES_BLOCK;
    while (index > 0) {
        index -= 1;
        counter[index] +%= 1;
        if (counter[index] != 0) return;
    }
}

/// The counter block's last 32 bits up by one, as GCM counts.
pub fn increment32(counter: *[crypto.AES_BLOCK]u8) void {
    var index: usize = crypto.AES_BLOCK;
    while (index > crypto.AES_BLOCK - 4) {
        index -= 1;
        counter[index] +%= 1;
        if (counter[index] != 0) return;
    }
}

/// `into` exclusive-ored with `with`.
pub fn xorBlock(into: *[crypto.AES_BLOCK]u8, with: *const [crypto.AES_BLOCK]u8) void {
    for (into, with) |*byte, other| byte.* ^= other;
}

/// `bytes` overwritten with zeroes in a way the compiler keeps.
pub fn wipe(bytes: []u8) void {
    for (bytes) |*byte| @as(*volatile u8, byte).* = 0;
}

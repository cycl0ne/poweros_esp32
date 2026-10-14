// SPDX-License-Identifier: MIT
//! The crypto table the radio's libraries are started with
//! (wpa_crypto_funcs_t, version 1): the hashes, ciphers and key
//! derivations they use for protected management frames and key
//! handling. Until the supplicant does WPA2, every entry refuses (-1).

/// ESP_WIFI_CRYPTO_VERSION.
pub const crypto_version: u32 = 1;

pub const CryptoFuncs = extern struct {
    size: u32,
    version: u32,
    hmac_sha256_vector: ?*const anyopaque,
    pbkdf2_sha1: ?*const anyopaque,
    aes_128_encrypt: ?*const anyopaque,
    aes_128_decrypt: ?*const anyopaque,
    omac1_aes_128: ?*const anyopaque,
    ccmp_decrypt: ?*const anyopaque,
    ccmp_encrypt: ?*const anyopaque,
    aes_gmac: ?*const anyopaque,
    sha256_vector: ?*const anyopaque,
    aes_wrap: ?*const anyopaque,
    aes_unwrap: ?*const anyopaque,
};

comptime {
    if (@sizeOf(usize) == 4 and @sizeOf(CryptoFuncs) != 52) @compileError("the crypto table is 13 words");
}

fn refuse() callconv(.c) c_int {
    return -1;
}

pub const funcs: CryptoFuncs = .{
    .size = @sizeOf(CryptoFuncs),
    .version = crypto_version,
    .hmac_sha256_vector = &refuse,
    .pbkdf2_sha1 = &refuse,
    .aes_128_encrypt = &refuse,
    .aes_128_decrypt = &refuse,
    .omac1_aes_128 = &refuse,
    .ccmp_decrypt = &refuse,
    .ccmp_encrypt = &refuse,
    .aes_gmac = &refuse,
    .sha256_vector = &refuse,
    .aes_wrap = &refuse,
    .aes_unwrap = &refuse,
};

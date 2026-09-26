// SPDX-License-Identifier: MIT
//! crypto.library's structures and constants: the hash, HMAC and cipher
//! contexts a caller keeps, the AES-GCM message, the numbers ModExp
//! takes, and the error codes. The calls are in `sdk.interface.crypto`.
//!
//! A context is the caller's: it lives wherever the caller puts it (on
//! the stack, in its own structure), holds the whole state of one
//! computation, and needs no freeing. Any number of them may be in use
//! at once, by any number of tasks; the library takes the chip's engine
//! for the length of one call and leaves nothing of a context in it. Its
//! fields are the library's to read and write - a caller only hands it
//! over.
//!
//! Each context starts with its size, which `.{}` fills in, and ends in
//! reserved bytes. The Init call refuses a context whose size is less
//! than the library's own idea of it, before writing anything, and a
//! later version that needs more of a context takes it from the
//! reserved bytes or from a size a new program declares - the calls stay
//! the same.
//!
//! Every byte string is in the order it has on the wire: a digest, a key,
//! an IV, and a number for ModExp, most significant byte first.

/// The library's name, for OpenLibrary.
pub const CRYPTONAME = "crypto.library";

// --- errors -------------------------------------------------------------------

/// What a call that can fail answers: 0, or one of these.
pub const CRYPTOERR_OK: i32 = 0;
/// An algorithm or a cipher mode the library does not have.
pub const CRYPTOERR_ALGORITHM: i32 = -1;
/// A key whose length the cipher does not take (AES: 16 or 32 bytes).
pub const CRYPTOERR_KEY: i32 = -2;
/// A length the call cannot take: not a whole number of blocks where it
/// has to be, a nonce of none, a number longer than the engine's.
pub const CRYPTOERR_LENGTH: i32 = -3;
/// OpenGcm: the tag does not match; nothing was written to the output.
pub const CRYPTOERR_TAG: i32 = -4;
/// ModExp: a modulus that is even, or less than 3.
pub const CRYPTOERR_NUMBER: i32 = -5;
/// An Init call: a context whose `size` is less than this version of
/// the library's; nothing was written to it.
pub const CRYPTOERR_CONTEXT: i32 = -6;

// --- hashes -------------------------------------------------------------------

/// The hash algorithms, for InitHash and InitHmac.
pub const HASH_SHA1: u32 = 1;
pub const HASH_SHA224: u32 = 2;
pub const HASH_SHA256: u32 = 3;
pub const HASH_SHA384: u32 = 4;
pub const HASH_SHA512: u32 = 5;

/// The longest digest there is, SHA-512's: a buffer this long takes any.
pub const DIGEST_MAX: u32 = 64;
/// The longest block there is, SHA-384's and SHA-512's.
pub const HASH_BLOCK_MAX: u32 = 128;

/// The bytes of an algorithm's digest, or 0 for one there is not.
pub inline fn digestLength(algorithm: u32) u32 {
    return switch (algorithm) {
        HASH_SHA1 => 20,
        HASH_SHA224 => 28,
        HASH_SHA256 => 32,
        HASH_SHA384 => 48,
        HASH_SHA512 => 64,
        else => 0,
    };
}

/// The bytes of an algorithm's block, or 0 for one there is not.
pub inline fn blockLength(algorithm: u32) u32 {
    return switch (algorithm) {
        HASH_SHA1, HASH_SHA224, HASH_SHA256 => 64,
        HASH_SHA384, HASH_SHA512 => 128,
        else => 0,
    };
}

/// One hash under way: InitHash, UpdateHash as often as there is data,
/// FinishHash. 256 bytes.
pub const HashContext = extern struct {
    /// The context's size in bytes, as the program was built with it.
    size: u32 = @sizeOf(HashContext),
    /// HASH_*; 0 until InitHash.
    algorithm: u32 = 0,
    /// Whether a block has gone through the engine yet: before the
    /// first, the engine starts from the algorithm's own initial state.
    started: u32 = 0,
    /// The bytes waiting in `buffer` for a whole block.
    buffered: u32 = 0,
    /// The bytes hashed so far, those in the buffer included.
    total: u64 align(4) = 0,
    /// The state between blocks, as the digest's bytes are laid out.
    state: [16]u32 = @splat(0),
    buffer: [HASH_BLOCK_MAX]u8 = @splat(0),
    reserved: [40]u8 = @splat(0),
};

/// One HMAC under way: InitHmac, UpdateHmac, FinishHmac. The inner hash,
/// and the outer one with the key's block already through it. 528 bytes.
pub const HmacContext = extern struct {
    /// The context's size in bytes, as the program was built with it.
    size: u32 = @sizeOf(HmacContext),
    reserved: [12]u8 = @splat(0),
    inner: HashContext = .{},
    outer: HashContext = .{},
};

// --- ciphers ------------------------------------------------------------------

/// AES's block, and what CBC's IV and CTR's counter block are.
pub const AES_BLOCK: u32 = 16;

/// The cipher modes, for InitCipher. ECB and CBC take whole blocks; CTR
/// takes any length and carries the rest of a block to the next call.
pub const CIPHER_AES_ECB: u32 = 1;
pub const CIPHER_AES_CBC: u32 = 2;
pub const CIPHER_AES_CTR: u32 = 3;
/// Or-ed into the mode: decrypt. CTR is the same both ways and ignores it.
pub const CIPHERF_DECRYPT: u32 = 1 << 16;

/// One cipher under way: InitCipher, then UpdateCipher over the data.
/// 128 bytes.
pub const CipherContext = extern struct {
    /// The context's size in bytes, as the program was built with it.
    size: u32 = @sizeOf(CipherContext),
    /// CIPHER_*, CIPHERF_DECRYPT or-ed in.
    mode: u32 = 0,
    /// 16 or 32.
    key_length: u32 = 0,
    key: [32]u8 = @splat(0),
    /// CBC: the last ciphertext block. CTR: the next counter block.
    chain: [AES_BLOCK]u8 = @splat(0),
    /// CTR: the key stream of the counter block last used, and how much
    /// of it is used up.
    stream: [AES_BLOCK]u8 = @splat(0),
    stream_used: u32 = AES_BLOCK,
    reserved: [48]u8 = @splat(0),
};

comptime {
    if (@sizeOf(HashContext) != 256 or @sizeOf(HmacContext) != 528 or @sizeOf(CipherContext) != 128) {
        @compileError("crypto.library: a context's size moved; it is part of the ABI");
    }
}

/// AES-GCM's tag: 16 bytes, always.
pub const GCM_TAG: u32 = 16;

/// One message for SealGcm or OpenGcm. SealGcm encrypts `input` into
/// `output` and writes the tag; OpenGcm checks the tag, and only then
/// decrypts `input` into `output`. `input` and `output` may be the same.
pub const GcmMessage = extern struct {
    key: [*]const u8,
    /// 16 or 32.
    key_length: u32,
    nonce: [*]const u8,
    /// 12 is what GCM is made for; any length but 0 is taken.
    nonce_length: u32,
    /// Authenticated and not encrypted: a header. Null when `aad_length`
    /// is 0.
    aad: ?[*]const u8 = null,
    aad_length: u32 = 0,
    input: ?[*]const u8 = null,
    output: ?[*]u8 = null,
    length: u32 = 0,
    /// SealGcm writes it, OpenGcm reads it.
    tag: *[GCM_TAG]u8,
};

// --- numbers ------------------------------------------------------------------

/// The longest number ModExp takes: 4096 bits.
pub const NUMBER_MAX: u32 = 512;

/// A non-negative number for ModExp: `length` bytes, most significant
/// first. Leading zero bytes are allowed.
pub const Number = extern struct {
    bytes: [*]const u8,
    length: u32,
};

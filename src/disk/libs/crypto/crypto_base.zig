// SPDX-License-Identifier: MIT
//! crypto.library's base: exec's Library header, the handles it keeps,
//! a lock for each of the chip's three engines, and the numbers ModExp
//! works in. There is one base, shared by every opener: what a caller's
//! computation is lives in the caller's context, not here.

const sdk = @import("sdk");
const exec = sdk.exec;
const crypto = sdk.crypto;
const ExecBase = sdk.interface.exec.ExecBase;

/// The words of the longest number ModExp takes.
pub const number_words = crypto.NUMBER_MAX / 4;

/// ModExp's working numbers, in the engine's form: 32-bit words, least
/// significant first.
pub const Numbers = extern struct {
    base_value: [number_words]u32 = @splat(0),
    exponent: [number_words]u32 = @splat(0),
    modulus: [number_words]u32 = @splat(0),
    /// R squared modulo the modulus, R being 2 to the engine's bits.
    rinv: [number_words]u32 = @splat(0),
    result: [number_words]u32 = @splat(0),
};

pub const CryptoBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    /// One caller at a time in each engine: a caller holds the lock for
    /// the blocks of one call, and leaves its state in its context.
    sha_lock: exec.SignalSemaphore = .{},
    aes_lock: exec.SignalSemaphore = .{},
    /// Held for all of ModExp: it guards `numbers` as well as the engine.
    rsa_lock: exec.SignalSemaphore = .{},
    /// The host's stand-in for the chip's generator (xorshift32).
    random_state: u32 = 0x2545_F491,
    numbers: Numbers = .{},
};

pub fn cryptoBase(lib: *exec.Library) *CryptoBase {
    return @fieldParentPtr("lib", lib);
}

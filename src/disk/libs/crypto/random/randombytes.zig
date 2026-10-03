// SPDX-License-Identifier: MIT
//! RandomBytes: bytes from the chip's random number generator.

const sdk = @import("sdk");
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _engine = @import("../engine/_engine.zig");

/// Fills a buffer with random bytes.
///
/// SYNOPSIS:
/// ```zig
/// fn RandomBytes(cb: *CryptoBase, buffer: *anyopaque, length: u32) void
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `buffer`: room for `length` bytes.
/// - `length`: any.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The bytes come straight from the chip's generator, which draws on the
/// noise of the SAR ADCs the kernel keeps sampling from boot to the end,
/// whether or not the radio runs (and on the radio's as well when it
/// does). They are fit for keys, nonces and IVs as they are, with no
/// generator of the library's own in between.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// The generator refills between reads in a few cycles; the reads are
/// spaced so that no word is read twice. `C:test/Crypto RANDOM` puts
/// 20000 of its bits through FIPS 140-2's monobit, poker and long-run
/// tests.
///
/// BUGS:
/// A driver that takes the SAR ADCs over for readings must leave them
/// sampling, or the generator is left with timing noise alone.
///
/// SEE ALSO:
/// `SealGcm`, `InitCipher`
///
/// EXAMPLES:
/// ```zig
/// var key: [32]u8 = undefined;
/// cb.RandomBytes(&key, key.len);
/// ```
pub fn RandomBytes(cb: *CryptoBase, buffer: *anyopaque, length: u32) void {
    const bytes: [*]u8 = @ptrCast(buffer);
    if (_engine.on_chip) return sdk.hardware.rng.fill(bytes[0..length]);
    // The host's tests: xorshift, which only has to be different bytes.
    for (bytes[0..length]) |*byte| {
        var state = cb.random_state;
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        cb.random_state = state;
        byte.* = @truncate(state);
    }
}

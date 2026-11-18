// SPDX-License-Identifier: MIT
//! RandomBytes: bytes from the chip's random number generator.

const builtin = @import("builtin");
const sdk = @import("sdk");
const CryptoBase = @import("../crypto_base.zig").CryptoBase;

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
/// The bytes come straight from the machine's generator, with no
/// generator of the library's own in between (sdk.hardware.rng):
/// - on the ESP32s, the chip's, which draws on the noise of the SAR ADCs
///   the kernel keeps sampling from boot to the end, whether or not the
///   radio runs (and on the radio's as well when it does);
/// - on the JH7110 (the VisionFive 2), its TRNG;
/// - on the BCM2711 and the BCM2712 (the Raspberry Pi CM4 and CM5), their
///   RNG200 (SINCE 2.13);
/// - on an x86-64 machine, the core's `rdrand`.
/// From any of these they are fit for keys, nonces and IVs as they are.
/// A machine without one - QEMU's virt - gets them from timing jitter,
/// which is not fit for keys: its kernel says so as it starts ("random
/// numbers from timing jitter").
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// On the ESP32s the generator refills between reads in a few cycles;
/// the reads are spaced so that no word is read twice. The RNG200 hands
/// out each word of its FIFO once, to whichever core reads it. `C:test/Crypto RANDOM` puts
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
    if (builtin.os.tag == .freestanding) return sdk.hardware.rng.fill(bytes[0..length]);
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

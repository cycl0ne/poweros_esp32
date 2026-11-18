// SPDX-License-Identifier: MIT
//! CryptoEngines: which of the library's work runs on hardware.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _engine = @import("_engine.zig");
const jh7110 = @import("jh7110.zig");

/// Says which work runs on hardware here - an engine of the chip's, or
/// the core's own instructions - and so which algorithms are the fast
/// ones.
///
/// SYNOPSIS:
/// ```zig
/// fn CryptoEngines(cb: *CryptoBase) u32
/// ```
///
/// SINCE: 2.13. LVO -136.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// CRYPTOENG_* bits: CRYPTOENG_AES for AES's rounds, CRYPTOENG_GHASH for
/// GCM's multiplications, CRYPTOENG_SHA256 for SHA-1, SHA-224 and
/// SHA-256, CRYPTOENG_SHA512 for SHA-384 and SHA-512. A bit that is clear
/// is software, or the core's vector registers.
///
/// BEHAVIOR:
/// The answer is the machine's and the same for every call: the S3's
/// engines do AES and SHA; the JH7110's (VisionFive 2) AES, all of GCM
/// and SHA-2; an x86-64 core AES with AES-NI, GHASH with PCLMULQDQ and
/// SHA-256 with the SHA extensions; an AArch64 core with the crypto
/// extension (the CM5's Cortex-A76) AES with AESE and AESD, GHASH with
/// PMULL and SHA-256 with its SHA-1 and SHA-256 instructions. An AArch64
/// core without it (the CM4's Cortex-A72) has none of the bits: its AES
/// runs on the vector registers, constant-time but not fast, and its
/// GHASH and SHA in software. ChaCha20 and Poly1305 are software
/// everywhere - on the vector registers where there are some - and have
/// no bit.
///
/// CONTEXT:
/// - Waits: on the VisionFive 2 the first call that asks sets up the
///   JH7110's engine, as the first that uses it would, and may wait for
///   it.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// TLS and SSH ask it to put their ciphers in order: ChaCha20-Poly1305
/// first where CRYPTOENG_AES is clear, AES-GCM first where it is set.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SealChaChaPoly`, `SealGcm`
///
/// EXAMPLES:
/// ```zig
/// const fast_aes = cb.CryptoEngines() & crypto.CRYPTOENG_AES != 0;
/// ```
pub fn CryptoEngines(cb: *CryptoBase) u32 {
    var engines: u32 = 0;
    if (_engine.on_chip) engines |= crypto.CRYPTOENG_AES | crypto.CRYPTOENG_SHA256 | crypto.CRYPTOENG_SHA512;
    if (jh7110.take(cb)) |state| {
        jh7110.give(cb, state);
        engines |= crypto.CRYPTOENG_AES | crypto.CRYPTOENG_GHASH | crypto.CRYPTOENG_SHA256 | crypto.CRYPTOENG_SHA512;
    }
    if (cb.core_aes) engines |= crypto.CRYPTOENG_AES;
    if (cb.core_clmul) engines |= crypto.CRYPTOENG_GHASH;
    if (cb.core_sha) engines |= crypto.CRYPTOENG_SHA256;
    return engines;
}

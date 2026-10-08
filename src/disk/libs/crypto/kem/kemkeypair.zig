// SPDX-License-Identifier: MIT
//! KemKeyPair: a key pair for a key encapsulation mechanism.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _base = @import("../crypto_base.zig");
const _cipher = @import("../cipher/_cipher.zig");
const _kem = @import("_kem.zig");

/// Makes a key pair for a key encapsulation mechanism: a public key that
/// others encapsulate secrets to, and the private key that takes them out
/// again.
///
/// SYNOPSIS:
/// ```zig
/// fn KemKeyPair(cb: *CryptoBase, kem: u32, public_key: *anyopaque, private_key: *anyopaque) i32
/// ```
///
/// SINCE: 1.2. LVO -92.
///
/// INPUTS:
/// - `kem`: KEM_MLKEM768.
/// - `public_key`: room for MLKEM768_PUBLIC bytes (1184).
/// - `private_key`: room for MLKEM768_PRIVATE bytes (2400).
///
/// RESULT:
/// CRYPTOERR_OK, with both keys written; CRYPTOERR_ALGORITHM for another
/// `kem`, with nothing written.
///
/// BEHAVIOR:
/// ML-KEM-768 (FIPS 203): the seeds d and z come from RandomBytes, and
/// the keys from them as ML-KEM.KeyGen_internal makes them - the public
/// key the encoded t̂ and ρ, the private key K-PKE's own, the public key,
/// its SHA3-256 and z.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do; it takes about 4 KiB of the caller's stack.
///
/// OWNERSHIP:
/// Both keys are the caller's; the private key is to be overwritten once
/// it is done with.
///
/// NOTES:
/// The keys are as good as `RandomBytes`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Encapsulate`, `Decapsulate`, `RandomBytes`
///
/// EXAMPLES:
/// ```zig
/// var public_key: [crypto.MLKEM768_PUBLIC]u8 = undefined;
/// var private_key: [crypto.MLKEM768_PRIVATE]u8 = undefined;
/// _ = cb.KemKeyPair(crypto.KEM_MLKEM768, &public_key, &private_key);
/// ```
pub fn KemKeyPair(cb: *CryptoBase, kem: u32, public_key: *anyopaque, private_key: *anyopaque) i32 {
    if (kem != crypto.KEM_MLKEM768) return crypto.CRYPTOERR_ALGORITHM;
    var seeds: [64]u8 = undefined;
    _base.iface(cb).RandomBytes(&seeds, seeds.len);
    const public_bytes: *[_kem.public_bytes]u8 = @ptrCast(public_key);
    const private_bytes: *[_kem.private_bytes]u8 = @ptrCast(private_key);
    _kem.keyGen(seeds[0..32], seeds[32..64], public_bytes, private_bytes);
    _cipher.wipe(&seeds);
    return crypto.CRYPTOERR_OK;
}

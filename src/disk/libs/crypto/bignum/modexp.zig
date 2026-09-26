// SPDX-License-Identifier: MIT
//! ModExp: modular exponentiation, what RSA and Diffie-Hellman are made
//! of, on the RSA engine.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Number = crypto.Number;
const _base = @import("../crypto_base.zig");
const CryptoBase = _base.CryptoBase;
const _bignum = @import("_bignum.zig");
const rsa = @import("../engine/rsa.zig");

/// Raises a number to a power modulo another.
///
/// SYNOPSIS:
/// ```zig
/// fn ModExp(cb: *CryptoBase, result: *anyopaque, base_value: *const Number, exponent: *const Number, modulus: *const Number) i32
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `result`: room for as many bytes as `modulus.length`.
/// - `base_value`: any number of up to NUMBER_MAX significant bytes; it
///   need not be less than the modulus.
/// - `exponent`: no longer than the modulus, counted in 32-bit words:
///   the engine's operands are all as long as the modulus.
/// - `modulus`: odd, at least 3, of up to NUMBER_MAX (512) significant
///   bytes - 4096 bits.
///
/// RESULT:
/// CRYPTOERR_OK, with `base_value ^ exponent mod modulus` in `result`,
/// most significant byte first and as long as the modulus as given,
/// leading zeroes included. CRYPTOERR_NUMBER for an even modulus or one
/// less than 3; CRYPTOERR_LENGTH for a number longer than it may be.
/// Nothing is written on an error.
///
/// BEHAVIOR:
/// The numbers are big-endian byte strings, as RSA and Diffie-Hellman
/// send them (PKCS #1's I2OSP), and are only read. The work is done
/// in the engine on operands as long as the modulus, in 32-bit words;
/// the library works out the engine's two constants for the modulus and
/// first reduces a base that is not less than it. An exponent of 0
/// answers 1.
///
/// The engine runs in its constant-time mode: each exponent bit costs the
/// same, 0 or 1. It starts from the exponent's highest 1 bit, which gives
/// away only how long the exponent is - a public exponent of 17 bits
/// takes 17 steps, a private one is as long as its modulus in any case.
///
/// CONTEXT:
/// - Waits: yes, for the RSA engine while another task has it; the
///   engine is held for the whole call.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The numbers' copies in the library and the
/// exponent in the engine are cleared before the call returns.
///
/// NOTES:
/// The constants are worked out in software on every call, bit by bit:
/// a 2048-bit modulus costs 4096 doubling steps before the engine
/// starts. A caller who signs many times with one key pays that each
/// time.
///
/// BUGS:
/// A private-key operation is not blinded: the engine's constant time is
/// what stands against timing, and nothing stands against power analysis.
///
/// SEE ALSO:
/// `RandomBytes`
///
/// EXAMPLES:
/// ```zig
/// // An RSA signature checked: signature ^ e mod n.
/// var decoded: [256]u8 = undefined;
/// const s: crypto.Number = .{ .bytes = &signature, .length = 256 };
/// const e: crypto.Number = .{ .bytes = &.{ 1, 0, 1 }, .length = 3 };
/// const n: crypto.Number = .{ .bytes = &modulus, .length = 256 };
/// if (cb.ModExp(&decoded, &s, &e, &n) != crypto.CRYPTOERR_OK) return error.Key;
/// ```
pub fn ModExp(cb: *CryptoBase, result: *anyopaque, base_value: *const Number, exponent: *const Number, modulus: *const Number) i32 {
    const modulus_bytes = _bignum.significantBytes(modulus);
    if (modulus_bytes > crypto.NUMBER_MAX) return crypto.CRYPTOERR_LENGTH;
    if (modulus_bytes == 0 or modulus.bytes[modulus.length - 1] & 1 == 0) return crypto.CRYPTOERR_NUMBER;
    if (modulus_bytes == 1 and modulus.bytes[modulus.length - 1] < 3) return crypto.CRYPTOERR_NUMBER;
    const words = (modulus_bytes + 3) / 4;
    if (_bignum.significantBytes(exponent) > 4 * words) return crypto.CRYPTOERR_LENGTH;
    const base_bytes = _bignum.significantBytes(base_value);
    if (base_bytes > crypto.NUMBER_MAX) return crypto.CRYPTOERR_LENGTH;

    const sys = cb.sys_base;
    sys.ObtainSemaphore(&cb.rsa_lock);
    defer sys.ReleaseSemaphore(&cb.rsa_lock);
    const numbers = &cb.numbers;
    defer wipe(numbers);

    const m = numbers.modulus[0..words];
    _bignum.load(m, modulus);
    _bignum.load(numbers.exponent[0..words], exponent);
    // The base as it came, in `result` for now, then reduced.
    const base_words = @max((base_bytes + 3) / 4, 1);
    _bignum.load(numbers.result[0..base_words], base_value);
    _bignum.reduce(numbers.base_value[0..words], numbers.result[0..base_words], m);

    const exponent_bits = _bignum.bitLength(numbers.exponent[0..words]);
    if (exponent_bits == 0) {
        for (numbers.result[0..words]) |*word| word.* = 0;
        numbers.result[0] = 1;
    } else {
        _bignum.rSquared(numbers.rinv[0..words], m);
        rsa.modExp(numbers, words, _bignum.mPrime(m[0]), exponent_bits);
    }
    _bignum.store(@ptrCast(result), modulus.length, numbers.result[0..words]);
    return crypto.CRYPTOERR_OK;
}

fn wipe(numbers: *_base.Numbers) void {
    const bytes: [*]volatile u8 = @ptrCast(numbers);
    for (0..@sizeOf(_base.Numbers)) |index| bytes[index] = 0;
}

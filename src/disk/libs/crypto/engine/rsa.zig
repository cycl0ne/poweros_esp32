// SPDX-License-Identifier: MIT
//! The RSA engine's modular exponentiation: Z = X ^ Y mod M, on numbers
//! of up to 128 words (4096 bits), in Montgomery form.
//!
//! The engine takes the modulus M, the base X (already less than M), the
//! exponent Y, R^2 mod M in Z (R being 2 to the operands' bits) and
//! M' = -M^-1 mod 2^32, all four operands of the same number of words;
//! the caller works the last two out (`../bignum/_bignum.zig`). It
//! answers in Z.
//!
//! Its constant-time option is on: every exponent bit costs the same,
//! whether it is 0 or 1. Its search option is on too, and starts at the
//! exponent's highest 1 bit instead of at the top of the operand, which
//! gives away only how long the exponent is. A public exponent of 17 bits
//! takes 17 steps rather than 4096, and a private one is as long as its
//! modulus anyway.
//!
//! The caller holds the base's `rsa_lock` for the whole of ModExp, since
//! the numbers are the base's as well; this file takes no lock.

const sdk = @import("sdk");
const hardware = sdk.hardware;
const reg = hardware.mmio.reg;
const _base = @import("../crypto_base.zig");
const Numbers = _base.Numbers;
const _engine = @import("_engine.zig");
const soft = @import("soft_rsa.zig");

const m_mem = hardware.map.RSA + 0x000;
const z_mem = hardware.map.RSA + 0x200;
const y_mem = hardware.map.RSA + 0x400;
const x_mem = hardware.map.RSA + 0x600;
const m_prime = hardware.map.RSA + 0x800;
const length = hardware.map.RSA + 0x804;
const modexp_start = hardware.map.RSA + 0x80C;
const query_interrupt = hardware.map.RSA + 0x818;
const clear_interrupt = hardware.map.RSA + 0x81C;
const constant_time = hardware.map.RSA + 0x820;
const search_open = hardware.map.RSA + 0x824;
const search_pos = hardware.map.RSA + 0x828;
const interrupt_enable = hardware.map.RSA + 0x82C;

/// `numbers.result` = base ^ exponent mod modulus, each `words` long.
/// `exponent_bits`: the exponent's length in bits, at least 1.
pub fn modExp(numbers: *Numbers, words: u32, mprime: u32, exponent_bits: u32) void {
    if (!_engine.on_chip) return soft.modExp(numbers, words, mprime, exponent_bits);
    reg(interrupt_enable).* = 0;
    reg(length).* = words - 1;
    for (0..words) |index| {
        reg(x_mem + 4 * index).* = numbers.base_value[index];
        reg(y_mem + 4 * index).* = numbers.exponent[index];
        reg(m_mem + 4 * index).* = numbers.modulus[index];
        reg(z_mem + 4 * index).* = numbers.rinv[index];
    }
    reg(m_prime).* = mprime;
    reg(constant_time).* = 1;
    reg(search_open).* = 1;
    reg(search_pos).* = exponent_bits - 1;
    reg(clear_interrupt).* = 1;
    reg(modexp_start).* = 1;
    while (reg(query_interrupt).* == 0) {}
    reg(clear_interrupt).* = 1;
    reg(search_open).* = 0;
    for (0..words) |index| {
        numbers.result[index] = reg(z_mem + 4 * index).*;
        // The exponent may be a secret: not left in the engine.
        reg(y_mem + 4 * index).* = 0;
    }
}

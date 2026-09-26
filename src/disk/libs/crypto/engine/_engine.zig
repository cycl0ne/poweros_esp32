// SPDX-License-Identifier: MIT
//! The chip's crypto engines, and what stands in for them on the host.
//!
//! Three engines do the work: SHA (`sha.zig`), AES (`aes.zig`) and RSA's
//! big-number unit (`rsa.zig`). Each is fed by the CPU, a block or a
//! number at a time through its registers, and each has a lock in the
//! base, which a call holds while it has the engine. The chaining a mode
//! needs - CBC, CTR, GCM, a hash's padding, HMAC - is the calls' own, on
//! top of these.
//!
//! On the host, where the tests run, there is no engine: each file hands
//! the same work to a software model of it (`soft_*.zig`), with the same
//! inputs and the same state layout, so everything above the engine is
//! the code the chip runs.
//!
//! `start` gives the engines their clocks and takes them out of reset
//! when the library is made; `stop` turns them off at its expunge.

const builtin = @import("builtin");
const sdk = @import("sdk");
const hardware = sdk.hardware;
const system = hardware.system;
const reg = hardware.mmio.reg;

/// Whether this is the chip, with engines, or the host, without.
pub const on_chip = builtin.cpu.arch == .xtensa;

/// SYSTEM's RSA memory power control: RSA_MEM_PD [0].
const rsa_pd_ctrl = hardware.map.SYSTEM + 0x40;
const rsa_mem_pd: u32 = 1 << 0;
/// Nonzero once the RSA engine has cleared its memory after power-up.
const rsa_query_clean = hardware.map.RSA + 0x808;

/// The engines clocked, out of reset, and the RSA engine's memory
/// powered up and cleared.
pub fn start() void {
    if (!on_chip) return;
    system.enable(.crypto_aes);
    system.enable(.crypto_sha);
    system.enable(.crypto_rsa);
    system.releaseReset(.crypto_ds);
    system.releaseReset(.crypto_hmac);
    reg(rsa_pd_ctrl).* &= ~rsa_mem_pd;
    while (reg(rsa_query_clean).* == 0) {}
}

/// The engines stopped: in reset, their clocks off, RSA's memory powered
/// down.
pub fn stop() void {
    if (!on_chip) return;
    reg(rsa_pd_ctrl).* |= rsa_mem_pd;
    system.holdInReset(.crypto_rsa);
    system.holdInReset(.crypto_sha);
    system.holdInReset(.crypto_aes);
    system.clockOff(.crypto_rsa);
    system.clockOff(.crypto_sha);
    system.clockOff(.crypto_aes);
}

/// Four bytes as the chip loads them, least significant first: how a
/// byte string goes into an engine's 32-bit registers.
pub inline fn loadLittle(bytes: [*]const u8) u32 {
    return @as(u32, bytes[0]) | @as(u32, bytes[1]) << 8 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 24;
}

/// A register's word back into four bytes, least significant first.
pub inline fn storeLittle(bytes: [*]u8, word: u32) void {
    bytes[0] = @truncate(word);
    bytes[1] = @truncate(word >> 8);
    bytes[2] = @truncate(word >> 16);
    bytes[3] = @truncate(word >> 24);
}

/// Four bytes, most significant first.
pub inline fn loadBig(bytes: [*]const u8) u32 {
    return @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | @as(u32, bytes[3]);
}

/// A word into four bytes, most significant first.
pub inline fn storeBig(bytes: [*]u8, word: u32) void {
    bytes[0] = @truncate(word >> 24);
    bytes[1] = @truncate(word >> 16);
    bytes[2] = @truncate(word >> 8);
    bytes[3] = @truncate(word);
}

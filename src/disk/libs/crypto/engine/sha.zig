// SPDX-License-Identifier: MIT
//! The SHA engine: SHA-1, SHA-224, SHA-256, SHA-384 and SHA-512 over
//! whole blocks, fed by the CPU.
//!
//! A block is written into the engine's message registers and started:
//! with START for a hash's first block, which begins from the
//! algorithm's own initial state, or with CONTINUE, which goes on from
//! the state in the hash registers. The engine lets its state be written
//! back as well as read, so a hash does not keep the engine between
//! calls: `run` puts the caller's state in, runs its blocks, and takes the
//! state out again, and any number of hashes take turns. The state is
//! kept exactly as the registers hold it, which is the digest's own byte
//! order - the finished digest is its first bytes.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const hardware = sdk.hardware;
const reg = hardware.mmio.reg;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _engine = @import("_engine.zig");
const soft = @import("soft_sha.zig");

const mode = hardware.map.SHA + 0x00;
const start = hardware.map.SHA + 0x10;
const @"continue" = hardware.map.SHA + 0x14;
const busy = hardware.map.SHA + 0x18;
const h_mem = hardware.map.SHA + 0x40;
const m_mem = hardware.map.SHA + 0x80;

/// The engine's number for an algorithm.
fn engineMode(algorithm: u32) u32 {
    return switch (algorithm) {
        crypto.HASH_SHA1 => 0,
        crypto.HASH_SHA224 => 1,
        crypto.HASH_SHA256 => 2,
        crypto.HASH_SHA384 => 3,
        else => 4,
    };
}

/// The words of state an algorithm keeps: SHA-1 five, SHA-224 and
/// SHA-256 eight, SHA-384 and SHA-512 sixteen.
pub fn stateWords(algorithm: u32) u32 {
    return switch (algorithm) {
        crypto.HASH_SHA1 => 5,
        crypto.HASH_SHA224, crypto.HASH_SHA256 => 8,
        else => 16,
    };
}

/// `blocks` whole blocks of `data` through the hash whose state is
/// `state`. `first`: the hash has had no block yet, and starts from the
/// algorithm's initial state rather than from `state`.
pub fn run(cb: *CryptoBase, algorithm: u32, state: *[16]u32, first: bool, data: [*]const u8, blocks: u32) void {
    if (!_engine.on_chip) return soft.run(algorithm, state, first, data, blocks);
    if (blocks == 0) return;
    const sys = cb.sys_base;
    const block_words = crypto.blockLength(algorithm) / 4;
    const state_words = stateWords(algorithm);
    sys.ObtainSemaphore(&cb.sha_lock);
    defer sys.ReleaseSemaphore(&cb.sha_lock);
    while (reg(busy).* != 0) {}
    reg(mode).* = engineMode(algorithm);
    if (!first) {
        for (0..state_words) |index| reg(h_mem + 4 * index).* = state[index];
    }
    var at = data;
    for (0..blocks) |block| {
        while (reg(busy).* != 0) {}
        for (0..block_words) |index| reg(m_mem + 4 * index).* = _engine.loadLittle(at + 4 * index);
        reg(if (first and block == 0) start else @"continue").* = 1;
        at += 4 * block_words;
    }
    while (reg(busy).* != 0) {}
    for (0..state_words) |index| state[index] = reg(h_mem + 4 * index).*;
}

// SPDX-License-Identifier: MIT
//! The AES engine: one 16-byte block at a time, encrypted or decrypted
//! with a 128- or 256-bit key, fed by the CPU.
//!
//! A caller begins a session, which takes the engine and loads the key
//! and the direction once; runs its blocks through it; and ends it, which
//! lets the engine go. The engine holds nothing between sessions that
//! the next one does not overwrite, so a mode's chaining - CBC's previous
//! block, CTR's counter, GCM's hash - is the caller's, in its context,
//! and any number of ciphers take turns.
//!
//! The engine's rounds take the same time whatever the key and the data,
//! which a table-driven AES in software does not.
//!
//! On an x86-64 core with AES-NI (`cb.core_aes`) the session is the
//! core's round keys instead (`x64.zig`); a caller with a run of blocks
//! takes them from the session (`core`) and goes through them many
//! blocks at a time.

const sdk = @import("sdk");
const hardware = sdk.hardware;
const reg = hardware.mmio.reg;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _engine = @import("_engine.zig");
const soft = @import("soft_aes.zig");
const x64 = @import("x64.zig");

const key_mem = hardware.map.AES + 0x00;
const text_in = hardware.map.AES + 0x20;
const text_out = hardware.map.AES + 0x30;
const mode = hardware.map.AES + 0x40;
const trigger = hardware.map.AES + 0x48;
const state = hardware.map.AES + 0x4C;
const dma_enable = hardware.map.AES + 0x90;

/// The engine, taken for one caller's blocks.
pub const Session = struct {
    cb: *CryptoBase,
    decrypt: bool,
    /// The software's expanded key; the chip keeps its own.
    schedule: if (_engine.on_chip) void else soft.Schedule,
    /// The x86-64 core's round keys, where it has AES-NI.
    keys: if (x64.built) x64.Keys else void,

    /// The core's round keys, made for this session's direction, where
    /// the blocks go through AES-NI; null elsewhere.
    pub fn core(session: *const Session) ?*const x64.Keys {
        if (x64.built and session.cb.core_aes) return &session.keys;
        return null;
    }

    /// One block through the engine. `input` and `output` may be the
    /// same block.
    pub fn block(session: *Session, input: *const [16]u8, output: *[16]u8) void {
        if (x64.built and session.cb.core_aes) {
            const given = x64.load(input);
            x64.store(output, if (session.decrypt) x64.decrypt(&session.keys, given) else x64.encrypt(&session.keys, given));
            return;
        }
        if (!_engine.on_chip) {
            if (session.decrypt) soft.decrypt(&session.schedule, input, output) else soft.encrypt(&session.schedule, input, output);
            return;
        }
        for (0..4) |index| reg(text_in + 4 * index).* = _engine.loadLittle(input[4 * index ..].ptr);
        reg(trigger).* = 1;
        while (reg(state).* != 0) {}
        for (0..4) |index| _engine.storeLittle(output[4 * index ..].ptr, reg(text_out + 4 * index).*);
    }

    /// The engine let go, and the key in it overwritten.
    pub fn end(session: *Session) void {
        if (x64.built and session.cb.core_aes) {
            x64.wipe(&session.keys);
            return;
        }
        if (!_engine.on_chip) {
            session.schedule = .{};
            return;
        }
        for (0..8) |index| reg(key_mem + 4 * index).* = 0;
        const sys = session.cb.sys_base;
        sys.ReleaseSemaphore(&session.cb.aes_lock);
    }
};

/// The engine taken, with `key` (16 or 32 bytes, checked by the caller)
/// loaded for `decrypt` or for encrypting. Ended with `Session.end`.
pub fn begin(cb: *CryptoBase, key: [*]const u8, key_length: u32, decrypt: bool) Session {
    if (x64.built) {
        var session: Session = .{ .cb = cb, .decrypt = decrypt, .schedule = .{}, .keys = .{} };
        if (cb.core_aes) x64.expand(&session.keys, key, key_length, decrypt) else soft.expand(&session.schedule, key, key_length);
        return session;
    }
    if (!_engine.on_chip) {
        var session: Session = .{ .cb = cb, .decrypt = decrypt, .schedule = .{}, .keys = {} };
        soft.expand(&session.schedule, key, key_length);
        return session;
    }
    const sys = cb.sys_base;
    sys.ObtainSemaphore(&cb.aes_lock);
    reg(dma_enable).* = 0;
    for (0..key_length / 4) |index| reg(key_mem + 4 * index).* = _engine.loadLittle(key + 4 * index);
    // Encrypt 0 (128) or 2 (256); decrypt adds 4.
    reg(mode).* = (if (decrypt) @as(u32, 4) else 0) + key_length / 8 - 2;
    return .{ .cb = cb, .decrypt = decrypt, .schedule = {}, .keys = {} };
}

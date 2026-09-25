// SPDX-License-Identifier: MIT
//! Initial sequence numbers after RFC 6528: a clock that ticks every
//! 4 microseconds, plus a keyed hash of the connection's addresses and
//! ports, so the numbers of one connection tell nothing about another's
//! and a stranger cannot guess where a new connection starts.
//!
//! The hash is SipHash-2-4, written here, keyed with 128 bits the stack
//! takes from the chip's random number generator when it starts.

const sdk = @import("sdk");
const builtin = @import("builtin");
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _timer = @import("../timer/_timer.zig");

/// The key made, when the stack starts. On the host, where there is no
/// generator, a fixed one: the tests want the same numbers every run.
pub fn makeKey(stack: *StackBase) void {
    if (builtin.cpu.arch == .xtensa) {
        sdk.hardware.rng.fill(&stack.isn_key);
    } else {
        for (&stack.isn_key, 0..) |*byte, index| byte.* = @truncate(index * 29 + 7);
    }
}

/// The initial sequence number for a connection from `local` to `remote`.
pub fn initialSequence(stack: *StackBase, local_address: u32, local_port: u16, remote_address: u32, remote_port: u16) u32 {
    var message: [12]u8 = undefined;
    put32(message[0..4], local_address);
    put32(message[4..8], remote_address);
    message[8] = @truncate(local_port >> 8);
    message[9] = @truncate(local_port);
    message[10] = @truncate(remote_port >> 8);
    message[11] = @truncate(remote_port);
    const clock: u32 = @truncate(_timer.systemTime(stack) / 4);
    return clock +% @as(u32, @truncate(sipHash(&stack.isn_key, &message)));
}

fn put32(into: *[4]u8, value: u32) void {
    into.* = .{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
}

fn load64(bytes: []const u8) u64 {
    var value: u64 = 0;
    for (bytes, 0..) |byte, index| value |= @as(u64, byte) << @intCast(8 * index);
    return value;
}

const Sip = struct {
    v0: u64,
    v1: u64,
    v2: u64,
    v3: u64,

    fn round(sip: *Sip) void {
        sip.v0 +%= sip.v1;
        sip.v1 = rotate(sip.v1, 13) ^ sip.v0;
        sip.v0 = rotate(sip.v0, 32);
        sip.v2 +%= sip.v3;
        sip.v3 = rotate(sip.v3, 16) ^ sip.v2;
        sip.v0 +%= sip.v3;
        sip.v3 = rotate(sip.v3, 21) ^ sip.v0;
        sip.v2 +%= sip.v1;
        sip.v1 = rotate(sip.v1, 17) ^ sip.v2;
        sip.v2 = rotate(sip.v2, 32);
    }

    fn compress(sip: *Sip, block: u64) void {
        sip.v3 ^= block;
        sip.round();
        sip.round();
        sip.v0 ^= block;
    }
};

fn rotate(value: u64, bits: u6) u64 {
    return (value << bits) | (value >> @intCast(@as(u7, 64) - bits));
}

/// SipHash-2-4 of `message` under `key`.
pub fn sipHash(key: *const [16]u8, message: []const u8) u64 {
    const k0 = load64(key[0..8]);
    const k1 = load64(key[8..16]);
    var sip: Sip = .{
        .v0 = k0 ^ 0x736f6d6570736575,
        .v1 = k1 ^ 0x646f72616e646f6d,
        .v2 = k0 ^ 0x6c7967656e657261,
        .v3 = k1 ^ 0x7465646279746573,
    };
    var at: usize = 0;
    while (at + 8 <= message.len) : (at += 8) sip.compress(load64(message[at..][0..8]));
    const last = @as(u64, @truncate(message.len)) << 56 | load64(message[at..]);
    sip.compress(last);
    sip.v2 ^= 0xFF;
    for (0..4) |_| sip.round();
    return sip.v0 ^ sip.v1 ^ sip.v2 ^ sip.v3;
}

// SPDX-License-Identifier: MIT
//! Random bits, under the ESP32s' name: **from timing jitter, not from a
//! hardware source** - QEMU's virt offers its randomness only as a virtio
//! device, and the BCM2712's generator is not driven yet. Jitter is had by
//! timing a short loop on the cycle counter against the system counter
//! many times and mixing what it saw into a running state. It is no
//! stronger than that jitter, which on an emulator may be little: good
//! enough for sequence numbers and ids, **not** for keys.
//!
//! Every program built with the SDK has a copy of this code, the kernel's
//! is only one; each keeps its own state.

const cpu = @import("cpu.zig");

var state: u64 = 0x9E37_79B9_7F4A_7C15;

/// SplitMix64's finaliser: every input bit reaches every output bit.
fn mix(value: u64) u64 {
    var z = value;
    z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
    return z ^ (z >> 31);
}

/// 32 bits from timing jitter.
fn jitter() u32 {
    var round: u32 = 0;
    while (round < 32) : (round += 1) {
        const before = cpu.cycles();
        var spin: u32 = 0;
        while (spin < 16 + (state & 15)) : (spin += 1) asm volatile ("nop");
        state = mix(state ^ (cpu.cycles() -% before) ^ (cpu.time() << 32) ^ cpu.time());
    }
    return @truncate(state >> 16);
}

/// 32 random bits.
pub fn read() u32 {
    return jitter();
}

/// `into` filled with random bytes.
pub fn fill(into: []u8) void {
    var left = into;
    while (left.len != 0) {
        const word = jitter();
        const bytes: []const u8 = @ptrCast(&word);
        const length = @min(left.len, bytes.len);
        @memcpy(left[0..length], bytes[0..length]);
        left = left[length..];
    }
}

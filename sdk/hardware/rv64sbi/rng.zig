// SPDX-License-Identifier: MIT
//! Random bits, under the ESP32s' name - **from timing jitter, not from
//! a hardware source.** Neither machine has one the kernel drives yet:
//! QEMU's virt offers its randomness only as a virtio device, and the
//! JH7110's TRNG is the VisionFive 2 board's to add. Until then each read
//! times a short loop on the cycle counter against `time` many times and
//! mixes what it saw into a running state. It is no stronger than that
//! jitter, which on an emulator may be little: good enough for sequence
//! numbers and ids, **not** for keys.

const cpu = @import("cpu.zig");

var state: u64 = 0x9E37_79B9_7F4A_7C15;

/// SplitMix64's finaliser: every input bit reaches every output bit.
fn mix(value: u64) u64 {
    var z = value;
    z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
    return z ^ (z >> 31);
}

/// 32 random bits.
pub fn read() u32 {
    var round: u32 = 0;
    while (round < 32) : (round += 1) {
        const before = cpu.cycles();
        var spin: u32 = 0;
        while (spin < 16 + (state & 15)) : (spin += 1) asm volatile ("nop");
        state = mix(state ^ (cpu.cycles() -% before) ^ (cpu.time() << 32));
    }
    return @truncate(state >> 16);
}

/// `into` filled with random bytes.
pub fn fill(into: []u8) void {
    var word: u32 = 0;
    for (into, 0..) |*byte, index| {
        if (index % 4 == 0) word = read();
        byte.* = @truncate(word >> @intCast(8 * (index % 4)));
    }
}

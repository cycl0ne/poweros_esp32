// SPDX-License-Identifier: MIT
//! Random bits, under the ESP32s' name: from the board's generator where
//! it has one - the RNG200 of the Raspberry Pi CM4's BCM2711 and the
//! CM5's BCM2712 (rng200.zig), which the kernel has started - and else
//! **from timing jitter, not from a hardware source**: QEMU's virt offers
//! its randomness only as a virtio device, which the kernel does not
//! drive. Jitter is had by timing a short loop on the cycle counter
//! against the system counter many times and mixing what it saw into a
//! running state. It is no stronger than that jitter, which on an
//! emulator may be little: good enough for sequence numbers and ids,
//! **not** for keys.
//!
//! Every program built with the SDK has a copy of this code, the kernel's
//! is only one, so the generator is found where each can see it: a part
//! of kind PARTKIND_RNG in the board's system tag list (`parts.zig`) - no
//! library to open, so any code may call this - once per copy, on the
//! first call. A word is taken with the caller's core's tasks and
//! interrupts kept out (Disable); the generator itself keeps the cores
//! from taking the same word (`rng200.take`).

const cpu = @import("cpu.zig");
const rng200 = @import("rng200.zig");
const parts = @import("../rv64sbi/parts.zig");
const exec = @import("../../libs/exec/exec.zig");
const st = @import("../../libs/expansion/systemtags.zig");

var state: u64 = 0x9E37_79B9_7F4A_7C15;

const Source = enum(u8) { unknown, jitter, rng200 };
var source: Source = .unknown;
/// Where the board's generator is, when `source` is .rng200.
var generator: usize = 0;

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

fn sysBase() *exec.ExecBase {
    const cell: *const volatile *exec.ExecBase = exec.AbsExecBase;
    return cell.*;
}

/// Where the board's generator is: its PARTKIND_RNG part's PART_Address,
/// for a generator this code drives.
fn findGenerator() ?usize {
    const part = parts.find(st.PARTKIND_RNG, st.CHIP_BCM2711_RNG200) orelse return null;
    return parts.value(part, st.PART_Address);
}

/// A word from the generator, or null - and jitter from then on - if it
/// has none, or does not answer.
fn word() ?u32 {
    if (source == .unknown) {
        if (findGenerator()) |base| {
            generator = base;
            source = .rng200;
        } else source = .jitter;
    }
    if (source != .rng200) return null;
    const sys = sysBase();
    sys.Disable();
    const taken = rng200.take(generator);
    sys.Enable();
    if (taken == null) source = .jitter;
    return taken;
}

/// 32 random bits.
pub fn read() u32 {
    return word() orelse jitter();
}

/// `into` filled with random bytes.
pub fn fill(into: []u8) void {
    var left = into;
    while (left.len != 0) {
        const one = word() orelse jitter();
        const bytes: []const u8 = @ptrCast(&one);
        const length = @min(left.len, bytes.len);
        @memcpy(left[0..length], bytes[0..length]);
        left = left[length..];
    }
}

// SPDX-License-Identifier: MIT
//! Random bits. This is the first chip in the tree with a generator of its
//! own: where the core has `rdrand` - every core this system runs on does,
//! and the emulator's does - the bits come from it, which is a real source
//! and not an estimate of one. Where a core has not, they come from timing
//! jitter as they do on the machines with no generator: a short loop timed
//! on the counter many times, mixed into a running state, which is no
//! stronger than that jitter and is **not** for keys.
//!
//! Which it is, is asked once and remembered (`from_hardware`), so the
//! kernel can say in its first lines where the machine's randomness comes
//! from rather than leaving it to be guessed.
//!
//! Every program built with the SDK has a copy of this code, the kernel's
//! is only one; each keeps its own state.

const cpu = @import("cpu.zig");

/// Leaf 1, ECX bit 30: the core has `rdrand`.
const LEAF1_RDRAND: u32 = 1 << 30;

var asked: bool = false;
var have_hardware: bool = false;

/// Whether the bits come from the core's own generator rather than from
/// timing jitter.
pub fn fromHardware() bool {
    if (!asked) {
        have_hardware = cpu.highestLeaf() >= 1 and cpu.leaf(1, 0).ecx & LEAF1_RDRAND != 0;
        asked = true;
    }
    return have_hardware;
}

/// 64 bits out of the core's generator, or null if it had none ready. The
/// instruction may fail when many cores ask at once, and the architecture
/// says to try ten times before giving up on it.
fn fromCore() ?u64 {
    var tries: u32 = 0;
    while (tries < 10) : (tries += 1) {
        var value: u64 = undefined;
        const ok = asm volatile (
            \\rdrand %[value]
            \\setc %[ok]
            : [value] "=r" (value),
              [ok] "=r" (-> u8),
        );
        if (ok != 0) return value;
    }
    return null;
}

var state: u64 = 0x9E37_79B9_7F4A_7C15;

/// SplitMix64's finaliser: every input bit reaches every output bit.
fn mix(value: u64) u64 {
    var z = value;
    z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
    return z ^ (z >> 31);
}

/// 32 bits from timing jitter, for a core with no generator: a short loop
/// timed on the counter, whose length differs by a few cycles each time,
/// and what differs mixed in.
fn jitter() u32 {
    var round: u32 = 0;
    while (round < 32) : (round += 1) {
        const before = cpu.cycles();
        var spin: u32 = 0;
        while (spin < 16) : (spin += 1) cpu.relax();
        state = mix(state ^ (cpu.cycles() -% before));
    }
    return @truncate(state >> 32);
}

/// 32 random bits.
pub fn read() u32 {
    if (fromHardware()) {
        if (fromCore()) |value| {
            state = mix(state ^ value);
            return @truncate(value);
        }
    }
    return jitter();
}

/// `into` filled with random bytes.
pub fn fill(into: []u8) void {
    var done: usize = 0;
    while (done < into.len) {
        const word = read();
        var byte: usize = 0;
        while (byte < 4 and done < into.len) : (byte += 1) {
            into[done] = @truncate(word >> @intCast(8 * byte));
            done += 1;
        }
    }
}

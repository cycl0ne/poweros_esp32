// SPDX-License-Identifier: MIT
//! Random bits, under the ESP32s' name: from the board's generator where
//! it has one - the JH7110's TRNG on the VisionFive 2 (trng.zig), which
//! the kernel has started - and else **from timing jitter, not from a
//! hardware source**: QEMU's virt offers its randomness only as a virtio
//! device, which the kernel does not drive. Jitter is had by timing a
//! short loop on the cycle counter against `time` many times and mixing
//! what it saw into a running state. It is no stronger than that jitter,
//! which on an emulator may be little: good enough for sequence numbers
//! and ids, **not** for keys.
//!
//! Every program built with the SDK has a copy of this code, the kernel's
//! is only one, so the generator is found where each can see it: a part
//! of kind PARTKIND_RNG in the board's system tag list, reached through
//! exec's FindResident - no library to open, so any code may call this.
//! Once per copy, on the first call. A request runs with interrupts off,
//! so two callers' requests do not meet in its registers; that holds on
//! one core.

const cpu = @import("cpu.zig");
const trng = @import("trng.zig");
const exec = @import("../../libs/exec/exec.zig");
const st = @import("../../libs/expansion/systemtags.zig");
const SYSTEM_RESIDENT = @import("../../libs/expansion/expansion.zig").SYSTEM_RESIDENT;
const tagitem = @import("../../libs/utility/tagitem.zig");

var state: u64 = 0x9E37_79B9_7F4A_7C15;

const Source = enum(u8) { unknown, jitter, trng };
var source: Source = .unknown;
/// Where the board's generator is, when `source` is .trng.
var trng_base: usize = 0;

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
        state = mix(state ^ (cpu.cycles() -% before) ^ (cpu.time() << 32));
    }
    return @truncate(state >> 16);
}

fn sysBase() *exec.ExecBase {
    const cell: *const volatile *exec.ExecBase = exec.AbsExecBase;
    return cell.*;
}

/// The value of `tag` in `list`, or null.
fn find(list: [*]const tagitem.TagItem, tag: tagitem.Tag) ?usize {
    var at: usize = 0;
    while (list[at].tag != tagitem.TAG_DONE) : (at += 1) {
        if (list[at].tag == tag) return list[at].data;
    }
    return null;
}

/// Where the board's generator is: its PARTKIND_RNG part's PART_Address,
/// for a generator this code drives.
fn findGenerator() ?usize {
    const tag = sysBase().FindResident(SYSTEM_RESIDENT) orelse return null;
    if (tag.type != .board) return null;
    const root: [*]const tagitem.TagItem = @ptrCast(@alignCast(tag.init orelse return null));
    var at: usize = 0;
    while (root[at].tag != tagitem.TAG_DONE) : (at += 1) {
        if (root[at].tag != st.SYSTAG_Part) continue;
        const part: [*]const tagitem.TagItem = @ptrFromInt(root[at].data);
        if (find(part, st.PART_Kind) != st.PARTKIND_RNG) continue;
        if (find(part, st.PART_Chip) != st.CHIP_JH7110_TRNG) continue;
        return find(part, st.PART_Address);
    }
    return null;
}

/// One request's worth from the generator, or null - and jitter from
/// then on - if it does not answer.
fn request(into: *[trng.words]u32) bool {
    if (source == .unknown) {
        if (findGenerator()) |base| {
            trng_base = base;
            source = .trng;
        } else source = .jitter;
    }
    if (source != .trng) return false;
    const sys = sysBase();
    sys.Disable();
    const answered = trng.generate(trng_base, into);
    sys.Enable();
    if (!answered) source = .jitter;
    return answered;
}

/// 32 random bits.
pub fn read() u32 {
    var words: [trng.words]u32 = undefined;
    if (request(&words)) return words[0];
    return jitter();
}

/// `into` filled with random bytes.
pub fn fill(into: []u8) void {
    var words: [trng.words]u32 = undefined;
    var left = into;
    while (left.len != 0) {
        if (!request(&words)) {
            for (&words) |*word| word.* = jitter();
        }
        const bytes: []const u8 = @ptrCast(&words);
        const length = @min(left.len, bytes.len);
        @memcpy(left[0..length], bytes[0..length]);
        left = left[length..];
    }
}

// SPDX-License-Identifier: MIT
//! The platform interrupt controller (PLIC), as the RISC-V PLIC
//! specification lays it out: a priority per source, a pending bit per
//! source, and per context - one hart in one privilege mode - an enable
//! bit per source, a priority threshold, and the claim register that
//! answers the highest pending source and, written back, completes it.
//!
//! Which context is supervisor mode of which hart is the machine's: on
//! QEMU's virt hart n has 2n (machine) and 2n + 1 (supervisor); on the
//! JH7110 hart 0, the S7, has only a machine context, 0, so hart n of the
//! U74s has 2n - 1 and 2n. The kernel sets `contexts` from the board.

const map = @import("map.zig");
const reg = @import("mmio.zig").reg;
const intbits = @import("intbits.zig");

const PRIORITY = 0x0;
const PENDING = 0x1000;
const ENABLE = 0x2000;
const ENABLE_STRIDE = 0x80;
const CONTEXT = 0x20_0000;
const CONTEXT_STRIDE = 0x1000;
const THRESHOLD = 0x0;
const CLAIM = 0x4;

/// Supervisor mode of hart n is context `first + stride * n`.
pub const Contexts = struct { first: u32, stride: u32 };
pub var contexts: Contexts = .{ .first = 1, .stride = 2 };

/// The highest source the machine's PLIC has: past it there are neither
/// priorities nor enable bits. The kernel sets it from the board.
pub var sources: u32 = intbits.INTB_PLIC_COUNT - 1;

/// Whether the PLIC has `source`; 0 is none.
pub fn has(source: u32) bool {
    return source != 0 and source <= sources;
}

/// The supervisor context of hart `hartid`.
pub fn supervisorContext(hartid: usize) usize {
    return contexts.first + contexts.stride * hartid;
}

/// `source`'s priority: 0 never interrupts, 1 is the lowest that does.
pub fn setPriority(source: u32, priority: u32) void {
    reg(map.PLIC + PRIORITY + 4 * @as(usize, source)).* = priority;
}

/// Whether `source` is pending.
pub fn pending(source: u32) bool {
    return reg(map.PLIC + PENDING + 4 * @as(usize, source / 32)).* & (@as(u32, 1) << @intCast(source % 32)) != 0;
}

fn enableWord(context: usize, source: u32) *volatile u32 {
    return reg(map.PLIC + ENABLE + ENABLE_STRIDE * context + 4 * @as(usize, source / 32));
}

/// `source` taken by `context`, or not.
pub fn setEnabled(context: usize, source: u32, on: bool) void {
    const bit = @as(u32, 1) << @intCast(source % 32);
    const word = enableWord(context, source);
    if (on) word.* |= bit else word.* &= ~bit;
}

pub fn isEnabled(context: usize, source: u32) bool {
    return enableWord(context, source).* & (@as(u32, 1) << @intCast(source % 32)) != 0;
}

/// Only sources above `threshold` interrupt `context`.
pub fn setThreshold(context: usize, threshold: u32) void {
    reg(map.PLIC + CONTEXT + CONTEXT_STRIDE * context + THRESHOLD).* = threshold;
}

/// The highest pending source `context` takes, claimed; 0 for none.
pub fn claim(context: usize) u32 {
    return reg(map.PLIC + CONTEXT + CONTEXT_STRIDE * context + CLAIM).*;
}

/// `source`, which `claim` answered, done with.
pub fn complete(context: usize, source: u32) void {
    reg(map.PLIC + CONTEXT + CONTEXT_STRIDE * context + CLAIM).* = source;
}

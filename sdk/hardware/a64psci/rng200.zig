// SPDX-License-Identifier: MIT
//! Broadcom's RNG200 (CHIP_BCM2711_RNG200), the true random number
//! generator of the Raspberry Pi CM4's BCM2711 and the CM5's BCM2712: a
//! bank of free-running oscillators, sampled, checked by the block's own
//! health tests, and handed out as 32-bit words through a FIFO of 16.
//!
//! **The firmware has usually started it.** The VideoCore's firmware on
//! the CM4 leaves it running - every generator on, the sample clock's
//! divider at 3, which is what Raspberry Pi's Linux sets too - and its
//! FIFO full. The kernel starts it once (`start`), before exec runs and
//! before the other cores take tasks: where it is not running, both
//! halves are reset, the first 256 Kibit it makes thrown away, and it is
//! switched on; where it is, it is left as it is. After that `rng` takes
//! its words (`take`). It is polled; its interrupt stays off.
//!
//! **No word is handed out twice.** A read of the FIFO's data register
//! takes a word out of it, and a read of an empty FIFO gives no fresh
//! one. Every program has a copy of this code, and up to four cores may
//! read at once, so a reader takes a word only while the FIFO holds at
//! least as many as there are cores (`cores`), with its own core's tasks
//! and interrupts kept out (the caller's Disable): however many read at
//! that moment, each gets a word of its own.
//!
//! The registers by the names of Linux's driver (iproc-rng200.c); the
//! values the BCM2711's firmware leaves were read on a CM4.

const reg = @import("mmio.zig").reg;

const CTRL = 0x00;
const RNG_SOFT_RESET = 0x04;
const RBG_SOFT_RESET = 0x08;
const TOTAL_BIT_COUNT = 0x0C;
const TOTAL_BIT_COUNT_THRESHOLD = 0x10;
const INT_STATUS = 0x18;
const FIFO_DATA = 0x20;
const FIFO_COUNT = 0x24;

/// Every random bit generator on.
const CTRL_RBGEN_MASK: u32 = 0x1FFF;
/// What it runs with: every generator on, the sample clock's divider at
/// 3 - the firmware's value, and Linux's for the BCM2711.
const CTRL_RUN: u32 = 0x3 << 13 | CTRL_RBGEN_MASK;
const SOFT_RESET: u32 = 1;
/// The block's health tests failed for good, or once.
const INT_MASTER_FAIL_LOCKOUT: u32 = 1 << 31;
const INT_NIST_FAIL: u32 = 1 << 5;
const INT_FAILED: u32 = INT_MASTER_FAIL_LOCKOUT | INT_NIST_FAIL;
const FIFO_COUNT_MASK: u32 = 0xFF;
const FIFO_THRESHOLD_SHIFT = 8;
/// The bits thrown away after a reset: the first a generator makes are
/// the least random.
const discarded_bits: u32 = 0x40000;
/// The bits it has to have made before it counts as warm.
const warm_bits: u32 = 16;

/// The words the FIFO must hold for a reader to take one: one for each
/// core that may read at the same moment. The BCM2711 and the BCM2712
/// have four.
pub const cores = 4;

/// How many times a wait reads its register before it gives up: far
/// longer than the FIFO takes to fill.
const patience: u32 = 2_000_000;

fn at(base: usize, offset: usize) *volatile u32 {
    return reg(base + offset);
}

/// Whether the generators are switched on.
fn running(base: usize) bool {
    return at(base, CTRL).* & CTRL_RBGEN_MASK != 0;
}

/// Both halves reset, the first bits set to be thrown away, and the
/// generators switched on (Linux's restart, with the BCM2711's settings).
fn restart(base: usize) void {
    at(base, CTRL).* = at(base, CTRL).* & ~CTRL_RBGEN_MASK;
    at(base, INT_STATUS).* = 0xFFFF_FFFF;
    at(base, RBG_SOFT_RESET).* = at(base, RBG_SOFT_RESET).* | SOFT_RESET;
    at(base, RNG_SOFT_RESET).* = at(base, RNG_SOFT_RESET).* | SOFT_RESET;
    at(base, RNG_SOFT_RESET).* = at(base, RNG_SOFT_RESET).* & ~SOFT_RESET;
    at(base, RBG_SOFT_RESET).* = at(base, RBG_SOFT_RESET).* & ~SOFT_RESET;
    at(base, TOTAL_BIT_COUNT_THRESHOLD).* = discarded_bits;
    at(base, FIFO_COUNT).* = 2 << FIFO_THRESHOLD_SHIFT;
    at(base, CTRL).* = CTRL_RUN;
}

/// Whether it has warmed up and has a word for the first reader.
fn ready(base: usize) bool {
    var tries: u32 = 0;
    while (tries < patience) : (tries += 1) {
        if (at(base, INT_STATUS).* & INT_FAILED != 0) return false;
        if (at(base, TOTAL_BIT_COUNT).* > warm_bits and at(base, FIFO_COUNT).* & FIFO_COUNT_MASK >= cores) return true;
    }
    return false;
}

/// How the generator was found.
pub const Started = enum {
    /// Running already - the firmware's - and making words.
    found,
    /// Switched on here, and making words.
    started,
    /// Making no words, or failing its health tests.
    failed,
};

/// The generator at `base` running and making words: left as it is where
/// it runs and passes its tests, else restarted.
pub fn start(base: usize) Started {
    if (running(base) and at(base, INT_STATUS).* & INT_FAILED == 0 and ready(base)) return .found;
    restart(base);
    return if (ready(base)) .started else .failed;
}

/// A word out of the FIFO, once it holds `cores` of them; null if it
/// does not fill in time. A generator that failed its health tests is
/// restarted, once, as Linux's driver does. The caller keeps the other
/// tasks and interrupts of its own core out while it runs.
pub fn take(base: usize) ?u32 {
    var restarted = false;
    var tries: u32 = 0;
    while (tries < patience) : (tries += 1) {
        if (at(base, INT_STATUS).* & INT_FAILED != 0) {
            if (restarted) return null;
            restart(base);
            restarted = true;
            continue;
        }
        if (at(base, FIFO_COUNT).* & FIFO_COUNT_MASK >= cores) return at(base, FIFO_DATA).*;
    }
    return null;
}

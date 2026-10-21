// SPDX-License-Identifier: MIT
//! The JH7110's true random number generator, in its security block
//! (CHIP_JH7110_TRNG): a noise source that seeds a generator, which gives
//! 256 bits a request. The kernel starts it once (`start`), before exec
//! runs and before the other harts take tasks: its two bus clocks on and
//! its reset released in the STG clock and reset generator (`system`),
//! 256-bit mode, a first seeding. After that `rng` asks it for numbers
//! (`generate`). It is polled; its interrupt, PLIC source 30, stays off.
//! The registers by the names of Linux's driver (jh7110-trng.c).

const reg = @import("mmio.zig").reg;
const system = @import("system.zig");

const CTRL = 0x00;
const STAT = 0x04;
const MODE = 0x08;
const IE = 0x10;
const ISTAT = 0x14;
const RAND0 = 0x20;
const AUTO_RQSTS = 0x60;
const AUTO_AGE = 0x64;

const CTRL_GENE_RANDNUM: u32 = 0x1;
const CTRL_EXEC_RANDRESEED: u32 = 0x2;
const STAT_SEEDED: u32 = 1 << 9;
const STAT_RAND_GENERATING: u32 = 1 << 30;
const STAT_RAND_SEEDING: u32 = 1 << 31;
const MODE_R256: u32 = 1 << 3;
/// The events as Linux enables them. They latch in ISTAT, which is read
/// here; with the PLIC source off none of them interrupts.
const IE_ALL: u32 = 1 << 31 | 1 << 4 | 1 << 1 | 1 << 0;
const ISTAT_RAND_RDY: u32 = 1 << 0;
const ISTAT_SEED_DONE: u32 = 1 << 1;
const ISTAT_LFSR_LOCKUP: u32 = 1 << 4;

/// The words one request gives.
pub const words = 8;

/// How many times a wait reads its register before it gives up: far
/// longer than a seeding takes.
const patience: u32 = 1_000_000;

fn at(base: usize, offset: usize) *volatile u32 {
    return reg(base + offset);
}

/// Whether `mask` came up in ISTAT; it is cleared there.
fn event(base: usize, mask: u32) bool {
    var tries: u32 = 0;
    while (tries < patience) : (tries += 1) {
        if (at(base, ISTAT).* & mask != 0) {
            at(base, ISTAT).* = mask;
            return true;
        }
    }
    return false;
}

/// Whether the generator is neither generating nor seeding.
fn idle(base: usize) bool {
    var tries: u32 = 0;
    while (tries < patience) : (tries += 1) {
        if (at(base, STAT).* & (STAT_RAND_GENERATING | STAT_RAND_SEEDING) == 0) return true;
    }
    return false;
}

/// A new seed from the noise source.
fn reseed(base: usize) bool {
    at(base, CTRL).* = CTRL_EXEC_RANDRESEED;
    return event(base, ISTAT_SEED_DONE);
}

/// The generator at `base` started: clocked, out of reset, in 256-bit
/// mode and seeded. False if it did not seed.
pub fn start(base: usize) bool {
    system.clockOn(.stg, system.STGCLK_SEC_AHB);
    system.clockOn(.stg, system.STGCLK_SEC_MISC_AHB);
    system.releaseReset(.stg, system.STGRST_SEC_AHB);
    _ = system.waitOutOfReset(.stg, system.STGRST_SEC_AHB);
    // No reseeding of its own: it reseeds when asked, here.
    at(base, AUTO_AGE).* = 0;
    at(base, AUTO_RQSTS).* = 0;
    at(base, ISTAT).* = at(base, ISTAT).*;
    at(base, IE).* = IE_ALL;
    at(base, MODE).* |= MODE_R256;
    return reseed(base) and at(base, STAT).* & STAT_SEEDED != 0;
}

/// One request's 256 bits into `into`. False if the generator did not
/// answer. The caller keeps every other caller out while it runs.
pub fn generate(base: usize, into: *[words]u32) bool {
    if (!idle(base)) return false;
    // A fault in its shift register (a single-event upset) wants a new
    // seed before it is used again.
    if (at(base, ISTAT).* & ISTAT_LFSR_LOCKUP != 0) {
        at(base, ISTAT).* = ISTAT_LFSR_LOCKUP;
        if (!reseed(base)) return false;
    }
    // A RAND_RDY left from the last request, or from the seeding, would
    // be taken for this one's: the words read while they are still being
    // made, cleared at its start and mostly zero.
    at(base, ISTAT).* = ISTAT_RAND_RDY;
    at(base, CTRL).* = CTRL_GENE_RANDNUM;
    if (!event(base, ISTAT_RAND_RDY) or !idle(base)) return false;
    for (into, 0..) |*word, index| word.* = at(base, RAND0 + 4 * index).*;
    return true;
}

// SPDX-License-Identifier: MPL-2.0
//! The rendezvous: the other core held still while this one does what
//! nothing else may run beside - a flash write, which suspends both
//! caches, so that no instruction in flash and no byte in PSRAM can be
//! reached until it is done.
//!
//! The holding core asks with the other core's cross-core interrupt and
//! waits until it answers that it is parked: in `parkHere`, in internal
//! RAM, with its interrupts masked, calling nothing - so no instruction
//! and no window spill of it reaches the caches - and spinning on a word
//! in internal RAM until it is let go. Only then are the caches touched.
//!
//! A core that spins with its interrupts masked - for a lock the holder
//! has, say - never takes that interrupt, so every such spin asks
//! `parkIfAsked` as it goes round. And two cores asking at once: the one
//! that loses the request parks for the one that won, then asks again.

const cpu = @import("cpu.zig");
const cpu1 = @import("cpu1.zig");
const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;

/// The core that asked and one, or 0; whether the other core is parked;
/// and the word that lets it go. Internal RAM (.bss), which the parked
/// core reads with the caches suspended.
var asker: u32 = 0;
var parked: u32 = 0;
var released: u32 = 0;

/// The other core parked and held; returns once it is. The caller has
/// its own interrupts masked. Nothing on one core.
pub fn holdOther() void {
    _ = holdOtherWithin(null);
}

/// `holdOther` that waits for the other core at most `spins` rounds: for a
/// machine that is failing, whose other core may be stuck itself with its
/// interrupts masked. True once it is parked, and on one core; false when
/// it never said so - it is asked still, parks if it ever looks, and
/// `releaseOther` lets it go either way.
pub fn holdOtherWithin(spins: ?u32) bool {
    if (!cpu1.isUp()) return true;
    const me = cpu.coreId();
    while (@cmpxchgStrong(u32, &asker, 0, me + 1, .acquire, .monotonic) != null) {
        // The other core asked first: park for it, then ask again.
        parkIfAsked();
    }
    @atomicStore(u32, &released, 0, .release);
    reg(hardware.system.CPU_INTR_FROM_CPU_0 + 4 * @as(usize, 1 - me)).* = 1;
    var round: u32 = 0;
    while (@atomicLoad(u32, &parked, .acquire) == 0) : (round +%= 1) {
        if (spins) |limit| {
            if (round >= limit) return false;
        }
    }
    return true;
}

/// The held core let go; returns once it has left its loop.
pub fn releaseOther() void {
    if (!cpu1.isUp()) return;
    @atomicStore(u32, &released, 1, .release);
    while (@atomicLoad(u32, &parked, .acquire) != 0) {}
    @atomicStore(u32, &asker, 0, .release);
}

/// Parked if the other core asks: from the cross-core interrupt, and from
/// every spin with interrupts masked.
pub fn parkIfAsked() void {
    const asked = @atomicLoad(u32, &asker, .acquire);
    if (asked == 0 or asked == cpu.coreId() + 1) return;
    parkHere();
}

/// The loop a held core waits in: internal RAM, no calls, nothing but the
/// three words above, until it is let go.
noinline fn parkHere() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    const parked_word: *volatile u32 = &parked;
    const released_word: *volatile u32 = &released;
    parked_word.* = 1;
    while (released_word.* == 0) {}
    parked_word.* = 0;
}

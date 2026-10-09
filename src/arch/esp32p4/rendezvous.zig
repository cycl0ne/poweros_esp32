// SPDX-License-Identifier: MPL-2.0
//! The rendezvous: the other core held still while this one does what
//! nothing else may run beside - the ROM debugger looking at a stopped
//! machine, an alert that ends it, and later a flash write, which suspends
//! the caches the other core runs through.
//!
//! The holding core asks with the other core's cross-core interrupt and
//! waits until it answers that it is parked: in `parkHere`, with its
//! interrupts masked, calling nothing, spinning on a word until it is let
//! go.
//!
//! A core that spins with its interrupts masked - for a lock the holder
//! has, say - never takes that interrupt, so every such spin asks
//! `parkIfAsked` as it goes round. And two cores asking at once: the one
//! that loses the request parks for the one that won, then asks again.

const cpu = @import("cpu.zig");
const cpu1 = @import("cpu1.zig");
const intmatrix = @import("intmatrix.zig");

/// The core that asked and one, or 0; whether the other core is parked;
/// and the word that lets it go.
var asker: u32 = 0;
var parked: u32 = 0;
var released: u32 = 0;
/// How many more times the holding core has asked while it holds: an
/// alert holds the other core, and the debugger it offers holds it again.
var nested: u32 = 0;

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
    if (@atomicLoad(u32, &asker, .acquire) == me + 1) {
        nested += 1;
        return true;
    }
    while (@cmpxchgStrong(u32, &asker, 0, me + 1, .acquire, .monotonic) != null) {
        // The other core asked first: park for it, then ask again.
        parkIfAsked();
    }
    @atomicStore(u32, &released, 0, .release);
    intmatrix.raiseCrossCore(1 - me);
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
    if (nested != 0) {
        nested -= 1;
        return;
    }
    @atomicStore(u32, &released, 1, .release);
    while (@atomicLoad(u32, &parked, .acquire) != 0) {}
    @atomicStore(u32, &asker, 0, .release);
}

/// The longest each core was parked, in cycles.
pub var parked_max: [2]u32 = @splat(0);

/// Parked if the other core asks: from the cross-core interrupt, and from
/// every spin with interrupts masked.
pub fn parkIfAsked() void {
    const asked = @atomicLoad(u32, &asker, .acquire);
    const core = cpu.coreId();
    if (asked == 0 or asked == core + 1) return;
    const before = cpu.ccount();
    parkHere();
    parked_max[core] = @max(parked_max[core], cpu.ccount() -% before);
}

/// The loop a held core waits in: no calls, nothing but the words above,
/// until it is let go.
noinline fn parkHere() void {
    const parked_word: *volatile u32 = &parked;
    const released_word: *volatile u32 = &released;
    parked_word.* = 1;
    while (released_word.* == 0) {}
    parked_word.* = 0;
}

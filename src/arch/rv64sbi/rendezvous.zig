// SPDX-License-Identifier: MPL-2.0
//! The rendezvous: the other cores held still while this one does what
//! nothing else may run beside - the ROM debugger looking at a stopped
//! machine, an alert that ends it.
//!
//! The holding core asks with each running core's cross-core interrupt
//! and waits until every one of them answers that it is parked: in
//! `parkHere`, with its interrupts masked, calling nothing, spinning on a
//! word until it is let go.
//!
//! A core that spins with its interrupts masked - for a lock the holder
//! has, say - never takes that interrupt, so every such spin asks
//! `parkIfAsked` as it goes round. And two cores asking at once: the one
//! that loses the request parks for the one that won, then asks again.
//!
//! Each hold has a word of its own - a count, and the holding core - so a
//! parked core waits for its own hold to be let go and nothing else: it
//! is never let go by the one before, and once let go it does not park
//! again for the same hold while the holder is still on its way out.

const cpu = @import("cpu.zig");
const cpu1 = @import("cpu1.zig");
const plic = @import("plic.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const max_cores = @import("../../rom/libs/exec/exec_base.zig").max_cores;

/// The hold asked for - its count above the low byte, the asking core
/// and one in it - or 0; the last hold let go; and how many cores are
/// parked.
var hold: u32 = 0;
var let_go: u32 = 0;
var parked: u32 = 0;
/// The holds counted, for the next one's word.
var holds: u32 = 0;
/// The hold each core last parked for and was let go by.
var parked_for: [max_cores]u32 = @splat(0);
/// How many more times the holding core has asked while it holds: an
/// alert holds the other cores, and the debugger it offers holds them
/// again.
var nested: u32 = 0;

/// The cores running: exec's count, once another core is up.
fn running() u32 {
    if (!cpu1.isUp()) return 1;
    return @atomicLoad(u32, &exec.SysBase.cores_running, .acquire);
}

/// The other cores parked and held; returns once they are. The caller has
/// its own interrupts masked. Nothing on one core.
pub fn holdOther() void {
    _ = holdOtherWithin(null);
}

/// `holdOther` that waits for the other cores at most `spins` rounds: for
/// a machine that is failing, where one may be stuck itself with its
/// interrupts masked. True once all are parked, and on one core; false
/// when one never said so - it is asked still, parks if it ever looks,
/// and `releaseOther` lets it go either way.
pub fn holdOtherWithin(spins: ?u32) bool {
    const cores = running();
    if (cores < 2) return true;
    const me = cpu.coreId();
    if (@atomicLoad(u32, &hold, .acquire) & 0xFF == me + 1) {
        nested += 1;
        return true;
    }
    const count = @atomicRmw(u32, &holds, .Add, 1, .monotonic) +% 1;
    const word = count << 8 | (me + 1);
    while (@cmpxchgStrong(u32, &hold, 0, word, .acq_rel, .monotonic) != null) {
        // Another core asked first: park for it, then ask again.
        parkIfAsked();
    }
    for (0..cores) |core| {
        if (core != me) plic.raiseCrossCore(@intCast(core));
    }
    var round: u32 = 0;
    while (@atomicLoad(u32, &parked, .acquire) < cores - 1) : (round +%= 1) {
        if (spins) |limit| {
            if (round >= limit) return false;
        }
    }
    return true;
}

/// The held cores let go; returns once each has left its loop.
pub fn releaseOther() void {
    if (!cpu1.isUp()) return;
    if (nested != 0) {
        nested -= 1;
        return;
    }
    @atomicStore(u32, &let_go, @atomicLoad(u32, &hold, .acquire), .release);
    while (@atomicLoad(u32, &parked, .acquire) != 0) {}
    @atomicStore(u32, &hold, 0, .release);
}

/// The longest each core was parked, in cycles.
pub var parked_max: [max_cores]u32 = @splat(0);

/// Parked if another core asks, and has not let this one go yet: from the
/// cross-core interrupt, and from every spin for another core.
/// Its interrupts are masked while it parks, whatever the spin had:
/// with them on - a task in AcquireLock's spin - the cross-core
/// interrupt would park it again inside the park, and the interrupt's
/// exit could switch the task away there, counted as parked until it
/// runs again: which nothing does while the holder waits for it with
/// the system's lock and the others spin for that.
pub fn parkIfAsked() void {
    const state = cpu.disableInterrupts();
    defer cpu.restoreInterrupts(state);
    const asked = @atomicLoad(u32, &hold, .acquire);
    const core = cpu.coreId();
    if (asked == 0 or asked & 0xFF == core + 1 or parked_for[core] == asked) return;
    const before = cpu.ccount();
    parkHere(asked);
    parked_for[core] = asked;
    parked_max[core] = @max(parked_max[core], cpu.ccount() -% before);
}

/// The loop a held core waits in: no calls, nothing but the words above,
/// until its hold is let go.
noinline fn parkHere(asked: u32) void {
    @setRuntimeSafety(false);
    _ = @atomicRmw(u32, &parked, .Add, 1, .acq_rel);
    while (@atomicLoad(u32, &let_go, .acquire) != asked) {}
    _ = @atomicRmw(u32, &parked, .Sub, 1, .acq_rel);
}

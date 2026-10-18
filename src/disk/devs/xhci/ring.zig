// SPDX-License-Identifier: MIT
//! The rings TRBs go round on: a ring the driver fills and the controller
//! takes from (the command ring, an endpoint's transfer ring), and the
//! event ring the controller fills and the driver takes from.
//!
//! **Whose a TRB is** is said by its cycle bit. The side that fills a
//! ring writes its TRBs with its cycle state, and the side that takes
//! from it takes each TRB whose bit matches its own; at the end of the
//! ring both flip theirs, so what is left over from the last time round
//! never matches.
//!
//! **A ring the driver fills** is one segment whose last TRB is a Link
//! back to its start, with Toggle Cycle: the controller flips its cycle
//! state as it follows it. The Link is handed over each time round as
//! any TRB is, by its cycle bit, and carries the chain bit of the TRB
//! before it, so a TD may run on past it. Where the next TRB goes is
//! never the Link itself - a VL805 is not to be pointed at one.
//!
//! **The event ring** is one segment, no Link: the controller goes back
//! to its start by itself, as the Event Ring Segment Table says it is
//! only so long.
//!
//! The memory is the caller's; nothing here allocates, writes back or
//! drops a cache line. A TRB's address is the one the controller uses:
//! memory is where the processor sees it, on the machines this runs on.

const regs = @import("regs.zig");

/// A TRB: a parameter, a status, a control word with the cycle bit.
pub const Trb = extern struct {
    param_lo: u32 = 0,
    param_hi: u32 = 0,
    status: u32 = 0,
    control: u32 = 0,

    pub fn param(trb: Trb) u64 {
        return @as(u64, trb.param_hi) << 32 | trb.param_lo;
    }
};

pub fn lo(address: u64) u32 {
    return @truncate(address);
}

pub fn hi(address: u64) u32 {
    return @truncate(address >> 32);
}

/// A ring the driver fills: a command ring or a transfer ring.
pub const Ring = struct {
    trbs: [*]Trb = undefined,
    count: u32 = 0,
    /// Where the next TRB goes, and the cycle state it goes with.
    enqueue: u32 = 0,
    cycle: u32 = 1,

    /// The ring made over `trbs`, empty: everything zeroed, the last TRB
    /// a Link back to the first, not yet handed over.
    pub fn init(ring: *Ring, trbs: []Trb) void {
        @memset(trbs, .{});
        ring.* = .{ .trbs = trbs.ptr, .count = @intCast(trbs.len) };
        const start: u64 = @intFromPtr(trbs.ptr);
        const link = &trbs[trbs.len - 1];
        link.param_lo = lo(start);
        link.param_hi = hi(start);
        link.control = regs.typeField(regs.TRB_LINK) | regs.TRB_TC;
    }

    /// The ring emptied again from its start, for an endpoint added
    /// afresh: what the controller is pointed at with cycle state 1.
    pub fn reset(ring: *Ring) void {
        ring.init(ring.trbs[0..ring.count]);
    }

    pub fn bytes(ring: *const Ring) usize {
        return @as(usize, ring.count) * @sizeOf(Trb);
    }

    /// Where the next TRB goes, as the controller is told: its address
    /// with the cycle state in bit 0.
    pub fn dequeuePointer(ring: *const Ring) u64 {
        return @as(u64, @intFromPtr(&ring.trbs[ring.enqueue])) | ring.cycle;
    }

    /// A TRB put on the ring, its cycle bit the ring's; where it went.
    /// Its control word is written last.
    pub fn push(ring: *Ring, trb: Trb) usize {
        const at: *volatile Trb = &ring.trbs[ring.enqueue];
        at.param_lo = trb.param_lo;
        at.param_hi = trb.param_hi;
        at.status = trb.status;
        at.control = (trb.control & ~regs.TRB_CYCLE) | ring.cycle;
        const address = @intFromPtr(at);
        ring.enqueue += 1;
        if (ring.enqueue == ring.count - 1) {
            const link: *volatile Trb = &ring.trbs[ring.count - 1];
            link.control = (link.control & ~(regs.TRB_CYCLE | regs.TRB_CHAIN)) | (trb.control & regs.TRB_CHAIN) | ring.cycle;
            ring.enqueue = 0;
            ring.cycle ^= 1;
        }
        return address;
    }
};

/// The ring the controller fills with events.
pub const EventRing = struct {
    trbs: [*]Trb = undefined,
    count: u32 = 0,
    /// The next event to take, and the cycle state it has when it is
    /// there.
    dequeue: u32 = 0,
    cycle: u32 = 1,

    pub fn init(ring: *EventRing, trbs: []Trb) void {
        @memset(trbs, .{});
        ring.* = .{ .trbs = trbs.ptr, .count = @intCast(trbs.len) };
    }

    pub fn bytes(ring: *const EventRing) usize {
        return @as(usize, ring.count) * @sizeOf(Trb);
    }

    /// The next event, if the controller has written it: a copy, its
    /// control word read first, so the rest is what came with it.
    pub fn peek(ring: *const EventRing) ?Trb {
        const at: *volatile Trb = &ring.trbs[ring.dequeue];
        const control = at.control;
        if (control & regs.TRB_CYCLE != ring.cycle) return null;
        return .{ .param_lo = at.param_lo, .param_hi = at.param_hi, .status = at.status, .control = control };
    }

    /// Past the event taken.
    pub fn advance(ring: *EventRing) void {
        ring.dequeue += 1;
        if (ring.dequeue == ring.count) {
            ring.dequeue = 0;
            ring.cycle ^= 1;
        }
    }

    /// Where the next event will be: what ERDP is written.
    pub fn dequeueAddress(ring: *const EventRing) u64 {
        return @intFromPtr(&ring.trbs[ring.dequeue]);
    }
};

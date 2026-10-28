// SPDX-License-Identifier: MIT
//! Selective acknowledgements (RFC 2018), and the repair of a loss with
//! what they say (RFC 6675).
//!
//! **Receiving**: while segments are held beyond a hole (reorder.zig),
//! every acknowledgement names them in up to four blocks - first the one
//! that holds the segment that came last, as the RFC asks, then the
//! highest of the others. A segment carries as many as fit beside its
//! data in the peer's MSS; output.zig leaves room for all four in the
//! data it sends while anything is held.
//!
//! **Sending**: the blocks the peer names are kept, merged, between
//! SND.UNA and SND.MAX - eight ranges at the most; the highest is let go
//! when a ninth comes, which only means bytes the peer has may be sent
//! again. A block below what is acknowledged (a duplicate's report, RFC
//! 2883) or past what was sent is not kept.
//!
//! A repair begins at the third duplicate acknowledgement, or as soon as
//! SND.UNA's segment counts as lost. A duplicate is an acknowledgement
//! whose blocks name bytes none named before (RFC 6675's), not one that
//! tells of a segment that came twice: each segment sent again for
//! nothing brings one of those, and three of them began a repair for
//! nothing again - close to 800 repairs in three writes of 200 MB to a
//! NAS whose path puts a segment behind the next now and then. The
//! threshold is halved, the congestion window set to it, and that
//! segment sent again at once. A byte counts as lost when more than two
//! segments' worth, or three blocks, are SACKed past it. From then on
//! what goes out is held to the window by the pipe - what is still in
//! flight: what was sent past SND.UNA, less what the peer holds, less
//! what is lost and was not sent again. Each acknowledgement that
//! shrinks the pipe lets the next lost stretch go, or new data when
//! nothing lost is left; one that acknowledges part of what was sent,
//! while the peer holds bytes past it, shows SND.UNA's segment missing
//! too, and sends it at once if it has not gone (RFC 6582). With nothing
//! held past it, the segment that began the repair came late rather than
//! not at all, and SND.UNA's is only on its way. The repair ends when
//! everything up to where it began (`recover`) is acknowledged, and the
//! window stays at the threshold.
//!
//! A timeout forgets the blocks - the peer may have let go of what it
//! held - and everything from SND.UNA goes again; no repair begins until
//! all of that is acknowledged.

const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _tcp = @import("_tcp.zig");
const Tcb = _tcp.Tcb;
const Range = _tcp.Range;
const output = @import("output.zig");
const timers = @import("timers.zig");

/// The option's bytes for `count` blocks: two NOPs in front, so the
/// blocks fall on words.
pub fn optionBytes(count: usize) u32 {
    return if (count == 0) 0 else 4 + 8 * @as(u32, @intCast(count));
}

/// The most the option takes: four blocks.
pub const option_max = optionBytes(_tcp.sack_blocks_max);

/// How many blocks fit beside `length` bytes of data.
pub fn fitting(tcb: *const Tcb, length: u32) usize {
    const room = tcb.mss -| length;
    if (room < optionBytes(1)) return 0;
    return @min(_tcp.sack_blocks_max, (room - 4) / 8);
}

// --- receiving -------------------------------------------------------------------------

/// The blocks an acknowledgement going out names, as many as `into`
/// holds: how many. The held segments are in sequence order; touching
/// ones make one block.
pub fn blocks(tcb: *Tcb, into: []Range) usize {
    if (into.len == 0 or tcb.held_count == 0) return 0;
    var newest: ?Range = null;
    // The highest blocks but the newest's, the last ones in a circle.
    var others: [_tcp.sack_blocks_max]Range = undefined;
    var other_count: usize = 0;
    var current: ?Range = null;
    var it = tcb.held.iterator();
    while (true) {
        const next: ?Range = if (it.next()) |node| fresh: {
            const frame: *Frame = @fieldParentPtr("node", node);
            break :fresh .{ .start = frame.sequence, .end = frame.sequence +% frame.length };
        } else null;
        if (current) |*range| {
            if (next) |more| {
                if (_tcp.atOrBefore(more.start, range.end)) {
                    if (_tcp.after(more.end, range.end)) range.end = more.end;
                    continue;
                }
            }
            if (_tcp.atOrBefore(range.start, tcb.held_last) and _tcp.before(tcb.held_last, range.end)) {
                newest = range.*;
            } else {
                others[other_count % others.len] = range.*;
                other_count += 1;
            }
        }
        current = next orelse break;
    }
    var count: usize = 0;
    if (newest) |range| {
        into[0] = range;
        count = 1;
    }
    var index = other_count;
    while (count < into.len and index > 0 and other_count - index < others.len) {
        index -= 1;
        into[count] = others[index % others.len];
        count += 1;
    }
    return count;
}

// --- sending ---------------------------------------------------------------------------

/// The blocks a segment from the peer named, kept: what of each lies
/// past what `ack` acknowledges, if it ends no later than SND.MAX. True
/// when one of them names bytes no block named before, which is what
/// makes an acknowledgement a duplicate one (RFC 6675).
pub fn record(tcb: *Tcb, named: []const Range, ack: u32) bool {
    const floor = if (_tcp.after(ack, tcb.snd_una)) ack else tcb.snd_una;
    var more = false;
    for (named) |block| {
        if (!_tcp.before(block.start, block.end) or _tcp.after(block.end, tcb.snd_max) or _tcp.atOrBefore(block.end, floor)) continue;
        const range: Range = .{ .start = if (_tcp.before(block.start, floor)) floor else block.start, .end = block.end };
        if (!held(tcb, range)) more = true;
        keep(tcb, range);
    }
    return more;
}

/// Whether a block kept holds all of `range`: the blocks are merged, so
/// one does if they do.
fn held(tcb: *const Tcb, range: Range) bool {
    for (tcb.sacked[0..tcb.sacked_count]) |have| {
        if (_tcp.atOrBefore(have.start, range.start) and _tcp.atOrBefore(range.end, have.end)) return true;
    }
    return false;
}

/// A range merged into what is kept, which stays in order.
fn keep(tcb: *Tcb, fresh: Range) void {
    var range = fresh;
    var index: usize = 0;
    while (index < tcb.sacked_count) {
        const have = tcb.sacked[index];
        if (_tcp.atOrBefore(range.start, have.end) and _tcp.atOrBefore(have.start, range.end)) {
            if (_tcp.before(have.start, range.start)) range.start = have.start;
            if (_tcp.after(have.end, range.end)) range.end = have.end;
            for (index + 1..tcb.sacked_count) |later| tcb.sacked[later - 1] = tcb.sacked[later];
            tcb.sacked_count -= 1;
        } else {
            index += 1;
        }
    }
    var at: usize = 0;
    while (at < tcb.sacked_count and _tcp.before(tcb.sacked[at].start, range.start)) at += 1;
    if (tcb.sacked_count == _tcp.sacked_max) {
        if (at == _tcp.sacked_max) return;
        tcb.sacked_count -= 1;
    }
    var shift: usize = tcb.sacked_count;
    while (shift > at) : (shift -= 1) tcb.sacked[shift] = tcb.sacked[shift - 1];
    tcb.sacked[at] = range;
    tcb.sacked_count += 1;
}

/// What SND.UNA has passed, let go of.
pub fn prune(tcb: *Tcb) void {
    var kept: u32 = 0;
    for (tcb.sacked[0..tcb.sacked_count]) |range| {
        if (_tcp.atOrBefore(range.end, tcb.snd_una)) continue;
        tcb.sacked[kept] = .{ .start = if (_tcp.before(range.start, tcb.snd_una)) tcb.snd_una else range.start, .end = range.end };
        kept += 1;
    }
    tcb.sacked_count = kept;
}

/// Where loss begins: the start of the highest block that more than two
/// segments' worth, or three blocks, are SACKed from (RFC 6675's
/// IsLost). What is missing below it is lost; SND.UNA when nothing is.
fn lostBelow(tcb: *const Tcb) u32 {
    var bytes: u32 = 0;
    var index = tcb.sacked_count;
    while (index > 0) {
        index -= 1;
        const range = tcb.sacked[index];
        bytes +%= range.end -% range.start;
        if (bytes > 2 * tcb.mss or tcb.sacked_count - index >= 3) return range.start;
    }
    return tcb.snd_una;
}

/// Where looking for what is lost goes on from.
fn resendFrom(tcb: *const Tcb) u32 {
    return if (_tcp.after(tcb.resend_next, tcb.snd_una)) tcb.resend_next else tcb.snd_una;
}

/// The bytes from `from` up to `to` that no block holds.
fn missing(tcb: *const Tcb, from: u32, to: u32) u32 {
    var total: u32 = 0;
    var cursor = from;
    for (tcb.sacked[0..tcb.sacked_count]) |range| {
        if (!_tcp.before(cursor, to)) return total;
        if (_tcp.before(cursor, range.start)) total += (if (_tcp.before(range.start, to)) range.start else to) -% cursor;
        if (_tcp.after(range.end, cursor)) cursor = range.end;
    }
    if (_tcp.before(cursor, to)) total += to -% cursor;
    return total;
}

/// What is in flight while a loss is repaired (RFC 6675's pipe).
pub fn pipe(tcb: *const Tcb) u32 {
    var flight = tcb.snd_max -% tcb.snd_una;
    for (tcb.sacked[0..tcb.sacked_count]) |range| flight -|= range.end -% range.start;
    const from = resendFrom(tcb);
    const edge = lostBelow(tcb);
    if (_tcp.before(from, edge)) flight -|= missing(tcb, from, edge);
    return flight;
}

/// The first lost stretch not sent again yet, up to the next block.
fn nextLost(tcb: *const Tcb) ?Range {
    const edge = lostBelow(tcb);
    var cursor = resendFrom(tcb);
    for (tcb.sacked[0..tcb.sacked_count]) |range| {
        if (!_tcp.before(cursor, edge)) return null;
        if (_tcp.before(cursor, range.start)) return .{ .start = cursor, .end = if (_tcp.before(range.start, edge)) range.start else edge };
        if (_tcp.after(range.end, cursor)) cursor = range.end;
    }
    return null;
}

/// A segment's worth at most from `start`, not reaching `end`, sent
/// again: how much went.
fn resend(stack: *StackBase, tcb: *Tcb, start: u32, end: u32) u32 {
    const offset = start -% tcb.ring_seq;
    if (offset >= tcb.send.count) return 0;
    const length = @min(@min(end -% start, tcb.mss), tcb.send.count - offset);
    if (length == 0 or output.segment(stack, tcb, start, _tcp.ACK, offset, length) != 0) return 0;
    tcb.resend_next = start +% length;
    return length;
}

/// A duplicate acknowledgement from a peer that SACKs, counted: the
/// repair begun if it is the third or SND.UNA's segment counts as lost.
pub fn duplicate(stack: *StackBase, tcb: *Tcb) void {
    if (tcb.flags & (_tcp.recovering | _tcp.timed_out) != 0) return;
    if (tcb.dupacks < 3 and lostBelow(tcb) == tcb.snd_una) return;
    tcb.ssthresh = timers.halved(tcb);
    tcb.cwnd = tcb.ssthresh;
    tcb.recover = tcb.snd_max;
    tcb.resend_next = tcb.snd_una;
    tcb.flags |= _tcp.recovering;
    tcb.timing = 0;
    stack.counts.tcp_fast_retransmits += 1;
    // The first missing segment goes whatever is in flight (RFC 6675
    // 5, step 4.3).
    _ = resend(stack, tcb, tcb.snd_una, if (tcb.sacked_count > 0) tcb.sacked[0].start else tcb.snd_max);
}

/// While a repair goes on: what is lost sent again, as long as the
/// congestion window has a segment's room on top of the pipe (RFC 6675's
/// NextSeg, its first rule). New data is output.zig's to send.
pub fn repair(stack: *StackBase, tcb: *Tcb) void {
    while (nextLost(tcb)) |lost| {
        if (pipe(tcb) +| tcb.mss > tcb.cwnd) return;
        if (resend(stack, tcb, lost.start, lost.end) == 0) return;
    }
}

/// A partial acknowledgement during a repair, while the peer holds bytes
/// past it: SND.UNA's segment is missing too (RFC 6582's rule), and is
/// sent at once unless it has been. With nothing held past it, SND.UNA's
/// segment is only on its way: after a segment that came late rather
/// than not at all, every acknowledgement until the repair ends is a
/// partial one.
pub fn partial(stack: *StackBase, tcb: *Tcb) void {
    if (tcb.sacked_count == 0 or _tcp.after(tcb.resend_next, tcb.snd_una)) return;
    _ = resend(stack, tcb, tcb.snd_una, tcb.sacked[0].start);
}

/// New data acknowledged during a repair or after a timeout: either is
/// over once `recover` is, and a repair leaves the window at the
/// threshold.
pub fn acknowledged(tcb: *Tcb, ack: u32) void {
    if (_tcp.before(ack, tcb.recover)) return;
    if (tcb.flags & _tcp.recovering != 0) {
        tcb.cwnd = tcb.ssthresh;
        tcb.dupacks = 0;
    }
    tcb.flags &= ~(_tcp.recovering | _tcp.timed_out);
}

/// The retransmission timer ran out: what the peer said it holds is
/// forgotten, and a repair is over until what was sent is acknowledged.
pub fn timedOut(tcb: *Tcb) void {
    tcb.sacked_count = 0;
    if (tcb.flags & _tcp.sack_ok == 0) return;
    tcb.flags = (tcb.flags & ~_tcp.recovering) | _tcp.timed_out;
    tcb.recover = tcb.snd_max;
}

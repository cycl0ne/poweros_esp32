// SPDX-License-Identifier: MIT
//! A connection's timers and what they measure: the retransmission
//! timeout estimated from round trips (RFC 6298), the congestion window
//! (RFC 5681), and the three deadlines a connection has - retransmission
//! or persist, the delayed acknowledgement, and keepalive or TIME_WAIT.
//! Each is set only while its cause is there, and all of them are
//! entries in the stack's heap.
//!
//! **The timeout**: one second until a round trip has been measured; then
//! SRTT + 4·RTTVAR, in microseconds, held between 200 ms and 60 s. One
//! segment's round trip is timed at a time, and never one that was sent
//! again (Karn). Each timeout doubles it, and the next measurement
//! brings it back.
//!
//! **Congestion**: the window starts at RFC 6928's size, grows by a
//! segment per acknowledgement in slow start and by a segment per window
//! beyond the threshold. A timeout sends from the oldest unacknowledged
//! byte again with a window of one segment; three duplicate
//! acknowledgements send the missing segment at once and halve the window
//! (Reno's fast retransmit and recovery).
//!
//! **Persist**: a peer that shut its window is asked, one byte at a time,
//! backing off as the timeout does, so a lost window update cannot stall
//! the connection for ever. It shares the retransmission timer: the two
//! are never needed at once.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _timer = @import("../timer/_timer.zig");
const Timer = _timer.Timer;
const _tcp = @import("_tcp.zig");
const Tcb = _tcp.Tcb;
const output = @import("output.zig");

pub const rto_initial_us: u32 = 1_000_000;
pub const rto_min_us: u32 = 200_000;
pub const rto_max_us: u32 = 60_000_000;
/// Retransmissions before a connection is given up, and before a SYN is.
pub const retries_max: u8 = 12;
pub const syn_retries_max: u8 = 6;
pub const delack_us: u64 = 200_000;
pub const keep_idle_us: u64 = 2 * 60 * 60 * 1_000_000;
pub const keep_interval_us: u64 = 75_000_000;
pub const keep_probes_max = 9;

/// RFC 6928's initial window.
pub fn initialWindow(mss: u32) u32 {
    return @min(10 * mss, @max(2 * mss, 14600));
}

/// The connection stands: its congestion window starts, and keepalive if
/// it was asked for.
pub fn established(stack: *StackBase, tcb: *Tcb) void {
    tcb.cwnd = initialWindow(tcb.mss);
    tcb.ssthresh = 0xFFFF_FFFF;
    const now = _timer.systemTime(stack);
    tcb.last_heard = now;
    keepalive(stack, tcb, now);
}

// --- the retransmission timer -----------------------------------------------------

/// The retransmission timer set, if something is in flight and it is not
/// running.
pub fn arm(stack: *StackBase, tcb: *Tcb, now: u64) void {
    if (tcb.snd_una == tcb.snd_max or tcb.timer_retransmit.armed()) return;
    _ = _timer.set(stack, &tcb.timer_retransmit, now + tcb.rto);
}

/// New data acknowledged: the timer starts again for what is still in
/// flight, or stops.
pub fn restart(stack: *StackBase, tcb: *Tcb, now: u64) void {
    _timer.cancel(stack, &tcb.timer_retransmit);
    arm(stack, tcb, now);
}

/// A round trip measured: SRTT, RTTVAR and the timeout after RFC 6298.
pub fn measured(tcb: *Tcb, sample_us: u64) void {
    const sample: u32 = @intCast(@min(sample_us, rto_max_us));
    if (tcb.srtt == 0) {
        tcb.srtt = @max(sample, 1);
        tcb.rttvar = sample / 2;
    } else {
        const difference = if (tcb.srtt > sample) tcb.srtt - sample else sample - tcb.srtt;
        tcb.rttvar = (3 * tcb.rttvar + difference) / 4;
        tcb.srtt = @max((7 * tcb.srtt + sample) / 8, 1);
    }
    tcb.rto = @max(rto_min_us, @min(tcb.srtt + 4 * tcb.rttvar, rto_max_us));
}

/// `acked` bytes newly acknowledged: the congestion window grows.
pub fn grow(tcb: *Tcb, acked: u32) void {
    if (tcb.cwnd < tcb.ssthresh) {
        tcb.cwnd +|= @min(acked, tcb.mss);
    } else {
        tcb.cwnd +|= @max(tcb.mss * tcb.mss / @max(tcb.cwnd, 1), 1);
    }
}

/// Half of what is in flight, and never less than two segments: the
/// threshold after a loss.
fn halved(tcb: *const Tcb) u32 {
    return @max((tcb.snd_max -% tcb.snd_una) / 2, 2 * tcb.mss);
}

/// A duplicate acknowledgement: the third sends the missing segment at
/// once and halves the window; each after it lets one more segment out.
pub fn duplicate(stack: *StackBase, tcb: *Tcb) void {
    tcb.dupacks += 1;
    if (tcb.dupacks == 3) {
        tcb.ssthresh = halved(tcb);
        resendFirst(stack, tcb);
        tcb.cwnd = tcb.ssthresh + 3 * tcb.mss;
        tcb.timing = 0;
        stack.counts.tcp_fast_retransmits += 1;
    } else if (tcb.dupacks > 3) {
        tcb.cwnd +|= tcb.mss;
        output.output(stack, tcb);
    }
}

/// Recovery over: the window back to the threshold.
pub fn recovered(tcb: *Tcb) void {
    if (tcb.dupacks >= 3) tcb.cwnd = tcb.ssthresh;
    tcb.dupacks = 0;
}

/// The oldest unacknowledged segment sent again, alone.
fn resendFirst(stack: *StackBase, tcb: *Tcb) void {
    const offset = tcb.snd_una -% tcb.ring_seq;
    if (offset > tcb.send.count) return;
    const length = @min(tcb.send.count - offset, tcb.mss);
    if (length == 0) return;
    _ = output.segment(stack, tcb, tcb.snd_una, _tcp.ACK, offset, length);
}

/// The retransmission timer ran out - or, with the peer's window shut
/// and nothing in flight, the persist timer.
pub fn retransmitExpired(stack: *StackBase, fired: *Timer, now: u64) void {
    const tcb: *Tcb = @fieldParentPtr("timer_retransmit", fired);
    if (persisting(tcb)) return probe(stack, tcb, now);
    if (tcb.snd_una == tcb.snd_max) return;
    tcb.retries += 1;
    const syn_state = tcb.state == .syn_sent or tcb.state == .syn_received;
    if (tcb.retries > (if (syn_state) syn_retries_max else retries_max)) {
        stack.counts.tcp_timeouts += 1;
        return _tcp.close(stack, tcb.socket, bsd.ETIMEDOUT);
    }
    stack.counts.tcp_retransmits += 1;
    tcb.rto = @min(tcb.rto *| 2, rto_max_us);
    tcb.ssthresh = halved(tcb);
    tcb.cwnd = tcb.mss;
    tcb.dupacks = 0;
    tcb.timing = 0;
    _ = _timer.set(stack, &tcb.timer_retransmit, now + tcb.rto);
    if (syn_state and _tcp.before(tcb.snd_una, tcb.ring_seq)) {
        _ = output.sendSyn(stack, tcb);
        return;
    }
    // Everything from the oldest unacknowledged byte goes again, as the
    // window lets it.
    tcb.snd_nxt = tcb.snd_una;
    output.output(stack, tcb);
}

/// Whether the peer's window is shut with data waiting and nothing in
/// flight: what the persist timer is for.
pub fn persisting(tcb: *const Tcb) bool {
    return tcb.snd_wnd == 0 and tcb.snd_una == tcb.snd_max and tcb.snd_max -% tcb.ring_seq < tcb.send.count;
}

/// The persist timer set, if the window is shut and it is not running.
pub fn persist(stack: *StackBase, tcb: *Tcb, now: u64) void {
    if (!persisting(tcb) or tcb.timer_retransmit.armed()) return;
    _ = _timer.set(stack, &tcb.timer_retransmit, now + tcb.rto);
}

/// One byte past the shut window, to draw an acknowledgement that says
/// how the window stands; the next probe waits twice as long.
fn probe(stack: *StackBase, tcb: *Tcb, now: u64) void {
    const offset = tcb.snd_nxt -% tcb.ring_seq;
    if (offset < tcb.send.count) {
        tcb.flags |= _tcp.probing;
        _ = output.segment(stack, tcb, tcb.snd_nxt, _tcp.ACK, offset, 1);
    }
    stack.counts.tcp_window_probes += 1;
    tcb.rto = @min(tcb.rto *| 2, rto_max_us);
    _ = _timer.set(stack, &tcb.timer_retransmit, now + tcb.rto);
}

// --- the delayed acknowledgement ---------------------------------------------------

/// An acknowledgement owed for data that came in order: at once for every
/// second segment, else within 200 ms.
pub fn owe(stack: *StackBase, tcb: *Tcb, now: u64) void {
    tcb.unacked_segments += 1;
    if (tcb.unacked_segments >= 2) {
        tcb.flags |= _tcp.ack_now;
        return;
    }
    if (!tcb.timer_delack.armed()) _ = _timer.set(stack, &tcb.timer_delack, now + delack_us);
}

/// An acknowledgement went: nothing is owed.
pub fn paid(stack: *StackBase, tcb: *Tcb) void {
    tcb.unacked_segments = 0;
    _timer.cancel(stack, &tcb.timer_delack);
}

pub fn delackExpired(stack: *StackBase, fired: *Timer, now: u64) void {
    _ = now;
    const tcb: *Tcb = @fieldParentPtr("timer_delack", fired);
    tcb.flags |= _tcp.ack_now;
    output.output(stack, tcb);
}

// --- keepalive and TIME_WAIT -----------------------------------------------------

/// Keepalive set for the idle time after the last segment heard, if the
/// connection asked for it and stands.
pub fn keepalive(stack: *StackBase, tcb: *Tcb, now: u64) void {
    _ = now;
    if (tcb.flags & _tcp.keep_alive == 0 or tcb.state != .established) return;
    _ = _timer.set(stack, &tcb.timer_long, tcb.last_heard + keep_idle_us);
}

/// TIME_WAIT's end, or keepalive's turn.
pub fn longExpired(stack: *StackBase, fired: *Timer, now: u64) void {
    const tcb: *Tcb = @fieldParentPtr("timer_long", fired);
    if (tcb.state == .time_wait) return _tcp.close(stack, tcb.socket, 0);
    if (tcb.flags & _tcp.keep_alive == 0) return;
    switch (tcb.state) {
        .established, .close_wait, .fin_wait_1, .fin_wait_2 => {},
        else => return,
    }
    // Heard from since: wait the rest of the idle time.
    if (now < tcb.last_heard + keep_idle_us and tcb.probes == 0) {
        _ = _timer.set(stack, &tcb.timer_long, tcb.last_heard + keep_idle_us);
        return;
    }
    if (tcb.probes >= keep_probes_max) {
        stack.counts.tcp_timeouts += 1;
        return _tcp.close(stack, tcb.socket, bsd.ETIMEDOUT);
    }
    // A segment the peer has already had, which it must acknowledge.
    tcb.probes += 1;
    _ = output.segment(stack, tcb, tcb.snd_una -% 1, _tcp.ACK, 0, 0);
    _ = _timer.set(stack, &tcb.timer_long, now + keep_interval_us);
}

/// A segment came: the connection is alive.
pub fn heard(stack: *StackBase, tcb: *Tcb, now: u64) void {
    tcb.last_heard = now;
    if (tcb.probes != 0) {
        tcb.probes = 0;
        keepalive(stack, tcb, now);
    }
}

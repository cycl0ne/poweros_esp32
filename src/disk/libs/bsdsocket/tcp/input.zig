// SPDX-License-Identifier: MIT
//! TCP coming in: a segment checked, given to its connection, and taken
//! through RFC 9293's "SEGMENT ARRIVES" (3.10.7) for the state that
//! connection is in.
//!
//! **Checked first**: the header inside the segment and its data offset
//! inside the header's room, the checksum over the pseudo header, and the
//! options walked so that none is read past the option space (a length
//! of 0 or 1, or one past the end, ends the walk). Lengths are unsigned
//! throughout. A segment to an address sent to many is dropped.
//!
//! **No connection**: a segment for a port nobody listens on is answered
//! with a reset, unless it is one.
//!
//! **A listener** that gets a SYN makes a connection there and then, in
//! SYN-RECEIVED, and answers SYN and ACK; the connection waits in the
//! listener's queue until Accept takes it, and a full queue lets the SYN
//! go unanswered so the peer tries again. A SYN with data has its data
//! dropped; the peer sends it again once the connection stands.
//!
//! **A connection** takes a segment only if some of it falls in the
//! window, trims what falls outside, then takes RST, SYN, ACK, data and
//! FIN in that order, each as the RFC says for its state. Data is taken
//! when it starts at RCV.NXT and goes into the receive ring; data that
//! comes before its turn is dropped and a duplicate acknowledgement sent,
//! so the peer sends it again.
//!
//! **Urgent data** (URG): the pointer marks one past the last urgent
//! byte. That byte is set aside from the stream when it comes, for
//! Recv with MSG_OOB, and the place it was taken from is the mark.

const sdk = @import("sdk");
const _inet = @import("../inet/_inet.zig");
const Address = @import("../ip6/address.zig").Address;
const bsd = sdk.bsdsocket;
const exec = sdk.exec;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _ip = @import("../ip/_ip.zig");
const _route = @import("../route/_route.zig");
const _socket = @import("../socket/_socket.zig");
const Socket = _socket.Socket;
const _tcp = @import("_tcp.zig");
const Tcb = _tcp.Tcb;
const output = @import("output.zig");
const timers = @import("timers.zig");
const reorder = @import("reorder.zig");
const _timer = @import("../timer/_timer.zig");

const protocol: u8 = @intCast(bsd.IPPROTO_TCP);

/// A segment's header fields, as this layer reads them.
const Segment = struct {
    source_port: u16,
    destination_port: u16,
    seq: u32,
    ack: u32,
    flags: u8,
    window: u32,
    /// The urgent pointer, read with URG.
    urgent: u32,
    /// The MSS option, if it came.
    mss: ?u32,
    /// The data after the header, and what the segment occupies of the
    /// sequence space: the data, and one each for SYN and FIN.
    data: []const u8,
    length: u32,
};

/// A TCP segment that came in, the frame starting at it; `header` is the
/// IPv4 header in front of it.
pub fn input(stack: *StackBase, interface: *Interface, frame: *Frame, header: _inet.Packet) void {
    _ = interface;
    const sys = stack.sys_base;
    defer stack.frames.give(sys, frame);
    stack.counts.tcp_received += 1;
    const bytes = frame.bytes();
    if (bytes.len < _tcp.header_bytes) return bad(stack);
    const offset: u32 = @as(u32, bytes[12] >> 4) * 4;
    if (offset < _tcp.header_bytes or offset > bytes.len) return bad(stack);
    const total: u32 = @intCast(bytes.len);
    if (_ip.finish(_ip.sum(_inet.pseudoSum(header.source, header.destination, protocol, total), bytes)) != 0) return bad(stack);
    if (header.destination.isV4() and _netif.isBroadcast(stack, header.destination.v4())) return;
    const flags = bytes[13];
    const data = bytes[offset..];
    var seg: Segment = .{
        .source_port = _ip.get16(bytes, 0),
        .destination_port = _ip.get16(bytes, 2),
        .seq = _ip.get32(bytes, 4),
        .ack = _ip.get32(bytes, 8),
        .flags = flags,
        .window = _ip.get16(bytes, 14),
        .urgent = _ip.get16(bytes, 18),
        .mss = mssOption(bytes[_tcp.header_bytes..offset]),
        .data = data,
        .length = @as(u32, @intCast(data.len)) + @intFromBool(flags & _tcp.SYN != 0) + @intFromBool(flags & _tcp.FIN != 0),
    };
    const socket = _tcp.find(stack, header.destination, seg.destination_port, header.source, seg.source_port) orelse {
        return output.sendReset(stack, header, seg.destination_port, seg.source_port, seg.seq, seg.ack, seg.length, seg.flags);
    };
    const tcb = _tcp.of(socket);
    switch (tcb.state) {
        .listen => listening(stack, socket, &seg, header),
        .syn_sent => synSent(stack, tcb, &seg, header),
        .closed => {},
        else => synchronized(stack, tcb, &seg, header),
    }
}

fn bad(stack: *StackBase) void {
    stack.counts.tcp_bad += 1;
}

/// The MSS option among `options`, if it is there and whole.
fn mssOption(options: []const u8) ?u32 {
    var at: usize = 0;
    while (at < options.len) {
        const kind = options[at];
        if (kind == _tcp.option_end) return null;
        if (kind == _tcp.option_nop) {
            at += 1;
            continue;
        }
        if (at + 1 >= options.len) return null;
        const length = options[at + 1];
        if (length < 2 or at + length > options.len) return null;
        if (kind == _tcp.option_mss and length == 4) return _ip.get16(options, at + 2);
        at += length;
    }
    return null;
}

/// The MSS to send with: the peer's, if it named one, held to what our
/// own interface takes.
fn sendMss(stack: *StackBase, socket: *Socket, peer: ?u32) u32 {
    const own: u32 = if (_inet.route(stack, socket.remote_address, socket.scope)) |path| output.localMss(path.mtu, socket.remote_address) else _tcp.default_mss;
    const wanted = peer orelse _tcp.default_mss;
    return @max(@as(u32, 64), @min(wanted, own));
}

// --- LISTEN --------------------------------------------------------------------------

fn listening(stack: *StackBase, listener: *Socket, seg: *const Segment, header: _inet.Packet) void {
    if (seg.flags & _tcp.RST != 0) return;
    if (seg.flags & _tcp.ACK != 0) {
        return output.sendReset(stack, header, seg.destination_port, seg.source_port, seg.seq, seg.ack, seg.length, seg.flags);
    }
    if (seg.flags & _tcp.SYN == 0) return;
    const lt = _tcp.of(listener);
    if (lt.queued >= lt.backlog) {
        stack.counts.tcp_backlog_full += 1;
        return;
    }
    const owner = listener.owner orelse return;
    const child = _socket.createIn(stack, owner, bsd.SOCK_STREAM, bsd.IPPROTO_TCP) orelse return;
    if (!_tcp.create(stack, child)) return _socket.free(stack, child);
    const tcb = _tcp.of(child);
    child.local_address = header.destination;
    child.local_port = listener.local_port;
    child.remote_address = header.source;
    child.remote_port = seg.source_port;
    child.family = listener.family;
    child.v6only = listener.v6only;
    child.hop_limit = listener.hop_limit;
    child.scope = if (header.source.isLinkLocal()) header.arrived else null;
    child.flags |= _socket.bound | _socket.connected | (listener.flags & _socket.nonblocking);
    tcb.flags = _tcp.passive | (_tcp.of(listener).flags & _tcp.no_delay);
    tcb.state = .syn_received;
    tcb.irs = seg.seq;
    tcb.rcv_nxt = seg.seq +% 1;
    tcb.iss = _tcp.initialSequence(stack, child);
    tcb.snd_una = tcb.iss;
    tcb.snd_nxt = tcb.iss +% 1;
    tcb.snd_max = tcb.snd_nxt;
    tcb.ring_seq = tcb.iss +% 1;
    tcb.snd_wnd = seg.window;
    tcb.max_snd_wnd = seg.window;
    tcb.snd_wl1 = seg.seq;
    tcb.snd_wl2 = seg.ack;
    tcb.mss = sendMss(stack, child, seg.mss);
    tcb.listener = listener;
    stack.sys_base.AddTail(&lt.accept_queue, &tcb.accept_node);
    lt.queued += 1;
    _ = output.sendSyn(stack, tcb);
}

// --- SYN-SENT ------------------------------------------------------------------------

fn synSent(stack: *StackBase, tcb: *Tcb, seg: *const Segment, header: _inet.Packet) void {
    const socket = tcb.socket;
    var ack_acceptable = false;
    if (seg.flags & _tcp.ACK != 0) {
        if (_tcp.atOrBefore(seg.ack, tcb.iss) or _tcp.after(seg.ack, tcb.snd_nxt)) {
            return output.sendReset(stack, header, seg.destination_port, seg.source_port, seg.seq, seg.ack, seg.length, seg.flags);
        }
        ack_acceptable = _tcp.atOrBefore(tcb.snd_una, seg.ack) and _tcp.atOrBefore(seg.ack, tcb.snd_nxt);
    }
    if (seg.flags & _tcp.RST != 0) {
        if (ack_acceptable) _tcp.close(stack, socket, bsd.ECONNREFUSED);
        return;
    }
    if (seg.flags & _tcp.SYN == 0) return;
    tcb.irs = seg.seq;
    tcb.rcv_nxt = seg.seq +% 1;
    tcb.mss = sendMss(stack, socket, seg.mss);
    if (ack_acceptable) tcb.snd_una = seg.ack;
    if (_tcp.after(tcb.snd_una, tcb.iss)) {
        tcb.state = .established;
        tcb.snd_wnd = seg.window;
        tcb.max_snd_wnd = seg.window;
        tcb.snd_wl1 = seg.seq;
        tcb.snd_wl2 = seg.ack;
        tcb.flags |= _tcp.ack_now;
        timers.established(stack, tcb);
        timers.restart(stack, tcb, _timer.clock(stack));
        _socket.wake(socket, bsd.FD_CONNECT | bsd.FD_WRITE);
        // Data or a FIN that came with the SYN is taken as if it came
        // after it.
        if (seg.data.len > 0 or seg.flags & _tcp.FIN != 0) {
            var rest = seg.*;
            rest.seq +%= 1;
            rest.flags &= ~_tcp.SYN;
            rest.length -= 1;
            if (!takeText(stack, tcb, &rest)) return;
        }
        output.output(stack, tcb);
        return;
    }
    // Both ends opened at once.
    tcb.state = .syn_received;
    tcb.snd_wnd = seg.window;
    _ = output.sendSyn(stack, tcb);
}

// --- the synchronized states ------------------------------------------------------------

fn synchronized(stack: *StackBase, tcb: *Tcb, original: *const Segment, header: _inet.Packet) void {
    const socket = tcb.socket;
    var seg = original.*;
    if (predicted(stack, tcb, &seg)) return;
    const window = output.window(tcb);

    // First: is any of it inside the window?
    if (!acceptable(tcb, &seg, window)) {
        if (seg.flags & _tcp.RST == 0) {
            tcb.flags |= _tcp.ack_now;
            output.output(stack, tcb);
        }
        return;
    }
    trim(tcb, &seg, window);
    const now = _timer.clock(stack);
    timers.heard(stack, tcb, now);

    // Second: RST. Only one at exactly RCV.NXT resets; one elsewhere in
    // the window may be a guess by a stranger, and draws a challenge ACK
    // the real peer answers with a reset that fits (RFC 5961 3.2).
    if (seg.flags & _tcp.RST != 0) {
        if (seg.seq != tcb.rcv_nxt) return challenge(stack, tcb, now);
        switch (tcb.state) {
            .syn_received => _tcp.close(stack, socket, if (tcb.flags & _tcp.passive != 0) 0 else bsd.ECONNREFUSED),
            .established, .fin_wait_1, .fin_wait_2, .close_wait => _tcp.close(stack, socket, bsd.ECONNRESET),
            else => _tcp.close(stack, socket, 0),
        }
        return;
    }

    // Fourth: a SYN here is answered with a challenge ACK, and dropped
    // (RFC 5961 4.2).
    if (seg.flags & _tcp.SYN != 0) return challenge(stack, tcb, now);

    // Fifth: ACK.
    if (seg.flags & _tcp.ACK == 0) return;
    if (tcb.state == .syn_received) {
        if (!(_tcp.after(seg.ack, tcb.snd_una) and _tcp.atOrBefore(seg.ack, tcb.snd_nxt))) {
            return output.sendReset(stack, header, seg.destination_port, seg.source_port, seg.seq, seg.ack, seg.length, seg.flags);
        }
        tcb.state = .established;
        tcb.snd_wnd = seg.window;
        tcb.max_snd_wnd = @max(tcb.max_snd_wnd, seg.window);
        tcb.snd_wl1 = seg.seq;
        tcb.snd_wl2 = seg.ack;
        timers.established(stack, tcb);
        if (tcb.listener) |listener| {
            _socket.wake(listener, bsd.FD_ACCEPT | bsd.FD_READ);
        } else {
            _socket.wake(socket, bsd.FD_CONNECT | bsd.FD_WRITE);
        }
    }
    // The peer took a window probe's byte: it was sent after all.
    if (tcb.flags & _tcp.probing != 0) {
        tcb.flags &= ~_tcp.probing;
        if (seg.ack == tcb.snd_max +% 1 and tcb.snd_nxt == tcb.snd_max) {
            tcb.snd_nxt = seg.ack;
            tcb.snd_max = seg.ack;
        }
    }
    // An ACK for what was never sent, or older than any window the peer
    // could still be answering, is not the peer's: acknowledged and
    // dropped (RFC 5961 5.2).
    if (_tcp.after(seg.ack, tcb.snd_max) or _tcp.before(seg.ack, tcb.snd_una -% tcb.max_snd_wnd)) {
        return challenge(stack, tcb, now);
    }
    if (_tcp.after(seg.ack, tcb.snd_una)) {
        acknowledged(stack, tcb, seg.ack, now);
    } else if (seg.ack == tcb.snd_una and seg.data.len == 0 and seg.flags & (_tcp.SYN | _tcp.FIN) == 0 and
        seg.window == tcb.snd_wnd and tcb.snd_una != tcb.snd_max)
    {
        timers.duplicate(stack, tcb);
    }
    // The send window, from the newest segment only.
    if (_tcp.before(tcb.snd_wl1, seg.seq) or (tcb.snd_wl1 == seg.seq and _tcp.atOrBefore(tcb.snd_wl2, seg.ack))) {
        tcb.snd_wnd = seg.window;
        tcb.max_snd_wnd = @max(tcb.max_snd_wnd, seg.window);
        tcb.snd_wl1 = seg.seq;
        tcb.snd_wl2 = seg.ack;
    }
    const fin_acked = tcb.flags & _tcp.fin_sent != 0 and tcb.snd_una == tcb.snd_max;
    switch (tcb.state) {
        .fin_wait_1 => if (fin_acked) {
            tcb.state = .fin_wait_2;
        },
        .closing => if (fin_acked) _tcp.timeWait(stack, tcb),
        .last_ack => if (fin_acked) return _tcp.close(stack, socket, 0),
        .time_wait => {
            // The peer sent its FIN again: acknowledge it, and wait anew.
            if (seg.flags & _tcp.FIN != 0) {
                tcb.flags |= _tcp.ack_now;
                _tcp.timeWait(stack, tcb);
                output.output(stack, tcb);
            }
            return;
        },
        else => {},
    }

    // Sixth: URG, from the segment as it came, before any trimming.
    if (original.flags & _tcp.URG != 0 and original.urgent != 0) urgent(tcb, original.seq +% original.urgent);

    // Seventh and eighth: the data, and the FIN.
    if (!takeText(stack, tcb, &seg)) return;
    if (tcb.state != .closed) output.output(stack, tcb);
}

/// Header prediction: in ESTABLISHED, with nothing unusual about the
/// connection - no hole, no recovery, no probe, nothing sent again - a
/// segment that is exactly the next one, with only ACK (and PSH) set and
/// the same window, is either a pure acknowledgement of new data or the
/// next data and nothing else. Those two, most of what comes on a busy
/// connection, are taken here in a few steps; everything else goes the
/// whole way. True when the segment was taken.
fn predicted(stack: *StackBase, tcb: *Tcb, seg: *const Segment) bool {
    if (tcb.state != .established or seg.flags & ~_tcp.PSH != _tcp.ACK) return false;
    if (seg.seq != tcb.rcv_nxt or seg.window != tcb.snd_wnd or tcb.snd_nxt != tcb.snd_max) return false;
    if (tcb.held_bytes != 0 or tcb.dupacks != 0 or tcb.flags & (_tcp.probing | _tcp.read_shut) != 0) return false;
    const now = _timer.clock(stack);
    if (seg.data.len == 0) {
        if (!(_tcp.after(seg.ack, tcb.snd_una) and _tcp.atOrBefore(seg.ack, tcb.snd_max))) return false;
        timers.heard(stack, tcb, now);
        tcb.snd_wl1 = seg.seq;
        tcb.snd_wl2 = seg.ack;
        acknowledged(stack, tcb, seg.ack, now);
        stack.counts.tcp_predicted += 1;
        output.output(stack, tcb);
        return true;
    }
    if (seg.ack != tcb.snd_una or seg.data.len > tcb.receive.space()) return false;
    timers.heard(stack, tcb, now);
    tcb.snd_wl1 = seg.seq;
    tcb.snd_wl2 = seg.ack;
    tcb.rcv_nxt +%= _tcp.deliver(tcb, seg.data);
    _socket.wake(tcb.socket, bsd.FD_READ);
    timers.owe(stack, tcb, now);
    stack.counts.tcp_predicted += 1;
    if (tcb.flags & _tcp.ack_now != 0) output.output(stack, tcb);
    return true;
}

/// A challenge ACK: the connection's own numbers, sent at most
/// `challenges_per_second` times a second for the whole stack, so a
/// flood of forged segments cannot make it a flood of answers.
fn challenge(stack: *StackBase, tcb: *Tcb, now: u64) void {
    if (now >= stack.challenge_since + 1_000_000) {
        stack.challenge_since = now;
        stack.challenges = 0;
    }
    if (stack.challenges >= challenges_per_second) {
        stack.counts.tcp_challenges_dropped += 1;
        return;
    }
    stack.challenges += 1;
    stack.counts.tcp_challenges += 1;
    tcb.flags |= _tcp.ack_now;
    output.output(stack, tcb);
}

pub const challenges_per_second = 10;

/// RFC 9293's acceptability test: whether some of the segment lies in
/// the receive window.
fn acceptable(tcb: *const Tcb, seg: *const Segment, window: u32) bool {
    const first = seg.seq;
    const nxt = tcb.rcv_nxt;
    const in_window = struct {
        fn check(sequence: u32, start: u32, size: u32) bool {
            return _tcp.atOrBefore(start, sequence) and _tcp.before(sequence, start +% size);
        }
    }.check;
    if (seg.length == 0) {
        if (window == 0) return first == nxt;
        return in_window(first, nxt, window);
    }
    if (window == 0) return false;
    return in_window(first, nxt, window) or in_window(first +% seg.length -% 1, nxt, window);
}

/// What of the segment lies before RCV.NXT or past the window, cut off.
fn trim(tcb: *const Tcb, seg: *Segment, window: u32) void {
    if (_tcp.before(seg.seq, tcb.rcv_nxt)) {
        var early = tcb.rcv_nxt -% seg.seq;
        if (seg.flags & _tcp.SYN != 0) {
            seg.flags &= ~_tcp.SYN;
            seg.seq +%= 1;
            seg.length -= 1;
            early -= 1;
        }
        const cut: u32 = @min(early, @as(u32, @intCast(seg.data.len)));
        seg.data = seg.data[cut..];
        seg.seq +%= cut;
        seg.length -= cut;
    }
    const end = tcb.rcv_nxt +% window;
    const data_end = seg.seq +% @as(u32, @intCast(seg.data.len));
    if (_tcp.after(data_end, end)) {
        const over = data_end -% end;
        seg.data = seg.data[0 .. seg.data.len - over];
        seg.length -= over;
        if (seg.flags & _tcp.FIN != 0) {
            seg.flags &= ~_tcp.FIN;
            seg.length -= 1;
        }
    }
}

/// The peer acknowledged everything before `ack`: the round trip timed
/// if it was the segment being timed, the congestion window grown (or
/// recovery ended), that much of the send ring let go of, the program
/// told there is room, and the retransmission timer started again for
/// what is still in flight.
fn acknowledged(stack: *StackBase, tcb: *Tcb, ack: u32, now: u64) void {
    if (tcb.timing != 0 and _tcp.after(ack, tcb.rtt_seq)) {
        timers.measured(tcb, now -| tcb.rtt_start);
        tcb.timing = 0;
    }
    tcb.retries = 0;
    if (tcb.dupacks > 0) {
        timers.recovered(tcb);
    } else {
        timers.grow(tcb, ack -% tcb.snd_una);
    }
    tcb.snd_una = ack;
    if (tcb.flags & _tcp.urgent_out != 0 and _tcp.atOrAfter(ack, tcb.snd_up)) tcb.flags &= ~_tcp.urgent_out;
    if (_tcp.after(ack, tcb.ring_seq)) {
        const data_acked: u32 = @min(ack -% tcb.ring_seq, tcb.send.count);
        tcb.send.drop(data_acked);
        tcb.ring_seq +%= data_acked;
        if (data_acked > 0 or ack == tcb.snd_max) _socket.wake(tcb.socket, bsd.FD_WRITE);
    }
    if (_tcp.before(tcb.snd_nxt, tcb.snd_una)) tcb.snd_nxt = tcb.snd_una;
    timers.restart(stack, tcb, now);
}

/// The segment's data, if it is next, into the receive ring; its FIN, if
/// everything before it has come. False when the connection is gone - it
/// was reset for data nobody would read - and must not be touched again.
fn takeText(stack: *StackBase, tcb: *Tcb, seg: *const Segment) bool {
    const socket = tcb.socket;
    switch (tcb.state) {
        .established, .fin_wait_1, .fin_wait_2, .syn_received => {},
        else => return true,
    }
    if (seg.data.len > 0) {
        if (seg.seq != tcb.rcv_nxt) {
            // Before its turn: held until the hole is filled, and the peer
            // told at once what is missing.
            if (_tcp.after(seg.seq, tcb.rcv_nxt) and tcb.flags & _tcp.read_shut == 0) reorder.hold(stack, tcb, seg.seq, seg.data);
            tcb.flags |= _tcp.ack_now;
            return true;
        }
        if (tcb.flags & _tcp.read_shut != 0) {
            // Nobody will read it: the peer is told so.
            if (socket.flags & _socket.orphan != 0) {
                sendReset(stack, tcb);
                _tcp.close(stack, socket, 0);
                return false;
            }
            tcb.rcv_nxt +%= @intCast(seg.data.len);
        } else {
            const taken = _tcp.deliver(tcb, seg.data);
            tcb.rcv_nxt +%= taken;
            if (tcb.held_bytes > 0 and reorder.release(stack, tcb) > 0) {
                // A hole filled: said at once.
                tcb.flags |= _tcp.ack_now;
            }
            if (taken > 0) _socket.wake(socket, bsd.FD_READ);
        }
        timers.owe(stack, tcb, _timer.clock(stack));
    }
    const data_end = seg.seq +% @as(u32, @intCast(seg.data.len));
    if (seg.flags & _tcp.FIN != 0 and data_end == tcb.rcv_nxt and tcb.flags & _tcp.fin_received == 0) {
        tcb.rcv_nxt +%= 1;
        tcb.flags |= _tcp.fin_received | _tcp.ack_now;
        _socket.wake(socket, bsd.FD_READ | bsd.FD_CLOSE);
        switch (tcb.state) {
            .syn_received, .established => tcb.state = .close_wait,
            .fin_wait_1 => {
                if (tcb.flags & _tcp.fin_sent != 0 and tcb.snd_una == tcb.snd_max) {
                    _tcp.timeWait(stack, tcb);
                } else {
                    tcb.state = .closing;
                }
            },
            .fin_wait_2 => _tcp.timeWait(stack, tcb),
            else => {},
        }
    }
    return true;
}

/// Urgent data announced, ending before `up` (the last urgent byte is
/// the one before it). A pointer further on than any before replaces
/// what was announced; one whose byte was taken in already comes too
/// late to be set aside. The program is told (FD_OOB).
fn urgent(tcb: *Tcb, up: u32) void {
    switch (tcb.state) {
        .established, .fin_wait_1, .fin_wait_2, .syn_received => {},
        else => return,
    }
    if (tcb.flags & _tcp.read_shut != 0) return;
    if (tcb.oob_state != _tcp.oob_none and _tcp.atOrBefore(up, tcb.rcv_up)) return;
    tcb.rcv_up = up;
    const last = up -% 1;
    if (_tcp.before(last, tcb.rcv_nxt)) return;
    tcb.oob_seq = last;
    tcb.oob_state = _tcp.oob_pending;
    _socket.wake(tcb.socket, bsd.FD_OOB);
}

/// A reset from a connection that is going: its next sequence number, no
/// acknowledgement.
fn sendReset(stack: *StackBase, tcb: *Tcb) void {
    _ = output.segment(stack, tcb, tcb.snd_nxt, _tcp.RST, 0, 0);
}

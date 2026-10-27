// SPDX-License-Identifier: MIT
//! TCP going out: what the window lets a connection send, cut into
//! segments of at most the peer's MSS, the FIN once every byte before it
//! has gone, and the acknowledgements and resets that carry no data.
//!
//! A segment is built from the send ring into a fresh frame each time it
//! is sent, so nothing is kept per segment: sending again after a loss
//! reads the same bytes from the ring once more.
//!
//! Urgent data (MSG_OOB) goes in the ring like any other; SND.UP marks
//! its end, and each segment before it carries URG and the pointer.
//!
//! With SACK, an acknowledgement names what is held beyond a hole, and
//! while a loss is repaired what is lost goes first (sack.zig).

const sdk = @import("sdk");
const net = sdk.devices.network;
const _inet = @import("../inet/_inet.zig");
const Address = @import("../ip6/address.zig").Address;
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _ip = @import("../ip/_ip.zig");
const _route = @import("../route/_route.zig");
const _socket = @import("../socket/_socket.zig");
const Socket = _socket.Socket;
const _tcp = @import("_tcp.zig");
const Tcb = _tcp.Tcb;
const timers = @import("timers.zig");
const sack = @import("sack.zig");
const _timer = @import("../timer/_timer.zig");

const protocol: u8 = @intCast(bsd.IPPROTO_TCP);

/// The window to offer: the room in the receive ring, as much of it as
/// 16 bits say once shifted by the connection's scale.
pub fn window(tcb: *const Tcb) u32 {
    return @min(tcb.receive.space(), @as(u32, 65535) << @intCast(tcb.rcv_shift));
}

/// One segment of `connection`: `length` bytes from `ring_offset` in the
/// send ring, with `flags`. A SYN has the MSS option and, where this end
/// scales its windows, the window scale, and offers SACK - in our own
/// SYN always, in the answer to the peer's only when that offered it
/// too. Any other acknowledgement names what is held beyond a hole, as
/// many blocks as fit. 0, or the errno that says why it could not go.
pub fn segment(stack: *StackBase, tcb: *Tcb, sequence: u32, flags: u8, ring_offset: u32, length: u32) i32 {
    const socket = tcb.socket;
    const path = _inet.route(stack, socket.remote_address, socket.scope) orelse return bsd.EHOSTUNREACH;
    const frame = stack.frames.take(stack.sys_base) orelse return bsd.ENOBUFS;
    if (length > 0) tcb.send.copyOut(ring_offset, frame.room()[frame.start..][0..length]);
    frame.length = length;
    const with_mss = flags & _tcp.SYN != 0;
    const with_scale = with_mss and _tcp.window_shift != 0 and (tcb.state == .syn_sent or tcb.rcv_shift != 0);
    const with_sack_ok = with_mss and (tcb.state == .syn_sent or tcb.flags & _tcp.sack_ok != 0);
    var named: [_tcp.sack_blocks_max]_tcp.Range = undefined;
    const named_count = if (flags & (_tcp.SYN | _tcp.RST | _tcp.ACK) == _tcp.ACK and tcb.flags & _tcp.sack_ok != 0)
        sack.blocks(tcb, named[0..sack.fitting(tcb, length)])
    else
        0;
    const header_length: u32 = _tcp.header_bytes + @as(u32, if (with_mss) 4 else 0) + @as(u32, if (with_scale) 4 else 0) +
        @as(u32, if (with_sack_ok) 4 else 0) + sack.optionBytes(named_count);
    // A SYN's window is never scaled (RFC 7323 2.2); any other says the
    // window shifted down, and what it offers is that shifted back up.
    const shift: u5 = if (with_mss) 0 else @intCast(tcb.rcv_shift);
    const field = @min(window(tcb), @as(u32, 65535) << shift) >> shift;
    const offered = field << shift;
    const header = frame.push(header_length);
    _ip.put16(header, 0, socket.local_port);
    _ip.put16(header, 2, socket.remote_port);
    _ip.put32(header, 4, sequence);
    _ip.put32(header, 8, if (flags & _tcp.ACK != 0) tcb.rcv_nxt else 0);
    // While urgent data is out, every segment before its end says where
    // it ends (BSD's pointer: one past the last urgent byte).
    const urgent = flags & (_tcp.ACK | _tcp.RST) == _tcp.ACK and tcb.flags & _tcp.urgent_out != 0 and _tcp.after(tcb.snd_up, sequence);
    header[12] = @intCast((header_length / 4) << 4);
    header[13] = if (urgent) flags | _tcp.URG else flags;
    _ip.put16(header, 14, @intCast(field));
    _ip.put16(header, 16, 0);
    _ip.put16(header, 18, if (urgent) @intCast(@min(tcb.snd_up -% sequence, 0xFFFF)) else 0);
    var at: usize = _tcp.header_bytes;
    if (with_mss) {
        header[at] = _tcp.option_mss;
        header[at + 1] = 4;
        _ip.put16(header, at + 2, @intCast(localMss(path.mtu, socket.remote_address)));
        at += 4;
    }
    if (with_scale) {
        header[at..][0..4].* = .{ _tcp.option_nop, _tcp.option_window_scale, 3, _tcp.window_shift };
        at += 4;
    }
    if (with_sack_ok) {
        header[at..][0..4].* = .{ _tcp.option_nop, _tcp.option_nop, _tcp.option_sack_permitted, 2 };
        at += 4;
    }
    if (named_count > 0) {
        header[at..][0..4].* = .{ _tcp.option_nop, _tcp.option_nop, _tcp.option_sack, @intCast(2 + 8 * named_count) };
        at += 4;
        for (named[0..named_count]) |block| {
            _ip.put32(header, at, block.start);
            _ip.put32(header, at + 4, block.end);
            at += 8;
        }
    }
    // Over IPv4, a device that fills in checksums gets the segment with
    // its checksum 0.
    if (path.interface.offload & net.S2OFFLOADF_TX_CHECKSUMS != 0 and socket.remote_address.isV4()) {
        frame.fill_checksums = 1;
    } else {
        const total = frame.length;
        _ip.put16(header, 16, _ip.finish(_ip.sum(_inet.pseudoSum(socket.local_address, socket.remote_address, protocol, total), frame.bytes())));
    }
    if (flags & _tcp.ACK != 0) {
        tcb.rcv_adv = tcb.rcv_nxt +% offered;
        tcb.flags &= ~_tcp.ack_now;
        timers.paid(stack, tcb);
    }
    stack.counts.tcp_sent += 1;
    return _inet.output(stack, frame, socket.local_address, socket.remote_address, protocol, path, socket.hop_limit);
}

/// The MSS this machine takes over an interface of `mtu` to `peer`: what is
/// left of a packet once the IP header of the peer's family and TCP's own
/// are taken off.
pub fn localMss(mtu: u32, peer: Address) u32 {
    return mtu - _inet.headerBytes(peer) - _tcp.header_bytes;
}

/// Everything the connection may send now, sent: data as far as the
/// peer's window and the congestion window go - a small tail waits while
/// data is in flight, unless TCP_NODELAY or urgent data (Nagle) - the FIN once the data
/// before it has gone, and an acknowledgement if one is owed and nothing
/// else carried it. After a timeout SND.NXT is back at SND.UNA, and the
/// same loop sends everything again, FIN included. A segment the link
/// has no room for (ENOBUFS) waits for the acknowledgements of those
/// before it. While a loss is repaired with SACK, what is lost goes
/// first, and the congestion window holds the pipe rather than all that
/// was sent; while segments are held beyond a hole, each segment leaves
/// room for the blocks that name them.
pub fn output(stack: *StackBase, tcb: *Tcb) void {
    switch (tcb.state) {
        .closed, .listen, .syn_sent, .time_wait => {
            if (tcb.state == .time_wait and tcb.flags & _tcp.ack_now != 0) _ = segment(stack, tcb, tcb.snd_nxt, _tcp.ACK, 0, 0);
            return;
        },
        else => {},
    }
    const now = _timer.clock(stack);
    if (tcb.flags & _tcp.recovering != 0) sack.repair(stack, tcb);
    while (true) {
        // Nothing but an acknowledgement goes before our SYN is.
        const synced = _tcp.atOrAfter(tcb.snd_una, tcb.ring_seq);
        const data_end = tcb.ring_seq +% tcb.send.count;
        const unsent: u32 = if (!synced or _tcp.after(tcb.snd_nxt, data_end)) 0 else data_end -% tcb.snd_nxt;
        const offset = tcb.snd_nxt -% tcb.ring_seq;
        const in_flight = tcb.snd_nxt -% tcb.snd_una;
        const most = if (tcb.flags & _tcp.sack_ok != 0 and tcb.held_count > 0) tcb.mss - sack.option_max else tcb.mss;
        // While a loss is repaired, a segment goes only when the
        // congestion window has room for a whole one (RFC 6675 5).
        const repairing = tcb.flags & _tcp.recovering != 0;
        const congestion_room = tcb.cwnd -| (if (repairing) sack.pipe(tcb) else in_flight);
        const usable = @min(tcb.snd_wnd -| in_flight, if (repairing and congestion_room < most) 0 else congestion_room);
        var length: u32 = @min(unsent, @min(usable, most));
        const small_tail = length > 0 and length < most and length == unsent and in_flight > 0;
        if (small_tail and tcb.flags & (_tcp.no_delay | _tcp.fin_wanted | _tcp.urgent_out) == 0) length = 0;
        const send_fin = synced and tcb.flags & _tcp.fin_wanted != 0 and length == unsent and tcb.snd_nxt +% length == data_end;
        if (length == 0 and !send_fin and tcb.flags & _tcp.ack_now == 0) break;
        var flags: u8 = _tcp.ACK;
        if (length > 0 and length == unsent) flags |= _tcp.PSH;
        if (send_fin) flags |= _tcp.FIN;
        // The segment is counted as sent before it goes: over lo0 its
        // answer comes back to this connection before `segment` returns,
        // and must find SND.NXT past it.
        const sequence = tcb.snd_nxt;
        const fresh = _tcp.atOrAfter(sequence, tcb.snd_max);
        tcb.snd_nxt +%= length + @intFromBool(send_fin);
        if (_tcp.after(tcb.snd_nxt, tcb.snd_max)) tcb.snd_max = tcb.snd_nxt;
        if (send_fin and tcb.flags & _tcp.fin_sent == 0) {
            tcb.flags |= _tcp.fin_sent;
            tcb.state = switch (tcb.state) {
                .syn_received, .established => .fin_wait_1,
                .close_wait => .last_ack,
                else => tcb.state,
            };
        }
        // One segment's round trip timed at a time, never one sent again.
        if (length > 0 and fresh and tcb.timing == 0) {
            tcb.timing = 1;
            tcb.rtt_seq = sequence;
            tcb.rtt_start = now;
        }
        const refused = segment(stack, tcb, sequence, flags, offset, length);
        if (refused == bsd.ENOBUFS) {
            // No frame, or the link's queue full: the segment did not go.
            // SND.NXT goes back to it, and the congestion window to half
            // of what is in flight, so the queue drains before the next
            // burst; the acknowledgements of what went send it, or the
            // timer does if none come. Not the connection's error.
            tcb.snd_nxt = sequence;
            if (tcb.timing != 0 and tcb.rtt_seq == sequence) tcb.timing = 0;
            tcb.ssthresh = @max((sequence -% tcb.snd_una) / 2, 2 * tcb.mss);
            tcb.cwnd = tcb.ssthresh;
            timers.arm(stack, tcb, now);
            break;
        }
        if (refused != 0) {
            tcb.socket.pending_error = refused;
            break;
        }
        if (length > 0 or send_fin) timers.arm(stack, tcb, now);
        if (length == 0) break;
    }
    timers.persist(stack, tcb, now);
}

/// A SYN, or a SYN and ACK answering one: ISS, the MSS option and the
/// window scale where it goes.
pub fn sendSyn(stack: *StackBase, tcb: *Tcb) i32 {
    const flags: u8 = if (tcb.state == .syn_received) _tcp.SYN | _tcp.ACK else _tcp.SYN;
    const refused = segment(stack, tcb, tcb.iss, flags, 0, 0);
    timers.arm(stack, tcb, _timer.clock(stack));
    return refused;
}

/// A reset for a segment that has no connection to go to, or that a
/// connection refuses. `header` is the IPv4 header of the segment, `seq`
/// and `ack` its numbers, `length` what it occupies of the sequence
/// space, `flags` its flags.
pub fn sendReset(stack: *StackBase, header: _inet.Packet, local_port: u16, remote_port: u16, seq: u32, ack: u32, length: u32, flags: u8) void {
    if (flags & _tcp.RST != 0) return;
    const path = _inet.route(stack, header.source, header.arrived) orelse return;
    const frame = stack.frames.take(stack.sys_base) orelse return;
    const out = frame.push(_tcp.header_bytes);
    _ip.put16(out, 0, local_port);
    _ip.put16(out, 2, remote_port);
    if (flags & _tcp.ACK != 0) {
        _ip.put32(out, 4, ack);
        _ip.put32(out, 8, 0);
        out[13] = _tcp.RST;
    } else {
        _ip.put32(out, 4, 0);
        _ip.put32(out, 8, seq +% length);
        out[13] = _tcp.RST | _tcp.ACK;
    }
    out[12] = (_tcp.header_bytes / 4) << 4;
    _ip.put16(out, 14, 0);
    _ip.put16(out, 16, 0);
    _ip.put16(out, 18, 0);
    _ip.put16(out, 16, _ip.finish(_ip.sum(_inet.pseudoSum(header.destination, header.source, protocol, _tcp.header_bytes), out)));
    stack.counts.tcp_resets_sent += 1;
    _ = _inet.output(stack, frame, header.destination, header.source, protocol, path, 0);
}

// SPDX-License-Identifier: MIT
//! One session channel (RFC 4254), the part either end does alike: the
//! data both ways, each end's window, the ends of the input and the
//! close. The server (`connection.zig`) and the client (`client.zig`)
//! each hold one; opening it and its requests are theirs.
//!
//! **In**: what the peer sends goes into a ring of `ring_bytes`, which is
//! the window the peer is given; reading from it gives the window back
//! once half of it is read. The peer's extended data (its errors) goes
//! into the same ring when the end keeps it, and is given back at once
//! when not. **Out**: data keeps to the window and the packet size the
//! peer gave, and waits while a key exchange runs.
//!
//! Our number for the channel is always 0: an end has one channel.

const sdk = @import("sdk");
const wire = @import("wire.zig");
const transport_file = @import("transport.zig");
const Transport = transport_file.Transport;
const Reader = wire.Reader;
const Writer = wire.Writer;

/// The window the peer is given, and the largest packet we take.
pub const ring_bytes = 16384;
pub const our_max_packet: u32 = 8192;
/// The most data one packet to the peer carries.
pub const data_max: u32 = 4096;

pub const Channel = struct {
    /// Open both ways: the peer's number, window and packet size known.
    open: bool = false,
    peer_channel: u32 = 0,
    peer_window: u32 = 0,
    peer_max_packet: u32 = 0,
    /// The peer sent its end; it closed the channel; we closed it; we
    /// sent our end.
    input_ended: bool = false,
    peer_closed: bool = false,
    closed: bool = false,
    output_ended: bool = false,
    /// The peer's extended data read with its data.
    keep_extended: bool = false,
    /// What the peer sent, and what of the window is read but not given
    /// back yet.
    ring: [ring_bytes]u8 = undefined,
    ring_start: usize = 0,
    ring_length: usize = 0,
    unacknowledged: u32 = 0,
    window_left: u32 = ring_bytes,

    /// The channel open, with the peer's number, window and packet size.
    pub fn opened(channel: *Channel, peer_channel: u32, window: u32, max_packet: u32) void {
        channel.open = true;
        channel.peer_channel = peer_channel;
        channel.peer_window = window;
        channel.peer_max_packet = max_packet;
    }

    /// The messages on the channel either end answers alike - the window,
    /// data, the end, the close - handled: whether `kind` was one.
    pub fn handle(channel: *Channel, t: *Transport, kind: u8, reader: *Reader) bool {
        switch (kind) {
            transport_file.msg_channel_window_adjust => {
                const more = reader.uint32();
                channel.peer_window +|= more;
            },
            transport_file.msg_channel_data, transport_file.msg_channel_extended_data => {
                const extended = kind == transport_file.msg_channel_extended_data;
                if (extended) _ = reader.uint32();
                const data = reader.string();
                if (reader.bad or data.len > channel.window_left) {
                    t.disconnect(transport_file.reason_protocol_error, "past the window");
                    return true;
                }
                channel.window_left -= @intCast(data.len);
                if (extended and !channel.keep_extended) {
                    // Not read by anyone: the window given back at once.
                    channel.unacknowledged += @intCast(data.len);
                    channel.acknowledge(t, false);
                } else {
                    channel.push(data);
                }
            },
            transport_file.msg_channel_eof => channel.input_ended = true,
            transport_file.msg_channel_close => {
                channel.input_ended = true;
                channel.peer_closed = true;
                channel.close(t);
            },
            else => return false,
        }
        return true;
    }

    /// A message about the channel with nothing but the peer's number.
    pub fn reply(channel: *const Channel, t: *Transport, kind: u8) void {
        var bytes: [5]u8 = undefined;
        bytes[0] = kind;
        wire.put32(bytes[1..5], channel.peer_channel);
        t.send(&bytes);
    }

    /// A byte in among what the peer sent - an interrupt as Ctrl-C.
    pub fn pushByte(channel: *Channel, byte: u8) void {
        if (channel.ring_length == channel.ring.len) return;
        channel.ring[(channel.ring_start + channel.ring_length) % channel.ring.len] = byte;
        channel.ring_length += 1;
    }

    fn push(channel: *Channel, data: []const u8) void {
        // The window keeps the peer within the ring; an interrupt may have
        // taken a byte of it.
        for (data) |byte| channel.pushByte(byte);
    }

    /// The window given back when half of it is read - or now, with
    /// `now`.
    pub fn acknowledge(channel: *Channel, t: *Transport, now: bool) void {
        if (channel.unacknowledged == 0 or channel.closed or channel.peer_closed or t.kex != .idle) return;
        if (!now and channel.unacknowledged < ring_bytes / 2) return;
        var bytes: [9]u8 = undefined;
        bytes[0] = transport_file.msg_channel_window_adjust;
        wire.put32(bytes[1..5], channel.peer_channel);
        wire.put32(bytes[5..9], channel.unacknowledged);
        t.send(&bytes);
        channel.window_left += channel.unacknowledged;
        channel.unacknowledged = 0;
    }

    /// What the peer sent, into `into`: how many bytes.
    pub fn read(channel: *Channel, t: *Transport, into: []u8) usize {
        const count = @min(into.len, channel.ring_length);
        for (into[0..count]) |*byte| {
            byte.* = channel.ring[channel.ring_start];
            channel.ring_start = (channel.ring_start + 1) % channel.ring.len;
        }
        channel.ring_length -= count;
        channel.unacknowledged += @intCast(count);
        if (t.roomForReply()) channel.acknowledge(t, false);
        return count;
    }

    pub fn readable(channel: *const Channel) usize {
        return channel.ring_length;
    }

    /// Whether nothing more will come from the peer: it sent its end, or
    /// the connection is gone.
    pub fn inputEnded(channel: *const Channel, t: *const Transport) bool {
        return channel.input_ended or t.ended();
    }

    /// Whether data can go to the peer now.
    pub fn writable(channel: *const Channel, t: *const Transport) bool {
        return t.phase == .packets and channel.open and !channel.closed and !channel.peer_closed and !channel.output_ended and
            t.kex == .idle and channel.peer_window > 0 and t.out.len - t.out_length >= data_max + 64;
    }

    /// Whether data can never go to the peer again.
    pub fn writeEnded(channel: *const Channel, t: *const Transport) bool {
        return t.ended() or channel.closed or channel.peer_closed or channel.output_ended;
    }

    /// `data` to the peer, as much as its window, its packet size and the
    /// output take: how many bytes.
    pub fn write(channel: *Channel, t: *Transport, data: []const u8) usize {
        if (!channel.writable(t)) return 0;
        const most = @min(@min(channel.peer_window, channel.peer_max_packet), data_max);
        const count: u32 = @intCast(@min(data.len, most));
        if (count == 0) return 0;
        var bytes: [9 + data_max]u8 = undefined;
        var writer = Writer{ .bytes = &bytes };
        writer.byte(transport_file.msg_channel_data);
        writer.uint32(channel.peer_channel);
        writer.string(data[0..count]);
        t.send(writer.written());
        channel.peer_window -= count;
        return count;
    }

    /// Our end: EOF sent, once.
    pub fn endOutput(channel: *Channel, t: *Transport) void {
        if (!channel.open or channel.output_ended or channel.closed or t.phase != .packets) return;
        channel.reply(t, transport_file.msg_channel_eof);
        channel.output_ended = true;
    }

    /// CLOSE sent, once.
    pub fn close(channel: *Channel, t: *Transport) void {
        if (!channel.open or channel.closed or t.phase != .packets) return;
        channel.reply(t, transport_file.msg_channel_close);
        channel.closed = true;
    }
};

// SPDX-License-Identifier: MIT
//! Capture sockets (PF_PACKET): every frame an interface sends or takes,
//! copied to each capture socket that watches it, as a datagram that
//! starts with a CaptureHeader - when, which way, how long, which
//! interface - and then the frame with its link header: Ethernet's made
//! again from the addresses the device gave with the packet, or lo0's
//! four-byte address family.
//!
//! **Taking nothing from the stack.** A copy comes from the frame pool,
//! and a socket holds `queue_max` of them at the most - small frames are
//! many to a buffer - so a program that does not read cannot starve the
//! device reads of frames; what does not fit is counted and told with the
//! next frame that does. With no capture socket open nothing is looked
//! at: the taps cost a compare.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _socket = @import("../socket/_socket.zig");
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _timer = @import("../timer/_timer.zig");
const _frame = @import("../frame/_frame.zig");

/// The most frames a capture socket keeps unread.
pub const queue_max = 16;

const header_bytes = @sizeOf(bsd.CaptureHeader);
const ethernet_bytes = 14;
const null_bytes = 4;

/// How a frame is framed for the capture: its link header's fields.
pub const Link = union(enum) {
    ethernet: struct { to: *const [6]u8, from: *const [6]u8, packet_type: u16 },
    loopback,
};

/// `packet`, going `direction` through `interface`, copied to every
/// capture socket that watches it. Under the lock.
pub fn tap(stack: *StackBase, interface: *Interface, packet: []const u8, direction: u8, link: Link) void {
    const sys = stack.sys_base;
    var it = stack.sockets.iterator();
    var when: ?sdk.devices.timer.TimeVal = null;
    while (it.next()) |node| {
        const socket = _socket.fromNode(node);
        if (socket.flags & _socket.capture == 0 or socket.flags & _socket.capture_detached != 0) continue;
        if (socket.capture_interface) |watched| {
            if (watched != interface) continue;
        }
        var queued: u32 = 0;
        var frames = socket.receive.iterator();
        while (frames.next()) |_| queued += 1;
        const copy = if (queued < queue_max) stack.frames.take(sys) else null;
        const frame = copy orelse {
            socket.capture_dropped +|= 1;
            continue;
        };
        const now = when orelse blk: {
            when = _timer.date(stack);
            break :blk when.?;
        };
        const link_bytes: u32 = if (link == .loopback) null_bytes else ethernet_bytes;
        const whole: u32 = link_bytes + @as(u32, @intCast(packet.len));
        // The header goes in the headroom, the frame behind it; a frame
        // longer than the buffer is cut.
        frame.start = _frame.headroom - header_bytes;
        const room = frame.capacity - frame.start - header_bytes;
        const kept = @min(whole, room);
        const header: bsd.CaptureHeader = .{
            .secs = now.secs,
            .micro = now.micro,
            .length = whole,
            .dropped = socket.capture_dropped,
            .direction = direction,
            .link = if (link == .loopback) bsd.CAPTURE_LINK_NULL else bsd.CAPTURE_LINK_ETHERNET,
            .interface = interface.name,
        };
        socket.capture_dropped = 0;
        const out = frame.room()[frame.start..][0 .. header_bytes + kept];
        @memcpy(out[0..header_bytes], @as(*const [header_bytes]u8, @ptrCast(&header)));
        var linked: [ethernet_bytes]u8 = undefined;
        switch (link) {
            .ethernet => |fields| {
                linked[0..6].* = fields.to.*;
                linked[6..12].* = fields.from.*;
                linked[12] = @truncate(fields.packet_type >> 8);
                linked[13] = @truncate(fields.packet_type);
            },
            .loopback => {
                const family: u32 = bsd.AF_INET;
                linked[0..4].* = @bitCast(family);
            },
        }
        const body = out[header_bytes..];
        const link_part = @min(link_bytes, kept);
        @memcpy(body[0..link_part], linked[0..link_part]);
        const packet_part = kept - link_part;
        @memcpy(body[link_part..][0..packet_part], packet[0..packet_part]);
        frame.length = header_bytes + kept;
        sys.AddTail(&socket.receive, &frame.node);
        socket.receive_bytes += frame.cost();
        _socket.wake(socket, bsd.FD_READ);
    }
}

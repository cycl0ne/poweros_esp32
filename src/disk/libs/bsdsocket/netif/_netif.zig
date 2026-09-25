// SPDX-License-Identifier: MIT
//! Interfaces: where the stack's packets go out and come in. Each has a
//! name, an address with its netmask, and an MTU. The loopback interface,
//! `lo0` at 127.0.0.1/8, is always there: what it sends comes straight
//! back in, under the same holding of the lock, with no device and no
//! link header. An interface on a network device (`device.zig`) has an
//! Ethernet address, and sends through its `transmit`: a packet for a
//! station on its net goes to the Ethernet address ARP finds for it, a
//! broadcast to every station.
//!
//! Addresses are kept in the chip's order, as numbers to mask and compare;
//! they are turned into the network's order only where a header is
//! written.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _ip = @import("../ip/_ip.zig");
const _arp = @import("../arp/_arp.zig");
const _timer = @import("../timer/_timer.zig");

/// Hands `frame` to the link, to the station `to`, as a packet of
/// `packet_type`: 0, or the errno of a frame that could not go. The frame
/// is the link's either way.
pub const TransmitFn = *const fn (stack: *StackBase, interface: *Interface, frame: *Frame, to: *const [6]u8, packet_type: u16) i32;

pub const Interface = extern struct {
    /// "lo0", or the name the interface was added as.
    name: [16]u8 = @splat(0),
    address: u32 = 0,
    netmask: u32 = 0,
    /// The address every station on the interface's net answers to.
    broadcast: u32 = 0,
    /// The most bytes of IP one packet may have.
    mtu: u32 = 0,
    used: u8 = 0,
    up: u8 = 0,
    loopback: u8 = 0,
    /// A link that needs no ARP - SLIP, a point-to-point link, the host
    /// tests' link between two stacks: every frame goes to `transmit` as
    /// it is.
    no_arp: u8 = 0,
    /// The address comes from DHCP, one is bound now, or a link-local one
    /// stands in while DHCP gets no answer.
    dhcp: u8 = 0,
    bound: u8 = 0,
    link_local: u8 = 0,
    pad3: u8 = 0,
    /// Its Ethernet address, for an interface on a device.
    hardware: [6]u8 = @splat(0),
    pad2: [2]u8 = .{ 0, 0 },
    /// How a frame goes out, and what it goes out through.
    transmit: ?TransmitFn = null,
    device: ?*anyopaque = null,
    /// Packets out and in, and the ones that could not go.
    sent: u64 align(4) = 0,
    received: u64 align(4) = 0,
    dropped: u32 = 0,

    /// Whether `address` is on the interface's own net.
    pub fn holds(interface: *const Interface, address: u32) bool {
        return address & interface.netmask == interface.address & interface.netmask;
    }

    /// Its name, as a C string.
    pub fn nameText(interface: *const Interface) [*:0]const u8 {
        return @ptrCast(&interface.name);
    }
};

/// The loopback interface's MTU: large, since nothing carries it.
pub const loopback_mtu: u32 = 1500;

/// `lo0`, and its route.
pub fn addLoopback(stack: *StackBase) void {
    const lo = &stack.interfaces[0];
    lo.* = .{
        .address = bsd.INADDR_LOOPBACK,
        .netmask = 0xFF00_0000,
        .broadcast = 0x7FFF_FFFF,
        .mtu = loopback_mtu,
        .used = 1,
        .up = 1,
        .loopback = 1,
    };
    @memcpy(lo.name[0..3], "lo0");
    _ = @import("../route/_route.zig").add(stack, 0x7F00_0000, 0xFF00_0000, 0, lo);
}

pub fn loopbackOf(stack: *StackBase) *Interface {
    return &stack.interfaces[0];
}

/// The interface whose address `address` is, if any is.
pub fn owning(stack: *StackBase, address: u32) ?*Interface {
    for (&stack.interfaces) |*interface| {
        if (interface.used != 0 and interface.up != 0 and interface.address == address) return interface;
    }
    return null;
}

/// The interface called `name`, if there is one.
pub fn named(stack: *StackBase, name: [*:0]const u8) ?*Interface {
    for (&stack.interfaces) |*interface| {
        if (interface.used == 0) continue;
        var at: usize = 0;
        while (at < interface.name.len and interface.name[at] == name[at] and name[at] != 0) at += 1;
        if (at < interface.name.len and interface.name[at] == name[at]) return interface;
    }
    return null;
}

/// A free interface slot, if there is one.
pub fn free(stack: *StackBase) ?*Interface {
    for (&stack.interfaces) |*interface| {
        if (interface.used == 0) return interface;
    }
    return null;
}

/// Whether a packet to `address` is for this machine: one of its
/// addresses, the limited broadcast, or the broadcast of one of its nets.
pub fn isOurs(stack: *StackBase, address: u32) bool {
    if (address == bsd.INADDR_BROADCAST) return true;
    for (&stack.interfaces) |*interface| {
        if (interface.used == 0 or interface.up == 0) continue;
        if (address == interface.address or address == interface.broadcast) return true;
        if (interface.loopback != 0 and interface.holds(address)) return true;
    }
    return false;
}

/// Whether `address` is sent to many: the limited broadcast, a net's
/// broadcast, or a multicast group.
pub fn isBroadcast(stack: *StackBase, address: u32) bool {
    if (address == bsd.INADDR_BROADCAST or address >> 28 == 0xE) return true;
    for (&stack.interfaces) |*interface| {
        if (interface.used != 0 and address == interface.broadcast) return true;
    }
    return false;
}

/// `frame`, an IPv4 packet, out on `interface` to the station `next_hop`.
/// The frame is the interface's from here: 0, or the errno of a packet
/// that could not go.
pub fn output(stack: *StackBase, interface: *Interface, frame: *Frame, next_hop: u32) i32 {
    interface.sent += 1;
    if (interface.loopback != 0) return loop(stack, interface, frame);
    if (interface.no_arp != 0) return transmit(stack, interface, frame, &_arp.broadcast, _ip.ethertype);
    if (next_hop == bsd.INADDR_BROADCAST or next_hop == interface.broadcast) {
        return transmit(stack, interface, frame, &_arp.broadcast, _ip.ethertype);
    }
    return _arp.resolve(stack, interface, next_hop, frame, _timer.systemTime(stack));
}

/// `frame` back in on lo0. The outermost of these delivers; a packet sent
/// while it runs - TCP answering a segment with one - waits in the queue
/// and is delivered by the same loop after it, so nothing recurses.
fn loop(stack: *StackBase, interface: *Interface, frame: *Frame) i32 {
    const sys = stack.sys_base;
    if (stack.looping != 0) {
        sys.AddTail(&stack.loopback_queue, &frame.node);
        return 0;
    }
    stack.looping = 1;
    defer stack.looping = 0;
    var next: ?*Frame = frame;
    while (next) |packet| {
        interface.received += 1;
        _ip.input(stack, interface, packet);
        next = if (sys.RemHead(&stack.loopback_queue)) |node| @fieldParentPtr("node", node) else null;
    }
    return 0;
}

/// `frame` handed to the interface's link for the station `to`.
pub fn transmit(stack: *StackBase, interface: *Interface, frame: *Frame, to: *const [6]u8, packet_type: u16) i32 {
    const send = interface.transmit orelse {
        interface.dropped += 1;
        stack.frames.give(stack.sys_base, frame);
        return bsd.ENETDOWN;
    };
    return send(stack, interface, frame, to, packet_type);
}

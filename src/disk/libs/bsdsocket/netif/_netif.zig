// SPDX-License-Identifier: MIT
//! Interfaces: where the stack's packets go out and come in. Each has a
//! name, an address with its netmask, and an MTU. The loopback interface,
//! `lo0` at 127.0.0.1/8, is always there: what it sends comes straight
//! back in, under the same holding of the lock, with no device and no
//! link header. An interface on a network device is added by
//! AddInterfaceTagList.
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
    pad: u8 = 0,
    /// Packets out and in.
    sent: u64 align(4) = 0,
    received: u64 align(4) = 0,

    /// Whether `address` is on the interface's own net.
    pub fn holds(interface: *const Interface, address: u32) bool {
        return address & interface.netmask == interface.address & interface.netmask;
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

/// `frame`, an IPv4 packet, out on `interface` to the station `next_hop`.
/// The frame is the interface's from here: sent and given back, or
/// dropped.
pub fn output(stack: *StackBase, interface: *Interface, frame: *Frame, next_hop: u32) void {
    _ = next_hop;
    interface.sent += 1;
    if (interface.loopback != 0) {
        interface.received += 1;
        return _ip.input(stack, interface, frame);
    }
    stack.frames.give(stack.sys_base, frame);
}

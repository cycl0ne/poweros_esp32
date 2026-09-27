// SPDX-License-Identifier: MIT
//! IPv4 (RFC 791): the header checked and taken off a packet coming in,
//! and put on a packet going out, with the one's-complement checksum
//! both use.
//!
//! **In**: the version is 4, the header at least 20 bytes and inside the
//! packet, the total length at least the header and at most the packet
//! (a link may pad behind it, which is cut off), the header's checksum
//! right, and the destination this machine. Anything else is dropped and
//! counted. Fragments are put back together (`reassembly.zig`) before
//! they go further. This machine forwards nothing.
//!
//! **Out**: a header of 20 bytes without options, the identification
//! counted up, don't-fragment set - a packet larger than the interface's
//! MTU is refused before it gets here - and a time to live of 64.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _route = @import("../route/_route.zig");
const _udp = @import("../udp/_udp.zig");
const _icmp = @import("../icmp/_icmp.zig");
const _tcp_input = @import("../tcp/input.zig");
const reassembly = @import("reassembly.zig");
const _inet = @import("../inet/_inet.zig");

pub const header_bytes = 20;
/// IPv4's EtherType, the packet type a network device reads it by.
pub const ethertype: u16 = 0x0800;
pub const default_ttl: u8 = 64;
const flag_dont_fragment: u16 = 0x4000;
const flag_more_fragments: u16 = 0x2000;
const offset_mask: u16 = 0x1FFF;

/// The header's fields a protocol above needs.
pub const Header = struct {
    source: u32,
    destination: u32,
    protocol: u8,
    /// The header's own length, options included: how far in front of
    /// the transport's header the packet starts.
    header_length: u32,
    identification: u16,
};

/// The fragment word: more fragments follow, and the offset in 8-byte
/// units.
pub const flag_more: u16 = 0x2000;
pub const fragment_offset: u16 = 0x1FFF;

// --- bytes in the network's order ---------------------------------------------

pub fn get16(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) << 8 | bytes[at + 1];
}

pub fn get32(bytes: []const u8, at: usize) u32 {
    return @as(u32, get16(bytes, at)) << 16 | get16(bytes, at + 2);
}

pub fn put16(bytes: []u8, at: usize, value: u16) void {
    bytes[at] = @truncate(value >> 8);
    bytes[at + 1] = @truncate(value);
}

pub fn put32(bytes: []u8, at: usize, value: u32) void {
    put16(bytes, at, @truncate(value >> 16));
    put16(bytes, at + 2, @truncate(value));
}

// --- the checksum ---------------------------------------------------------------

/// `bytes` added to a running one's-complement sum of 16-bit words; an
/// odd byte at the end counts as the high half of a word.
pub fn sum(start: u32, bytes: []const u8) u32 {
    var total = start;
    var at: usize = 0;
    while (at + 1 < bytes.len) : (at += 2) total += get16(bytes, at);
    if (at < bytes.len) total += @as(u32, bytes[at]) << 8;
    return total;
}

/// The sum folded and inverted: the checksum to write, or 0 when a
/// packet whose checksum field is included checks out.
pub fn finish(total: u32) u16 {
    var folded = total;
    while (folded >> 16 != 0) folded = (folded & 0xFFFF) + (folded >> 16);
    return ~@as(u16, @truncate(folded));
}

/// The pseudo header TCP and UDP sum over: both addresses, the protocol
/// and the transport's length.
pub fn pseudoSum(source: u32, destination: u32, protocol: u8, length: u32) u32 {
    return (source >> 16) + (source & 0xFFFF) + (destination >> 16) + (destination & 0xFFFF) +
        protocol + length;
}

// --- in and out ------------------------------------------------------------------

/// A packet that came in on `interface`, the frame starting at its IPv4
/// header. The frame is this layer's from here.
pub fn input(stack: *StackBase, interface: *Interface, frame: *Frame) void {
    const sys = stack.sys_base;
    stack.counts.ip_received += 1;
    const packet = frame.bytes();
    if (packet.len < header_bytes or packet[0] >> 4 != 4) return drop(stack, frame, &stack.counts.ip_bad_header);
    const header_length: u32 = @as(u32, packet[0] & 0xF) * 4;
    const total = get16(packet, 2);
    if (header_length < header_bytes or header_length > packet.len or total < header_length or total > packet.len) {
        return drop(stack, frame, &stack.counts.ip_bad_header);
    }
    if (finish(sum(0, packet[0..header_length])) != 0) return drop(stack, frame, &stack.counts.ip_bad_checksum);
    const header: Header = .{
        .source = get32(packet, 12),
        .destination = get32(packet, 16),
        .protocol = packet[9],
        .header_length = header_length,
        .identification = get16(packet, 4),
    };
    if (!_netif.isOurs(stack, header.destination)) return drop(stack, frame, &stack.counts.ip_not_ours);
    frame.trim(total);
    const fragment = get16(packet, 6);
    if (fragment & (flag_more_fragments | offset_mask) != 0) {
        stack.counts.ip_fragments += 1;
        return reassembly.input(stack, interface, frame, header, fragment);
    }
    frame.pull(header_length);
    switch (header.protocol) {
        @as(u8, @intCast(bsd.IPPROTO_UDP)) => _udp.input(stack, interface, frame, _inet.Packet.fromV4(header)),
        @as(u8, @intCast(bsd.IPPROTO_ICMP)) => _icmp.input(stack, interface, frame, header),
        @as(u8, @intCast(bsd.IPPROTO_TCP)) => _tcp_input.input(stack, interface, frame, _inet.Packet.fromV4(header)),
        else => {
            stack.counts.ip_unknown_protocol += 1;
            stack.frames.give(sys, frame);
        },
    }
}

fn drop(stack: *StackBase, frame: *Frame, count: *u32) void {
    count.* += 1;
    stack.frames.give(stack.sys_base, frame);
}

/// `frame`, holding a transport's header and data, given an IPv4 header
/// and sent on its way by `hop`. The frame goes with it. 0, or the errno
/// of a packet that could not go.
pub fn output(stack: *StackBase, frame: *Frame, source: u32, destination: u32, protocol: u8, hop: _route.Hop) i32 {
    const header = frame.push(header_bytes);
    header[0] = 0x45;
    header[1] = 0;
    put16(header, 2, @intCast(frame.length));
    put16(header, 4, stack.ip_id);
    stack.ip_id +%= 1;
    put16(header, 6, flag_dont_fragment);
    header[8] = default_ttl;
    header[9] = protocol;
    put16(header, 10, 0);
    put32(header, 12, source);
    put32(header, 16, destination);
    put16(header, 10, finish(sum(0, header)));
    stack.counts.ip_sent += 1;
    return _netif.output(stack, hop.interface, frame, hop.next_hop);
}

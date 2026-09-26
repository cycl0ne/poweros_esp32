// SPDX-License-Identifier: MIT
//! Ethernet framing: the 14-byte header in front of every frame - where
//! it goes, where it came from, and the type of what it carries - and the
//! kinds of address a frame can be sent to.

/// The bytes of a hardware address, and the bits Sana2DeviceQuery counts.
pub const address_bytes = 6;
pub const address_bits: u32 = address_bytes * 8;
/// The header: two addresses and the type.
pub const header_bytes = 2 * address_bytes + 2;
/// The most a frame carries, and the most a whole frame is without its
/// checksum.
pub const mtu: u32 = 1500;
pub const frame_max: u32 = header_bytes + mtu;

pub const Address = [address_bytes]u8;

/// Every station on the link.
pub const broadcast: Address = @splat(0xFF);

/// A frame's header. `type` is the two bytes after the addresses: an
/// EtherType from 0x0600 on, below that the length of an IEEE 802.3 frame,
/// which a reader asks for by that same number.
pub const Header = struct {
    dst: Address,
    src: Address,
    type: u16,
};

/// The header at the front of `frame`, or null if the frame is too short
/// to have one.
pub fn parse(frame: []const u8) ?Header {
    if (frame.len < header_bytes) return null;
    return .{
        .dst = frame[0..address_bytes].*,
        .src = frame[address_bytes .. 2 * address_bytes].*,
        .type = @as(u16, frame[12]) << 8 | frame[13],
    };
}

/// A header at the front of `into`, which holds at least `header_bytes`.
pub fn write(into: []u8, dst: *const Address, src: *const Address, packet_type: u16) void {
    into[0..address_bytes].* = dst.*;
    into[address_bytes .. 2 * address_bytes].* = src.*;
    into[12] = @truncate(packet_type >> 8);
    into[13] = @truncate(packet_type);
}

/// A group address: its first byte's lowest bit is set. The broadcast
/// address is one too.
pub fn isGroup(address: *const Address) bool {
    return address[0] & 1 != 0;
}

pub fn isBroadcast(address: *const Address) bool {
    for (address) |byte| {
        if (byte != 0xFF) return false;
    }
    return true;
}

// SPDX-License-Identifier: MIT
//! The two descriptor rings, for realnet.device: what a descriptor is,
//! and the few things done to one.
//!
//! **A ring is a ring by its last descriptor.** The controller has no
//! register saying where a ring ends: it walks from the first descriptor
//! on and starts again at the one marked as the end, so the mark goes on
//! the last descriptor of each ring and is written again every time that
//! descriptor is handed over.
//!
//! **Ownership is the whole protocol.** Each descriptor has a bit that
//! says whose it is. The driver fills a descriptor and sets the bit; the
//! controller clears it when it has used the descriptor, and what it
//! writes back is in the same words. Nothing else is read or written on
//! either side, so a descriptor is the only thing that has to be written
//! back to memory and read past the caches.
//!
//! **Both descriptors are 32 bytes**, which is what the controller is
//! told to expect in its receive configuration. A frame never spans
//! descriptors here: a buffer holds a whole frame, and one that arrived
//! in pieces is thrown away.
//!
//! **The ownership bit goes last**, with a barrier in front of it: the
//! controller looks at a descriptor whenever it likes, so everything
//! else in it has to have reached memory before the bit that says it may
//! be read does.

const barrier = @import("sdk").hardware.barrier;

/// One descriptor the controller takes a frame into. The driver writes
/// `address` and `command`; the controller writes `length`, `extra` and
/// `command` back.
pub const Receive = extern struct {
    /// Not used by either side.
    reserved: [2]u32 = @splat(0),
    /// What the controller wrote: the hash it worked out, how long the
    /// frame is, and what it made of the headers.
    hash: u32 = 0,
    length: u16 = 0,
    header_info: u16 = 0,
    /// Where the frame goes.
    address: u64 align(4) = 0,
    /// What the controller found in the packet.
    extra: u32 = 0,
    /// Whose the descriptor is, and - on the way back - how the frame
    /// came in.
    command: u32 = 0,
};

/// One descriptor the controller sends a frame from.
pub const Transmit = extern struct {
    /// Whose it is, where the frame begins and ends, and how long it is.
    command: u32 = 0,
    /// What the controller is asked to work out on the way out; nothing
    /// is asked for here.
    extra: u32 = 0,
    /// Where the frame is.
    address: u64 align(4) = 0,
    reserved: [4]u32 = @splat(0),
};

comptime {
    if (@sizeOf(Receive) != 32) @compileError("a receive descriptor is 32 bytes");
    if (@sizeOf(Transmit) != 32) @compileError("a send descriptor is 32 bytes");
}

/// Whose a descriptor is: set by whoever hands it over.
pub const own: u32 = 0x8000_0000;
/// The last descriptor of a ring, which the controller starts again at.
pub const end_of_ring: u32 = 0x4000_0000;

/// A received frame's first and last descriptor, and whether anything
/// was wrong with it. The frame's length is the low bits of the same
/// word, and it carries the frame check sequence at its end.
pub const received_first: u32 = 0x0200_0000;
pub const received_last: u32 = 0x0100_0000;
pub const received_fault: u32 = 0x0010_0000;
pub const received_length: u32 = 0x0000_3fff;

/// What the controller found in a received packet: which checksums it
/// could check, and which of them were wrong.
const received_tcp_bad: u32 = 0x0100_0000;
const received_udp_bad: u32 = 0x0200_0000;
const received_ip_bad: u32 = 0x0400_0000;
const received_tcp: u32 = 0x1000_0000;
const received_udp: u32 = 0x2000_0000;
const received_ipv4: u32 = 0x4000_0000;
const received_ipv6: u32 = 0x8000_0000;

/// A sent frame's first and last descriptor. A frame is one descriptor
/// here, so both are set on it.
pub const sent_last: u32 = 0x1000_0000;
pub const sent_first: u32 = 0x2000_0000;

/// How many bytes of the frame the controller wrote, the frame check
/// sequence at its end included.
pub fn frameBytes(descriptor: *const volatile Receive) u32 {
    return descriptor.command & received_length;
}

/// Whether every checksum the controller could check in this packet was
/// right. A frame that is not a packet it knows is not answered as
/// checked: there was nothing to check.
pub fn receivedChecked(descriptor: *const volatile Receive) bool {
    const found = descriptor.extra;
    if (found & (received_ipv4 | received_ipv6) == 0) return false;
    if (found & (received_tcp | received_udp) == 0) return false;
    return found & (received_tcp_bad | received_udp_bad | received_ip_bad) == 0;
}

/// A receive descriptor handed to the controller: where the frame goes,
/// how much room there is, and the ring's end where this is the last
/// descriptor.
pub fn give(descriptor: *volatile Receive, address: u64, bytes: u32, last: bool) void {
    descriptor.address = address;
    descriptor.extra = 0;
    barrier.toDevice();
    descriptor.command = bytes | own | (if (last) end_of_ring else 0);
}

/// A send descriptor filled with a whole frame and handed over.
pub fn send(descriptor: *volatile Transmit, address: u64, bytes: u32, last: bool) void {
    descriptor.address = address;
    descriptor.extra = 0;
    barrier.toDevice();
    descriptor.command = bytes | own | sent_first | sent_last | (if (last) end_of_ring else 0);
}

/// Whether the controller has given a descriptor back. What it wrote in
/// the rest of the descriptor is read only after this says so, so the
/// read of the rest is kept behind this one.
pub fn done(command: u32) bool {
    if (command & own != 0) return false;
    barrier.fromDevice();
    return true;
}

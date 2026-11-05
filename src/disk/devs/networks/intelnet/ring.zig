// SPDX-License-Identifier: MIT
//! The two descriptor rings, for intelnet.device: what a descriptor is,
//! and the registers that tell the controller where its ring is and how
//! much of it is the driver's.
//!
//! A descriptor is sixteen bytes, and the controller writes back over
//! all of it. On the way to the controller a receive descriptor is two
//! addresses - where the frame goes, and where a split header would go,
//! which this driver never asks for; on the way back it is what the
//! controller made of the packet - its kind and what came of its
//! checksums - with the frame's status and its length. A send descriptor is the frame's address, the
//! command with the bytes in the buffer, and the whole packet's length;
//! on the way back, a status with one bit that matters.
//!
//! **Who owns what.** Each ring has a head the controller moves and a
//! tail the driver writes. The controller owns the descriptors from the
//! head up to the tail, so a ring whose head and tail are equal is one
//! the controller has nothing in: a ring of N descriptors holds N - 1 at
//! once, and the driver leaves that one gap rather than lose the
//! difference between full and empty.
//!
//! Every descriptor is written back as soon as it is done - the
//! thresholds that would hold a writeback back are left at zero - so the
//! done bit is what the task looks at and there is nothing else to wait
//! for.

const barrier = @import("sdk").hardware.barrier;
const mac = @import("mac.zig");

// --- the registers ----------------------------------------------------------------

/// Receive queue 0. The queues are 0x40 apart, and only the first is
/// used: one is what a single task can empty, and the frames are shared
/// out by the stack above, not by the card.
const rdbal = 0x0C000;
const rdbah = 0x0C004;
const rdlen = 0x0C008;
const srrctl = 0x0C00C;
const rdh = 0x0C010;
const rdt = 0x0C018;
const rxdctl = 0x0C028;

/// Send queue 0.
const tdbal = 0x0E000;
const tdbah = 0x0E004;
const tdlen = 0x0E008;
const tdh = 0x0E010;
const tdt = 0x0E018;
const txdctl = 0x0E028;

/// RXDCTL and TXDCTL: the queue is on. The controller sets it back when
/// it has really started, and clears it when it has really stopped.
const queue_enable: u32 = 0x0200_0000;

/// SRRCTL: a buffer's size in units of 1024 bytes, a descriptor of the
/// advanced kind with one buffer, and a frame dropped where no
/// descriptor is free rather than held in the card.
const srrctl_buffer_unit = 1024;
const srrctl_advance_one: u32 = 0x0200_0000;
const srrctl_drop: u32 = 0x8000_0000;

/// How long the driver waits for a queue to start or stop, in register
/// reads. Each is a transaction on the bus.
const settle_tries = 20_000;

// --- a descriptor -----------------------------------------------------------------

/// A receive descriptor, both ways round.
pub const Receive = extern struct {
    /// Going out: where the frame goes. Coming back: the packet's type
    /// and the hash of its addresses, neither of which is read here.
    address_low: u32 = 0,
    address_high: u32 = 0,
    /// Going out: where a split header would go. Coming back: the status
    /// and the errors.
    status: u32 = 0,
    /// Going out: the same. Coming back: the frame's length in the low
    /// half, its VLAN tag in the high one.
    length: u32 = 0,
};

/// A send descriptor, both ways round.
pub const Transmit = extern struct {
    /// The frame's address.
    address_low: u32 = 0,
    address_high: u32 = 0,
    /// The command, the descriptor's kind, and the bytes in this buffer.
    command: u32 = 0,
    /// Going out: the whole packet's length. Coming back: the status,
    /// with the done bit.
    status: u32 = 0,
};

/// A receive descriptor's status: the controller has written it back,
/// and the frame ended in this one.
pub const received_done: u32 = 0x0000_0001;
pub const received_last: u32 = 0x0000_0002;
/// The errors that mean the frame itself is broken and not worth
/// passing on: a bad frame checksum, a symbol error, a sequence error, a
/// carrier extension error, and the catch-all receive data error. The
/// two bits beside them say a packet's own checksums came out wrong,
/// which is a different thing: that frame arrived whole and is passed up
/// unmarked, for the opener to make of what it will.
pub const received_faults: u32 = 0x0100_0000 | 0x0200_0000 | 0x0400_0000 |
    0x1000_0000 | 0x8000_0000;

/// What the controller made of the packet's own checksums, in the same
/// word: it worked out the transport part's, it worked out the IP
/// header's, and - in the word's error half - either came out wrong. The
/// first bit is its way of saying it looked at neither.
const received_unchecked: u32 = 0x0000_0004;
const received_transport_checked: u32 = 0x0000_0020;
const received_ip_checked: u32 = 0x0000_0040;
const received_transport_bad: u32 = 0x2000_0000;
const received_ip_bad: u32 = 0x4000_0000;

/// What kind of packet the controller made it out to be, in the low half
/// of the first word on the way back: the field begins four bits up, and
/// these are the families whose checksums it is asked for - IPv4, IPv6,
/// and IPv6 with extension headers in front of the transport part.
const received_ipv4: u32 = 0x0000_0010;
const received_ipv6: u32 = 0x0000_0040 | 0x0000_0080;

/// A send descriptor's command: the frame ends here, the controller
/// appends the checksum, it writes the status back, the descriptor is of
/// the advanced kind, and it carries data rather than a context.
const send_last: u32 = 0x0100_0000;
const send_checksum: u32 = 0x0200_0000;
const send_report: u32 = 0x0800_0000;
const send_advanced: u32 = 0x2000_0000;
const send_data: u32 = 0x0030_0000;
/// Where the whole packet's length sits in the second word.
const send_length_shift = 14;
/// Beside it, the one option asked for: the controller finishes the
/// checksum of the packet's transport part, which the context descriptor
/// in front of the frame told it where to find. The bit next to this one
/// would have it fill in the IP header's checksum as well; that one is
/// worked out before the frame is handed over (`checksum.zig`).
const send_fill_transport: u32 = 0x0000_0200;
/// Its status: the controller is done with it.
pub const sent_done: u32 = 0x0000_0001;

/// A context descriptor, which is the same sixteen bytes read another
/// way. It carries no frame and the controller never writes it back: it
/// says where the headers of the frames behind it end, so that the
/// checksum they ask for covers the right bytes and goes in the right
/// place.
pub const Context = extern struct {
    /// The Ethernet header's length and the IP header's.
    lengths: u32 = 0,
    /// A starting number for a packet the controller cuts up; nothing
    /// here asks it to.
    seed: u32 = 0,
    /// That this is a context descriptor of the advanced kind, and what
    /// the transport part is.
    kind: u32 = 0,
    /// A segment's size, for that same cutting up, and which of the two
    /// contexts this is - the first, so nothing is set.
    segment: u32 = 0,
};

comptime {
    if (@sizeOf(Context) != @sizeOf(Transmit)) {
        @compileError("a context descriptor takes the place of a send descriptor");
    }
}

/// A context descriptor's own bits: that it is one, that it is of the
/// advanced kind, and that the transport part is TCP rather than UDP.
const context_descriptor: u32 = 0x0020_0000;
const context_advanced: u32 = 0x2000_0000;
const context_tcp: u32 = 0x0000_0800;
/// Where the Ethernet header's length sits in the first word. The IP
/// header's length is in the bits below it.
const context_mac_shift = 9;

/// A receive descriptor handed to the controller, empty: the address
/// first, then the two words it writes its answer into cleared, so the
/// done bit it had from last time is gone.
pub fn give(descriptor: *volatile Receive, address: u64) void {
    descriptor.address_low = @truncate(address);
    descriptor.address_high = @truncate(address >> 32);
    descriptor.status = 0;
    descriptor.length = 0;
}

/// The frame's length in a descriptor the controller wrote back.
pub fn frameBytes(descriptor: *volatile Receive) u32 {
    return descriptor.length & 0xFFFF;
}

/// Whether the controller worked out the packet's checksums and every
/// one of them came out right, which is what lets the opener skip the
/// sums itself.
///
/// An IPv4 packet carries a checksum over its header as well as one over
/// its transport part, and both have to have been checked; IPv6 has only
/// the transport one. A packet of any other kind, and one the controller
/// says it left alone, counts as unchecked - as does one whose transport
/// part it did not recognise, which is every kind but TCP and UDP.
pub fn receivedChecked(descriptor: *volatile Receive) bool {
    const status = descriptor.status;
    if (status & received_unchecked != 0) return false;
    if (status & received_transport_checked == 0 or status & received_transport_bad != 0) return false;
    const kind = descriptor.address_low;
    if (kind & received_ipv4 != 0) {
        return status & received_ip_checked != 0 and status & received_ip_bad == 0;
    }
    return kind & received_ipv6 != 0;
}

/// A send descriptor filled with one frame, which is the whole packet.
/// With `fill` the controller finishes the checksum of the packet's
/// transport part, which wants a context descriptor in front of this one.
pub fn send(descriptor: *volatile Transmit, address: u64, bytes: u32, fill: bool) void {
    descriptor.address_low = @truncate(address);
    descriptor.address_high = @truncate(address >> 32);
    descriptor.command = send_data | send_advanced | send_last | send_checksum |
        send_report | bytes;
    descriptor.status = bytes << send_length_shift |
        (if (fill) send_fill_transport else 0);
}

/// A context descriptor written over `descriptor`, for the frame in the
/// descriptor behind it: `mac_bytes` is its Ethernet header, `ip_bytes`
/// its IP header, and `tcp` whether its transport part is TCP rather
/// than UDP.
pub fn context(descriptor: *volatile Transmit, mac_bytes: u32, ip_bytes: u32, tcp: bool) void {
    const into: *volatile Context = @ptrCast(descriptor);
    into.lengths = mac_bytes << context_mac_shift | ip_bytes;
    into.seed = 0;
    into.kind = context_descriptor | context_advanced | (if (tcp) context_tcp else 0);
    into.segment = 0;
}

// --- the rings --------------------------------------------------------------------

/// The receive ring given to the controller and started: `at` the
/// registers, `ring` where the descriptors are, `count` how many, and
/// `buffer_bytes` how long each frame buffer is. False where the queue
/// does not start.
///
/// The tail is written last and names the final descriptor, which leaves
/// the controller the other `count - 1`.
pub fn startReceive(at: usize, ring: u64, count: u32, buffer_bytes: u32) bool {
    mac.write(at, rxdctl, 0);
    if (!settled(at, rxdctl, false)) return false;
    mac.write(at, rdbah, @truncate(ring >> 32));
    mac.write(at, rdbal, @truncate(ring));
    mac.write(at, rdlen, count * @sizeOf(Receive));
    mac.write(at, srrctl, buffer_bytes / srrctl_buffer_unit | srrctl_advance_one | srrctl_drop);
    mac.write(at, rdh, 0);
    mac.write(at, rdt, 0);
    barrier.toDevice();
    mac.write(at, rxdctl, queue_enable);
    if (!settled(at, rxdctl, true)) return false;
    mac.write(at, rdt, count - 1);
    return true;
}

/// The send ring given to the controller and started, with nothing in
/// it. False where the queue does not start.
pub fn startTransmit(at: usize, ring: u64, count: u32) bool {
    mac.write(at, txdctl, 0);
    if (!settled(at, txdctl, false)) return false;
    mac.write(at, tdbah, @truncate(ring >> 32));
    mac.write(at, tdbal, @truncate(ring));
    mac.write(at, tdlen, count * @sizeOf(Transmit));
    mac.write(at, tdh, 0);
    mac.write(at, tdt, 0);
    barrier.toDevice();
    mac.write(at, txdctl, queue_enable);
    return settled(at, txdctl, true);
}

/// Both queues stopped. The controller finishes what it has in hand
/// first, and the driver waits for it: a descriptor still in its hands
/// points at a buffer that is about to be given back.
pub fn stop(at: usize) void {
    mac.write(at, rxdctl, 0);
    mac.write(at, txdctl, 0);
    _ = settled(at, rxdctl, false);
    _ = settled(at, txdctl, false);
}

/// Whether a queue's control register has caught up with what was
/// written to it.
fn settled(at: usize, which: usize, on: bool) bool {
    var tries: u32 = 0;
    while (tries < settle_tries) : (tries += 1) {
        const control = mac.read(at, which);
        if (control == 0xFFFF_FFFF) return false;
        if ((control & queue_enable != 0) == on) return true;
    }
    return false;
}

/// The descriptors up to and including `last` handed to the controller.
pub fn receiveTail(at: usize, last: u32) void {
    barrier.toDevice();
    mac.write(at, rdt, last);
}

/// The controller told to look at everything written up to `next`.
pub fn transmitTail(at: usize, next: u32) void {
    barrier.toDevice();
    mac.write(at, tdt, next);
}

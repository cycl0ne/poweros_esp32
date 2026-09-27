// SPDX-License-Identifier: MIT
//! IPv6 fragments put back together (RFC 8200, 4.5): the pieces of one
//! packet - the same source, destination and identification - are copied
//! into one large frame at their offsets, behind a base header made from
//! the first piece's, and when every byte from 0 to the end the last
//! piece gives is there, the packet goes through IPv6 input again, whole
//! and without its fragment header. The extension headers in front of
//! the fragment header were read with each piece and are not kept.
//!
//! **What is refused**, every time dropping the whole packet: a piece
//! other than the last whose length is not a multiple of 8 (a parameter
//! problem pointing at its payload length goes back), a piece that would
//! put the packet past 65535 bytes (one pointing at its offset), a piece
//! that overlaps one already there (RFC 5722), two last pieces that
//! disagree on the end, and a first piece that does not hold the whole
//! header chain up to the transport's header (RFC 7112; a parameter
//! problem of code 3). At most `slots_max` packets are put together at
//! once, each for at most 60 seconds; when one runs out of time with its
//! first piece there, a time-exceeded goes back quoting it.
//!
//! Only two slots: IPv6 is fragmented only where a packet starts, and a
//! sender that learns the path's MTU stops doing it.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _frame = @import("../frame/_frame.zig");
const Frame = _frame.Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _timer = @import("../timer/_timer.zig");
const Timer = _timer.Timer;
const _ip = @import("../ip/_ip.zig");
const _ip6 = @import("_ip6.zig");
const _icmp6 = @import("../icmp6/_icmp6.zig");
const _inet = @import("../inet/_inet.zig");
const Address = @import("address.zig").Address;

pub const slots_max = 2;
pub const timeout_us: u64 = 60_000_000;
/// The most bytes behind the base header a packet has.
pub const payload_max: u32 = 65535;
const blocks_max = (payload_max + 7) / 8;
/// The bytes of the first piece kept for the time-exceeded that quotes
/// it: its base header, its fragment header and what follows.
const quote_bytes = 64;

/// A fragment as the walk of its headers found it.
pub const Piece = struct {
    source: Address,
    destination: Address,
    /// Where the fragment header starts, and what it says follows it.
    header_length: u32,
    next_header: u8,
    /// The offset and M bit, and the identification.
    word: u16,
    identification: u32,
};

pub const Slot = extern struct {
    timer: Timer = .{},
    used: u8 = 0,
    have_first: u8 = 0,
    next_header: u8 = 0,
    pad: u8 = 0,
    identification: u32 = 0,
    source: Address = .{},
    destination: Address = .{},
    interface: ?*Interface = null,
    frame: ?*Frame = null,
    /// The bytes that are there, and the end the last piece gives (0
    /// until it came).
    received: u32 = 0,
    total: u32 = 0,
    /// The first piece as it came, for a time-exceeded, and how much of
    /// it there is.
    first: [quote_bytes]u8 = @splat(0),
    first_length: u32 = 0,
    blocks: [(blocks_max + 7) / 8]u8 = @splat(0),
};

pub const Slots = extern struct {
    slots: [slots_max]Slot = @splat(.{}),
};

/// Every slot's timer knows what to do, once, when the stack starts.
pub fn init(stack: *StackBase) void {
    for (&stack.reassembly6.slots) |*slot| {
        slot.* = .{};
        slot.timer.fire = &expired;
    }
}

fn find(stack: *StackBase, piece: *const Piece) ?*Slot {
    for (&stack.reassembly6.slots) |*slot| {
        if (slot.used != 0 and slot.identification == piece.identification and
            slot.source.eql(piece.source) and slot.destination.eql(piece.destination)) return slot;
    }
    return null;
}

fn claim(stack: *StackBase, piece: *const Piece, interface: *Interface) ?*Slot {
    for (&stack.reassembly6.slots) |*slot| {
        if (slot.used != 0) continue;
        const frame = stack.frames.takeLarge(stack.sys_base, _frame.headroom + _ip6.header_bytes + payload_max) orelse return null;
        const fire = slot.timer.fire;
        slot.* = .{
            .used = 1,
            .identification = piece.identification,
            .source = piece.source,
            .destination = piece.destination,
            .interface = interface,
            .frame = frame,
        };
        slot.timer.fire = fire;
        _ = _timer.set(stack, &slot.timer, _timer.clock(stack) + timeout_us);
        return slot;
    }
    return null;
}

fn release(stack: *StackBase, slot: *Slot) void {
    _timer.cancel(stack, &slot.timer);
    if (slot.frame) |frame| stack.frames.give(stack.sys_base, frame);
    slot.frame = null;
    slot.used = 0;
}

/// Every packet being put together given up, when the library goes.
pub fn deinit(stack: *StackBase) void {
    for (&stack.reassembly6.slots) |*slot| {
        if (slot.used != 0) release(stack, slot);
    }
}

/// Out of time: its first piece, if it came, quoted in a time-exceeded.
fn expired(stack: *StackBase, fired: *Timer, now: u64) void {
    _ = now;
    const slot: *Slot = @fieldParentPtr("timer", fired);
    stack.counts.ip6_reassembly_dropped += 1;
    if (slot.have_first != 0) {
        if (stack.frames.take(stack.sys_base)) |quoted| {
            @memcpy(quoted.room()[quoted.start..][0..slot.first_length], slot.first[0..slot.first_length]);
            quoted.length = slot.first_length;
            const packet: _inet.Packet = .{ .source = slot.source, .destination = slot.destination, .protocol = _ip6.fragment, .header_length = _ip6.header_bytes };
            _icmp6.sendError(stack, slot.interface.?, quoted, packet, _icmp6.time_exceeded, _icmp6.code_reassembly, 0);
            stack.frames.give(stack.sys_base, quoted);
        }
    }
    release(stack, slot);
}

fn giveUp(stack: *StackBase, slot: ?*Slot, fragment: *Frame) void {
    stack.counts.ip6_reassembly_dropped += 1;
    if (slot) |taken| release(stack, taken);
    stack.frames.give(stack.sys_base, fragment);
}

/// A parameter problem for the fragment, and the packet given up.
fn refuse(stack: *StackBase, interface: *Interface, slot: ?*Slot, fragment: *Frame, piece: *const Piece, code: u8, pointer: u32) void {
    const packet: _inet.Packet = .{ .source = piece.source, .destination = piece.destination, .protocol = _ip6.fragment, .header_length = piece.header_length };
    _icmp6.sendError(stack, interface, fragment, packet, _icmp6.parameter_problem, code, pointer);
    giveUp(stack, slot, fragment);
}

/// The least a transport's header has: what the first piece must hold of
/// it.
fn upperMinimum(next_header: u8) ?u32 {
    return switch (next_header) {
        @as(u8, @intCast(bsd.IPPROTO_TCP)) => 20,
        @as(u8, @intCast(bsd.IPPROTO_UDP)) => 8,
        _ip6.protocol_icmp6 => 4,
        else => null,
    };
}

/// Whether the first piece's data holds every extension header and the
/// transport's header.
fn holdsChain(data: []const u8, first_header: u8) bool {
    var next = first_header;
    var at: u32 = 0;
    while (true) {
        switch (next) {
            _ip6.hop_by_hop, _ip6.routing, _ip6.destination_options => {
                if (at + 2 > data.len) return false;
                const length = (@as(u32, data[at + 1]) + 1) * 8;
                if (at + length > data.len) return false;
                next = data[at];
                at += length;
            },
            _ip6.no_next_header => return true,
            else => {
                const least = upperMinimum(next) orelse return true;
                return at + least <= data.len;
            },
        }
    }
}

/// A fragment that came in on `interface`, the frame starting at its
/// base header and cut to its payload. The frame is this layer's.
pub fn input(stack: *StackBase, interface: *Interface, fragment: *Frame, piece: Piece) void {
    const packet = fragment.bytes();
    const data = packet[piece.header_length + 8 ..];
    const offset: u32 = @as(u32, piece.word & 0xFFF8);
    const more = piece.word & 1 != 0;
    const length: u32 = @intCast(data.len);
    const end = offset + length;
    if (more and length % 8 != 0) return refuse(stack, interface, find(stack, &piece), fragment, &piece, _ip6.problem_field, 4);
    if (end + (piece.header_length - _ip6.header_bytes) > payload_max) {
        return refuse(stack, interface, find(stack, &piece), fragment, &piece, _ip6.problem_field, piece.header_length + 2);
    }
    if (offset == 0 and !holdsChain(data, piece.next_header)) {
        return refuse(stack, interface, find(stack, &piece), fragment, &piece, _ip6.problem_chain, 0);
    }
    if (length == 0) return giveUp(stack, find(stack, &piece), fragment);
    const slot = find(stack, &piece) orelse claim(stack, &piece, interface) orelse return giveUp(stack, null, fragment);

    const first_block = offset / 8;
    const end_block = (end + 7) / 8;
    var block = first_block;
    while (block < end_block) : (block += 1) {
        if (slot.blocks[block / 8] & (@as(u8, 1) << @intCast(block % 8)) != 0) return giveUp(stack, slot, fragment);
    }
    if (!more) {
        if (slot.total != 0 and slot.total != end) return giveUp(stack, slot, fragment);
        slot.total = end;
    }
    if (slot.total != 0 and end > slot.total) return giveUp(stack, slot, fragment);
    const whole = slot.frame.?;
    @memcpy(whole.room()[_frame.headroom + _ip6.header_bytes + offset ..][0..length], data);
    block = first_block;
    while (block < end_block) : (block += 1) slot.blocks[block / 8] |= @as(u8, 1) << @intCast(block % 8);
    slot.received += length;
    if (offset == 0) {
        slot.have_first = 1;
        slot.next_header = piece.next_header;
        slot.first_length = @min(@as(u32, @intCast(packet.len)), quote_bytes);
        @memcpy(slot.first[0..slot.first_length], packet[0..slot.first_length]);
    }
    stack.frames.give(stack.sys_base, fragment);
    if (slot.total == 0 or slot.received != slot.total or slot.have_first == 0) return;

    // Whole: a base header made for it, and it goes in again.
    const header = whole.room()[_frame.headroom..][0.._ip6.header_bytes];
    header.* = slot.first[0.._ip6.header_bytes].*;
    _ip.put16(header, 4, @intCast(slot.total));
    header[6] = slot.next_header;
    whole.start = _frame.headroom;
    whole.length = _ip6.header_bytes + slot.total;
    slot.frame = null;
    const arrived = slot.interface.?;
    release(stack, slot);
    stack.counts.ip6_reassembled += 1;
    _ip6.input(stack, arrived, whole);
}

// SPDX-License-Identifier: MIT
//! Fragments put back together (RFC 791, RFC 815's hole idea as a
//! bitmap): the pieces of one datagram - the same source, destination,
//! identification and protocol - are copied into one large frame at
//! their offsets, and when every byte from 0 to the end the last piece
//! gives is there, the datagram goes through IPv4 input again, whole.
//!
//! **What is refused**, every time dropping the whole datagram: a piece
//! that would put it past 65535 bytes; a piece that overlaps one already
//! there (an overlap is only ever an attack or a broken sender, and
//! refusing it takes away the question of which copy wins); two last
//! pieces that disagree on the end; a piece other than the last whose
//! length is not a multiple of 8. At most `slots_max` datagrams are put
//! together at once, each for at most 30 seconds; its timer lets it go
//! after that.
//!
//! The large frame is allocated for the largest datagram there can be,
//! once per datagram, and freed when the datagram has been read or given
//! up on.

const sdk = @import("sdk");
const exec = sdk.exec;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _frame = @import("../frame/_frame.zig");
const Frame = _frame.Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _timer = @import("../timer/_timer.zig");
const Timer = _timer.Timer;
const _ip = @import("_ip.zig");

pub const slots_max = 4;
pub const timeout_us: u64 = 30_000_000;
pub const datagram_max: u32 = 65535;
/// The 8-byte blocks a datagram has at most, and the bitmap of them.
const blocks_max = (datagram_max + 7) / 8;

pub const Slot = extern struct {
    timer: Timer = .{},
    used: u8 = 0,
    protocol: u8 = 0,
    identification: u16 = 0,
    source: u32 = 0,
    destination: u32 = 0,
    interface: ?*Interface = null,
    frame: ?*Frame = null,
    /// The data bytes that are there, and the end the last piece gives
    /// (0 until it came).
    received: u32 = 0,
    total: u32 = 0,
    /// The first piece's header, without options, once it came.
    header: [_ip.header_bytes]u8 = @splat(0),
    have_first: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    blocks: [(blocks_max + 7) / 8]u8 = @splat(0),
};

pub const Slots = extern struct {
    slots: [slots_max]Slot = @splat(.{}),
};

/// Every slot's timer knows what to do, once, when the stack starts.
pub fn init(stack: *StackBase) void {
    for (&stack.reassembly.slots) |*slot| {
        slot.* = .{};
        slot.timer.fire = &expired;
    }
}

fn find(stack: *StackBase, header: _ip.Header) ?*Slot {
    for (&stack.reassembly.slots) |*slot| {
        if (slot.used != 0 and slot.source == header.source and slot.destination == header.destination and
            slot.identification == header.identification and slot.protocol == header.protocol) return slot;
    }
    return null;
}

fn claim(stack: *StackBase, header: _ip.Header, interface: *Interface) ?*Slot {
    for (&stack.reassembly.slots) |*slot| {
        if (slot.used != 0) continue;
        const frame = stack.frames.takeLarge(stack.sys_base, _frame.headroom + datagram_max) orelse return null;
        const fire = slot.timer.fire;
        slot.* = .{
            .used = 1,
            .protocol = header.protocol,
            .identification = header.identification,
            .source = header.source,
            .destination = header.destination,
            .interface = interface,
            .frame = frame,
        };
        slot.timer.fire = fire;
        _ = _timer.set(stack, &slot.timer, _timer.clock(stack) + timeout_us);
        return slot;
    }
    return null;
}

/// `slot` let go: its frame, unless it was handed on, freed.
fn release(stack: *StackBase, slot: *Slot) void {
    _timer.cancel(stack, &slot.timer);
    if (slot.frame) |frame| stack.frames.give(stack.sys_base, frame);
    slot.frame = null;
    slot.used = 0;
}

/// Every datagram being put together given up, when the library goes.
pub fn deinit(stack: *StackBase) void {
    for (&stack.reassembly.slots) |*slot| {
        if (slot.used != 0) release(stack, slot);
    }
}

fn expired(stack: *StackBase, fired: *Timer, now: u64) void {
    _ = now;
    const slot: *Slot = @fieldParentPtr("timer", fired);
    stack.counts.ip_reassembly_dropped += 1;
    release(stack, slot);
}

fn giveUp(stack: *StackBase, slot: ?*Slot, fragment: *Frame) void {
    stack.counts.ip_reassembly_dropped += 1;
    if (slot) |taken| release(stack, taken);
    stack.frames.give(stack.sys_base, fragment);
}

/// A fragment that came in on `interface`, the frame starting at its IPv4
/// header and cut to its total length. The frame is this layer's.
pub fn input(stack: *StackBase, interface: *Interface, fragment: *Frame, header: _ip.Header, word: u16) void {
    const packet = fragment.bytes();
    const data = packet[header.header_length..];
    const offset: u32 = @as(u32, word & _ip.fragment_offset) * 8;
    const more = word & _ip.flag_more != 0;
    const length: u32 = @intCast(data.len);
    const end = offset + length;
    if (length == 0 or (more and length % 8 != 0) or _ip.header_bytes + end > datagram_max) {
        return giveUp(stack, find(stack, header), fragment);
    }
    const slot = find(stack, header) orelse claim(stack, header, interface) orelse return giveUp(stack, null, fragment);

    // No byte of it may be there already.
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
    @memcpy(whole.room()[_frame.headroom + _ip.header_bytes + offset ..][0..length], data);
    block = first_block;
    while (block < end_block) : (block += 1) slot.blocks[block / 8] |= @as(u8, 1) << @intCast(block % 8);
    slot.received += length;
    if (offset == 0) {
        slot.header = packet[0.._ip.header_bytes].*;
        slot.have_first = 1;
    }
    stack.frames.give(stack.sys_base, fragment);
    if (slot.total == 0 or slot.received != slot.total or slot.have_first == 0) return;

    // Whole: its header made the datagram's, and it goes in again.
    const datagram_header = whole.room()[_frame.headroom..][0.._ip.header_bytes];
    datagram_header.* = slot.header;
    datagram_header[0] = 0x45;
    _ip.put16(datagram_header, 2, @intCast(_ip.header_bytes + slot.total));
    _ip.put16(datagram_header, 6, 0);
    _ip.put16(datagram_header, 10, 0);
    _ip.put16(datagram_header, 10, _ip.finish(_ip.sum(0, datagram_header)));
    whole.start = _frame.headroom;
    whole.length = _ip.header_bytes + slot.total;
    slot.frame = null;
    release(stack, slot);
    stack.counts.ip_reassembled += 1;
    _ip.input(stack, slot.interface.?, whole);
}

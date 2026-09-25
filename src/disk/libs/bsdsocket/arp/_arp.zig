// SPDX-License-Identifier: MIT
//! ARP (RFC 826): which Ethernet address an IPv4 address on an interface's
//! net has.
//!
//! **The cache** holds an entry per address asked about. An entry is
//! `pending` while its question is out, holding the first few packets for
//! the address; `resolved` once an answer came; `checking` when its life
//! is up and it is asked once more, straight to the address it had;
//! `held` after a question went unanswered, when sends to it fail at once
//! with `EHOSTUNREACH` rather than vanish.
//!
//! **Paced**: a question goes out at once, then again every second, five
//! times in all; then the address is held for twenty seconds before it
//! may be asked again. A resolved entry lives twenty minutes; if traffic
//! came from the address meanwhile it simply lives on, so a busy peer is
//! never asked, and otherwise it is checked with one question to the
//! address it had.
//!
//! **Answered**: a question for one of our addresses is answered, and the
//! station that asked is learned, since it is about to be spoken to.
//!
//! Everything here runs under the stack's lock; `now` is the caller's.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _timer = @import("../timer/_timer.zig");
const Timer = _timer.Timer;
const _ip = @import("../ip/_ip.zig");

pub const ethertype: u16 = 0x0806;
pub const packet_bytes = 28;
pub const entries_max = 32;
/// Packets kept for an address while its question is out.
pub const queue_max = 3;

pub const retry_us: u64 = 1_000_000;
pub const tries_max = 5;
pub const hold_us: u64 = 20_000_000;
pub const life_us: u64 = 20 * 60 * 1_000_000;
pub const check_us: u64 = 3_000_000;

const request: u16 = 1;
const reply: u16 = 2;

pub const broadcast: [6]u8 = @splat(0xFF);

pub const State = enum(u8) { free, pending, resolved, checking, held };

pub const Entry = extern struct {
    timer: Timer = .{},
    address: u32 = 0,
    hardware: [6]u8 = @splat(0),
    state: State = .free,
    tries: u8 = 0,
    interface: ?*Interface = null,
    /// The packets waiting for the answer, oldest first.
    queue: exec.List = .{},
    queued: u32 = 0,
    /// Traffic came from the address since its life was last looked at.
    heard: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
};

pub const Cache = extern struct {
    entries: [entries_max]Entry = @splat(.{}),
    /// Packets dropped: no room in an entry's queue, a held address, a
    /// question that went unanswered.
    dropped: u32 = 0,
    requests_sent: u32 = 0,
    replies_sent: u32 = 0,
    bad: u32 = 0,
};

/// Every entry's queue made a list, once, when the stack starts.
pub fn init(stack: *StackBase) void {
    for (&stack.arp.entries) |*entry| {
        entry.* = .{};
        entry.queue.init(.unknown);
        entry.timer.fire = &fire;
    }
}

fn find(stack: *StackBase, interface: *Interface, address: u32) ?*Entry {
    for (&stack.arp.entries) |*entry| {
        if (entry.state != .free and entry.interface == interface and entry.address == address) return entry;
    }
    return null;
}

/// A free entry, or the resolved one closest to its end made free; null
/// when every entry has a question out or is held.
fn claim(stack: *StackBase) ?*Entry {
    var oldest: ?*Entry = null;
    for (&stack.arp.entries) |*entry| {
        if (entry.state == .free) return entry;
        if (entry.state != .resolved) continue;
        if (oldest == null or entry.timer.deadline < oldest.?.timer.deadline) oldest = entry;
    }
    const entry = oldest orelse return null;
    release(stack, entry);
    return entry;
}

/// `entry` emptied and free; what it held is dropped.
fn release(stack: *StackBase, entry: *Entry) void {
    _timer.cancel(stack, &entry.timer);
    dropQueue(stack, entry);
    entry.state = .free;
    entry.interface = null;
}

fn dropQueue(stack: *StackBase, entry: *Entry) void {
    const sys = stack.sys_base;
    while (sys.RemHead(&entry.queue)) |node| {
        stack.frames.give(sys, @fieldParentPtr("node", node));
        stack.arp.dropped += 1;
    }
    entry.queued = 0;
}

/// `frame`, an IPv4 packet, sent to `next_hop` on `interface` once its
/// Ethernet address is known: at once, or when the answer comes. 0, or
/// `EHOSTUNREACH` when the address is held, `ENOBUFS` when there is no
/// room to ask; the frame is this layer's either way.
pub fn resolve(stack: *StackBase, interface: *Interface, next_hop: u32, frame: *Frame, now: u64) i32 {
    const sys = stack.sys_base;
    const entry = find(stack, interface, next_hop) orelse blk: {
        const entry = claim(stack) orelse {
            stack.frames.give(sys, frame);
            stack.arp.dropped += 1;
            return bsd.ENOBUFS;
        };
        entry.address = next_hop;
        entry.interface = interface;
        entry.state = .pending;
        entry.tries = 1;
        entry.heard = 0;
        ask(stack, entry, &broadcast);
        _ = _timer.set(stack, &entry.timer, now + retry_us);
        break :blk entry;
    };
    switch (entry.state) {
        .resolved, .checking => return _netif.transmit(stack, interface, frame, &entry.hardware, _ip.ethertype),
        .pending => {
            if (entry.queued == queue_max) {
                const oldest = sys.RemHead(&entry.queue).?;
                stack.frames.give(sys, @fieldParentPtr("node", oldest));
                stack.arp.dropped += 1;
                entry.queued -= 1;
            }
            sys.AddTail(&entry.queue, &frame.node);
            entry.queued += 1;
            return 0;
        },
        .held, .free => {
            stack.frames.give(sys, frame);
            stack.arp.dropped += 1;
            return bsd.EHOSTUNREACH;
        },
    }
}

/// A question for `entry`'s address, to every station or straight to the
/// one it had.
fn ask(stack: *StackBase, entry: *Entry, to: *const [6]u8) void {
    const interface = entry.interface.?;
    send(stack, interface, request, to, &(@as([6]u8, @splat(0))), entry.address);
    stack.arp.requests_sent += 1;
}

/// An ARP packet of `operation` from `interface`, to the station `to`,
/// about `target_hardware` and `target_address`.
fn send(stack: *StackBase, interface: *Interface, operation: u16, to: *const [6]u8, target_hardware: *const [6]u8, target_address: u32) void {
    const frame = stack.frames.take(stack.sys_base) orelse return;
    const packet = frame.buffer[frame.start..][0..packet_bytes];
    frame.length = packet_bytes;
    _ip.put16(packet, 0, 1); // Ethernet
    _ip.put16(packet, 2, _ip.ethertype);
    packet[4] = 6;
    packet[5] = 4;
    _ip.put16(packet, 6, operation);
    packet[8..14].* = interface.hardware;
    _ip.put32(packet, 14, interface.address);
    packet[18..24].* = target_hardware.*;
    _ip.put32(packet, 24, target_address);
    _ = _netif.transmit(stack, interface, frame, to, ethertype);
}

/// A gratuitous question for the interface's own address, when it comes
/// up: every station's cache learns where it is.
pub fn announce(stack: *StackBase, interface: *Interface) void {
    send(stack, interface, request, &broadcast, &(@as([6]u8, @splat(0))), interface.address);
    stack.arp.requests_sent += 1;
}

/// An ARP packet that came in on `interface`.
pub fn input(stack: *StackBase, interface: *Interface, frame: *Frame, now: u64) void {
    const sys = stack.sys_base;
    defer stack.frames.give(sys, frame);
    const packet = frame.bytes();
    if (packet.len < packet_bytes or _ip.get16(packet, 0) != 1 or _ip.get16(packet, 2) != _ip.ethertype or
        packet[4] != 6 or packet[5] != 4)
    {
        stack.arp.bad += 1;
        return;
    }
    const operation = _ip.get16(packet, 6);
    const sender_hardware: [6]u8 = packet[8..14].*;
    const sender_address = _ip.get32(packet, 14);
    const target_address = _ip.get32(packet, 24);
    // A probe (sender 0.0.0.0) teaches nothing.
    if (sender_address != 0) {
        if (find(stack, interface, sender_address)) |entry| {
            learned(stack, entry, &sender_hardware, now);
        } else if (target_address == interface.address) {
            if (claim(stack)) |entry| {
                entry.address = sender_address;
                entry.interface = interface;
                entry.state = .pending;
                learned(stack, entry, &sender_hardware, now);
            }
        }
    }
    if (operation == request and target_address == interface.address and interface.address != 0) {
        send(stack, interface, reply, &sender_hardware, &sender_hardware, sender_address);
        stack.arp.replies_sent += 1;
    }
}

/// `entry`'s address is at `hardware`: what waited for it goes out, and it
/// lives from now.
fn learned(stack: *StackBase, entry: *Entry, hardware: *const [6]u8, now: u64) void {
    const sys = stack.sys_base;
    entry.hardware = hardware.*;
    entry.state = .resolved;
    entry.heard = 0;
    entry.tries = 0;
    _ = _timer.set(stack, &entry.timer, now + life_us);
    const interface = entry.interface.?;
    while (sys.RemHead(&entry.queue)) |node| {
        _ = _netif.transmit(stack, interface, @fieldParentPtr("node", node), &entry.hardware, _ip.ethertype);
    }
    entry.queued = 0;
}

/// Traffic from `address` at `hardware` on `interface`: a resolved entry
/// for it lives on without being asked.
pub fn heard(stack: *StackBase, interface: *Interface, address: u32, hardware: *const [6]u8) void {
    const entry = find(stack, interface, address) orelse return;
    if (entry.state != .resolved) return;
    for (entry.hardware, hardware) |had, got| {
        if (had != got) return;
    }
    entry.heard = 1;
}

/// An entry's deadline came.
fn fire(stack: *StackBase, fired: *Timer, now: u64) void {
    const entry: *Entry = @fieldParentPtr("timer", fired);
    switch (entry.state) {
        .pending => {
            if (entry.tries < tries_max) {
                entry.tries += 1;
                ask(stack, entry, &broadcast);
                _ = _timer.set(stack, &entry.timer, now + retry_us);
                return;
            }
            dropQueue(stack, entry);
            entry.state = .held;
            _ = _timer.set(stack, &entry.timer, now + hold_us);
        },
        .resolved => {
            if (entry.heard != 0) {
                entry.heard = 0;
                _ = _timer.set(stack, &entry.timer, now + life_us);
                return;
            }
            entry.state = .checking;
            ask(stack, entry, &entry.hardware);
            _ = _timer.set(stack, &entry.timer, now + check_us);
        },
        .checking, .held, .free => release(stack, entry),
    }
}

/// Every entry on `interface` gone, when the interface goes.
pub fn forget(stack: *StackBase, interface: *Interface) void {
    for (&stack.arp.entries) |*entry| {
        if (entry.state != .free and entry.interface == interface) release(stack, entry);
    }
}

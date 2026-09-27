// SPDX-License-Identifier: MIT
//! Neighbor Discovery (RFC 4861): which Ethernet address an IPv6 address
//! on a link has, and duplicate address detection (RFC 4862, 5.4) for
//! the interface's own addresses.
//!
//! **The neighbor cache** holds an entry per neighbor spoken to or heard
//! from. An entry is `incomplete` while its solicitation is out - to the
//! neighbor's solicited-node group, three times a second apart - holding
//! the first few packets for it; with no answer they are dropped and the
//! entry goes. An answer that says it was solicited makes it `reachable`,
//! for the interface's reachable time (30 seconds, taken at random
//! between half and one and a half of it); after that it is `stale`, and
//! is still used. The first packet to a stale neighbor makes it `delay`:
//! five seconds on, unless an answer came meanwhile, it is `probe`d with
//! solicitations straight to the address it had, three a second apart,
//! and goes if none is answered. A solicitation or an unsolicited
//! advertisement that brings an Ethernet address makes an entry stale
//! with it.
//!
//! **Answered**: a solicitation for one of the interface's usable
//! addresses is answered with an advertisement - to the asker, or to all
//! nodes when it asked from the unspecified address - that carries our
//! Ethernet address and asks to override what the asker had.
//!
//! **Checked**: a message is taken only with a hop limit of 255, which no
//! router forwards, code 0, its length at least its fixed part, a target
//! that is no group, and options none of which has length 0. An
//! advertisement to a group may not say it was solicited; a solicitation
//! from the unspecified address must go to a solicited-node group and
//! carry no Ethernet address.
//!
//! **Duplicate address detection**: an address is `tentative` until it
//! has been checked: after a random delay of up to a second, a
//! solicitation for it goes out from the unspecified address, with a
//! nonce (RFC 7527) so that a link which echoes it back is not taken for
//! another station, and when a second passes without an advertisement
//! for the address or another station's solicitation for it, it is
//! `preferred`. A duplicate stable address is made again with the next
//! counter (RFC 7217), up to three times; any other duplicate is never
//! used.
//!
//! Everything here runs under the stack's lock; `now` is the caller's.

const builtin = @import("builtin");
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
const _ip6 = @import("../ip6/_ip6.zig");
const _inet = @import("../inet/_inet.zig");
const mld = @import("mld.zig");
const router = @import("router.zig");
const Address = @import("../ip6/address.zig").Address;

pub const entries_max = 16;
/// Packets kept for a neighbor while its solicitation is out.
pub const queue_max = 3;

pub const retrans_us: u64 = 1_000_000;
pub const delay_us: u64 = 5_000_000;
pub const reachable_us: u32 = 30_000_000;
pub const solicits_max = 3;
/// Stable addresses tried again after a duplicate.
pub const idgen_retries = 3;
/// The most a duplicate address check waits before it asks.
pub const dad_delay_us: u32 = 1_000_000;
/// ND's hop limit, which no router forwards.
pub const hop_limit: u8 = 255;

pub const router_solicitation: u8 = 133;
pub const router_advertisement: u8 = 134;
pub const neighbor_solicitation: u8 = 135;
pub const neighbor_advertisement: u8 = 136;
pub const redirect: u8 = 137;

pub const option_source: u8 = 1;
pub const option_target: u8 = 2;
pub const option_nonce: u8 = 14;

/// An advertisement's flags.
pub const flag_router: u8 = 0x80;
pub const flag_solicited: u8 = 0x40;
pub const flag_override: u8 = 0x20;

/// The bytes of a solicitation or advertisement before its options.
pub const message_bytes = 24;

pub const State = enum(u8) { free, incomplete, reachable, stale, delay, probe };

pub const Entry = extern struct {
    timer: Timer = .{},
    address: Address = .{},
    hardware: [6]u8 = @splat(0),
    state: State = .free,
    /// Solicitations sent since it was last answered.
    probes: u8 = 0,
    /// It said it is a router.
    router: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    interface: ?*Interface = null,
    /// The packets waiting for the answer, oldest first.
    queue: exec.List = .{},
    queued: u32 = 0,
    /// When it was last used or heard from.
    used_at: u64 align(4) = 0,
};

pub const Cache = extern struct {
    entries: [entries_max]Entry = @splat(.{}),
    random_state: u32 = 0x6C07_8965,
};

/// Every entry's queue made a list, once, when the stack starts.
pub fn init(stack: *StackBase) void {
    for (&stack.nd.entries) |*entry| {
        entry.* = .{};
        entry.queue.init(.unknown);
        entry.timer.fire = &fire;
    }
}

pub fn random(stack: *StackBase) u32 {
    if (builtin.cpu.arch == .xtensa) return sdk.hardware.rng.read();
    const state = &stack.nd.random_state;
    state.* ^= state.* << 13;
    state.* ^= state.* >> 17;
    state.* ^= state.* << 5;
    return state.*;
}

/// A random time below `most` microseconds.
pub fn below(stack: *StackBase, most: u32) u64 {
    if (most == 0) return 0;
    return random(stack) % most;
}

/// The reachable time an interface uses: its base taken at random between
/// half and one and a half of it (RFC 4861, 6.3.2).
pub fn reachableTime(stack: *StackBase, interface: *Interface) u64 {
    const base: u64 = interface.ip6.reachable_us;
    return base / 2 + below(stack, @intCast(@min(base, 0xFFFF_FFFF)));
}

pub fn find(stack: *StackBase, interface: *Interface, address: Address) ?*Entry {
    for (&stack.nd.entries) |*entry| {
        if (entry.state != .free and entry.interface == interface and entry.address.eql(address)) return entry;
    }
    return null;
}

/// A free entry, or the stale one used longest ago made free; null when
/// every entry is busy.
fn claim(stack: *StackBase) ?*Entry {
    var oldest: ?*Entry = null;
    for (&stack.nd.entries) |*entry| {
        if (entry.state == .free) return entry;
        if (entry.state != .stale) continue;
        if (oldest == null or entry.used_at < oldest.?.used_at) oldest = entry;
    }
    const entry = oldest orelse return null;
    release(stack, entry);
    return entry;
}

fn release(stack: *StackBase, entry: *Entry) void {
    _timer.cancel(stack, &entry.timer);
    dropQueue(stack, entry);
    entry.state = .free;
    entry.interface = null;
    entry.router = 0;
}

fn dropQueue(stack: *StackBase, entry: *Entry) void {
    const sys = stack.sys_base;
    while (sys.RemHead(&entry.queue)) |node| {
        stack.frames.give(sys, @fieldParentPtr("node", node));
        stack.counts.nd_dropped += 1;
    }
    entry.queued = 0;
}

/// A new entry for `address` on `interface` in `state`, or null.
fn create(stack: *StackBase, interface: *Interface, address: Address, state: State, now: u64) ?*Entry {
    const entry = claim(stack) orelse return null;
    entry.address = address;
    entry.interface = interface;
    entry.state = state;
    entry.probes = 0;
    entry.router = 0;
    entry.used_at = now;
    return entry;
}

/// `frame`, an IPv6 packet, sent to `next_hop` on `interface` once its
/// Ethernet address is known: at once, or when the answer comes. 0, or
/// `ENOBUFS` when there is no room to ask; the frame is this layer's
/// either way.
pub fn resolve(stack: *StackBase, interface: *Interface, next_hop: Address, frame: *Frame, now: u64) i32 {
    const sys = stack.sys_base;
    const entry = find(stack, interface, next_hop) orelse blk: {
        const entry = create(stack, interface, next_hop, .incomplete, now) orelse {
            stack.frames.give(sys, frame);
            stack.counts.nd_dropped += 1;
            return bsd.ENOBUFS;
        };
        entry.probes = 1;
        solicit(stack, interface, next_hop, null);
        _ = _timer.set(stack, &entry.timer, now + interface.ip6.retrans_us);
        break :blk entry;
    };
    entry.used_at = now;
    switch (entry.state) {
        .reachable, .delay, .probe => return _netif.transmit(stack, interface, frame, &entry.hardware, _ip6.ethertype),
        .stale => {
            entry.state = .delay;
            _ = _timer.set(stack, &entry.timer, now + delay_us);
            return _netif.transmit(stack, interface, frame, &entry.hardware, _ip6.ethertype);
        },
        .incomplete => {
            if (entry.queued == queue_max) {
                const oldest = sys.RemHead(&entry.queue).?;
                stack.frames.give(sys, @fieldParentPtr("node", oldest));
                stack.counts.nd_dropped += 1;
                entry.queued -= 1;
            }
            sys.AddTail(&entry.queue, &frame.node);
            entry.queued += 1;
            return 0;
        },
        .free => unreachable,
    }
}

/// What waited for `entry` sent, now that its Ethernet address is known.
fn flush(stack: *StackBase, entry: *Entry) void {
    const sys = stack.sys_base;
    const interface = entry.interface.?;
    while (sys.RemHead(&entry.queue)) |node| {
        _ = _netif.transmit(stack, interface, @fieldParentPtr("node", node), &entry.hardware, _ip6.ethertype);
    }
    entry.queued = 0;
}

/// An entry's deadline came.
fn fire(stack: *StackBase, fired: *Timer, now: u64) void {
    const entry: *Entry = @fieldParentPtr("timer", fired);
    const interface = entry.interface.?;
    switch (entry.state) {
        .incomplete, .probe => {
            if (entry.probes < solicits_max) {
                entry.probes += 1;
                solicit(stack, interface, entry.address, if (entry.state == .probe) &entry.hardware else null);
                _ = _timer.set(stack, &entry.timer, now + interface.ip6.retrans_us);
                return;
            }
            release(stack, entry);
        },
        .reachable => entry.state = .stale,
        .delay => {
            entry.state = .probe;
            entry.probes = 1;
            solicit(stack, interface, entry.address, &entry.hardware);
            _ = _timer.set(stack, &entry.timer, now + interface.ip6.retrans_us);
        },
        .stale, .free => {},
    }
}

/// Every entry on `interface` gone, when the interface goes.
pub fn forget(stack: *StackBase, interface: *Interface) void {
    for (&stack.nd.entries) |*entry| {
        if (entry.state != .free and entry.interface == interface) release(stack, entry);
    }
}

// --- sending -------------------------------------------------------------------------

/// `frame`, holding an ND message, given its checksum and IPv6 header and
/// sent: to the station `station` when it is known, to the group's
/// Ethernet address for a group, else through the neighbor cache.
pub fn send(stack: *StackBase, interface: *Interface, frame: *Frame, source: Address, destination: Address, station: ?*const [6]u8) void {
    const message = frame.bytes();
    _ip.put16(message, 2, 0);
    _ip.put16(message, 2, _ip.finish(_ip.sum(_inet.pseudoSum(source, destination, _ip6.protocol_icmp6, frame.length), message)));
    _ip6.prepend(stack, frame, source, destination, _ip6.protocol_icmp6, hop_limit);
    if (interface.no_arp != 0) {
        interface.sent += 1;
        _ = _netif.transmit(stack, interface, frame, &@import("../arp/_arp.zig").broadcast, _ip6.ethertype);
    } else if (station) |to| {
        interface.sent += 1;
        _ = _netif.transmit(stack, interface, frame, to, _ip6.ethertype);
    } else if (destination.isMulticast()) {
        interface.sent += 1;
        const group = _netif.groupStation(destination);
        _ = _netif.transmit(stack, interface, frame, &group, _ip6.ethertype);
    } else {
        _ = _netif.output6(stack, interface, frame, destination);
    }
}

/// A frame holding a solicitation or advertisement's fixed part for
/// `target`, of `kind`, with `flags`; null when no frame is free.
fn messageFrame(stack: *StackBase, kind: u8, flags: u8, target: Address) ?*Frame {
    const frame = stack.frames.take(stack.sys_base) orelse return null;
    const bytes = frame.room()[frame.start..][0..message_bytes];
    frame.length = message_bytes;
    bytes[0] = kind;
    bytes[1] = 0;
    _ip.put16(bytes, 2, 0);
    _ip.put32(bytes, 4, @as(u32, flags) << 24);
    bytes[8..24].* = target.bytes;
    return frame;
}

/// A link-layer address option of `kind` behind what `frame` holds.
pub fn addLinkOption(frame: *Frame, kind: u8, hardware: [6]u8) void {
    const option = frame.room()[frame.start + frame.length ..][0..8];
    option[0] = kind;
    option[1] = 1;
    option[2..8].* = hardware;
    frame.length += 8;
}

/// A solicitation for `target`: to its solicited-node group, or straight
/// to the station `station` it had, from the interface's link-local
/// address with our Ethernet address.
fn solicit(stack: *StackBase, interface: *Interface, target: Address, station: ?*const [6]u8) void {
    const source = _ip6.linkLocal(interface) orelse sourceOnLink(interface) orelse return;
    const frame = messageFrame(stack, neighbor_solicitation, 0, target) orelse return;
    addLinkOption(frame, option_source, interface.hardware);
    stack.counts.nd_solicits_sent += 1;
    send(stack, interface, frame, source, if (station != null) target else target.solicitedNode(), station);
}

/// Any usable address of the interface, when it has no link-local one.
fn sourceOnLink(interface: *Interface) ?Address {
    for (&interface.ip6.addresses) |*entry| {
        if (entry.usable()) return entry.address;
    }
    return null;
}

/// An advertisement for our `target` to `destination`.
fn advertise(stack: *StackBase, interface: *Interface, target: Address, destination: Address, flags: u8) void {
    const frame = messageFrame(stack, neighbor_advertisement, flags, target) orelse return;
    addLinkOption(frame, option_target, interface.hardware);
    stack.counts.nd_adverts_sent += 1;
    send(stack, interface, frame, target, destination, null);
}

// --- in ------------------------------------------------------------------------------

/// What a message's options held: a link-layer address and a nonce, if
/// they were there; null when an option was malformed.
const Options = struct {
    link: ?[6]u8 = null,
    nonce: ?[6]u8 = null,
};

fn readOptions(options: []const u8, link_kind: u8) ?Options {
    var found: Options = .{};
    var at: usize = 0;
    while (at < options.len) {
        if (at + 2 > options.len) return null;
        const length = @as(usize, options[at + 1]) * 8;
        if (length == 0 or at + length > options.len) return null;
        if (options[at] == link_kind and length >= 8) found.link = options[at + 2 ..][0..6].*;
        if (options[at] == option_nonce and length == 8) found.nonce = options[at + 2 ..][0..6].*;
        at += length;
    }
    return found;
}

/// A Neighbor Discovery message that came in on `interface`, the frame
/// starting at it and its checksum checked. The frame is this layer's.
pub fn input(stack: *StackBase, interface: *Interface, frame: *Frame, packet: _inet.Packet, now: u64) void {
    defer stack.frames.give(stack.sys_base, frame);
    const bytes = frame.bytes();
    if (packet.hop_limit != hop_limit or bytes[1] != 0) {
        stack.counts.nd_bad += 1;
        return;
    }
    switch (bytes[0]) {
        neighbor_solicitation => solicited(stack, interface, bytes, packet, now),
        neighbor_advertisement => advertised(stack, interface, bytes, packet, now),
        router_advertisement => router.advertised(stack, interface, bytes, packet, now),
        redirect => router.redirected(stack, interface, bytes, packet, now),
        else => {},
    }
}

fn solicited(stack: *StackBase, interface: *Interface, bytes: []const u8, packet: _inet.Packet, now: u64) void {
    if (bytes.len < message_bytes) return bad(stack);
    const target: Address = .{ .bytes = bytes[8..24].* };
    if (target.isMulticast()) return bad(stack);
    const options = readOptions(bytes[message_bytes..], option_source) orelse return bad(stack);
    const from_nobody = packet.source.isUnspecified();
    if (from_nobody and (options.link != null or !isSolicitedNode(packet.destination))) return bad(stack);
    const own = _ip6.addressOf(interface, target) orelse return;
    switch (own.state) {
        .tentative => {
            // Another station checking the same address - unless it is
            // our own check come back.
            if (!from_nobody) return;
            if (options.nonce) |nonce| {
                if (eqlStation(nonce, own.nonce)) return;
            }
            return duplicate(stack, own, now);
        },
        .preferred, .deprecated => {},
        .unused, .duplicate => return,
    }
    if (from_nobody) {
        return advertise(stack, interface, target, Address.all_nodes, flag_override);
    }
    if (options.link) |hardware| heard(stack, interface, packet.source, hardware, now);
    advertise(stack, interface, target, packet.source, flag_solicited | flag_override);
}

fn advertised(stack: *StackBase, interface: *Interface, bytes: []const u8, packet: _inet.Packet, now: u64) void {
    if (bytes.len < message_bytes) return bad(stack);
    const target: Address = .{ .bytes = bytes[8..24].* };
    const flags = bytes[4];
    if (target.isMulticast() or (packet.destination.isMulticast() and flags & flag_solicited != 0)) return bad(stack);
    const options = readOptions(bytes[message_bytes..], option_target) orelse return bad(stack);
    if (_ip6.addressOf(interface, target)) |own| {
        // Somebody has our address: fatal while it is still being checked.
        if (own.state == .tentative) duplicate(stack, own, now);
        return;
    }
    const entry = find(stack, interface, target) orelse return;
    entry.used_at = now;
    if (entry.state == .incomplete) {
        const hardware = options.link orelse return;
        entry.hardware = hardware;
        entry.router = @intFromBool(flags & flag_router != 0);
        entry.probes = 0;
        if (flags & flag_solicited != 0) {
            entry.state = .reachable;
            _ = _timer.set(stack, &entry.timer, now + reachableTime(stack, interface));
        } else {
            entry.state = .stale;
            _timer.cancel(stack, &entry.timer);
        }
        return flush(stack, entry);
    }
    const differs = if (options.link) |hardware| !eqlStation(hardware, entry.hardware) else false;
    if (flags & flag_override == 0 and differs) {
        if (entry.state == .reachable) {
            entry.state = .stale;
            _timer.cancel(stack, &entry.timer);
        }
        return;
    }
    if (options.link) |hardware| entry.hardware = hardware;
    entry.router = @intFromBool(flags & flag_router != 0);
    if (flags & flag_solicited != 0) {
        entry.state = .reachable;
        entry.probes = 0;
        _ = _timer.set(stack, &entry.timer, now + reachableTime(stack, interface));
    } else if (differs) {
        entry.state = .stale;
        _timer.cancel(stack, &entry.timer);
    }
}

fn bad(stack: *StackBase) void {
    stack.counts.nd_bad += 1;
}

fn isSolicitedNode(address: Address) bool {
    const prefix = [13]u8{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0xff };
    for (address.bytes[0..13], prefix) |a, b| if (a != b) return false;
    return true;
}

fn eqlStation(a: [6]u8, b: [6]u8) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// A neighbor at `hardware` told of itself, in a solicitation or a
/// router's message: an entry for it made or brought up to date, stale.
pub fn heard(stack: *StackBase, interface: *Interface, address: Address, hardware: [6]u8, now: u64) void {
    if (find(stack, interface, address)) |entry| {
        entry.used_at = now;
        if (entry.state == .incomplete) {
            entry.hardware = hardware;
            entry.state = .stale;
            _timer.cancel(stack, &entry.timer);
            return flush(stack, entry);
        }
        if (!eqlStation(entry.hardware, hardware)) {
            entry.hardware = hardware;
            entry.state = .stale;
            _timer.cancel(stack, &entry.timer);
        }
        return;
    }
    const entry = create(stack, interface, address, .stale, now) orelse return;
    entry.hardware = hardware;
}

// --- duplicate address detection ------------------------------------------------------

/// `own`, tentative, checked: its solicitation sent after up to
/// `delay_most` microseconds.
pub fn check(stack: *StackBase, own: *_ip6.InterfaceAddress, delay_most: u32) void {
    own.state = .tentative;
    own.checks_left = 1;
    for (&own.nonce) |*byte| byte.* = @truncate(random(stack));
    own.timer.fire = &checkFire;
    _ = _timer.set(stack, &own.timer, _timer.clock(stack) + below(stack, delay_most));
}

fn checkFire(stack: *StackBase, fired: *Timer, now: u64) void {
    const own: *_ip6.InterfaceAddress = @fieldParentPtr("timer", fired);
    const interface = own.interface.?;
    if (own.state != .tentative) return;
    if (own.checks_left == 0) {
        own.state = .preferred;
        return _ip6.ready(stack, own, now);
    }
    own.checks_left -= 1;
    if (messageFrame(stack, neighbor_solicitation, 0, own.address)) |frame| {
        const option = frame.room()[frame.start + frame.length ..][0..8];
        option[0] = option_nonce;
        option[1] = 1;
        option[2..8].* = own.nonce;
        frame.length += 8;
        stack.counts.nd_solicits_sent += 1;
        send(stack, interface, frame, Address.any, own.address.solicitedNode(), null);
    }
    _ = _timer.set(stack, &own.timer, now + interface.ip6.retrans_us);
}

/// Another station has `own`: a stable address made again with the next
/// counter, anything else never used.
fn duplicate(stack: *StackBase, own: *_ip6.InterfaceAddress, now: u64) void {
    _ = now;
    stack.counts.nd_duplicates += 1;
    const interface = own.interface.?;
    _timer.cancel(stack, &own.timer);
    mld.leaveGroup(stack, interface, own.address.solicitedNode());
    if (interface.ip6.identifier == bsd.IFID_STABLE and stack.crypto != null and own.counter < idgen_retries) {
        own.counter += 1;
        const prefix = own.address.bytes[0..8].*;
        own.address = _ip6.addressFor(stack, interface, &prefix, own.counter);
        mld.joinGroup(stack, interface, own.address.solicitedNode());
        return check(stack, own, dad_delay_us);
    }
    own.state = .duplicate;
}

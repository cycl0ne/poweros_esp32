// SPDX-License-Identifier: MIT
//! The DHCPv6 client (RFC 8415), one per interface that takes addresses
//! from its routers (IFIPV6_AUTO). It starts when a router's
//! advertisement asks for it (`nd/router.zig`):
//!
//! **The M flag** - addresses are handed out: SOLICIT goes to every DHCPv6
//! server and relay on the link (`ff02::1:2`); the ADVERTISEs that come
//! back in the first retransmission time are weighed by their preference
//! (one of 255 is taken at once, any one at all after that time), and the
//! best server is asked with REQUEST. Its REPLY gives the addresses - each
//! one alone (/128): the prefix's route comes from the routers - checked
//! for a duplicate before they are used, and the name servers and the
//! search domain. At T1 the client RENEWs with its server, at T2 it
//! REBINDs with any, and when the addresses' valid lifetimes have ended it
//! starts again. An address another station has is DECLINEd, and the
//! client starts again. Removing the interface gives the addresses back
//! (RELEASE).
//!
//! **The O flag alone** - only other settings: INFORMATION-REQUEST, whose
//! REPLY gives the name servers and the search domain, asked again after
//! its refresh time (a day unless it names one, ten minutes at the least).
//!
//! The name servers go beside those the routers named, for as long as the
//! lease lasts, or twice the refresh time; the search domain likewise.
//! Every message carries the client's DUID-LL (its Ethernet address),
//! the interface's index as the IAID, and the time since its exchange
//! began, and goes again after RFC 8415's times (7.6): doubled each time,
//! a tenth either way at random, up to the message's most.
//!
//! **Every length is checked**: an option cut short makes the message
//! nothing, and one whose transaction or client id is not ours is not
//! taken. A message while the client is idle is left to the sockets.

const sdk = @import("sdk");
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
const _nd = @import("../nd/_nd.zig");
const router = @import("../nd/router.zig");
const slaac = @import("../nd/slaac.zig");
const Address = @import("../ip6/address.zig").Address;

pub const client_port: u16 = 546;
pub const server_port: u16 = 547;
/// `ff02::1:2`, every DHCPv6 server and relay on the link.
pub const all_servers: Address = .{ .bytes = .{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2 } };

// Message types.
pub const solicit: u8 = 1;
pub const advertise: u8 = 2;
pub const request: u8 = 3;
pub const renew: u8 = 5;
pub const rebind: u8 = 6;
pub const reply: u8 = 7;
pub const release: u8 = 8;
pub const decline: u8 = 9;
pub const information_request: u8 = 11;

// Options.
pub const option_client_id: u16 = 1;
pub const option_server_id: u16 = 2;
pub const option_ia_na: u16 = 3;
pub const option_ia_address: u16 = 5;
pub const option_request: u16 = 6;
pub const option_preference: u16 = 7;
pub const option_elapsed_time: u16 = 8;
pub const option_status_code: u16 = 13;
pub const option_dns_servers: u16 = 23;
pub const option_domain_list: u16 = 24;
pub const option_refresh_time: u16 = 32;

// Status codes.
pub const status_success: u16 = 0;
pub const status_no_addresses: u16 = 2;
pub const status_no_binding: u16 = 3;
pub const status_not_on_link: u16 = 4;

const second_us: u64 = 1_000_000;
/// RFC 8415's times (7.6): the first retransmission time and the most of
/// each message, and how long the first SOLICIT or INFORMATION-REQUEST
/// waits.
const start_delay_us: u32 = 1_000_000;
const solicit_us: u64 = 1 * second_us;
const solicit_max_us: u64 = 3600 * second_us;
const request_us: u64 = 1 * second_us;
const request_max_us: u64 = 30 * second_us;
const requests_max = 10;
const renew_us: u64 = 10 * second_us;
const renew_max_us: u64 = 600 * second_us;
const inform_us: u64 = 1 * second_us;
const inform_max_us: u64 = 3600 * second_us;
/// INFORMATION_REFRESH_TIME's default and least, in seconds.
pub const refresh_default_s: u32 = 86400;
pub const refresh_min_s: u32 = 600;
/// The soonest a lease is renewed, whatever it says.
const t1_min_s: u32 = 10;

/// The addresses one lease holds here, and the longest server DUID kept.
pub const leased_max = 2;
const server_id_max = 64;
/// DUID-LL: its type, Ethernet's hardware type, and the address.
const duid_bytes = 10;

pub const State = enum(u8) { idle, soliciting, requesting, bound, renewing, rebinding, informing, informed };

/// An interface's DHCPv6 client.
pub const Client = extern struct {
    timer: Timer = .{},
    state: State = .idle,
    /// Messages sent in this exchange; whether an ADVERTISE is held, and
    /// its preference.
    tries: u8 = 0,
    advertised: u8 = 0,
    preference: u8 = 0,
    /// The exchange's transaction id, 24 bits.
    xid: u32 = 0,
    /// The server asked, or that gave the lease: its DUID.
    server_id: [server_id_max]u8 = @splat(0),
    server_id_length: u32 = 0,
    /// The addresses the held ADVERTISE offers, or the lease gave.
    addresses: [leased_max]Address = @splat(.{}),
    address_count: u32 = 0,
    /// When this exchange's first message went, and the time to the next.
    exchange_start: u64 align(4) = 0,
    retransmit_us: u64 align(4) = 0,
    /// When the lease is renewed (T1), rebound (T2), and when its
    /// addresses end; 0 for never.
    t1_at: u64 align(4) = 0,
    t2_at: u64 align(4) = 0,
    ends_at: u64 align(4) = 0,
    interface: ?*Interface = null,
};

/// The client ready on `interface`, idle until a router asks for it.
/// Under the lock.
pub fn start(stack: *StackBase, interface: *Interface) void {
    _ = stack;
    const client = &interface.ip6.dhcp6;
    client.* = .{ .interface = interface };
    client.timer.fire = &fire;
}

/// The client stopped, when the interface's IPv6 goes.
pub fn stop(stack: *StackBase, interface: *Interface) void {
    const client = &interface.ip6.dhcp6;
    _timer.cancel(stack, &client.timer);
    client.state = .idle;
}

/// The lease given back, while the interface can still send: before it
/// is taken down.
pub fn giveBack(stack: *StackBase, interface: *Interface) void {
    const client = &interface.ip6.dhcp6;
    if (client.interface == null) return;
    if ((client.state == .bound or client.state == .renewing or client.state == .rebinding) and client.address_count > 0) {
        client.xid = _nd.random(stack) & 0xFF_FFFF;
        client.exchange_start = _timer.clock(stack);
        send(stack, client, release, null);
    }
    stop(stack, interface);
}

/// A router's advertisement came in on `interface` with `flags`: the
/// client started when they ask for DHCPv6 and it is not at it already -
/// or moved on to addresses when they are asked for at last.
pub fn advertised(stack: *StackBase, interface: *Interface, flags: u8) void {
    const client = &interface.ip6.dhcp6;
    if (client.interface == null or interface.ip6.autoconf == 0) return;
    const managed = flags & router.flag_managed != 0;
    switch (client.state) {
        .idle => {
            if (managed) {
                begin(stack, client, .soliciting);
            } else if (flags & router.flag_other != 0) {
                begin(stack, client, .informing);
            }
        },
        .informing, .informed => if (managed) begin(stack, client, .soliciting),
        else => {},
    }
}

/// A new exchange of `state`: a new transaction, its first message after
/// a random delay for SOLICIT and INFORMATION-REQUEST, at once else.
fn begin(stack: *StackBase, client: *Client, state: State) void {
    client.state = state;
    client.tries = 0;
    client.retransmit_us = 0;
    client.xid = _nd.random(stack) & 0xFF_FFFF;
    if (state == .soliciting) {
        client.advertised = 0;
        client.preference = 0;
        client.address_count = 0;
    }
    const delay: u64 = if (state == .soliciting or state == .informing) _nd.below(stack, start_delay_us) else 0;
    _ = _timer.set(stack, &client.timer, _timer.clock(stack) + delay);
}

fn fire(stack: *StackBase, fired: *Timer, now: u64) void {
    const client: *Client = @fieldParentPtr("timer", fired);
    switch (client.state) {
        .idle => {},
        .soliciting => {
            // The first retransmission time is over: the best ADVERTISE
            // is taken.
            if (client.advertised != 0) return begin(stack, client, .requesting);
            next(stack, client, solicit, solicit_us, solicit_max_us, 0, now);
        },
        .requesting => {
            if (client.tries >= requests_max) return begin(stack, client, .soliciting);
            next(stack, client, request, request_us, request_max_us, 0, now);
        },
        .informing => next(stack, client, information_request, inform_us, inform_max_us, 0, now),
        .informed => begin(stack, client, .informing),
        .bound => begin(stack, client, .renewing),
        .renewing => {
            if (client.t2_at != 0 and now >= client.t2_at) return begin(stack, client, .rebinding);
            next(stack, client, renew, renew_us, renew_max_us, client.t2_at, now);
        },
        .rebinding => {
            if (client.ends_at != 0 and now >= client.ends_at) {
                forget(stack, client);
                return begin(stack, client, .soliciting);
            }
            next(stack, client, rebind, renew_us, renew_max_us, client.ends_at, now);
        },
    }
}

/// The exchange's next message of `kind` sent, and the one after it set
/// for its retransmission time - no later than `until`, unless that is 0.
fn next(stack: *StackBase, client: *Client, kind: u8, initial_us: u64, most_us: u64, until: u64, now: u64) void {
    if (client.tries == 0) client.exchange_start = now;
    client.retransmit_us = retransmitTime(stack, client.retransmit_us, initial_us, most_us, kind == solicit);
    client.tries +|= 1;
    send(stack, client, kind, null);
    var at = now + client.retransmit_us;
    if (until != 0 and at > until) at = until;
    _ = _timer.set(stack, &client.timer, at);
}

/// RFC 8415, 15: the time to the next message, from `previous` (0 before
/// the first): the first `initial`, then twice the last, each a tenth
/// either way at random - the first SOLICIT's only more - and held near
/// `most`.
fn retransmitTime(stack: *StackBase, previous: u64, initial: u64, most: u64, first_longer: bool) u64 {
    const base = if (previous == 0) initial else previous;
    const tenth = base / 10;
    var time = if (previous == 0) initial else 2 * previous;
    if (previous == 0 and first_longer) {
        time += 1 + _nd.below(stack, @intCast(@max(tenth, 1)));
    } else {
        time = time - tenth + _nd.below(stack, @intCast(2 * tenth + 1));
    }
    if (most != 0 and time > most) time = most - most / 10 + _nd.below(stack, @intCast(most / 5 + 1));
    return time;
}

// --- messages out ---------------------------------------------------------------------

fn putOption(bytes: []u8, at: usize, code: u16, data: []const u8) usize {
    _ip.put16(bytes, at, code);
    _ip.put16(bytes, at + 2, @intCast(data.len));
    @memcpy(bytes[at + 4 ..][0..data.len], data);
    return at + 4 + data.len;
}

/// The client's DUID-LL: type 3, hardware type 1, its Ethernet address.
fn duid(interface: *const Interface) [duid_bytes]u8 {
    const station = interface.hardware;
    return .{ 0, 3, 0, 1, station[0], station[1], station[2], station[3], station[4], station[5] };
}

/// A message of `kind` for the exchange, to every server on the link:
/// the client's id, the server's where it names one, the time it took
/// so far, what it asks for, and its IA_NA with the addresses it holds -
/// or only `only`.
fn send(stack: *StackBase, client: *Client, kind: u8, only: ?Address) void {
    const interface = client.interface.?;
    const source = _ip6.linkLocal(interface) orelse return;
    const frame = stack.frames.take(stack.sys_base) orelse return;
    const bytes = frame.room()[frame.start..];
    bytes[0] = kind;
    bytes[1] = @truncate(client.xid >> 16);
    bytes[2] = @truncate(client.xid >> 8);
    bytes[3] = @truncate(client.xid);
    var at: usize = 4;
    at = putOption(bytes, at, option_client_id, &duid(interface));
    if (kind == request or kind == renew or kind == release or kind == decline) {
        at = putOption(bytes, at, option_server_id, client.server_id[0..client.server_id_length]);
    }
    const elapsed: u16 = @intCast(@min((_timer.clock(stack) -| client.exchange_start) / 10_000, 0xFFFF));
    var two: [2]u8 = undefined;
    _ip.put16(&two, 0, elapsed);
    at = putOption(bytes, at, option_elapsed_time, &two);
    if (kind != release and kind != decline) {
        var asked: [6]u8 = undefined;
        _ip.put16(&asked, 0, option_dns_servers);
        _ip.put16(&asked, 2, option_domain_list);
        _ip.put16(&asked, 4, option_refresh_time);
        at = putOption(bytes, at, option_request, if (kind == information_request) &asked else asked[0..4]);
    }
    if (kind != information_request) {
        // IA_NA: its IAID, T1 and T2 left to the server, the addresses.
        const ia_at = at;
        _ip.put16(bytes, at, option_ia_na);
        at += 4;
        _ip.put32(bytes, at, _netif.index(stack, interface));
        _ip.put32(bytes, at + 4, 0);
        _ip.put32(bytes, at + 8, 0);
        at += 12;
        if (kind != solicit) {
            for (client.addresses[0..client.address_count]) |address| {
                if (only) |wanted| if (!wanted.eql(address)) continue;
                var entry: [24]u8 = @splat(0);
                entry[0..16].* = address.bytes;
                at = putOption(bytes, at, option_ia_address, &entry);
            }
        }
        _ip.put16(bytes, ia_at + 2, @intCast(at - ia_at - 4));
    }
    frame.length = @intCast(at);
    transmit(stack, interface, frame, source);
}

/// `frame`, a DHCPv6 message, given its UDP header and sent to every
/// server on the link from `source`, with a hop limit of 1.
fn transmit(stack: *StackBase, interface: *Interface, frame: *Frame, source: Address) void {
    const udp = frame.push(8);
    _ip.put16(udp, 0, client_port);
    _ip.put16(udp, 2, server_port);
    _ip.put16(udp, 4, @intCast(frame.length));
    _ip.put16(udp, 6, 0);
    const protocol: u8 = @intCast(bsd.IPPROTO_UDP);
    var checksum = _ip.finish(_ip.sum(_inet.pseudoSum(source, all_servers, protocol, frame.length), frame.bytes()));
    if (checksum == 0) checksum = 0xFFFF;
    _ip.put16(udp, 6, checksum);
    const path = _inet.route(stack, all_servers, interface) orelse return stack.frames.give(stack.sys_base, frame);
    _ = _inet.output(stack, frame, source, all_servers, protocol, path, 1);
}

// --- messages in -----------------------------------------------------------------------

/// What a server's message says that the client reads.
const Found = struct {
    client_id: ?[]const u8 = null,
    server_id: ?[]const u8 = null,
    /// The IA_NA for our IAID, behind its IAID.
    ia_na: ?[]const u8 = null,
    status: u16 = status_success,
    preference: u8 = 0,
    servers: ?[]const u8 = null,
    domains: ?[]const u8 = null,
    refresh_s: ?u32 = null,
};

/// Each option in `bytes`: its code and its data; null at the end, and
/// `bad` set when one runs past the end.
const Options = struct {
    bytes: []const u8,
    at: usize = 0,
    bad: bool = false,

    fn next(options: *Options) ?struct { code: u16, data: []const u8 } {
        if (options.at >= options.bytes.len) return null;
        if (options.at + 4 > options.bytes.len) {
            options.bad = true;
            return null;
        }
        const code = _ip.get16(options.bytes, options.at);
        const length = _ip.get16(options.bytes, options.at + 2);
        if (options.at + 4 + length > options.bytes.len) {
            options.bad = true;
            return null;
        }
        const data = options.bytes[options.at + 4 ..][0..length];
        options.at += 4 + length;
        return .{ .code = code, .data = data };
    }
};

/// The options of a message, or null when one is malformed.
fn read(options_bytes: []const u8, iaid: u32) ?Found {
    var found: Found = .{};
    var options: Options = .{ .bytes = options_bytes };
    while (options.next()) |option| {
        switch (option.code) {
            option_client_id => found.client_id = option.data,
            option_server_id => found.server_id = option.data,
            option_ia_na => if (option.data.len >= 12 and _ip.get32(option.data, 0) == iaid) {
                found.ia_na = option.data;
            },
            option_status_code => if (option.data.len >= 2) {
                found.status = _ip.get16(option.data, 0);
            },
            option_preference => if (option.data.len == 1) {
                found.preference = option.data[0];
            },
            option_dns_servers => if (option.data.len % 16 == 0) {
                found.servers = option.data;
            },
            option_domain_list => found.domains = option.data,
            option_refresh_time => if (option.data.len == 4) {
                found.refresh_s = _ip.get32(option.data, 0);
            },
            else => {},
        }
    }
    return if (options.bad) null else found;
}

/// An IA_NA's status, and its addresses with their lifetimes in seconds.
const Lease = struct {
    t1_s: u32 = 0,
    t2_s: u32 = 0,
    status: u16 = status_success,
    addresses: [leased_max]Address = @splat(.{}),
    preferred_s: [leased_max]u32 = @splat(0),
    valid_s: [leased_max]u32 = @splat(0),
    count: usize = 0,
};

/// What an IA_NA holds, or null when it is malformed.
fn leaseOf(ia: []const u8) ?Lease {
    var lease: Lease = .{ .t1_s = _ip.get32(ia, 4), .t2_s = _ip.get32(ia, 8) };
    var options: Options = .{ .bytes = ia[12..] };
    while (options.next()) |option| {
        switch (option.code) {
            option_status_code => if (option.data.len >= 2) {
                lease.status = _ip.get16(option.data, 0);
            },
            option_ia_address => if (option.data.len >= 24 and lease.count < leased_max) {
                const preferred_s = _ip.get32(option.data, 16);
                const valid_s = _ip.get32(option.data, 20);
                // A preferred lifetime past the valid one: not taken.
                if (preferred_s > valid_s) continue;
                lease.addresses[lease.count] = .{ .bytes = option.data[0..16].* };
                lease.preferred_s[lease.count] = preferred_s;
                lease.valid_s[lease.count] = valid_s;
                lease.count += 1;
            },
            else => {},
        }
    }
    return if (options.bad) null else lease;
}

/// A message from a server on `interface` (to UDP port 546 from 547),
/// from its type on: whether it was the client's - true unless the client
/// is idle, when it is left to whatever socket is bound there.
pub fn input(stack: *StackBase, interface: *Interface, message: []const u8) bool {
    const client = &interface.ip6.dhcp6;
    if (client.interface == null or client.state == .idle) return false;
    if (message.len < 4) return true;
    const xid = @as(u32, message[1]) << 16 | @as(u32, message[2]) << 8 | message[3];
    if (xid != client.xid) return true;
    const found = read(message[4..], _netif.index(stack, interface)) orelse return true;
    const own = duid(interface);
    const client_id = found.client_id orelse return true;
    if (client_id.len != own.len or !eqlBytes(client_id, &own)) return true;
    const now = _timer.clock(stack);
    switch (message[0]) {
        advertise => if (client.state == .soliciting) takeAdvertise(stack, client, found),
        reply => switch (client.state) {
            .requesting, .renewing, .rebinding => takeReply(stack, client, found, now),
            .informing => takeInformation(stack, client, found, now),
            else => {},
        },
        else => {},
    }
    return true;
}

fn eqlBytes(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn keepServerId(client: *Client, server_id: []const u8) bool {
    if (server_id.len == 0 or server_id.len > server_id_max) return false;
    @memcpy(client.server_id[0..server_id.len], server_id);
    client.server_id_length = @intCast(server_id.len);
    return true;
}

/// An ADVERTISE while soliciting: kept when it offers addresses and is
/// preferred over the one held; asked for at once when its preference is
/// 255, or the first retransmission time is over.
fn takeAdvertise(stack: *StackBase, client: *Client, found: Found) void {
    const server_id = found.server_id orelse return;
    if (found.status == status_no_addresses) return;
    const lease = leaseOf(found.ia_na orelse return) orelse return;
    if (lease.status == status_no_addresses or lease.count == 0) return;
    if (client.advertised != 0 and found.preference <= client.preference) return;
    if (!keepServerId(client, server_id)) return;
    client.advertised = 1;
    client.preference = found.preference;
    client.address_count = @intCast(lease.count);
    @memcpy(client.addresses[0..lease.count], lease.addresses[0..lease.count]);
    if (found.preference == 255 or client.tries > 1) begin(stack, client, .requesting);
}

/// A REPLY to REQUEST, RENEW or REBIND: the lease's addresses added or
/// brought up to date, its times set, and the name servers and the
/// search domain kept.
fn takeReply(stack: *StackBase, client: *Client, found: Found, now: u64) void {
    const interface = client.interface.?;
    if (found.status == status_not_on_link) return begin(stack, client, .soliciting);
    if (found.status != status_success) return;
    const lease = leaseOf(found.ia_na orelse return) orelse return;
    if (found.server_id) |server_id| _ = keepServerId(client, server_id);
    switch (lease.status) {
        status_success => {},
        // The server has no binding for us: asked for one.
        status_no_binding => return begin(stack, client, .requesting),
        else => return if (client.state == .requesting) begin(stack, client, .soliciting),
    }
    var count: u32 = 0;
    var shortest_preferred_s: u32 = 0xFFFF_FFFF;
    var ends: u64 = now;
    for (0..lease.count) |index| {
        const address = lease.addresses[index];
        const entry = _ip6.addressOf(interface, address);
        if (lease.valid_s[index] == 0) {
            if (entry) |held| if (held.dhcp6 != 0) _ip6.removeAddress(stack, held);
            continue;
        }
        const made = entry orelse blk: {
            const added = _ip6.addAddress(stack, interface, address, 128, .tentative) orelse continue;
            added.dhcp6 = 1;
            break :blk added;
        };
        // An address of the interface's own making is left as it is.
        if (made.dhcp6 == 0) continue;
        made.preferred_until = if (lease.preferred_s[index] == 0) now else router.until(now, lease.preferred_s[index]);
        made.valid_until = router.until(now, lease.valid_s[index]);
        if (made.state == .deprecated and lease.preferred_s[index] != 0) made.state = .preferred;
        slaac.schedule(stack, made, now);
        client.addresses[count] = address;
        count += 1;
        shortest_preferred_s = @min(shortest_preferred_s, lease.preferred_s[index]);
        if (made.valid_until == 0 or ends == 0) ends = 0 else ends = @max(ends, made.valid_until);
    }
    if (count == 0) return begin(stack, client, .soliciting);
    client.address_count = count;
    client.ends_at = ends;
    // T1 and T2 left to the client: half and four fifths of the shortest
    // preferred lifetime.
    var t1_s = lease.t1_s;
    var t2_s = lease.t2_s;
    if (t1_s == 0 or t2_s == 0 or t1_s > t2_s) {
        t1_s = if (shortest_preferred_s == 0xFFFF_FFFF) 0xFFFF_FFFF else shortest_preferred_s / 2;
        t2_s = if (shortest_preferred_s == 0xFFFF_FFFF) 0xFFFF_FFFF else shortest_preferred_s / 5 * 4;
    }
    t1_s = @max(t1_s, t1_min_s);
    t2_s = @max(t2_s, t1_s);
    client.t1_at = router.until(now, t1_s);
    client.t2_at = router.until(now, t2_s);
    keepSettings(interface, found, client.ends_at, now);
    client.state = .bound;
    client.tries = 0;
    if (client.t1_at == 0) return _timer.cancel(stack, &client.timer);
    _ = _timer.set(stack, &client.timer, client.t1_at);
}

/// A REPLY to INFORMATION-REQUEST: the name servers and the search
/// domain, and the time to ask again.
fn takeInformation(stack: *StackBase, client: *Client, found: Found, now: u64) void {
    if (found.status != status_success) return;
    const refresh_s = @max(found.refresh_s orelse refresh_default_s, refresh_min_s);
    const refresh_at = router.until(now, refresh_s);
    // Kept past the refresh, so a slow answer then leaves no gap.
    const held_until = if (refresh_at == 0) 0 else refresh_at + @as(u64, refresh_s) * second_us;
    keepSettings(client.interface.?, found, held_until, now);
    client.state = .informed;
    client.tries = 0;
    if (refresh_at == 0) return _timer.cancel(stack, &client.timer);
    _ = _timer.set(stack, &client.timer, refresh_at);
}

/// The name servers and the search domain of `found`, kept beside the
/// routers' until `held_until` (0 for ever).
fn keepSettings(interface: *Interface, found: Found, held_until: u64, now: u64) void {
    const routers = &interface.ip6.routers;
    if (found.servers) |servers| {
        var at: usize = 0;
        while (at + 16 <= servers.len) : (at += 16) {
            const server: Address = .{ .bytes = servers[at..][0..16].* };
            if (server.isUnspecified() or server.isMulticast()) continue;
            router.keepServer(routers, server, held_until, false, now);
        }
    }
    if (found.domains) |domains| router.keepDomain(routers, domains, held_until);
}

/// Every address the client was given taken off its interface.
fn forget(stack: *StackBase, client: *Client) void {
    const interface = client.interface.?;
    for (&interface.ip6.addresses) |*entry| {
        if (entry.state != .unused and entry.dhcp6 != 0) _ip6.removeAddress(stack, entry);
    }
    client.address_count = 0;
}

/// `entry`, an address the client was given, turned out to be another
/// station's: DECLINEd, and the client starts again. Its group is left
/// already; the entry is the caller's to let go.
pub fn duplicate(stack: *StackBase, entry: *_ip6.InterfaceAddress) void {
    const interface = entry.interface.?;
    const client = &interface.ip6.dhcp6;
    if (client.interface == null or client.server_id_length == 0) return;
    client.xid = _nd.random(stack) & 0xFF_FFFF;
    client.exchange_start = _timer.clock(stack);
    send(stack, client, decline, entry.address);
    begin(stack, client, .soliciting);
}

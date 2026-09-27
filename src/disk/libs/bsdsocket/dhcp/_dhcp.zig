// SPDX-License-Identifier: MIT
//! The DHCP client (RFC 2131, options after RFC 2132), and a link-local
//! address while it gets no answer (RFC 3927). One client per interface
//! whose file says `Configure = DHCP`, on the stack task's timers.
//!
//! **Getting an address.** DISCOVER goes to everyone from 0.0.0.0, with
//! the broadcast flag set so the answers come back to everyone too - the
//! interface has no address to be answered at. The first OFFER is taken:
//! REQUEST names its server and address, and an ACK gives the lease. The
//! address is checked with two ARP probes before it is used (RFC 5227);
//! an answer means someone has it already, and the client DECLINEs it and
//! starts again. Otherwise the interface takes the address, its netmask,
//! the router as its default route, and the name servers and domain.
//!
//! **Keeping it.** At T1 (half the lease) the client asks its server
//! again, straight; at T2 (seven eighths) it asks everyone; when the
//! lease runs out the address goes and it starts from the beginning. A
//! NAK, at any point, starts it again too. Removing the interface gives
//! the lease back (RELEASE).
//!
//! **No server.** Messages are sent again after 4, 8, 16, 32 and then 64
//! seconds, give or take one. After the third DISCOVER with no OFFER, a
//! 169.254.x.y address - picked from the Ethernet address, the next on
//! each conflict - is probed three times, a second apart, and taken if
//! nobody answers; DHCP goes on behind it, and replaces it when a server
//! is found.
//!
//! **Every length is checked**: the fixed header inside the datagram, the
//! magic cookie, and each option inside the options; an option cut short
//! ends the walk.

const sdk = @import("sdk");
const builtin = @import("builtin");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _route = @import("../route/_route.zig");
const _ip = @import("../ip/_ip.zig");
const _arp = @import("../arp/_arp.zig");
const _timer = @import("../timer/_timer.zig");
const Timer = _timer.Timer;
const _names = @import("../names/_names.zig");
const configure = @import("../netif/configureinterfacetaglist.zig");

pub const client_port: u16 = 68;
pub const server_port: u16 = 67;

const op_request: u8 = 1;
const op_reply: u8 = 2;
const magic: u32 = 0x6382_5363;
/// The fixed part: op to file, then the magic cookie.
const fixed_bytes = 236;
const options_at = fixed_bytes + 4;
/// A BOOTP message is 300 bytes at least; the rest is padding.
const message_min = 300;

// Message types (option 53).
const discover: u8 = 1;
const offer: u8 = 2;
const request: u8 = 3;
const decline: u8 = 4;
const ack: u8 = 5;
const nak: u8 = 6;
const release: u8 = 7;

// Options.
const option_pad: u8 = 0;
const option_netmask: u8 = 1;
const option_router: u8 = 3;
const option_dns: u8 = 6;
const option_domain: u8 = 15;
const option_ntp: u8 = 42;
const option_requested: u8 = 50;
const option_lease: u8 = 51;
const option_type: u8 = 53;
const option_server: u8 = 54;
const option_parameters: u8 = 55;
const option_client_id: u8 = 61;
const option_end: u8 = 255;

const retry_first_us: u64 = 4_000_000;
const retry_most_us: u64 = 64_000_000;
/// DISCOVERs without an OFFER before a link-local address is taken.
const discovers_before_link_local = 3;
const probe_us: u64 = 1_000_000;
const probes = 2;
const link_local_probes = 3;
/// The shortest a renewal is retried after.
const renew_retry_min_us: u64 = 60_000_000;

pub const State = enum(u8) { idle, selecting, requesting, checking, bound, renewing, rebinding };

pub const Client = extern struct {
    timer: Timer = .{},
    state: State = .idle,
    /// Messages sent in the state it is in, and DISCOVERs without an
    /// OFFER in a row.
    tries: u8 = 0,
    discovers: u8 = 0,
    /// A link-local address being probed, and the probes sent.
    link_local_probing: u8 = 0,
    link_local_probes_sent: u8 = 0,
    conflicts: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    xid: u32 = 0,
    /// The server and the address it offers or leased; the lease, from
    /// when.
    server: u32 = 0,
    offered: u32 = 0,
    netmask: u32 = 0,
    router: u32 = 0,
    lease_us: u64 align(4) = 0,
    lease_start: u64 align(4) = 0,
    /// The link-local address being probed or held.
    link_local: u32 = 0,
    /// The time servers the last ACK named (option 42).
    time_servers: [2]u32 = .{ 0, 0 },
};

pub const Clients = extern struct {
    clients: [_base.interfaces_max]Client = @splat(.{}),
    /// For the transaction ids and jitter on the host, where there is no
    /// generator.
    random_state: u32 = 0x2545_F491,
    requests_sent: u32 = 0,
    bad: u32 = 0,
};

fn clientOf(stack: *StackBase, interface: *Interface) *Client {
    const index = (@intFromPtr(interface) - @intFromPtr(&stack.interfaces[0])) / @sizeOf(Interface);
    return &stack.dhcp.clients[index];
}

/// The time servers DHCP named for `interface`, or zeros.
pub fn timeServers(stack: *StackBase, interface: *Interface) [2]u32 {
    if (interface.dhcp == 0) return .{ 0, 0 };
    return clientOf(stack, interface).time_servers;
}

fn interfaceOf(stack: *StackBase, client: *Client) *Interface {
    const index = (@intFromPtr(client) - @intFromPtr(&stack.dhcp.clients[0])) / @sizeOf(Client);
    return &stack.interfaces[index];
}

fn random(stack: *StackBase) u32 {
    if (builtin.cpu.arch == .xtensa) return sdk.hardware.rng.read();
    const state = &stack.dhcp.random_state;
    state.* ^= state.* << 13;
    state.* ^= state.* >> 17;
    state.* ^= state.* << 5;
    return state.*;
}

/// Every client's timer knows what to do, once, when the stack starts.
pub fn init(stack: *StackBase) void {
    for (&stack.dhcp.clients) |*client| {
        client.* = .{};
        client.timer.fire = &expired;
    }
}

/// DHCP started on an interface that has just come up.
pub fn start(stack: *StackBase, interface: *Interface) void {
    const client = clientOf(stack, interface);
    const fire = client.timer.fire;
    client.* = .{};
    client.timer.fire = fire;
    begin(stack, client, _timer.clock(stack));
}

/// From the beginning: DISCOVER.
fn begin(stack: *StackBase, client: *Client, now: u64) void {
    client.state = .selecting;
    client.tries = 0;
    client.xid = random(stack);
    send(stack, client, discover);
    client.discovers += 1;
    later(stack, client, now);
}

/// The next retry: 4 s doubling to 64 s, a second either way.
fn later(stack: *StackBase, client: *Client, now: u64) void {
    const shift: u6 = @intCast(@min(client.tries, 4));
    const wait = @min(retry_first_us << shift, retry_most_us);
    const jitter = @as(u64, random(stack) % 2_000_000);
    client.tries +|= 1;
    _ = _timer.set(stack, &client.timer, now + wait - 1_000_000 + jitter);
}

/// The interface's link back after it was off: a lease there is renewed
/// with its server at once, and without one DHCP starts again.
pub fn linkUp(stack: *StackBase, interface: *Interface) void {
    if (interface.dhcp == 0) return;
    const client = clientOf(stack, interface);
    const now = _timer.clock(stack);
    switch (client.state) {
        .bound, .renewing, .rebinding => {
            client.state = .renewing;
            client.tries = 0;
            send(stack, client, request);
            renewLater(stack, client, now, client.lease_start + client.lease_us * 7 / 8);
        },
        .idle => {},
        else => begin(stack, client, now),
    }
}

/// The interface going: the lease given back, the client stopped. Under
/// the lock, before the device is closed.
pub fn stop(stack: *StackBase, interface: *Interface) void {
    if (interface.dhcp == 0) return;
    const client = clientOf(stack, interface);
    _timer.cancel(stack, &client.timer);
    if (client.state == .bound or client.state == .renewing or client.state == .rebinding) send(stack, client, release);
    client.state = .idle;
}

// --- messages out ----------------------------------------------------------------------

fn send(stack: *StackBase, client: *Client, kind: u8) void {
    const interface = interfaceOf(stack, client);
    const frame = stack.frames.take(stack.sys_base) orelse return;
    const message = frame.room()[frame.start..][0..message_min];
    @memset(message, 0);
    message[0] = op_request;
    message[1] = 1; // Ethernet
    message[2] = 6;
    _ip.put32(message, 4, client.xid);
    // Everyone answers everyone until the address is ours.
    const own = kind == request and (client.state == .renewing or client.state == .rebinding) or kind == release;
    if (!own) _ip.put16(message, 10, 0x8000);
    if (own) _ip.put32(message, 12, interface.address);
    message[28..34].* = interface.hardware;
    _ip.put32(message, fixed_bytes, magic);
    var at: usize = options_at;
    const put = struct {
        fn option(into: []u8, index: *usize, code: u8, value: []const u8) void {
            into[index.*] = code;
            into[index.* + 1] = @intCast(value.len);
            @memcpy(into[index.* + 2 ..][0..value.len], value);
            index.* += 2 + value.len;
        }
    }.option;
    put(message, &at, option_type, &.{kind});
    var id: [7]u8 = undefined;
    id[0] = 1;
    id[1..7].* = interface.hardware;
    put(message, &at, option_client_id, &id);
    var address: [4]u8 = undefined;
    if (kind == request and client.state == .requesting or kind == decline) {
        _ip.put32(&address, 0, client.offered);
        put(message, &at, option_requested, &address);
    }
    if (kind == request and client.state == .requesting or kind == decline or kind == release) {
        _ip.put32(&address, 0, client.server);
        put(message, &at, option_server, &address);
    }
    if (kind == discover or kind == request) {
        put(message, &at, option_parameters, &.{ option_netmask, option_router, option_dns, option_domain, option_lease, option_ntp });
    }
    message[at] = option_end;
    frame.length = message_min;

    // UDP from 68 to 67.
    const unicast = kind == release or (kind == request and client.state == .renewing);
    const source: u32 = if (own) interface.address else 0;
    const destination: u32 = if (unicast) client.server else bsd.INADDR_BROADCAST;
    const udp = frame.push(8);
    _ip.put16(udp, 0, client_port);
    _ip.put16(udp, 2, server_port);
    _ip.put16(udp, 4, @intCast(frame.length));
    _ip.put16(udp, 6, 0);
    var checksum = _ip.finish(_ip.sum(_ip.pseudoSum(source, destination, @intCast(bsd.IPPROTO_UDP), frame.length), frame.bytes()));
    if (checksum == 0) checksum = 0xFFFF;
    _ip.put16(udp, 6, checksum);
    // A RELEASE goes to every station on the link, though to the server
    // alone in IP: the interface is about to go, and must not wait for
    // ARP to find the server first.
    const hop: _route.Hop = if (kind == release)
        .{ .interface = interface, .next_hop = bsd.INADDR_BROADCAST }
    else if (unicast)
        (_route.lookup(stack, destination) orelse .{ .interface = interface, .next_hop = destination })
    else
        .{ .interface = interface, .next_hop = destination };
    stack.dhcp.requests_sent += 1;
    _ = _ip.output(stack, frame, source, destination, @intCast(bsd.IPPROTO_UDP), hop);
}

// --- messages in ----------------------------------------------------------------------

/// What a server's message says.
const Reply = struct {
    kind: u8 = 0,
    yiaddr: u32 = 0,
    server: u32 = 0,
    netmask: u32 = 0,
    router: u32 = 0,
    lease: u32 = 0,
    dns: [bsd.NAMESERVERS_MAX]u32 = @splat(0),
    dns_count: usize = 0,
    domain: []const u8 = &.{},
    time_servers: [2]u32 = .{ 0, 0 },
};

/// A datagram to port 68 on `interface`, the frame starting at its data.
/// True when it was taken as DHCP's; the frame is the caller's either
/// way.
pub fn input(stack: *StackBase, interface: *Interface, data: []const u8) bool {
    if (interface.dhcp == 0) return false;
    const client = clientOf(stack, interface);
    if (client.state == .idle) return true;
    const reply = parse(data, client.xid, &interface.hardware) orelse {
        stack.dhcp.bad += 1;
        return true;
    };
    const now = _timer.clock(stack);
    switch (reply.kind) {
        offer => if (client.state == .selecting) {
            client.state = .requesting;
            client.server = reply.server;
            client.offered = reply.yiaddr;
            client.tries = 0;
            client.discovers = 0;
            send(stack, client, request);
            later(stack, client, now);
        },
        ack => switch (client.state) {
            .requesting => {
                take(client, &reply, now);
                client.state = .checking;
                client.tries = 0;
                _arp.probe(stack, interface, client.offered);
                _ = _timer.set(stack, &client.timer, now + probe_us);
            },
            .renewing, .rebinding => {
                take(client, &reply, now);
                bind(stack, client, now);
            },
            else => {},
        },
        nak => switch (client.state) {
            .requesting, .renewing, .rebinding, .bound => {
                unbind(stack, client);
                begin(stack, client, now);
            },
            else => {},
        },
        else => {},
    }
    // The name servers and the domain, from the ACK.
    if (reply.kind == ack) {
        for (reply.dns[0..reply.dns_count]) |server| _ = _names.addServer(stack, @import("../ip6/address.zig").Address.fromV4(server));
        if (reply.domain.len > 0) {
            const length = @min(reply.domain.len, stack.domain.len - 1);
            @memcpy(stack.domain[0..length], reply.domain[0..length]);
            stack.domain[length] = 0;
        }
    }
    return true;
}

fn take(client: *Client, reply: *const Reply, now: u64) void {
    client.offered = reply.yiaddr;
    if (reply.server != 0) client.server = reply.server;
    client.netmask = if (reply.netmask != 0) reply.netmask else 0xFFFF_FF00;
    client.router = reply.router;
    client.lease_us = @as(u64, if (reply.lease == 0) 3600 else reply.lease) * 1_000_000;
    client.lease_start = now;
    client.time_servers = reply.time_servers;
}

/// A server's reply to us, or null when it is none: too short, not a
/// reply, another transaction, another client, no cookie, no type, an
/// option running past the end.
fn parse(data: []const u8, xid: u32, hardware: *const [6]u8) ?Reply {
    if (data.len < options_at or data[0] != op_reply) return null;
    if (_ip.get32(data, 4) != xid) return null;
    for (data[28..34], hardware) |got, want| {
        if (got != want) return null;
    }
    if (_ip.get32(data, fixed_bytes) != magic) return null;
    var reply: Reply = .{ .yiaddr = _ip.get32(data, 16) };
    var at: usize = options_at;
    while (at < data.len) {
        const code = data[at];
        if (code == option_end) break;
        if (code == option_pad) {
            at += 1;
            continue;
        }
        if (at + 1 >= data.len) return null;
        const length = data[at + 1];
        if (at + 2 + length > data.len) return null;
        const value = data[at + 2 ..][0..length];
        switch (code) {
            option_type => if (length == 1) {
                reply.kind = value[0];
            },
            option_server => if (length == 4) {
                reply.server = _ip.get32(value, 0);
            },
            option_netmask => if (length == 4) {
                reply.netmask = _ip.get32(value, 0);
            },
            option_router => if (length >= 4) {
                reply.router = _ip.get32(value, 0);
            },
            option_lease => if (length == 4) {
                reply.lease = _ip.get32(value, 0);
            },
            option_dns => {
                var index: usize = 0;
                while (index + 4 <= length and reply.dns_count < reply.dns.len) : (index += 4) {
                    reply.dns[reply.dns_count] = _ip.get32(value, index);
                    reply.dns_count += 1;
                }
            },
            option_domain => reply.domain = value,
            option_ntp => {
                var index: usize = 0;
                while (index + 4 <= length and index / 4 < reply.time_servers.len) : (index += 4) {
                    reply.time_servers[index / 4] = _ip.get32(value, index);
                }
            },
            else => {},
        }
        at += 2 + length;
    }
    if (reply.kind == 0) return null;
    if ((reply.kind == offer or reply.kind == ack) and (reply.yiaddr == 0 or reply.yiaddr == bsd.INADDR_BROADCAST)) return null;
    return reply;
}

// --- bound and unbound --------------------------------------------------------------

/// The leased address the interface's: its net, its router, and T1 set.
fn bind(stack: *StackBase, client: *Client, now: u64) void {
    const interface = interfaceOf(stack, client);
    client.state = .bound;
    client.tries = 0;
    client.link_local_probing = 0;
    interface.link_local = 0;
    configure.setAddress(stack, interface, client.offered, client.netmask);
    if (client.router != 0) _ = _route.setDefault(stack, client.router);
    interface.bound = 1;
    _ = _timer.set(stack, &client.timer, client.lease_start + client.lease_us / 2);
    _ = now;
}

/// The address given up: no lease any more.
fn unbind(stack: *StackBase, client: *Client) void {
    const interface = interfaceOf(stack, client);
    if (interface.bound == 0) return;
    interface.bound = 0;
    if (client.router != 0 and _route.defaultThrough(stack, interface) == client.router) _ = _route.remove(stack, 0, 0);
    configure.setAddress(stack, interface, 0, 0);
}

/// The client's deadline: a retry, the end of a probe, T1, T2, the
/// lease's end.
fn expired(stack: *StackBase, fired: *Timer, now: u64) void {
    const client: *Client = @fieldParentPtr("timer", fired);
    const interface = interfaceOf(stack, client);
    if (client.link_local_probing != 0 and client.state == .selecting and client.link_local_probes_sent > 0) {
        return linkLocalStep(stack, client, now);
    }
    switch (client.state) {
        .idle => {},
        .selecting => {
            if (client.discovers >= discovers_before_link_local and interface.link_local == 0 and client.link_local_probing == 0) {
                linkLocalStart(stack, client, now);
            }
            client.xid = random(stack);
            send(stack, client, discover);
            client.discovers +|= 1;
            if (client.link_local_probing == 0) later(stack, client, now);
        },
        .requesting => {
            if (client.tries >= 4) return begin(stack, client, now);
            send(stack, client, request);
            later(stack, client, now);
        },
        .checking => {
            client.tries += 1;
            if (client.tries < probes) {
                _arp.probe(stack, interface, client.offered);
                _ = _timer.set(stack, &client.timer, now + probe_us);
                return;
            }
            bind(stack, client, now);
        },
        .bound => {
            client.state = .renewing;
            send(stack, client, request);
            renewLater(stack, client, now, client.lease_start + client.lease_us * 7 / 8);
        },
        .renewing => {
            const t2 = client.lease_start + client.lease_us * 7 / 8;
            if (now >= t2) {
                client.state = .rebinding;
                send(stack, client, request);
                renewLater(stack, client, now, client.lease_start + client.lease_us);
                return;
            }
            send(stack, client, request);
            renewLater(stack, client, now, t2);
        },
        .rebinding => {
            if (now >= client.lease_start + client.lease_us) {
                unbind(stack, client);
                return begin(stack, client, now);
            }
            send(stack, client, request);
            renewLater(stack, client, now, client.lease_start + client.lease_us);
        },
    }
}

/// The next try at renewing: half the time to `until`, a minute at the
/// least, `until` at the most.
fn renewLater(stack: *StackBase, client: *Client, now: u64, until: u64) void {
    const half = if (until > now) (until - now) / 2 else 0;
    const next = @min(now + @max(half, renew_retry_min_us), until);
    _ = _timer.set(stack, &client.timer, @max(next, now + 1));
}

// --- conflicts ---------------------------------------------------------------------

/// An ARP packet came in on `interface`: if it shows someone else has the
/// address being checked, or wants the link-local one being probed, the
/// address is not ours to take.
pub fn arpSeen(stack: *StackBase, interface: *Interface, sender_address: u32, sender_hardware: *const [6]u8, target_address: u32) void {
    if (interface.dhcp == 0) return;
    const client = clientOf(stack, interface);
    var own = true;
    for (sender_hardware, interface.hardware) |got, mine| {
        if (got != mine) own = false;
    }
    if (own) return;
    const now = _timer.clock(stack);
    if (client.state == .checking and (sender_address == client.offered or (sender_address == 0 and target_address == client.offered))) {
        stack.dhcp.bad += 1;
        send(stack, client, decline);
        begin(stack, client, now);
        return;
    }
    if (client.link_local != 0 and (sender_address == client.link_local or (sender_address == 0 and target_address == client.link_local))) {
        client.conflicts +|= 1;
        if (interface.link_local != 0) {
            interface.link_local = 0;
            configure.setAddress(stack, interface, 0, 0);
        }
        linkLocalStart(stack, client, now);
    }
}

// --- link-local ----------------------------------------------------------------------

/// A link-local address picked - from the Ethernet address, the next one
/// after each conflict - and its probing begun.
fn linkLocalStart(stack: *StackBase, client: *Client, now: u64) void {
    const interface = interfaceOf(stack, client);
    const hardware = interface.hardware;
    const seed: u32 = (@as(u32, hardware[2]) << 24 | @as(u32, hardware[3]) << 16 | @as(u32, hardware[4]) << 8 | hardware[5]) +% @as(u32, client.conflicts) *% 2654435761;
    // 169.254.1.0 to 169.254.254.255.
    const host = 0x100 + seed % (254 * 256);
    client.link_local = 0xA9FE_0000 | host;
    client.link_local_probing = 1;
    client.link_local_probes_sent = 1;
    _arp.probe(stack, interface, client.link_local);
    _ = _timer.set(stack, &client.timer, now + probe_us);
}

fn linkLocalStep(stack: *StackBase, client: *Client, now: u64) void {
    const interface = interfaceOf(stack, client);
    if (client.link_local_probes_sent < link_local_probes) {
        client.link_local_probes_sent += 1;
        _arp.probe(stack, interface, client.link_local);
        _ = _timer.set(stack, &client.timer, now + probe_us);
        return;
    }
    // Nobody has it: it is ours until DHCP finds a server.
    client.link_local_probing = 0;
    client.link_local_probes_sent = 0;
    interface.link_local = 1;
    configure.setAddress(stack, interface, client.link_local, 0xFFFF_0000);
    later(stack, client, now);
}

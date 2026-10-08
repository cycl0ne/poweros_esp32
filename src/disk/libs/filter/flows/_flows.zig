// SPDX-License-Identifier: MIT
//! The exchanges this machine began: a UDP datagram it sent, an echo it
//! sent. Each is noted as it goes out, and an answer to it - from the
//! other end's address and port to ours, or an echo's answer with its
//! identifier - passes without a rule. TCP needs none of this: the stack
//! tells the hook a connection's segments.
//!
//! A fixed table in the library's base: a slot per exchange, the one
//! quiet longest given to a new one when all are taken. An exchange lives
//! `udp_life_us` after its last packet, an echo `echo_life_us`; the time
//! is read as a packet comes, so no timer runs.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const filter = sdk.filter;

pub const slots = 256;
pub const udp_life_us: u64 = 60 * 1_000_000;
pub const echo_life_us: u64 = 10 * 1_000_000;

const udp: u8 = @intCast(bsd.IPPROTO_UDP);
const icmp: u8 = @intCast(bsd.IPPROTO_ICMP);
const icmp6: u8 = @intCast(bsd.IPPROTO_ICMPV6);

pub const Flow = extern struct {
    used: u8 = 0,
    protocol: u8 = 0,
    /// An echo's identifier as `local_port`, and 0 as `remote_port`.
    local_port: u16 = 0,
    remote_port: u16 = 0,
    pad: [2]u8 = .{ 0, 0 },
    local: [16]u8 = @splat(0),
    remote: [16]u8 = @splat(0),
    /// When its last packet went or came, in microseconds.
    last: u64 align(4) = 0,
};

pub const Table = extern struct {
    flows: [slots]Flow = @splat(.{}),

    /// What `view`, going out, begins or keeps alive: a UDP datagram or
    /// an echo noted; anything else left alone.
    pub fn note(table: *Table, view: *const bsd.PacketView, now: u64) void {
        var key = keyOut(view) orelse return;
        key.last = now;
        if (table.find(&key, now)) |found| {
            found.last = now;
            return;
        }
        // A free slot, or one past its time, or the one quiet longest.
        var oldest: *Flow = &table.flows[0];
        for (&table.flows) |*slot| {
            if (slot.used == 0 or expired(slot, now)) {
                oldest = slot;
                break;
            }
            if (slot.last < oldest.last) oldest = slot;
        }
        oldest.* = key;
    }

    /// Whether `view`, coming in, answers a noted exchange: then it is
    /// kept alive.
    pub fn answers(table: *Table, view: *const bsd.PacketView, now: u64) bool {
        const key = keyIn(view) orelse return false;
        const found = table.find(&key, now) orelse return false;
        found.last = now;
        return true;
    }

    fn find(table: *Table, key: *const Flow, now: u64) ?*Flow {
        for (&table.flows) |*slot| {
            if (slot.used == 0 or slot.protocol != key.protocol) continue;
            if (slot.local_port != key.local_port or slot.remote_port != key.remote_port) continue;
            if (!same(&slot.local, &key.local) or !same(&slot.remote, &key.remote)) continue;
            if (expired(slot, now)) {
                slot.used = 0;
                return null;
            }
            return slot;
        }
        return null;
    }

    /// The exchanges alive at `now`, into `into`: how many there are.
    pub fn list(table: *Table, into: []filter.FilterFlowInfo, now: u64) u32 {
        var count: u32 = 0;
        for (&table.flows) |*slot| {
            if (slot.used == 0 or expired(slot, now)) continue;
            if (count < into.len) {
                into[count] = .{
                    .protocol = slot.protocol,
                    .local = .{ .s6_addr = slot.local },
                    .remote = .{ .s6_addr = slot.remote },
                    .local_port = slot.local_port,
                    .remote_port = slot.remote_port,
                    .idle_ms = @intCast(@min((now -| slot.last) / 1000, 0xFFFF_FFFF)),
                };
            }
            count += 1;
        }
        return count;
    }

    pub fn clear(table: *Table) void {
        for (&table.flows) |*slot| slot.used = 0;
    }
};

fn expired(flow: *const Flow, now: u64) bool {
    const life = if (flow.protocol == udp) udp_life_us else echo_life_us;
    return now -| flow.last > life;
}

/// An echo's identifier, from its ICMP header.
fn echoIdentifier(view: *const bsd.PacketView) ?u16 {
    if (view.length < 8) return null;
    const data = view.data.?;
    return @as(u16, data[4]) << 8 | data[5];
}

/// The exchange a packet going out belongs to, as the table keeps it.
fn keyOut(view: *const bsd.PacketView) ?Flow {
    var key: Flow = .{ .used = 1, .protocol = view.protocol, .local = view.source.s6_addr, .remote = view.destination.s6_addr };
    if (view.protocol == udp) {
        key.local_port = view.source_port;
        key.remote_port = view.destination_port;
        return key;
    }
    const echo: u8 = if (view.protocol == icmp) 8 else if (view.protocol == icmp6) 128 else return null;
    if (view.icmp_type != echo) return null;
    key.local_port = echoIdentifier(view) orelse return null;
    return key;
}

/// The exchange a packet coming in would answer.
fn keyIn(view: *const bsd.PacketView) ?Flow {
    var key: Flow = .{ .used = 1, .protocol = view.protocol, .local = view.destination.s6_addr, .remote = view.source.s6_addr };
    if (view.protocol == udp) {
        key.local_port = view.destination_port;
        key.remote_port = view.source_port;
        return key;
    }
    const reply: u8 = if (view.protocol == icmp) 0 else if (view.protocol == icmp6) 129 else return null;
    if (view.icmp_type != reply) return null;
    key.local_port = echoIdentifier(view) orelse return null;
    return key;
}

fn same(a: *const [16]u8, b: *const [16]u8) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

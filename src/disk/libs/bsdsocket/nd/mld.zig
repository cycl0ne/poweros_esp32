// SPDX-License-Identifier: MIT
//! MLDv2 (RFC 3810), as a host has it: the IPv6 groups an interface is
//! in, joined on its device, and reported to the link's routers - and so
//! to the switches that listen for reports - so that what is sent to them
//! reaches it.
//!
//! **The groups** are all nodes, which every node is in and which is
//! never reported, and the solicited-node group of each of the
//! interface's addresses that is not a duplicate; two addresses ending in
//! the same 24 bits share one. `joinGroup` and `leaveGroup` count them on
//! the device (`netif/device.zig`).
//!
//! **Reports** go to `ff02::16` from the interface's link-local address -
//! or the unspecified address while it has none yet - with a hop limit
//! of 1 and a hop-by-hop header carrying the router alert. A change in
//! the groups is reported twice (the robustness variable), each after a
//! random delay of up to a second: every group the interface is in as
//! CHANGE_TO_EXCLUDE_MODE with no sources, every group it left since as
//! CHANGE_TO_INCLUDE_MODE. A query - general, or for a group the
//! interface is in - is answered after a random delay of up to the query's
//! maximum response time with every group (or that one) as
//! MODE_IS_EXCLUDE. A query is taken only from a link-local address with
//! a hop limit of 1.

const sdk = @import("sdk");
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const device = @import("../netif/device.zig");
const _timer = @import("../timer/_timer.zig");
const Timer = _timer.Timer;
const _ip = @import("../ip/_ip.zig");
const _ip6 = @import("../ip6/_ip6.zig");
const _inet = @import("../inet/_inet.zig");
const _nd = @import("_nd.zig");
const Address = @import("../ip6/address.zig").Address;

pub const query: u8 = 130;
pub const report_v1: u8 = 131;
pub const done_v1: u8 = 132;
pub const report: u8 = 143;

/// A report's record types.
pub const mode_is_exclude: u8 = 2;
pub const to_include: u8 = 3;
pub const to_exclude: u8 = 4;

/// `ff02::16`, every MLDv2 router on the link.
pub const all_routers: Address = .{ .bytes = .{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x16 } };

pub const robustness = 2;
pub const unsolicited_us: u32 = 1_000_000;
/// Groups left and not reported yet.
pub const leaving_max = 4;

/// An interface's MLD: when it next reports, and what.
pub const Mld = extern struct {
    timer: Timer = .{},
    /// Reports of a change still to send, and whether a query waits for
    /// its answer, and for which group (`::` for all).
    changes_left: u8 = 0,
    answer: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    asked: Address = .{},
    leaving: [leaving_max]Address = @splat(.{}),
    leaving_count: u32 = 0,
    interface: ?*Interface = null,
};

fn deviceOf(interface: *Interface) ?*device.Device {
    if (interface.loopback != 0) return null;
    return @ptrCast(@alignCast(interface.device orelse return null));
}

/// MLD started on `interface`: all nodes joined on its device.
pub fn start(stack: *StackBase, interface: *Interface) void {
    const state = &interface.ip6.mld;
    state.* = .{ .interface = interface };
    state.timer.fire = &fire;
    if (deviceOf(interface)) |link| device.join(stack, link, _netif.groupStation(Address.all_nodes));
}

/// MLD stopped, when the interface goes.
pub fn stop(stack: *StackBase, interface: *Interface) void {
    _timer.cancel(stack, &interface.ip6.mld.timer);
}

/// Whether `interface` is in `group`, as its addresses make it.
fn inGroup(interface: *Interface, group: Address) bool {
    for (&interface.ip6.addresses) |*entry| {
        if (entry.state == .unused or entry.state == .duplicate) continue;
        if (entry.address.solicitedNode().eql(group)) return true;
    }
    return false;
}

/// One more address of `interface` in `group`.
pub fn joinGroup(stack: *StackBase, interface: *Interface, group: Address) void {
    if (interface.loopback != 0) return;
    if (deviceOf(interface)) |link| device.join(stack, link, _netif.groupStation(group));
    const state = &interface.ip6.mld;
    var at: u32 = 0;
    while (at < state.leaving_count) {
        if (state.leaving[at].eql(group)) {
            state.leaving_count -= 1;
            state.leaving[at] = state.leaving[state.leaving_count];
        } else at += 1;
    }
    changed(stack, interface);
}

/// One address of `interface` fewer in `group`; called before the
/// address itself is let go.
pub fn leaveGroup(stack: *StackBase, interface: *Interface, group: Address) void {
    if (interface.loopback != 0) return;
    if (deviceOf(interface)) |link| device.leave(stack, link, _netif.groupStation(group));
    const state = &interface.ip6.mld;
    // Still in it through another address: nothing to report.
    var others: u32 = 0;
    for (&interface.ip6.addresses) |*entry| {
        if (entry.state == .unused or entry.state == .duplicate) continue;
        if (entry.address.solicitedNode().eql(group)) others += 1;
    }
    if (others > 1) return;
    if (state.leaving_count < leaving_max) {
        state.leaving[state.leaving_count] = group;
        state.leaving_count += 1;
    }
    changed(stack, interface);
}

fn changed(stack: *StackBase, interface: *Interface) void {
    const state = &interface.ip6.mld;
    state.changes_left = robustness;
    soon(stack, state, unsolicited_us);
}

/// The next report within `most` microseconds, unless it is due sooner.
fn soon(stack: *StackBase, state: *Mld, most: u32) void {
    const at = _timer.clock(stack) + _nd.below(stack, most);
    if (state.timer.armed() and state.timer.deadline <= at) return;
    _ = _timer.set(stack, &state.timer, at);
}

/// A query that came in on `interface`, its checksum checked. The frame
/// stays the caller's.
pub fn input(stack: *StackBase, interface: *Interface, bytes: []const u8, packet: _inet.Packet) void {
    if (bytes.len < 24 or bytes[0] != query) return;
    if (packet.hop_limit != 1 or !packet.source.isLinkLocal()) return;
    const group: Address = .{ .bytes = bytes[8..24].* };
    if (!group.isUnspecified() and !inGroup(interface, group)) return;
    // The maximum response time in milliseconds: MLDv1's as it is,
    // MLDv2's code with its exponent above 32767.
    const code = _ip.get16(bytes, 4);
    const delay_ms: u32 = if (bytes.len < 28 or code < 32768) code else (@as(u32, code & 0x0FFF) | 0x1000) << @intCast(((code >> 12) & 7) + 3);
    const state = &interface.ip6.mld;
    if (state.answer != 0 and !state.asked.eql(group)) state.asked = .{} else state.asked = group;
    state.answer = 1;
    soon(stack, state, @max(delay_ms, 1) * 1000);
}

/// A report's time came.
fn fire(stack: *StackBase, fired: *Timer, now: u64) void {
    _ = now;
    const state: *Mld = @fieldParentPtr("timer", fired);
    const interface = state.interface.?;
    if (state.changes_left > 0) {
        send(stack, interface, to_exclude, null, true);
        state.changes_left -= 1;
        state.answer = 0;
        if (state.changes_left > 0) return soon(stack, state, unsolicited_us);
        state.leaving_count = 0;
        return;
    }
    if (state.answer != 0) {
        state.answer = 0;
        send(stack, interface, mode_is_exclude, if (state.asked.isUnspecified()) null else state.asked, false);
    }
}

/// A report: the interface's groups (or only `only`) as records of
/// `kind`, and with `leaving` the groups it left as CHANGE_TO_INCLUDE.
fn send(stack: *StackBase, interface: *Interface, kind: u8, only: ?Address, leaving: bool) void {
    const frame = stack.frames.take(stack.sys_base) orelse return;
    const bytes = frame.room()[frame.start..];
    var records: u16 = 0;
    var at: u32 = 8;
    // Each group once, however many addresses share it.
    for (&interface.ip6.addresses, 0..) |*entry, index| {
        if (entry.state == .unused or entry.state == .duplicate) continue;
        const group = entry.address.solicitedNode();
        if (only) |wanted| if (!wanted.eql(group)) continue;
        const seen = for (interface.ip6.addresses[0..index]) |*before| {
            if (before.state != .unused and before.state != .duplicate and before.address.solicitedNode().eql(group)) break true;
        } else false;
        if (seen) continue;
        at = record(bytes, at, kind, group);
        records += 1;
    }
    if (leaving) {
        const state = &interface.ip6.mld;
        for (state.leaving[0..state.leaving_count]) |group| {
            at = record(bytes, at, to_include, group);
            records += 1;
        }
    }
    if (records == 0) return stack.frames.give(stack.sys_base, frame);
    bytes[0] = report;
    bytes[1] = 0;
    _ip.put16(bytes, 2, 0);
    _ip.put16(bytes, 4, 0);
    _ip.put16(bytes, 6, records);
    frame.length = at;
    const source = _ip6.linkLocal(interface) orelse Address.any;
    const message = frame.bytes();
    _ip.put16(message, 2, _ip.finish(_ip.sum(_inet.pseudoSum(source, all_routers, _ip6.protocol_icmp6, frame.length), message)));
    // The hop-by-hop header: the router alert (MLD), and padding.
    const options = frame.push(8);
    @memcpy(options, &[8]u8{ _ip6.protocol_icmp6, 0, 5, 2, 0, 0, 1, 0 });
    _ip6.prepend(stack, frame, source, all_routers, _ip6.hop_by_hop, 1);
    stack.counts.mld_reports_sent += 1;
    interface.sent += 1;
    const station = _netif.groupStation(all_routers);
    _ = _netif.transmit(stack, interface, frame, if (interface.no_arp != 0) &@import("../arp/_arp.zig").broadcast else &station, _ip6.ethertype);
}

fn record(bytes: []u8, at: u32, kind: u8, group: Address) u32 {
    bytes[at] = kind;
    bytes[at + 1] = 0;
    _ip.put16(bytes, at + 2, 0);
    bytes[at + 4 ..][0..16].* = group.bytes;
    return at + 20;
}

// SPDX-License-Identifier: MIT
//! IGMPv3 (RFC 3376), as a host has it: the IPv4 groups an interface is
//! in, joined on its device, and reported to the link's routers - and so
//! to the switches that listen for reports - so that what is sent to them
//! reaches it.
//!
//! **The groups** are all hosts (`224.0.0.1`), which every host is in and
//! which is never reported, and the groups sockets joined on the
//! interface (IP_ADD_MEMBERSHIP), each counted by the sockets in it.
//! `joinSocketGroup` and `leaveSocketGroup` count them on the device
//! (`netif/device.zig`) as well, at the group's Ethernet address:
//! `01:00:5e` and the group's low 23 bits.
//!
//! **Reports** go to `224.0.0.22` from the interface's address - `0.0.0.0`
//! while it has none yet - with a time to live of 1 and the router alert
//! option. A change in the groups is reported twice (the robustness
//! variable), each after a random delay of up to a second: every group the
//! interface is in as CHANGE_TO_EXCLUDE_MODE with no sources, every group
//! it left since as CHANGE_TO_INCLUDE_MODE. A query - general, or for a
//! group the interface is in - is answered after a random delay of up to
//! the query's maximum response time with every group (or that one) as
//! MODE_IS_EXCLUDE. A query that also names sources is answered as one
//! for its group: a socket here takes every source.
//!
//! **Older routers** (RFC 3376, 7.2.1): an IGMPv1 query (8 bytes, no
//! response time) or an IGMPv2 one (8 bytes) puts the interface in that
//! version's mode for the Older Version Querier Present Timeout (260
//! seconds, the defaults'), renewed by every such query; IGMPv1's wins
//! while both are there. Then each group is reported on its own, as that
//! version's report sent to the group itself; a group left is told with an
//! IGMPv2 leave to all routers (`224.0.0.2`), and not at all to IGMPv1.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const Frame = @import("../frame/_frame.zig").Frame;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const device = @import("../netif/device.zig");
const _timer = @import("../timer/_timer.zig");
const Timer = _timer.Timer;
const _ip = @import("../ip/_ip.zig");
const _nd = @import("../nd/_nd.zig");

pub const protocol: u8 = @intCast(bsd.IPPROTO_IGMP);

/// The message types.
pub const query: u8 = 0x11;
pub const report_v1: u8 = 0x12;
pub const report_v2: u8 = 0x16;
pub const leave_v2: u8 = 0x17;
pub const report: u8 = 0x22;

/// A report's record types.
pub const mode_is_exclude: u8 = 2;
pub const to_include: u8 = 3;
pub const to_exclude: u8 = 4;

/// Groups with a meaning of their own, in the chip's order: every host,
/// every router (where an IGMPv2 leave goes), and every IGMPv3 router.
pub const all_hosts: u32 = 0xE000_0001;
pub const all_routers: u32 = 0xE000_0002;
pub const all_routers_v3: u32 = 0xE000_0016;

/// How long an older querier is believed to be there after its query:
/// the robustness variable times the query interval, and the query
/// response interval (RFC 3376, 8.12).
pub const older_present_us: u64 = 260_000_000;
/// An IGMPv1 query's maximum response time, which it does not say: ten
/// seconds, in tenths.
const v1_response_tenths: u32 = 100;

pub const robustness = 2;
pub const unsolicited_us: u32 = 1_000_000;

/// The groups sockets can join on one interface.
pub const groups_max = 8;
/// Groups left and not reported yet.
pub const leaving_max = 4;

/// A group sockets joined on an interface, and how many of them.
pub const Joined = extern struct {
    group: u32 = 0,
    users: u32 = 0,
};

/// An interface's IGMP: its groups, when it next reports, and what.
pub const Igmp = extern struct {
    timer: Timer = .{},
    /// Reports of a change still to send, and whether a query waits for
    /// its answer, and for which group (0 for all).
    changes_left: u8 = 0,
    answer: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    asked: u32 = 0,
    groups: [groups_max]Joined = @splat(.{}),
    leaving: [leaving_max]u32 = @splat(0),
    leaving_count: u32 = 0,
    /// Until when an IGMPv1 and an IGMPv2 querier are believed there; 0
    /// for none.
    v1_until: u64 align(4) = 0,
    v2_until: u64 align(4) = 0,
    interface: ?*Interface = null,
};

/// Whether `address` is an IPv4 group: 224.0.0.0/4.
pub fn isGroup(address: u32) bool {
    return address >> 28 == 0xE;
}

/// The Ethernet address an IPv4 group is sent to (RFC 1112, 6.4):
/// `01:00:5e` and the group's low 23 bits.
pub fn groupStation(group: u32) [6]u8 {
    return .{ 0x01, 0x00, 0x5e, @truncate((group >> 16) & 0x7F), @truncate(group >> 8), @truncate(group) };
}

fn deviceOf(interface: *Interface) ?*device.Device {
    if (interface.loopback != 0) return null;
    return @ptrCast(@alignCast(interface.device orelse return null));
}

/// IGMP started on `interface`: all hosts joined on its device. Under the
/// lock.
pub fn start(stack: *StackBase, interface: *Interface) void {
    const state = &interface.igmp;
    state.* = .{ .interface = interface };
    state.timer.fire = &fire;
    if (deviceOf(interface)) |link| device.join(stack, link, groupStation(all_hosts));
}

/// IGMP stopped, when the interface goes: its groups forgotten.
pub fn stop(stack: *StackBase, interface: *Interface) void {
    _timer.cancel(stack, &interface.igmp.timer);
    interface.igmp.groups = @splat(.{});
    interface.igmp.leaving_count = 0;
}

/// The entry of a group sockets joined on `interface`, if they did.
pub fn socketGroup(interface: *Interface, group: u32) ?*Joined {
    for (&interface.igmp.groups) |*joined| {
        if (joined.users != 0 and joined.group == group) return joined;
    }
    return null;
}

/// Whether a packet to the group `group` that came in on `interface` is
/// for this machine: all hosts, or a group a socket joined there.
pub fn isOurs(interface: *Interface, group: u32) bool {
    if (interface.igmp.interface == null) return false;
    return group == all_hosts or socketGroup(interface, group) != null;
}

/// One more socket in `group` on `interface`: the group joined on the
/// device and reported the first time. False when the interface is in as
/// many groups as it can be.
pub fn joinSocketGroup(stack: *StackBase, interface: *Interface, group: u32) bool {
    if (socketGroup(interface, group)) |joined| {
        joined.users += 1;
        return true;
    }
    for (&interface.igmp.groups) |*joined| {
        if (joined.users != 0) continue;
        joined.* = .{ .group = group, .users = 1 };
        if (deviceOf(interface)) |link| device.join(stack, link, groupStation(group));
        const state = &interface.igmp;
        var at: u32 = 0;
        while (at < state.leaving_count) {
            if (state.leaving[at] == group) {
                state.leaving_count -= 1;
                state.leaving[at] = state.leaving[state.leaving_count];
            } else at += 1;
        }
        if (group != all_hosts) changed(stack, interface);
        return true;
    }
    return false;
}

/// One socket fewer in `group` on `interface`: the last one leaves it on
/// the device and says so.
pub fn leaveSocketGroup(stack: *StackBase, interface: *Interface, group: u32) void {
    const joined = socketGroup(interface, group) orelse return;
    joined.users -= 1;
    if (joined.users != 0) return;
    if (deviceOf(interface)) |link| device.leave(stack, link, groupStation(group));
    if (group == all_hosts or interface.igmp.interface == null) return;
    const state = &interface.igmp;
    if (state.leaving_count < leaving_max) {
        state.leaving[state.leaving_count] = group;
        state.leaving_count += 1;
    }
    changed(stack, interface);
}

fn changed(stack: *StackBase, interface: *Interface) void {
    const state = &interface.igmp;
    if (state.interface == null) return;
    state.changes_left = robustness;
    soon(stack, state, unsolicited_us);
}

/// The next report within `most` microseconds, unless it is due sooner.
fn soon(stack: *StackBase, state: *Igmp, most: u32) void {
    const at = _timer.clock(stack) + _nd.below(stack, most);
    if (state.timer.armed() and state.timer.deadline <= at) return;
    _ = _timer.set(stack, &state.timer, at);
}

/// An IGMP message that came in on `interface`, the frame starting at it.
/// Queries are answered; a report or a leave of another host's changes
/// nothing here. The frame is this layer's from here.
pub fn input(stack: *StackBase, interface: *Interface, frame: *Frame) void {
    defer stack.frames.give(stack.sys_base, frame);
    stack.counts.igmp_received += 1;
    const bytes = frame.bytes();
    if (bytes.len < 8 or _ip.finish(_ip.sum(0, bytes)) != 0) {
        stack.counts.igmp_bad += 1;
        return;
    }
    if (bytes[0] != query or interface.igmp.interface == null) return;
    // IGMPv1's and IGMPv2's queries are 8 bytes, IGMPv3's at least 12;
    // anything between is no query.
    if (bytes.len > 8 and bytes.len < 12) return;
    const state = &interface.igmp;
    const now = _timer.clock(stack);
    const code = bytes[1];
    var tenths: u32 = code;
    if (bytes.len == 8 and code == 0) {
        state.v1_until = now + older_present_us;
        tenths = v1_response_tenths;
    } else if (bytes.len == 8) {
        state.v2_until = now + older_present_us;
    } else if (code >= 128) {
        // IGMPv3's code with its exponent: the mantissa with its leading
        // bit, shifted by the exponent and 3.
        tenths = (@as(u32, code & 0x0F) | 0x10) << @intCast(((code >> 4) & 7) + 3);
    }
    const group = _ip.get32(bytes, 4);
    if (group != 0 and (group == all_hosts or socketGroup(interface, group) == null)) return;
    if (state.answer != 0 and state.asked != group) state.asked = 0 else state.asked = group;
    state.answer = 1;
    soon(stack, state, @max(tenths, 1) * 100_000);
}

/// A report's time came.
fn fire(stack: *StackBase, fired: *Timer, now: u64) void {
    _ = now;
    const state: *Igmp = @fieldParentPtr("timer", fired);
    const interface = state.interface.?;
    if (state.changes_left > 0) {
        send(stack, interface, to_exclude, 0, true);
        state.changes_left -= 1;
        state.answer = 0;
        if (state.changes_left > 0) return soon(stack, state, unsolicited_us);
        state.leaving_count = 0;
        return;
    }
    if (state.answer != 0) {
        state.answer = 0;
        send(stack, interface, mode_is_exclude, state.asked, false);
    }
}

/// Whether `group` is one this interface reports: joined, and not all
/// hosts.
fn reported(joined: *const Joined) bool {
    return joined.users != 0 and joined.group != all_hosts;
}

/// A report: the interface's groups (or only `only`, unless it is 0) as
/// records of `kind`, and with `leaving` the groups it left as
/// CHANGE_TO_INCLUDE - or, while an older querier is there, the same as
/// that version's messages.
fn send(stack: *StackBase, interface: *Interface, kind: u8, only: u32, leaving: bool) void {
    const state = &interface.igmp;
    const now = _timer.clock(stack);
    if (state.v1_until > now or state.v2_until > now) return sendOld(stack, interface, state.v1_until > now, only, leaving);
    const frame = stack.frames.take(stack.sys_base) orelse return;
    const bytes = frame.room()[frame.start..];
    var records: u16 = 0;
    var at: u32 = 8;
    for (&state.groups) |*joined| {
        if (!reported(joined) or (only != 0 and joined.group != only)) continue;
        at = record(bytes, at, kind, joined.group);
        records += 1;
    }
    if (leaving) {
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
    _ip.put16(bytes, 2, _ip.finish(_ip.sum(0, frame.bytes())));
    transmit(stack, interface, frame, all_routers_v3);
}

fn record(bytes: []u8, at: u32, kind: u8, group: u32) u32 {
    bytes[at] = kind;
    bytes[at + 1] = 0;
    _ip.put16(bytes, at + 2, 0);
    _ip.put32(bytes, at + 4, group);
    return at + 8;
}

/// Each group (or only `only`) as an IGMPv1 or IGMPv2 report to itself,
/// and with `leaving` - for IGMPv2 - each group left as a leave to all
/// routers.
fn sendOld(stack: *StackBase, interface: *Interface, v1: bool, only: u32, leaving: bool) void {
    const state = &interface.igmp;
    for (&state.groups) |*joined| {
        if (!reported(joined) or (only != 0 and joined.group != only)) continue;
        message(stack, interface, if (v1) report_v1 else report_v2, joined.group, joined.group);
    }
    if (leaving and !v1) {
        for (state.leaving[0..state.leaving_count]) |group| message(stack, interface, leave_v2, group, all_routers);
    }
}

/// One IGMPv1 or IGMPv2 message of `kind` about `group`, to `destination`.
fn message(stack: *StackBase, interface: *Interface, kind: u8, group: u32, destination: u32) void {
    const frame = stack.frames.take(stack.sys_base) orelse return;
    const bytes = frame.room()[frame.start..][0..8];
    frame.length = 8;
    bytes[0] = kind;
    bytes[1] = 0;
    _ip.put16(bytes, 2, 0);
    _ip.put32(bytes, 4, group);
    _ip.put16(bytes, 2, _ip.finish(_ip.sum(0, bytes)));
    transmit(stack, interface, frame, destination);
}

/// `frame`, an IGMP message, out on `interface` to the group
/// `destination`: a time to live of 1 and the router alert.
fn transmit(stack: *StackBase, interface: *Interface, frame: *Frame, destination: u32) void {
    stack.counts.igmp_reports_sent += 1;
    _ = _ip.outputWith(stack, frame, interface.address, destination, protocol, .{ .interface = interface, .next_hop = destination }, .{ .ttl = 1, .router_alert = true });
}

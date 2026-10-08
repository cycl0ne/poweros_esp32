// SPDX-License-Identifier: MIT
//! Packet hooks (AddPacketHook): hooks a program puts in front of the
//! stack, which see every packet coming in and going out and say what
//! becomes of it - a firewall, a logger. Two chains, in and out, each
//! ordered by priority; an empty chain costs a compare.
//!
//! **Coming in**, a transport asks after its checksum and its lookup and
//! before it delivers or answers, so the hook is told what the packet is
//! for (PACKET_BELONGS_*), and a port a hook drops stays silent: TCP's
//! reset for a port nobody listens on comes after the hook. **Going
//! out**, IPv4's and IPv6's output ask before the IP header goes on.
//!
//! **What always passes** and reaches no hook: everything on a loopback
//! interface; IGMP, which no transport asks about; ICMPv4's errors
//! (unreachable, time exceeded, parameter problem) and ICMPv6's (1-4),
//! which path MTU and connections need; Neighbor Discovery and MLD; the
//! messages of this machine's DHCP and DHCPv6 client. A hook cannot cut an
//! interface off.
//!
//! **A hook is called under the stack's lock**, on whichever task holds
//! it - the stack's own for a packet coming in, the sending program's for
//! one going out - so it may not wait, call bsdsocket.library or touch a
//! file. AddPacketHook and RemPacketHook take the lock as well: once
//! RemPacketHook has returned, the hook is not running and will not be
//! called again.
//!
//! **A hook belongs to the base that added it**: when that base is
//! closed, its hooks go with it - unless it was added with PH_Keep, for a
//! library that adds it on one caller's task and takes it out on
//! another's.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const SocketBase = _base.SocketBase;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const Frame = @import("../frame/_frame.zig").Frame;
const Address = @import("../ip6/address.zig").Address;
const _capture = @import("../capture/_capture.zig");

/// A hook in a chain: the program's Hook, the base that added it (none
/// for one kept past it, PH_Keep), and the interface it looks at (an empty
/// name: every one). Its priority is the node's.
pub const PacketHook = struct {
    node: exec.Node = .{},
    hook: *utility.Hook,
    owner: ?*SocketBase,
    interface: [bsd.IFNAMSIZ]u8 = @splat(0),
};

pub const Verdict = enum { pass, drop, refuse };

/// A packet as a transport or an output hands it over to be asked about.
pub const Seen = struct {
    interface: *Interface,
    source: Address,
    destination: Address,
    protocol: u8,
    belongs: u8 = bsd.PACKET_BELONGS_NONE,
    /// The transport's header and what it carries.
    data: []const u8,
    /// Coming in: the frame, and how many bytes of IP header lie in front
    /// of `data` in it - for the capture's copy of a packet stopped.
    frame: ?*Frame = null,
    header_length: u32 = 0,
};

pub fn chain(stack: *StackBase, direction: u32) *exec.List {
    return if (direction == bsd.PH_OUT) &stack.hooks_out else &stack.hooks_in;
}

/// What becomes of a packet: the chain asked in its order, the first
/// answer that is not PACKET_PASS deciding. A packet going out is never
/// refused, only dropped. Under the lock.
pub fn ask(stack: *StackBase, direction: u32, seen: Seen) Verdict {
    const list = chain(stack, direction);
    if (list.isEmpty() or alwaysPasses(seen)) return .pass;
    var view = viewOf(stack, direction, seen);
    var it = list.iterator();
    while (it.next()) |node| {
        const entry: *PacketHook = @fieldParentPtr("node", node);
        if (entry.interface[0] != 0 and !sameName(&entry.interface, &seen.interface.name)) continue;
        const answer = stack.utility.?.CallHookPkt(entry.hook, &view, null);
        const verdict: Verdict = switch (answer) {
            bsd.PACKET_DROP => .drop,
            bsd.PACKET_REFUSE => if (direction == bsd.PH_OUT) .drop else .refuse,
            else => continue,
        };
        stopped(stack, direction, seen, verdict);
        return verdict;
    }
    return .pass;
}

/// A packet a hook stopped: counted, and coming in, copied to the
/// capture sockets marked CAPTURE_FILTERED.
fn stopped(stack: *StackBase, direction: u32, seen: Seen, verdict: Verdict) void {
    if (verdict == .refuse) stack.counts.hook_refused += 1 else stack.counts.hook_dropped += 1;
    if (direction != bsd.PH_IN or stack.captures == 0) return;
    const frame = seen.frame orelse return;
    if (frame.start < seen.header_length) return;
    const packet = frame.room()[frame.start - seen.header_length ..][0 .. seen.header_length + seen.data.len];
    _capture.tap(stack, seen.interface, packet, bsd.CAPTURE_IN, .filtered);
}

/// The packets that never reach a hook (see the file's head).
fn alwaysPasses(seen: Seen) bool {
    if (seen.interface.loopback != 0) return true;
    const data = seen.data;
    switch (seen.protocol) {
        @as(u8, @intCast(bsd.IPPROTO_ICMP)) => {
            if (data.len < 1) return false;
            return data[0] == 3 or data[0] == 11 or data[0] == 12;
        },
        @as(u8, @intCast(bsd.IPPROTO_ICMPV6)) => {
            if (data.len < 1) return false;
            const kind = data[0];
            return (kind >= 1 and kind <= 4) or (kind >= 130 and kind <= 137) or kind == 143;
        },
        @as(u8, @intCast(bsd.IPPROTO_UDP)) => {
            if (data.len < 4) return false;
            const source_port = get16(data, 0);
            const destination_port = get16(data, 2);
            const client: u16 = if (seen.source.isV4()) 68 else 546;
            const server: u16 = if (seen.source.isV4()) 67 else 547;
            return (source_port == client and destination_port == server) or (source_port == server and destination_port == client);
        },
        @as(u8, @intCast(bsd.IPPROTO_TCP)) => return false,
        else => return true,
    }
}

fn viewOf(stack: *StackBase, direction: u32, seen: Seen) bsd.PacketView {
    const data = seen.data;
    var view: bsd.PacketView = .{
        .direction = @intCast(direction),
        .family = if (seen.source.isV4()) bsd.AF_INET else bsd.AF_INET6,
        .protocol = seen.protocol,
        .belongs = if (direction == bsd.PH_IN) seen.belongs else bsd.PACKET_BELONGS_NONE,
        .interface_index = _netif.index(stack, seen.interface),
        .interface = seen.interface.name,
        .source = .{ .s6_addr = seen.source.bytes },
        .destination = .{ .s6_addr = seen.destination.bytes },
        .data = data.ptr,
        .length = @intCast(data.len),
    };
    switch (seen.protocol) {
        @as(u8, @intCast(bsd.IPPROTO_TCP)), @as(u8, @intCast(bsd.IPPROTO_UDP)) => if (data.len >= 4) {
            view.source_port = get16(data, 0);
            view.destination_port = get16(data, 2);
            if (seen.protocol == @as(u8, @intCast(bsd.IPPROTO_TCP)) and data.len >= 14) view.tcp_flags = data[13];
        },
        @as(u8, @intCast(bsd.IPPROTO_ICMP)), @as(u8, @intCast(bsd.IPPROTO_ICMPV6)) => if (data.len >= 2) {
            view.icmp_type = data[0];
            view.icmp_code = data[1];
        },
        else => {},
    }
    return view;
}

/// The chain's entry for `hook`, in either chain.
pub fn find(stack: *StackBase, hook: *utility.Hook) ?*PacketHook {
    for ([_]*exec.List{ &stack.hooks_in, &stack.hooks_out }) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            const entry: *PacketHook = @fieldParentPtr("node", node);
            if (entry.hook == hook) return entry;
        }
    }
    return null;
}

/// Every hook `owner` added, taken out: its base is being closed.
pub fn removeOwned(stack: *StackBase, owner: *SocketBase) void {
    const sys = stack.sys_base;
    for ([_]*exec.List{ &stack.hooks_in, &stack.hooks_out }) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            const entry: *PacketHook = @fieldParentPtr("node", node);
            if (entry.owner != @as(?*SocketBase, owner)) continue;
            sys.Remove(node);
            sys.FreeVec(entry);
        }
    }
}

fn sameName(a: *const [bsd.IFNAMSIZ]u8, b: *const [bsd.IFNAMSIZ]u8) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
        if (x == 0) return true;
    }
    return true;
}

fn get16(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) << 8 | bytes[at + 1];
}

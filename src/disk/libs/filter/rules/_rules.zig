// SPDX-License-Identifier: MIT
//! A rule set as filter.library keeps it: the rules in the file's order,
//! the defaults per interface, each with the line it came from, its text
//! and its count. One block of memory holds the set and both arrays, so a
//! load swaps one pointer and frees one block (`RuleSet.make`).
//!
//! **An address** is IPv6's sixteen bytes, IPv4's mapped (::ffff:a.b.c.d),
//! as bsdsocket.library's PacketView has them; an IPv4 net's prefix
//! counts the 96 bits of the mapping too, so one compare of the first
//! `prefix` bits serves both families.

const sdk = @import("sdk");
const filter = sdk.filter;
const bsd = sdk.bsdsocket;

pub const Action = enum(u8) {
    pass = filter.FILTER_PASS,
    block = filter.FILTER_BLOCK,
    refuse = filter.FILTER_REFUSE,

    /// The answer a packet hook gives for it.
    pub fn verdict(action: Action) u32 {
        return switch (action) {
            .pass => bsd.PACKET_PASS,
            .block => bsd.PACKET_DROP,
            .refuse => bsd.PACKET_REFUSE,
        };
    }
};

/// What `type` asked for: nothing, an echo, an echo's answer, a number.
pub const TypeMatch = enum(u8) { any, echo, echo_reply, number };

/// An end of a packet: a net (an address and how many of its first bits
/// count; 0 bits: any) of a family (0: either), and a range of ports.
pub const End = extern struct {
    bytes: [16]u8 = @splat(0),
    prefix: u8 = 0,
    family: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    low_port: u16 = 0,
    high_port: u16 = 0xFFFF,
};

pub const Rule = extern struct {
    action: Action = .pass,
    /// 0 (either), AF_INET or AF_INET6.
    family: u8 = 0,
    /// 0 (any), IPPROTO_TCP, IPPROTO_UDP, IPPROTO_ICMP or IPPROTO_ICMPV6.
    protocol: u8 = 0,
    /// Only TCP and UDP (a port was given), only ICMP (a type), only a
    /// segment that opens a connection (`flags S`).
    ports: u8 = 0,
    type_match: TypeMatch = .any,
    type_number: u8 = 0,
    syn_only: u8 = 0,
    pad: u8 = 0,
    /// The interface's name; empty for every one.
    interface: [bsd.IFNAMSIZ]u8 = @splat(0),
    from: End = .{},
    to: End = .{},
    line: u32 = 0,
    hits: u32 = 0,
    text: [filter.FILTER_TEXT_MAX]u8 = @splat(0),
};

pub const Default = extern struct {
    action: Action = .pass,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The interface's name; empty for every interface no other default
    /// names.
    interface: [bsd.IFNAMSIZ]u8 = @splat(0),
    line: u32 = 0,
    hits: u32 = 0,
    text: [filter.FILTER_TEXT_MAX]u8 = @splat(0),
};

/// The set, and behind it room for `rule_room` rules and `default_room`
/// defaults: one block.
pub const RuleSet = extern struct {
    rule_count: u32 = 0,
    default_count: u32 = 0,
    rule_room: u32 = 0,
    default_room: u32 = 0,

    /// The bytes a set with room for `rule_room` rules and `default_room`
    /// defaults takes.
    pub fn bytesFor(rule_room: u32, default_room: u32) usize {
        return @sizeOf(RuleSet) + @as(usize, rule_room) * @sizeOf(Rule) + @as(usize, default_room) * @sizeOf(Default);
    }

    /// An empty set made in `memory`, which holds `bytesFor(rule_room,
    /// default_room)` bytes.
    pub fn make(memory: []align(8) u8, rule_room: u32, default_room: u32) *RuleSet {
        const set: *RuleSet = @ptrCast(memory.ptr);
        set.* = .{ .rule_room = rule_room, .default_room = default_room };
        return set;
    }

    pub fn rules(set: *RuleSet) []Rule {
        const at: [*]Rule = @ptrCast(@alignCast(@as([*]u8, @ptrCast(set)) + @sizeOf(RuleSet)));
        return at[0..set.rule_count];
    }

    pub fn defaults(set: *RuleSet) []Default {
        const at: [*]Default = @ptrCast(@alignCast(@as([*]u8, @ptrCast(set)) + @sizeOf(RuleSet) + @as(usize, set.rule_room) * @sizeOf(Rule)));
        return at[0..set.default_count];
    }

    /// Room for one more rule: the new rule, or null when full.
    pub fn addRule(set: *RuleSet) ?*Rule {
        if (set.rule_count == set.rule_room) return null;
        set.rule_count += 1;
        const all = set.rules();
        all[all.len - 1] = .{};
        return &all[all.len - 1];
    }

    pub fn addDefault(set: *RuleSet) ?*Default {
        if (set.default_count == set.default_room) return null;
        set.default_count += 1;
        const all = set.defaults();
        all[all.len - 1] = .{};
        return &all[all.len - 1];
    }
};

/// Whether two NUL-padded interface names are the same.
pub fn sameName(a: *const [bsd.IFNAMSIZ]u8, b: *const [bsd.IFNAMSIZ]u8) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
        if (x == 0) return true;
    }
    return true;
}

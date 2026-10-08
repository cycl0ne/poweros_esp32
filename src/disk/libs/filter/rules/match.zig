// SPDX-License-Identifier: MIT
//! A packet held against a rule set: the first rule that matches, or the
//! default of the packet's interface. What passes before the rules - a
//! connection's segment, an answer to an exchange - is the hook's to say
//! (`hook/_hook.zig`); this is only the rules.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _rules = @import("_rules.zig");
const Rule = _rules.Rule;
const Default = _rules.Default;
const RuleSet = _rules.RuleSet;
const End = _rules.End;

/// The first rule `view` matches, or null.
pub fn firstRule(set: *RuleSet, view: *const bsd.PacketView) ?*Rule {
    for (set.rules()) |*rule| {
        if (matches(rule, view)) return rule;
    }
    return null;
}

/// The default for `view`'s interface: its own, or the one for every
/// interface; null for an interface no default names.
pub fn defaultFor(set: *RuleSet, view: *const bsd.PacketView) ?*Default {
    var every: ?*Default = null;
    for (set.defaults()) |*each| {
        if (each.interface[0] == 0) {
            every = each;
        } else if (_rules.sameName(&each.interface, &view.interface)) {
            return each;
        }
    }
    return every;
}

pub fn matches(rule: *const Rule, view: *const bsd.PacketView) bool {
    if (rule.interface[0] != 0 and !_rules.sameName(&rule.interface, &view.interface)) return false;
    if (rule.family != 0 and rule.family != view.family) return false;
    if (rule.protocol != 0 and rule.protocol != view.protocol) return false;
    const tcp: u8 = @intCast(bsd.IPPROTO_TCP);
    const udp: u8 = @intCast(bsd.IPPROTO_UDP);
    const icmp: u8 = @intCast(bsd.IPPROTO_ICMP);
    const icmp6: u8 = @intCast(bsd.IPPROTO_ICMPV6);
    if (rule.ports != 0 and view.protocol != tcp and view.protocol != udp) return false;
    if (rule.syn_only != 0 and view.tcp_flags & (bsd.TH_SYN | bsd.TH_ACK) != bsd.TH_SYN) return false;
    switch (rule.type_match) {
        .any => {},
        .echo, .echo_reply, .number => {
            if (view.protocol != icmp and view.protocol != icmp6) return false;
            const wanted: u8 = switch (rule.type_match) {
                .echo => if (view.protocol == icmp) 8 else 128,
                .echo_reply => if (view.protocol == icmp) 0 else 129,
                else => rule.type_number,
            };
            if (view.icmp_type != wanted) return false;
        },
    }
    if (!endMatches(&rule.from, &view.source.s6_addr, view.source_port)) return false;
    if (!endMatches(&rule.to, &view.destination.s6_addr, view.destination_port)) return false;
    return true;
}

fn endMatches(end: *const End, bytes: *const [16]u8, port: u16) bool {
    if (port < end.low_port or port > end.high_port) return false;
    var bit: u32 = 0;
    while (bit < end.prefix) {
        const index = bit / 8;
        if (end.prefix - bit >= 8) {
            if (bytes[index] != end.bytes[index]) return false;
            bit += 8;
        } else {
            const mask = ~(@as(u8, 0xFF) >> @intCast(end.prefix - bit));
            if (bytes[index] & mask != end.bytes[index]) return false;
            bit = end.prefix;
        }
    }
    return true;
}

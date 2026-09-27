// SPDX-License-Identifier: MIT
//! The order GetAddrInfo answers a name's addresses in: RFC 6724's
//! destination address selection, as far as a host with a handful of
//! addresses needs it. For each destination the stack looks for a route
//! and the source it would send from, then sorts by these rules, the
//! first that tells two apart deciding:
//!
//! 1. one it can reach before one it cannot;
//! 2. one whose scope its source shares;
//! 5. one whose label (in the policy table) its source shares;
//! 6. higher precedence in the policy table: `::1`, then IPv6 in
//!    general, then IPv4, then the transition prefixes and ULAs;
//! 8. the smaller scope;
//! 9. between IPv6 ones, the longer prefix shared with its source, up to
//!    64 bits;
//! 10. otherwise as they came.
//!
//! Rules 3, 4 and 7 (deprecated, home and native sources) need what this
//! stack does not have or never differs in here, and are left out.

const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _inet = @import("../inet/_inet.zig");
const address_file = @import("../ip6/address.zig");
const Address = address_file.Address;

/// A destination, and what the rules look at.
pub const Candidate = struct {
    address: Address,
    usable: bool = false,
    source: Address = .{},
};

const Policy = struct { prefix: Address, length: u8, precedence: u8, label: u8 };

fn prefix(comptime text: []const u8) Address {
    return comptime address_file.parse(text).?;
}

/// RFC 6724's default policy table, longest prefixes first.
const policies = [_]Policy{
    .{ .prefix = prefix("::1"), .length = 128, .precedence = 50, .label = 0 },
    .{ .prefix = prefix("::ffff:0:0"), .length = 96, .precedence = 35, .label = 4 },
    .{ .prefix = prefix("::"), .length = 96, .precedence = 1, .label = 3 },
    .{ .prefix = prefix("2001::"), .length = 32, .precedence = 5, .label = 5 },
    .{ .prefix = prefix("2002::"), .length = 16, .precedence = 30, .label = 2 },
    .{ .prefix = prefix("3ffe::"), .length = 16, .precedence = 1, .label = 12 },
    .{ .prefix = prefix("fec0::"), .length = 10, .precedence = 1, .label = 11 },
    .{ .prefix = prefix("fc00::"), .length = 7, .precedence = 3, .label = 13 },
    .{ .prefix = prefix("::"), .length = 0, .precedence = 40, .label = 1 },
};

fn policyOf(address: Address) Policy {
    for (policies) |policy| {
        if (address.inPrefix(policy.prefix, policy.length)) return policy;
    }
    unreachable;
}

/// The scope RFC 6724 gives an address: an IPv4 loopback or link-local
/// one is link scope (3.2), as IPv6's.
fn scopeOf(address: Address) u4 {
    if (address.isV4()) {
        const first = address.bytes[12];
        if (first == 127 or (first == 169 and address.bytes[13] == 254)) return 2;
        return 0xE;
    }
    return address.scope();
}

/// Each candidate's route and source looked up. Under the lock.
pub fn prepare(stack: *StackBase, candidates: []Candidate) void {
    for (candidates) |*candidate| {
        const path = _inet.route(stack, candidate.address, null) orelse continue;
        candidate.source = _inet.sourceFor(path, candidate.address) orelse continue;
        candidate.usable = true;
    }
}

/// Whether `a` goes before `b`.
fn before(a: *const Candidate, b: *const Candidate) bool {
    if (a.usable != b.usable) return a.usable;
    if (!a.usable) return false;
    const a_scope = scopeOf(a.address);
    const b_scope = scopeOf(b.address);
    const a_matches = a_scope == scopeOf(a.source);
    const b_matches = b_scope == scopeOf(b.source);
    if (a_matches != b_matches) return a_matches;
    const a_policy = policyOf(a.address);
    const b_policy = policyOf(b.address);
    const a_label = a_policy.label == policyOf(a.source).label;
    const b_label = b_policy.label == policyOf(b.source).label;
    if (a_label != b_label) return a_label;
    if (a_policy.precedence != b_policy.precedence) return a_policy.precedence > b_policy.precedence;
    if (a_scope != b_scope) return a_scope < b_scope;
    if (!a.address.isV4() and !b.address.isV4()) {
        const a_common = @min(a.address.commonBits(a.source), 64);
        const b_common = @min(b.address.commonBits(b.source), 64);
        if (a_common != b_common) return a_common > b_common;
    }
    return false;
}

/// The candidates sorted by the rules, those that tie kept as they came.
pub fn sort(candidates: []Candidate) void {
    var index: usize = 1;
    while (index < candidates.len) : (index += 1) {
        const moving = candidates[index];
        var at = index;
        while (at > 0 and before(&moving, &candidates[at - 1])) : (at -= 1) candidates[at] = candidates[at - 1];
        candidates[at] = moving;
    }
}

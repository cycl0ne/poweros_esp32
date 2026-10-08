// SPDX-License-Identifier: MIT
//! Temporary addresses (RFC 8981), for an interface with privacy
//! addresses on (IFA_PrivacyAddresses): beside the address a router's
//! prefix makes (`slaac.zig`), one more in the same prefix whose last 64
//! bits are random, so that what the machine connects to cannot follow it
//! from one day to the next by its address. Connections going out are
//! made from it (`inet/_inet.zig`, `sourceFor`); what comes in is
//! answered from whichever address it came to.
//!
//! **Lifetimes**: a temporary address is valid for two days and preferred
//! for one less a random part of up to 0.4 of a day (DESYNC_FACTOR, so the
//! machines on a link do not all renew at once), each held to what is left
//! of its prefix's; a router's advertisement of the prefix moves them only
//! within those ends. Five seconds (REGEN_ADVANCE) before it stops being
//! preferred the next one is made, so that there is always one to take;
//! the old one stays valid for the connections it has. None is made when
//! it would be preferred for no longer than that.
//!
//! **Duplicates**: a temporary address another station has is made again
//! with new random bits, up to three times; then the prefix gets no
//! temporary address while the duplicate one is kept.
//!
//! When the interface's addresses are all taken, the deprecated temporary
//! address that ends first makes room for the new one.

const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _ip6 = @import("../ip6/_ip6.zig");
const InterfaceAddress = _ip6.InterfaceAddress;
const _nd = @import("_nd.zig");
const slaac = @import("slaac.zig");
const Address = @import("../ip6/address.zig").Address;

const second_us: u64 = 1_000_000;
/// TEMP_VALID_LIFETIME and TEMP_PREFERRED_LIFETIME, the defaults.
pub const valid_us: u64 = 2 * 24 * 60 * 60 * second_us;
pub const preferred_us: u64 = 24 * 60 * 60 * second_us;
/// MAX_DESYNC_FACTOR: 0.4 of the preferred lifetime, in seconds.
pub const desync_most_s: u32 = 24 * 60 * 60 * 4 / 10;
/// REGEN_ADVANCE: 2 seconds, and the duplicate checks of every try
/// (TEMP_IDGEN_RETRIES, one check a second each).
pub const regenerate_us: u64 = (2 + _nd.idgen_retries) * second_us;

/// The earlier of two ends, either 0 for never.
fn earlier(a: u64, b: u64) u64 {
    if (a == 0) return b;
    if (b == 0) return a;
    return @min(a, b);
}

/// Whether `entry` is a temporary address in `prefix`/64.
fn ofPrefix(entry: *const InterfaceAddress, prefix: Address) bool {
    return entry.state != .unused and entry.temporary != 0 and entry.address.inPrefix(prefix, 64);
}

/// `prefix` with random last 64 bits, neither a reserved identifier nor
/// the one `interface` makes itself.
pub fn randomAddress(stack: *StackBase, interface: *Interface, prefix: *const [8]u8) Address {
    const own = _ip6.addressFor(stack, interface, prefix, 0);
    while (true) {
        var made: Address = .{};
        made.bytes[0..8].* = prefix.*;
        const high = _nd.random(stack);
        const low = _nd.random(stack);
        for (0..4) |at| {
            made.bytes[8 + at] = @truncate(high >> @intCast(24 - 8 * at));
            made.bytes[12 + at] = @truncate(low >> @intCast(24 - 8 * at));
        }
        if (!_ip6.isReservedIdentifier(made.bytes[8..16].*) and !made.eql(own)) return made;
    }
}

/// `stable`, an address made from a router's prefix, was just made or
/// had its lifetimes set again: its prefix's temporary addresses held to
/// them, and a new one made when the prefix has none to take.
pub fn refresh(stack: *StackBase, interface: *Interface, stable: *InterfaceAddress, now: u64) void {
    if (interface.ip6.privacy == 0) return;
    var current = false;
    for (&interface.ip6.addresses) |*entry| {
        if (!ofPrefix(entry, stable.address)) continue;
        // A duplicate after every try: no more for this prefix.
        if (entry.state == .duplicate) return;
        entry.preferred_until = earlier(entry.temporary_preferred_until, stable.preferred_until);
        entry.valid_until = earlier(entry.temporary_valid_until, stable.valid_until);
        const preferred = entry.preferred_until == 0 or entry.preferred_until > now;
        if (entry.state == .deprecated and preferred) entry.state = .preferred;
        if (entry.state == .preferred and !preferred) entry.state = .deprecated;
        if (entry.renewed == 0 and (entry.state == .tentative or entry.state == .preferred)) current = true;
        slaac.schedule(stack, entry, now);
    }
    if (!current) make(stack, interface, stable, now);
}

/// `entry`, a temporary address, is about to stop being preferred: the
/// one to follow it made, if its prefix's own address is still preferred.
pub fn renew(stack: *StackBase, entry: *InterfaceAddress, now: u64) void {
    entry.renewed = 1;
    const interface = entry.interface.?;
    if (interface.ip6.privacy == 0) return;
    const stable = slaac.fromPrefix(interface, entry.address) orelse return;
    if (stable.state != .preferred) return;
    make(stack, interface, stable, now);
}

/// A new temporary address in `stable`'s prefix, unless it would be
/// preferred for too short a time to be worth checking.
fn make(stack: *StackBase, interface: *Interface, stable: *InterfaceAddress, now: u64) void {
    if (stable.state != .preferred and stable.state != .tentative) return;
    const desync_us = _nd.below(stack, desync_most_s) * second_us;
    const own_preferred = now + preferred_us - desync_us;
    const own_valid = now + valid_us;
    const preferred_until = earlier(own_preferred, stable.preferred_until);
    if (preferred_until <= now + regenerate_us) return;
    const prefix = stable.address.bytes[0..8].*;
    const address = randomAddress(stack, interface, &prefix);
    const entry = _ip6.addAddress(stack, interface, address, 64, .tentative) orelse blk: {
        if (!makeRoom(stack, interface)) return;
        break :blk _ip6.addAddress(stack, interface, address, 64, .tentative) orelse return;
    };
    entry.autoconf = 1;
    entry.temporary = 1;
    entry.temporary_preferred_until = own_preferred;
    entry.temporary_valid_until = own_valid;
    entry.preferred_until = preferred_until;
    entry.valid_until = earlier(own_valid, stable.valid_until);
}

/// The deprecated or duplicate temporary address that ends first let go:
/// false when there is none.
fn makeRoom(stack: *StackBase, interface: *Interface) bool {
    var oldest: ?*InterfaceAddress = null;
    for (&interface.ip6.addresses) |*entry| {
        if (entry.temporary == 0 or (entry.state != .deprecated and entry.state != .duplicate)) continue;
        const ends = if (entry.state == .duplicate) 0 else entry.valid_until;
        if (oldest) |found| {
            const found_ends = if (found.state == .duplicate) 0 else found.valid_until;
            if (ends >= found_ends) continue;
        }
        oldest = entry;
    }
    _ip6.removeAddress(stack, oldest orelse return false);
    return true;
}

/// Privacy addresses turned on or off for a running interface: on, a
/// temporary address for each prefix; off, every temporary one let go.
pub fn set(stack: *StackBase, interface: *Interface, on: bool, now: u64) void {
    interface.ip6.privacy = @intFromBool(on);
    for (&interface.ip6.addresses) |*entry| {
        if (entry.state == .unused) continue;
        if (!on and entry.temporary != 0) {
            _ip6.removeAddress(stack, entry);
        } else if (on and entry.temporary == 0 and entry.autoconf != 0 and entry.usable()) {
            refresh(stack, interface, entry, now);
        }
    }
}

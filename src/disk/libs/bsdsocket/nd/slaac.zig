// SPDX-License-Identifier: MIT
//! Addresses from routers' prefixes (RFC 4862, 5.5), and the lifetimes
//! every such address runs out by.
//!
//! **A prefix with the A flag** of length 64 makes an address, unless
//! the interface's IPv6 is IFIPV6_FIXED: the
//! prefix and the interface identifier the interface is set to make
//! (`ip6/_ip6.zig`, `addressFor`), tentative until Neighbor Discovery has
//! checked it. A prefix of another length is passed over - an identifier
//! is 64 bits - and so is one whose preferred lifetime is longer than its
//! valid one.
//!
//! **Lifetimes**: an address stays preferred for its preferred lifetime,
//! then is deprecated - still valid, no longer picked for anything new -
//! and at the end of its valid lifetime it goes. An advertisement of the
//! same prefix sets them again, but a valid lifetime is cut short only
//! down to two hours, so a forged advertisement cannot take an address
//! away at once (RFC 4862, 5.5.3 e).
//!
//! With privacy addresses on, each such address has temporary ones beside
//! it (`privacy.zig`), which follow its lifetimes.

const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const _timer = @import("../timer/_timer.zig");
const Timer = _timer.Timer;
const _ip6 = @import("../ip6/_ip6.zig");
const router = @import("router.zig");
const privacy = @import("privacy.zig");
const Address = @import("../ip6/address.zig").Address;

pub const two_hours_us: u64 = 2 * 60 * 60 * 1_000_000;

/// The address `address_prefix` made on `interface`, if it made one -
/// not a temporary one.
pub fn fromPrefix(interface: *Interface, address_prefix: Address) ?*_ip6.InterfaceAddress {
    for (&interface.ip6.addresses) |*entry| {
        if (entry.state == .unused or entry.autoconf == 0 or entry.temporary != 0) continue;
        if (entry.address.inPrefix(address_prefix, 64)) return entry;
    }
    return null;
}

/// A prefix with the A flag, `length` bits of `address_prefix`, valid
/// and preferred for as many seconds as given.
pub fn prefix(stack: *StackBase, interface: *Interface, address_prefix: Address, length: u8, valid_s: u32, preferred_s: u32, now: u64) void {
    if (interface.ip6.autoconf == 0 or length != 64 or preferred_s > valid_s) return;
    const preferred_until = if (preferred_s == 0) now else router.until(now, preferred_s);
    if (fromPrefix(interface, address_prefix)) |entry| {
        if (entry.state == .duplicate) return;
        entry.preferred_until = preferred_until;
        // The valid lifetime: taken if it is longer than two hours or
        // than what is left; else held at two hours, unless less is left.
        const new_until = router.until(now, valid_s);
        const left: u64 = if (entry.valid_until == 0) ~@as(u64, 0) else entry.valid_until -| now;
        const offered: u64 = if (new_until == 0) ~@as(u64, 0) else new_until - now;
        if (offered > two_hours_us or offered > left) {
            entry.valid_until = new_until;
        } else if (left > two_hours_us) {
            entry.valid_until = now + two_hours_us;
        }
        if (entry.state == .deprecated and preferred_s != 0) entry.state = .preferred;
        schedule(stack, entry, now);
        return privacy.refresh(stack, interface, entry, now);
    }
    if (valid_s == 0) return;
    const bytes = address_prefix.bytes[0..8].*;
    const address = _ip6.addressFor(stack, interface, &bytes, 0);
    const entry = _ip6.addAddress(stack, interface, address, 64, .tentative) orelse return;
    entry.autoconf = 1;
    entry.preferred_until = preferred_until;
    entry.valid_until = router.until(now, valid_s);
    privacy.refresh(stack, interface, entry, now);
}

/// `entry`'s timer set for the next end of one of its lifetimes - or,
/// for a temporary address, for the time to make the one after it;
/// nothing for a tentative address, which is scheduled once it is
/// checked.
pub fn schedule(stack: *StackBase, entry: *_ip6.InterfaceAddress, now: u64) void {
    if (!entry.usable()) return;
    var next: u64 = 0;
    if (entry.state == .preferred and entry.preferred_until != 0) next = entry.preferred_until;
    if (renewing(entry)) next = entry.preferred_until -| privacy.regenerate_us;
    if (entry.valid_until != 0 and (next == 0 or entry.valid_until < next)) next = entry.valid_until;
    entry.timer.fire = &expired;
    if (next == 0) return _timer.cancel(stack, &entry.timer);
    _ = _timer.set(stack, &entry.timer, @max(next, now));
}

/// Whether `entry` is a temporary address whose follower is still to
/// make.
fn renewing(entry: *const _ip6.InterfaceAddress) bool {
    return entry.temporary != 0 and entry.renewed == 0 and entry.state == .preferred and entry.preferred_until != 0;
}

fn expired(stack: *StackBase, fired: *Timer, now: u64) void {
    const entry: *_ip6.InterfaceAddress = @fieldParentPtr("timer", fired);
    if (entry.valid_until != 0 and entry.valid_until <= now) return _ip6.removeAddress(stack, entry);
    if (renewing(entry) and entry.preferred_until -| privacy.regenerate_us <= now) privacy.renew(stack, entry, now);
    if (entry.state == .preferred and entry.preferred_until != 0 and entry.preferred_until <= now) entry.state = .deprecated;
    schedule(stack, entry, now);
}

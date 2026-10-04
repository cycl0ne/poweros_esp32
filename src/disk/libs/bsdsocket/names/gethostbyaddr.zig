// SPDX-License-Identifier: MIT
//! GetHostByAddr: the name an address has.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const resolver = @import("resolver.zig");
const Address = @import("../ip6/address.zig").Address;

/// The name an address has.
///
/// SYNOPSIS:
/// ```zig
/// fn GetHostByAddr(base: *SocketBase, address: *const anyopaque, length: u32, address_type: i32) ?*hostent
/// ```
///
/// SINCE: 1.0. LVO -168.
///
/// INPUTS:
/// - `address` - an IPv4 address, four bytes in network order as
///   `in_addr` holds it, or an IPv6 one, sixteen as `in6_addr` does.
/// - `length` - 4 for `AF_INET`, 16 for `AF_INET6`.
/// - `address_type` - `AF_INET` or `AF_INET6`.
///
/// RESULT:
/// A `hostent` of that family with the name and the address, or null
/// with `SBTC_HERRNO` saying why, as GetHostByName: also `NO_RECOVERY` for
/// another length or family.
///
/// BEHAVIOR:
/// The hosts file first, `localhost` for a loopback address, then a PTR
/// question to the name servers, as GetHostByName asks them: for
/// `d.c.b.a.in-addr.arpa`, or for an IPv6 address its 32 nibbles in
/// reverse under `ip6.arpa` (RFC 3596). An IPv4 address mapped into IPv6
/// is looked up as IPv4. Reverse answers are not cached.
///
/// CONTEXT:
/// - Waits: yes, for the name servers.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process, to read the hosts file.
///
/// OWNERSHIP:
/// As GetHostByName.
///
/// NOTES:
/// GetNameInfo answers the same for a sockaddr, and a port's service too.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetHostByName`, `GetNameInfo`
///
/// EXAMPLES:
/// ```zig
/// const address = sb.Inet_Addr("10.0.2.2");
/// if (sb.GetHostByAddr(&address, 4, bsd.AF_INET)) |host| _ = Printf(dl, "%s\n", .{host.h_name.?});
/// ```
pub fn GetHostByAddr(sb: *SocketBase, address: *const anyopaque, length: u32, address_type: i32) ?*bsd.hostent {
    const bytes: [*]const u8 = @ptrCast(address);
    if (length == 4 and address_type == bsd.AF_INET) {
        const network = @as(*align(1) const u32, @ptrCast(address)).*;
        return resolver.byAddress(sb, Address.fromV4(bsd.ntohl(network)), bsd.AF_INET);
    }
    if (length == 16 and address_type == bsd.AF_INET6) {
        return resolver.byAddress(sb, .{ .bytes = bytes[0..16].* }, bsd.AF_INET6);
    }
    sb.h_errno = bsd.NO_RECOVERY;
    return null;
}

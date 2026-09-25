// SPDX-License-Identifier: MIT
//! GetHostByAddr: the name an address has.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const resolver = @import("resolver.zig");

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
/// - `address` - an IPv4 address, four bytes in network order, as
///   `in_addr` holds it.
/// - `length` - 4.
/// - `address_type` - `AF_INET`.
///
/// RESULT:
/// A `hostent` with the name and the address, or null with `SBTC_HERRNO`
/// saying why, as GetHostByName: also `NO_RECOVERY` for another length or
/// family.
///
/// BEHAVIOR:
/// The hosts file first, then a PTR question for
/// `d.c.b.a.in-addr.arpa` to the name servers, as GetHostByName asks
/// them. Reverse answers are not cached.
///
/// CONTEXT:
/// - Waits: yes, for the name servers.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a process, to read the hosts file.
///
/// OWNERSHIP:
/// As GetHostByName.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetHostByName`
///
/// EXAMPLES:
/// ```zig
/// const address = sb.Inet_Addr("10.0.2.2");
/// if (sb.GetHostByAddr(&address, 4, bsd.AF_INET)) |host| _ = Printf(dl, "%s\n", .{host.h_name.?});
/// ```
pub fn GetHostByAddr(sb: *SocketBase, address: *const anyopaque, length: u32, address_type: i32) ?*bsd.hostent {
    if (length != 4 or address_type != bsd.AF_INET) {
        sb.h_errno = bsd.NO_RECOVERY;
        return null;
    }
    return resolver.byAddress(sb, @as(*align(1) const u32, @ptrCast(address)).*);
}

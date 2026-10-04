// SPDX-License-Identifier: MIT
//! AddDomainNameServer: a name server to ask.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _names = @import("_names.zig");

/// A name server added to the ones the resolver asks.
///
/// SYNOPSIS:
/// ```zig
/// fn AddDomainNameServer(base: *SocketBase, address: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -156.
///
/// INPUTS:
/// - `address` - the server, in network order.
///
/// RESULT:
/// 0, or -1 with Errno(): `EINVAL` (0.0.0.0), `ENOBUFS` (there are
/// `NAMESERVERS_MAX` already).
///
/// BEHAVIOR:
/// The servers are asked in the order they were added; one that is on
/// the list already stays where it is.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// DHCP and the interface files' `NameServer` add theirs the same way.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemoveDomainNameServer`, `GetHostByName`
///
/// EXAMPLES:
/// ```zig
/// _ = sb.AddDomainNameServer(sb.Inet_Addr("10.0.2.3"));
/// ```
pub fn AddDomainNameServer(sb: *SocketBase, address: u32) i32 {
    if (address == 0) return _socket.fail(sb, bsd.EINVAL, "AddDomainNameServer");
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    if (!_names.addServer(sb.stack, @import("../ip6/address.zig").Address.fromV4(bsd.ntohl(address)))) return _socket.fail(sb, bsd.ENOBUFS, "AddDomainNameServer");
    return 0;
}

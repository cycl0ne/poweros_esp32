// SPDX-License-Identifier: MIT
//! GetHostByName: the addresses a name has.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const resolver = @import("resolver.zig");

/// The addresses a name has.
///
/// SYNOPSIS:
/// ```zig
/// fn GetHostByName(base: *SocketBase, name: [*:0]const u8) ?*hostent
/// ```
///
/// SINCE: 1.0. LVO -164.
///
/// INPUTS:
/// - `name` - a host's name, "www.example.org", or an address as dotted
///   text.
///
/// RESULT:
/// A `hostent` - its name as the answer spelled it, and up to eight
/// addresses in network order - or null, with SocketBaseTagList's
/// `SBTC_HERRNO` saying why: `HOST_NOT_FOUND`, `NO_DATA` (a name without
/// addresses), `TRY_AGAIN` (no server answered, or a break signal came),
/// `NO_RECOVERY` (no name server to ask).
///
/// BEHAVIOR:
/// Looked for in turn: dotted text, which is its own answer; the hosts
/// file, `ENVARC:Sys/net/hosts`; `localhost`; the cache of earlier
/// answers; and DNS - the name servers DHCP, the interface files and
/// AddDomainNameServer gave, each asked three times, two seconds each. A
/// name without dots is asked for in the stack's domain first. What DNS
/// answers is cached for its time to live, between 30 s and an hour.
///
/// CONTEXT:
/// - Waits: yes, for the name servers; the break signals end it.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a process, to read the hosts file; a task goes without it.
///
/// OWNERSHIP:
/// The hostent is in the opener's base: the next GetHostByName or
/// GetHostByAddr overwrites it.
///
/// NOTES:
/// An answer counts only if it comes from the server asked, from port
/// 53, with the random id asked with; every length in it is checked
/// against the packet before it is read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetHostByAddr`, `AddDomainNameServer`, `SocketBaseTagList`
///
/// EXAMPLES:
/// ```zig
/// const host = sb.GetHostByName("example.org") orelse return;
/// var to: bsd.sockaddr_in = .{ .sin_port = bsd.htons(80) };
/// to.sin_addr.s_addr = @as(*align(1) const u32, @ptrCast(host.h_addr_list.?[0].?)).*;
/// ```
pub fn GetHostByName(sb: *SocketBase, name: [*:0]const u8) ?*bsd.hostent {
    return resolver.byName(sb, name);
}

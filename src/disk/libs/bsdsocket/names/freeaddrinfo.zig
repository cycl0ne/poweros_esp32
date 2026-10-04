// SPDX-License-Identifier: MIT
//! FreeAddrInfo: a list GetAddrInfo made, given back.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;

/// A list GetAddrInfo made, given back whole.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeAddrInfo(base: *SocketBase, list: *addrinfo) void
/// ```
///
/// SINCE: 1.1. LVO -204.
///
/// INPUTS:
/// - `list` - the first entry, as GetAddrInfo answered it.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The list is one block, which goes with its first entry; every entry
/// and what they point at are gone after it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list is the library's again.
///
/// NOTES:
/// An entry further down the list is not a list of its own: only the
/// first may be given.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetAddrInfo`
///
/// EXAMPLES:
/// ```zig
/// var list: ?*bsd.addrinfo = null;
/// if (sb.GetAddrInfo("example.org", "80", null, &list) == 0) sb.FreeAddrInfo(list.?);
/// ```
pub fn FreeAddrInfo(sb: *SocketBase, list: *bsd.addrinfo) void {
    sb.sys_base.FreeVec(list);
}

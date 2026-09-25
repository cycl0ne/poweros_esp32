// SPDX-License-Identifier: MIT
//! RemoveDomainNameServer: a name server no longer asked.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _names = @import("_names.zig");

/// A name server taken off the ones the resolver asks.
///
/// SYNOPSIS:
/// ```zig
/// fn RemoveDomainNameServer(base: *SocketBase, address: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -160.
///
/// INPUTS:
/// - `address` - the server, in network order.
///
/// RESULT:
/// 0, or -1 with Errno() `ENXIO`: it was not on the list.
///
/// BEHAVIOR:
/// The servers after it move up.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddDomainNameServer`
///
/// EXAMPLES:
/// ```zig
/// _ = sb.RemoveDomainNameServer(sb.Inet_Addr("10.0.2.3"));
/// ```
pub fn RemoveDomainNameServer(sb: *SocketBase, address: u32) i32 {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    if (!_names.removeServer(sb.stack, bsd.ntohl(address))) return _socket.fail(sb, bsd.ENXIO, "RemoveDomainNameServer");
    return 0;
}

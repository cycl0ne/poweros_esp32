// SPDX-License-Identifier: MIT
//! If_NameToIndex: an interface's index, by its name.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _netif = @import("_netif.zig");

/// The index of the interface called `name`: what `sin6_scope_id` names
/// it by.
///
/// SYNOPSIS:
/// ```zig
/// fn If_NameToIndex(base: *SocketBase, name: [*:0]const u8) u32
/// ```
///
/// SINCE: 1.1. LVO -192.
///
/// INPUTS:
/// - `name` - the interface's name, "eth0".
///
/// RESULT:
/// Its index, 1 or more, or 0 with errno ENXIO when there is no such
/// interface.
///
/// BEHAVIOR:
/// lo0 is 1, and the others count up in the order of the stack's
/// interface slots; an index stays the interface's until it is removed,
/// and the next interface added may take it then.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is kept.
///
/// NOTES:
/// A link-local address means something only with its interface:
/// `fe80::1%eth0` is `fe80::1` with this index in `sin6_scope_id`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `If_IndexToName`, `Inet_PtoN`
///
/// EXAMPLES:
/// ```zig
/// var to: bsd.sockaddr_in6 = .{ .sin6_scope_id = sb.If_NameToIndex("eth0") };
/// _ = sb.Inet_PtoN(bsd.AF_INET6, "fe80::2", &to.sin6_addr);
/// ```
pub fn If_NameToIndex(sb: *SocketBase, name: [*:0]const u8) u32 {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const interface = _netif.named(sb.stack, name) orelse {
        _socket.setErrno(sb, bsd.ENXIO);
        return 0;
    };
    return _netif.index(sb.stack, interface);
}

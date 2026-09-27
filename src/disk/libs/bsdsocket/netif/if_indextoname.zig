// SPDX-License-Identifier: MIT
//! If_IndexToName: an interface's name, by its index.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _netif = @import("_netif.zig");

/// The name of the interface at `index`, into `name`.
///
/// SYNOPSIS:
/// ```zig
/// fn If_IndexToName(base: *SocketBase, index: u32, name: [*]u8) ?[*:0]u8
/// ```
///
/// SINCE: 1.1. LVO -196.
///
/// INPUTS:
/// - `index` - an interface's index, as If_NameToIndex or a
///   `sin6_scope_id` has it.
/// - `name` - room for `IFNAMSIZ` bytes.
///
/// RESULT:
/// `name`, holding the interface's name, or null with errno ENXIO when no
/// interface has that index.
///
/// BEHAVIOR:
/// The name is copied with its NUL.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `name` is the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `If_NameToIndex`
///
/// EXAMPLES:
/// ```zig
/// var name: [bsd.IFNAMSIZ]u8 = undefined;
/// const text = sb.If_IndexToName(from.sin6_scope_id, &name) orelse return;
/// ```
pub fn If_IndexToName(sb: *SocketBase, index: u32, name: [*]u8) ?[*:0]u8 {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const interface = _netif.byIndex(sb.stack, index) orelse {
        _socket.setErrno(sb, bsd.ENXIO);
        return null;
    };
    var at: usize = 0;
    while (at + 1 < bsd.IFNAMSIZ and interface.name[at] != 0) : (at += 1) name[at] = interface.name[at];
    name[at] = 0;
    return @ptrCast(name);
}

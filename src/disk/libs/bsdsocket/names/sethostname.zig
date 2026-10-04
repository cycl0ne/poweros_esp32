// SPDX-License-Identifier: MIT
//! SetHostName: the machine's name set.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
const _names = @import("_names.zig");
const _lock = @import("../lock/_lock.zig");

/// The machine's name set.
///
/// SYNOPSIS:
/// ```zig
/// fn SetHostName(base: *SocketBase, name: [*:0]const u8) i32
/// ```
///
/// SINCE: 1.0. LVO -176.
///
/// INPUTS:
/// - `name` - 1 to 63 letters, digits and hyphens, not beginning or
///   ending with a hyphen.
///
/// RESULT:
/// 0, or -1 with Errno() `EINVAL` for a name that is not such a name.
///
/// BEHAVIOR:
/// It holds for the whole stack, every opener, until set again, and a
/// DHCP request after it carries it. Set before any interface is added,
/// it takes the place of `ENVARC:Sys/net/hostname`; C:net/HostName SAVE
/// writes that file, for the name to hold from the next boot.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The name is copied.
///
/// NOTES:
/// What a later mDNS answers to, as `<name>.local`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetHostName`
///
/// EXAMPLES:
/// ```zig
/// _ = sb.SetHostName("workbench");
/// ```
pub fn SetHostName(sb: *SocketBase, name: [*:0]const u8) i32 {
    var length: usize = 0;
    while (name[length] != 0 and length < 64) length += 1;
    if (length > 63 or !_names.validHostName(name[0..length])) return _socket.fail(sb, bsd.EINVAL, "SetHostName");
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const own = &sb.stack.hostname;
    @memcpy(own[0..length], name[0..length]);
    @memset(own[length..], 0);
    sb.stack.hostname_set = 1;
    return 0;
}

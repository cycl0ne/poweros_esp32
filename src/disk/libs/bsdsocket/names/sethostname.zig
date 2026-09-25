// SPDX-License-Identifier: MIT
//! SetHostName: the machine's name set.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
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
/// - `name` - 1 to 63 characters.
///
/// RESULT:
/// 0, or -1 with Errno() `EINVAL` for an empty name or one too long.
///
/// BEHAVIOR:
/// It holds for the whole stack, every opener, until set again.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
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
    if (length == 0 or length > 63) return _socket.fail(sb, bsd.EINVAL, "SetHostName");
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const own = &sb.stack.hostname;
    @memcpy(own[0..length], name[0..length]);
    @memset(own[length..], 0);
    return 0;
}

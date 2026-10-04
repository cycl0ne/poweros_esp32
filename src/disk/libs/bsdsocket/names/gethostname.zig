// SPDX-License-Identifier: MIT
//! GetHostName: the machine's name.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("../socket/_socket.zig");
const _names = @import("_names.zig");
const _lock = @import("../lock/_lock.zig");

/// The machine's name, into the caller's buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn GetHostName(base: *SocketBase, name: [*]u8, length: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -172.
///
/// INPUTS:
/// - `name` - where it goes.
/// - `length` - the room there, its NUL included.
///
/// RESULT:
/// 0, or -1 with Errno() `EINVAL` when it does not fit.
///
/// BEHAVIOR:
/// The name in `ENVARC:Sys/net/hostname`, read the first time an
/// interface is added or the name is asked for, or "poweros" without one;
/// SetHostName's once it has been called.
///
/// CONTEXT:
/// - Waits: for the stack's lock, and the first time for the file.
/// - Interrupts: no.
/// - Locks: none needed.
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
/// `SetHostName`
///
/// EXAMPLES:
/// ```zig
/// var name: [64]u8 = undefined;
/// _ = sb.GetHostName(&name, name.len);
/// ```
pub fn GetHostName(sb: *SocketBase, name: [*]u8, length: u32) i32 {
    _names.loadHostName(sb);
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    const own = &sb.stack.hostname;
    var size: usize = 0;
    while (size < own.len and own[size] != 0) size += 1;
    if (size + 1 > length) return _socket.fail(sb, bsd.EINVAL, "GetHostName");
    @memcpy(name[0..size], own[0..size]);
    name[size] = 0;
    return 0;
}

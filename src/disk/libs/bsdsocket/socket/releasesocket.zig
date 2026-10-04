// SPDX-License-Identifier: MIT
//! ReleaseSocket: a socket handed over for another task to take.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");

/// The socket taken out of the opener's table and left with the stack,
/// under an id, for ObtainSocket.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseSocket(base: *SocketBase, socket: i32, id: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -112.
///
/// INPUTS:
/// - `socket` - a descriptor from Socket.
/// - `id` - the id to hand it over by, or `UNIQUE_ID` for one the stack
///   makes up.
///
/// RESULT:
/// The id, or -1 with Errno(): `EBADF`, `EINVAL` (another socket waits
/// under that id already).
///
/// BEHAVIOR:
/// The descriptor is free at once. The socket stays as it was - bound,
/// connected, with its queue - and keeps taking datagrams, but belongs to
/// nobody and tells nobody of them until a task takes it with
/// ObtainSocket. This is how a server hands a connection to a task of its
/// own, each with its own base.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The socket is the stack's until ObtainSocket; one that is never taken
/// goes when the library does.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainSocket`
///
/// EXAMPLES:
/// ```zig
/// const id = sb.ReleaseSocket(socket, bsd.UNIQUE_ID);
/// // ... hand `id` to the task that will serve it
/// ```
pub fn ReleaseSocket(sb: *SocketBase, descriptor: i32, id: i32) i32 {
    const stack = sb.stack;
    const held = _lock.take(stack);
    defer _lock.give(stack, held);
    const socket = _socket.lookup(sb, descriptor) orelse return _socket.fail(sb, bsd.EBADF, "ReleaseSocket");
    var given = id;
    if (given == bsd.UNIQUE_ID) {
        while (released(stack, stack.next_release_id)) stack.next_release_id +%= 1;
        given = stack.next_release_id;
        stack.next_release_id = if (given == 0x7FFF_FFFF) 1 else given + 1;
    } else if (given < 0 or released(stack, given)) {
        return _socket.fail(sb, bsd.EINVAL, "ReleaseSocket");
    }
    sb.table.?[@intCast(descriptor)] = null;
    socket.owner = null;
    socket.descriptor = -1;
    socket.release_id = given;
    socket.events = 0;
    return given;
}

/// Whether a socket waits to be taken under `id`.
pub fn released(stack: *_base.StackBase, id: i32) bool {
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        const socket = _socket.fromNode(node);
        if (socket.owner == null and socket.release_id == id) return true;
    }
    return false;
}

// SPDX-License-Identifier: MIT
//! GetSocketEvents: the next socket with events to tell of.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");

/// The next of the opener's sockets that has events to tell of, and which.
///
/// SYNOPSIS:
/// ```zig
/// fn GetSocketEvents(base: *SocketBase, events: *u32) i32
/// ```
///
/// SINCE: 1.0. LVO -108.
///
/// INPUTS:
/// - `events` - gets the socket's events, FD_*.
///
/// RESULT:
/// The socket's descriptor, or -1 when no socket has any.
///
/// BEHAVIOR:
/// A socket tells of the events its `SO_EVENTMASK` names - `FD_READ` when
/// something comes to read, `FD_WRITE` when it can send, `FD_ERROR` when
/// the network reports an error for it - by raising the signal
/// `SBTC_SIGEVENTMASK` set, and keeps them until they are taken here. The
/// sockets are looked at in turn, starting after the one answered last,
/// so none is left waiting behind a busy one. A program serves any number
/// of sockets from its own Wait this way, beside its windows, without
/// WaitSelect.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands; the events are taken.
///
/// NOTES:
/// Call it until it answers -1 each time the event signal comes: one
/// signal may stand for events on many sockets.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetSockOpt`, `SocketBaseTagList`, `WaitSelect`
///
/// EXAMPLES:
/// ```zig
/// var events: u32 = 0;
/// var socket = sb.GetSocketEvents(&events);
/// while (socket >= 0) : (socket = sb.GetSocketEvents(&events)) handle(socket, events);
/// ```
pub fn GetSocketEvents(sb: *SocketBase, events: *u32) i32 {
    const held = _lock.take(sb.stack);
    defer _lock.give(sb.stack, held);
    var looked: u32 = 0;
    while (looked < sb.table_size) : (looked += 1) {
        const index = (sb.event_next + looked) % sb.table_size;
        const socket = sb.table.?[index] orelse continue;
        if (socket.events == 0) continue;
        events.* = socket.events;
        socket.events = 0;
        sb.event_next = (index + 1) % sb.table_size;
        return @intCast(index);
    }
    events.* = 0;
    return -1;
}

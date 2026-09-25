// SPDX-License-Identifier: MIT
//! Socket: a new socket in the opener's descriptor table.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const _lock = @import("../lock/_lock.zig");
const _tcp = @import("../tcp/_tcp.zig");
const _task = @import("../task/_task.zig");

/// A new socket, and the descriptor the other calls know it by.
///
/// SYNOPSIS:
/// ```zig
/// fn Socket(base: *SocketBase, domain: i32, socket_type: i32, protocol: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `domain` - `PF_INET`, the only family there is.
/// - `socket_type` - `SOCK_STREAM`: a connection, TCP; `SOCK_DGRAM`:
///   datagrams, UDP; `SOCK_RAW`: ICMP messages as they are, for a program
///   such as Ping.
/// - `protocol` - 0, or `IPPROTO_TCP` for a stream socket, `IPPROTO_UDP`
///   for a datagram socket; `IPPROTO_ICMP` for a raw one.
///
/// RESULT:
/// The descriptor, from 0 up, or -1 with Errno(): `EAFNOSUPPORT` for
/// another domain, `ESOCKTNOSUPPORT` for another type, `EPROTONOSUPPORT`
/// for another protocol, `EMFILE` when the descriptor table is full,
/// `ENOMEM`.
///
/// BEHAVIOR:
/// The socket takes the lowest free descriptor. It is bound to nothing
/// and connected to nothing; the first datagram it sends binds it to a
/// port of its own, or Bind chooses one first. It waits in its calls
/// unless FIONBIO says otherwise.
///
/// CONTEXT:
/// - Waits: only for the stack's lock.
/// - Interrupts: no.
/// - Forbid: not held.
/// - Process: a Task will do; it must be the one that opened the base.
///
/// OWNERSHIP:
/// The socket is the opener's until CloseSocket, or until it closes the
/// library, which closes every socket still open.
///
/// NOTES:
/// A raw ICMP socket receives a copy of every ICMP message that comes
/// in, its IPv4 header first; what it sends is the ICMP message, header
/// and checksum made by the program, and the stack puts the IPv4 header
/// in front. A stream socket has two rings of 8 KiB, one each way, which
/// SO_SNDBUF and SO_RCVBUF resize, and its first one starts the stack
/// task, which runs its timers.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseSocket`, `Bind`, `SendTo`, `RecvFrom`
///
/// EXAMPLES:
/// ```zig
/// const sb: *SocketBase = @ptrCast(sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return);
/// defer sys.CloseLibrary(sb.lib());
/// const socket = sb.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0);
/// if (socket < 0) return sb.Errno();
/// ```
pub fn Socket(sb: *SocketBase, domain: i32, socket_type: i32, protocol: i32) i32 {
    if (domain != bsd.PF_INET) return _socket.fail(sb, bsd.EAFNOSUPPORT, "Socket");
    const kind = switch (socket_type) {
        bsd.SOCK_DGRAM => if (protocol == 0 or protocol == bsd.IPPROTO_UDP) bsd.IPPROTO_UDP else return _socket.fail(sb, bsd.EPROTONOSUPPORT, "Socket"),
        bsd.SOCK_RAW => if (protocol == bsd.IPPROTO_ICMP) bsd.IPPROTO_ICMP else return _socket.fail(sb, bsd.EPROTONOSUPPORT, "Socket"),
        bsd.SOCK_STREAM => if (protocol == 0 or protocol == bsd.IPPROTO_TCP) bsd.IPPROTO_TCP else return _socket.fail(sb, bsd.EPROTONOSUPPORT, "Socket"),
        else => return _socket.fail(sb, bsd.ESOCKTNOSUPPORT, "Socket"),
    };
    const descriptor = blk: {
        const held = _lock.take(sb.stack);
        defer _lock.give(sb.stack, held);
        const socket = _socket.create(sb, socket_type, kind) orelse return _socket.fail(sb, sb.errno, "Socket");
        if (socket_type == bsd.SOCK_STREAM and !_tcp.create(sb.stack, socket)) {
            _socket.destroy(sb, socket);
            return _socket.fail(sb, bsd.ENOMEM, "Socket");
        }
        break :blk socket.descriptor;
    };
    // A connection's timers run on the stack task.
    if (socket_type == bsd.SOCK_STREAM and !_task.start(sb.stack)) {
        _ = _base.iface(sb).CloseSocket(descriptor);
        return _socket.fail(sb, bsd.ENOMEM, "Socket");
    }
    return descriptor;
}

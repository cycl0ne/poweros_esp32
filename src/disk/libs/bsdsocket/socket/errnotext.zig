// SPDX-License-Identifier: MIT
//! What an error number means, in words: for SocketBaseTagList's
//! SBTC_ERRNOSTRPTR and SBTC_HERRNOSTRPTR, so that a program prints
//! "Network is unreachable" and not only 51.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;

/// An errno's text; one for any number there is none for.
pub fn errnoText(errno: i32) [*:0]const u8 {
    return switch (errno) {
        0 => "No error",
        bsd.EPERM => "Operation not permitted",
        bsd.EINTR => "Interrupted",
        bsd.EIO => "Input/output error",
        bsd.ENXIO => "No such device",
        bsd.EBADF => "Not a socket of this program's",
        bsd.ENOMEM => "Not enough memory",
        bsd.EACCES => "Permission denied",
        bsd.EFAULT => "Bad address",
        bsd.EINVAL => "Invalid argument",
        bsd.EMFILE => "Too many open sockets",
        bsd.ENOSPC => "No room left in the buffer",
        bsd.EPIPE => "The connection is closed for writing",
        bsd.EWOULDBLOCK => "It would wait, and the socket does not",
        bsd.EINPROGRESS => "Under way",
        bsd.EALREADY => "Already under way",
        bsd.ENOTSOCK => "Not a socket",
        bsd.EDESTADDRREQ => "No address to send to",
        bsd.EMSGSIZE => "Message too long",
        bsd.EPROTOTYPE => "Wrong protocol for the socket",
        bsd.ENOPROTOOPT => "No such option",
        bsd.EPROTONOSUPPORT => "Protocol not supported",
        bsd.ESOCKTNOSUPPORT => "Socket type not supported",
        bsd.EOPNOTSUPP => "Not supported on this socket",
        bsd.EPFNOSUPPORT => "Protocol family not supported",
        bsd.EAFNOSUPPORT => "Address family not supported",
        bsd.EADDRINUSE => "Address already in use",
        bsd.EADDRNOTAVAIL => "Address not available here",
        bsd.ENETDOWN => "The network is down",
        bsd.ENETUNREACH => "Network is unreachable - no route to it",
        bsd.ENETRESET => "The network dropped the connection",
        bsd.ECONNABORTED => "Connection aborted",
        bsd.ECONNRESET => "Connection reset by the other side",
        bsd.ENOBUFS => "No buffer space",
        bsd.EISCONN => "Already connected",
        bsd.ENOTCONN => "Not connected",
        bsd.ESHUTDOWN => "The socket is shut down",
        bsd.ETOOMANYREFS => "Too many references",
        bsd.ETIMEDOUT => "Timed out",
        bsd.ECONNREFUSED => "Connection refused",
        bsd.EHOSTDOWN => "The host is down",
        bsd.EHOSTUNREACH => "No route to the host",
        else => "Unknown error",
    };
}

/// An h_errno's text.
pub fn hErrnoText(h_errno: i32) [*:0]const u8 {
    return switch (h_errno) {
        0 => "No error",
        bsd.HOST_NOT_FOUND => "No such host",
        bsd.TRY_AGAIN => "No answer from a name server; try again",
        bsd.NO_RECOVERY => "The name server failed",
        bsd.NO_DATA => "The name has no address of that kind",
        else => "Unknown error",
    };
}

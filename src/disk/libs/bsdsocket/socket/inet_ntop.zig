// SPDX-License-Identifier: MIT
//! Inet_NtoP: an address of either family as text.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const address_file = @import("../ip6/address.zig");
const Address = address_file.Address;

/// An address as text: IPv4's dotted quad, or IPv6's as RFC 5952 writes it.
///
/// SYNOPSIS:
/// ```zig
/// fn Inet_NtoP(base: *SocketBase, family: i32, source: *const anyopaque, destination: [*]u8, size: u32) ?[*:0]u8
/// ```
///
/// SINCE: 1.1. LVO -184.
///
/// INPUTS:
/// - `family` - AF_INET or AF_INET6.
/// - `source` - an `in_addr` for AF_INET, an `in6_addr` for AF_INET6.
/// - `destination` - where the text goes, NUL-terminated.
/// - `size` - its bytes: INET_ADDRSTRLEN and INET6_ADDRSTRLEN always do.
///
/// RESULT:
/// `destination`, or null with the errno set: EAFNOSUPPORT for another
/// family, ENOSPC when the text and its NUL do not fit.
///
/// BEHAVIOR:
/// IPv4 as four decimal numbers with dots between. IPv6 in lower case,
/// each group without its leading zeros, the longest run of two or more
/// zero groups as `::` (the first of runs equally long), and an IPv4
/// address mapped into IPv6 (`::ffff:0:0/96`) with its last 32 bits
/// dotted: `::ffff:10.0.2.15`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The text is the caller's, in the caller's buffer.
///
/// NOTES:
/// A zone (`%eth0`) is not part of an address and is not written.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Inet_PtoN`, `Inet_NtoA`
///
/// EXAMPLES:
/// ```zig
/// var text: [bsd.INET6_ADDRSTRLEN]u8 = undefined;
/// _ = sb.Inet_NtoP(bsd.AF_INET6, &from.sin6_addr, &text, text.len);
/// ```
pub fn Inet_NtoP(sb: *SocketBase, family: i32, source: *const anyopaque, destination: [*]u8, size: u32) ?[*:0]u8 {
    var text: [address_file.text_max]u8 = undefined;
    var length: usize = 0;
    if (family == bsd.AF_INET) {
        const in: *align(1) const bsd.in_addr = @ptrCast(source);
        var quad: [15]u8 = undefined;
        length = address_file.formatV4(bsd.ntohl(in.s_addr), &quad);
        @memcpy(text[0..length], quad[0..length]);
    } else if (family == bsd.AF_INET6) {
        const in6: *align(1) const bsd.in6_addr = @ptrCast(source);
        length = address_file.format(.{ .bytes = in6.s6_addr }, &text);
    } else {
        _socket.setErrno(sb, bsd.EAFNOSUPPORT);
        return null;
    }
    if (length + 1 > size) {
        _socket.setErrno(sb, bsd.ENOSPC);
        return null;
    }
    @memcpy(destination[0..length], text[0..length]);
    destination[length] = 0;
    return @ptrCast(destination);
}

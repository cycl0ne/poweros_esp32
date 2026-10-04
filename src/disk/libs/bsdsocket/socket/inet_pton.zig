// SPDX-License-Identifier: MIT
//! Inet_PtoN: text as an address of either family.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;
const _socket = @import("_socket.zig");
const address_file = @import("../ip6/address.zig");

/// Text as an address: IPv4's dotted quad, or IPv6 in any form RFC 4291
/// allows.
///
/// SYNOPSIS:
/// ```zig
/// fn Inet_PtoN(base: *SocketBase, family: i32, text: [*:0]const u8, destination: *anyopaque) i32
/// ```
///
/// SINCE: 1.1. LVO -188.
///
/// INPUTS:
/// - `family` - AF_INET or AF_INET6.
/// - `text` - the address, NUL-terminated.
/// - `destination` - an `in_addr` for AF_INET, an `in6_addr` for AF_INET6.
///
/// RESULT:
/// 1 with the address in `destination`; 0 when the text is no address of
/// the family, `destination` untouched; -1 with errno EAFNOSUPPORT for
/// another family.
///
/// BEHAVIOR:
/// AF_INET takes exactly four decimal numbers from 0 to 255 with dots
/// between, none with a leading zero but a lone 0 - not the shorter or
/// octal forms Inet_Addr also reads. AF_INET6 takes eight groups of one
/// to four hex digits, one run of them written `::`, and the last two as a
/// dotted IPv4 address if the text likes.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is kept.
///
/// NOTES:
/// A zone (`fe80::1%eth0`) is not an address and answers 0; its
/// interface belongs in `sin6_scope_id`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Inet_NtoP`, `Inet_Addr`
///
/// EXAMPLES:
/// ```zig
/// var to: bsd.sockaddr_in6 = .{ .sin6_port = bsd.htons(80) };
/// if (sb.Inet_PtoN(bsd.AF_INET6, "fec0::2", &to.sin6_addr) != 1) return;
/// ```
pub fn Inet_PtoN(sb: *SocketBase, family: i32, text: [*:0]const u8, destination: *anyopaque) i32 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    if (family == bsd.AF_INET) {
        const address = address_file.parseV4(text[0..length]) orelse return 0;
        const in: *align(1) bsd.in_addr = @ptrCast(destination);
        in.s_addr = bsd.htonl(address);
        return 1;
    }
    if (family == bsd.AF_INET6) {
        const address = address_file.parse(text[0..length]) orelse return 0;
        const in6: *align(1) bsd.in6_addr = @ptrCast(destination);
        in6.s6_addr = address.bytes;
        return 1;
    }
    _socket.setErrno(sb, bsd.EAFNOSUPPORT);
    return -1;
}

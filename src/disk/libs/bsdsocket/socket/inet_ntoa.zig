// SPDX-License-Identifier: MIT
//! Inet_NtoA: an address as dotted text.

const sdk = @import("sdk");
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;

/// An IPv4 address as dotted text, "10.0.2.15".
///
/// SYNOPSIS:
/// ```zig
/// fn Inet_NtoA(base: *SocketBase, address: u32) [*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -88.
///
/// INPUTS:
/// - `address` - in network order, as `in_addr.s_addr` holds it.
///
/// RESULT:
/// The text, in a buffer of the opener's base.
///
/// BEHAVIOR:
/// Four numbers from 0 to 255, with dots between.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer is the base's: the next Inet_NtoA overwrites it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Inet_Addr`
///
/// EXAMPLES:
/// ```zig
/// _ = Printf(dl, "from %s\n", .{sb.Inet_NtoA(from.sin_addr.s_addr)});
/// ```
pub fn Inet_NtoA(sb: *SocketBase, address: u32) [*:0]const u8 {
    const octets: [4]u8 = @bitCast(address);
    var at: usize = 0;
    for (octets, 0..) |octet, place| {
        if (octet >= 100) {
            sb.text[at] = '0' + octet / 100;
            at += 1;
        }
        if (octet >= 10) {
            sb.text[at] = '0' + octet / 10 % 10;
            at += 1;
        }
        sb.text[at] = '0' + octet % 10;
        at += 1;
        sb.text[at] = if (place == 3) 0 else '.';
        at += 1;
    }
    return @ptrCast(&sb.text);
}

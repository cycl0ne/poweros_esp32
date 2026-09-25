// SPDX-License-Identifier: MIT
//! Inet_Addr: dotted text as an address.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;

/// Dotted text, "10.0.2.2", as an IPv4 address.
///
/// SYNOPSIS:
/// ```zig
/// fn Inet_Addr(base: *SocketBase, text: [*:0]const u8) u32
/// ```
///
/// SINCE: 1.0. LVO -92.
///
/// INPUTS:
/// - `text` - four numbers from 0 to 255 with dots between.
///
/// RESULT:
/// The address in network order, as `in_addr.s_addr` holds it, or
/// `INADDR_NONE` when the text is no address.
///
/// BEHAVIOR:
/// Only the four-part decimal form is taken.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// "255.255.255.255" is a real address and answers the same as text that
/// is none.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Inet_NtoA`
///
/// EXAMPLES:
/// ```zig
/// var to: bsd.sockaddr_in = .{ .sin_port = bsd.htons(7), .sin_addr = .{ .s_addr = sb.Inet_Addr("10.0.2.2") } };
/// ```
pub fn Inet_Addr(_: *SocketBase, text: [*:0]const u8) u32 {
    var octets: [4]u8 = @splat(0);
    var part: usize = 0;
    var value: u32 = 0;
    var digits: u32 = 0;
    var at: usize = 0;
    while (true) : (at += 1) {
        const char = text[at];
        if (char >= '0' and char <= '9') {
            value = value * 10 + (char - '0');
            digits += 1;
            if (value > 255 or digits > 3) return bsd.INADDR_NONE;
            continue;
        }
        if (digits == 0 or part > 3) return bsd.INADDR_NONE;
        octets[part] = @intCast(value);
        part += 1;
        value = 0;
        digits = 0;
        if (char == 0) break;
        if (char != '.') return bsd.INADDR_NONE;
    }
    if (part != 4) return bsd.INADDR_NONE;
    return @bitCast(octets);
}

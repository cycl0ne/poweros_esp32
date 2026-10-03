// SPDX-License-Identifier: MIT
//! Whether a certificate is for the host a client asked for (RFC 6125):
//! the host against the subject's alternative names.
//!
//! A name is a dNSName, compared without regard to case and to a
//! trailing dot. A wildcard is taken only as the whole of the left-most
//! label (`*.example.com`), standing for exactly one label, and not over
//! a single remaining label (`*.com` stands for nothing). An address -
//! dotted IPv4 or IPv6 in its colon form - is compared with the
//! iPAddress names only, byte for byte. The subject's common name is not
//! looked at: a certificate names its hosts in subjectAltName, and one
//! that does not names none.

const der = @import("der.zig");

const dns_name = 0x82; // [2] IMPLICIT IA5String
const ip_address = 0x87; // [7] IMPLICIT OCTET STRING

/// Whether `alt_names` (subjectAltName's GeneralNames, their contents)
/// covers `host`.
pub fn matches(alt_names: []const u8, host_in: []const u8) bool {
    var host = host_in;
    if (host.len > 0 and host[host.len - 1] == '.') host = host[0 .. host.len - 1];
    if (host.len == 0) return false;

    var address: [16]u8 = undefined;
    const address_length = parseAddress(host, &address);

    var reader = der.Reader.of(alt_names);
    while (reader.next()) |name| {
        if (address_length != 0) {
            if (name.tag == ip_address and der.same(name.contents, address[0..address_length])) return true;
        } else if (name.tag == dns_name) {
            if (dnsMatches(name.contents, host)) return true;
        }
    }
    return false;
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

fn sameText(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (lower(x) != lower(y)) return false;
    return true;
}

fn dnsMatches(pattern_in: []const u8, host: []const u8) bool {
    var pattern = pattern_in;
    if (pattern.len > 0 and pattern[pattern.len - 1] == '.') pattern = pattern[0 .. pattern.len - 1];
    if (pattern.len >= 2 and pattern[0] == '*' and pattern[1] == '.') {
        const rest = pattern[1..]; // ".example.com"
        // At least two labels under the wildcard, and no other star.
        var dots: usize = 0;
        for (rest) |char| {
            if (char == '*') return false;
            if (char == '.') dots += 1;
        }
        if (dots < 2) return false;
        // One label of the host, then the rest exactly.
        const first_dot = indexOf(host, '.') orelse return false;
        if (first_dot == 0) return false;
        return sameText(host[first_dot..], rest);
    }
    for (pattern) |char| if (char == '*') return false;
    return sameText(pattern, host);
}

fn indexOf(text: []const u8, char: u8) ?usize {
    for (text, 0..) |c, index| if (c == char) return index;
    return null;
}

/// `host` as an address, into `out`: 4 bytes for IPv4, 16 for IPv6, 0
/// when it is a name.
fn parseAddress(host: []const u8, out: *[16]u8) usize {
    if (indexOf(host, ':') != null) return if (parseIp6(host, out)) 16 else 0;
    var parts: usize = 0;
    var value: u32 = 0;
    var digits: usize = 0;
    for (host) |char| {
        if (char == '.') {
            if (digits == 0 or parts == 3) return 0;
            out[parts] = @intCast(value);
            parts += 1;
            value = 0;
            digits = 0;
        } else if (char >= '0' and char <= '9') {
            value = value * 10 + (char - '0');
            digits += 1;
            if (value > 255 or digits > 3) return 0;
        } else return 0;
    }
    if (digits == 0 or parts != 3) return 0;
    out[3] = @intCast(value);
    return 4;
}

/// IPv6 in its colon form, `::` standing for a run of zero groups.
fn parseIp6(text: []const u8, out: *[16]u8) bool {
    var groups: [8]u16 = @splat(0);
    var count: usize = 0;
    var gap: ?usize = null;
    var at: usize = 0;
    if (text.len >= 2 and text[0] == ':' and text[1] == ':') {
        gap = 0;
        at = 2;
    } else if (text.len > 0 and text[0] == ':') return false;
    while (at < text.len) {
        if (count == 8) return false;
        var value: u32 = 0;
        var digits: usize = 0;
        while (at < text.len and text[at] != ':') : (at += 1) {
            const char = lower(text[at]);
            const digit: u32 = switch (char) {
                '0'...'9' => char - '0',
                'a'...'f' => char - 'a' + 10,
                else => return false,
            };
            value = value << 4 | digit;
            digits += 1;
            if (digits > 4) return false;
        }
        if (digits == 0) return false;
        groups[count] = @intCast(value);
        count += 1;
        if (at == text.len) break;
        at += 1; // the colon
        if (at < text.len and text[at] == ':') {
            if (gap != null) return false;
            gap = count;
            at += 1;
        } else if (at == text.len) return false;
    }
    if (gap) |start| {
        if (count == 8) return false;
        // The groups after the gap moved to the end.
        const after = count - start;
        var index: usize = 0;
        while (index < after) : (index += 1) {
            groups[7 - index] = groups[count - 1 - index];
            groups[count - 1 - index] = 0;
        }
    } else if (count != 8) return false;
    for (groups, 0..) |group, index| {
        out[2 * index] = @truncate(group >> 8);
        out[2 * index + 1] = @truncate(group);
    }
    return true;
}

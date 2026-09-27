// SPDX-License-Identifier: MIT
//! The stack's address above the IP layers: sixteen bytes, IPv6's, in
//! network order. An IPv4 address is held in its mapped form,
//! `::ffff:a.b.c.d` (RFC 4291, 2.5.5.2), so a socket, a connection and a
//! datagram's sender are the same whichever family carried them, and a
//! socket bound to `::` takes both. IPv4's own layer (`ip/`, `arp/`,
//! `dhcp/`, an interface's IPv4 address and routes) keeps its `u32` in the
//! chip's order, and meets this type at the transports' edge (`fromV4`,
//! `v4`).
//!
//! **Text** both ways, as RFC 5952 writes an address and RFC 4291 (2.2)
//! reads one: `format` writes the groups in lower case without leading
//! zeros and the longest run of two or more zero groups as `::` (the first
//! of equal runs), and a mapped address with its IPv4 part dotted;
//! `parse` takes any of the forms 4291 allows, a dotted IPv4 tail
//! included. `formatV4` and `parseV4` are IPv4's dotted quad, which
//! Inet_PtoN reads strictly: four decimal numbers, no other form.

/// An address: IPv6's sixteen bytes, IPv4 mapped.
pub const Address = extern struct {
    bytes: [16]u8 = @splat(0),

    /// `::`, the unspecified address.
    pub const any: Address = .{};
    /// `::1`.
    pub const loopback: Address = .{ .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } };
    /// `ff02::1`, every node on the link.
    pub const all_nodes: Address = .{ .bytes = .{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } };
    /// `ff02::2`, every router on the link.
    pub const all_routers: Address = .{ .bytes = .{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 } };

    /// The first twelve bytes of a mapped IPv4 address.
    const mapped_prefix = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };

    /// An IPv4 address, in the chip's order, as its mapped form.
    pub fn fromV4(address: u32) Address {
        var made: Address = .{};
        @memcpy(made.bytes[0..12], &mapped_prefix);
        made.bytes[12] = @truncate(address >> 24);
        made.bytes[13] = @truncate(address >> 16);
        made.bytes[14] = @truncate(address >> 8);
        made.bytes[15] = @truncate(address);
        return made;
    }

    /// Whether it is a mapped IPv4 address.
    pub fn isV4(address: Address) bool {
        return eql12(address.bytes[0..12], &mapped_prefix);
    }

    /// Its IPv4 address, in the chip's order; meaningful only when `isV4`.
    pub fn v4(address: Address) u32 {
        return @as(u32, address.bytes[12]) << 24 | @as(u32, address.bytes[13]) << 16 |
            @as(u32, address.bytes[14]) << 8 | address.bytes[15];
    }

    pub fn eql(address: Address, other: Address) bool {
        for (address.bytes, other.bytes) |a, b| if (a != b) return false;
        return true;
    }

    /// Whether it says "any address": `::`, or IPv4's 0.0.0.0 mapped.
    pub fn isUnspecified(address: Address) bool {
        if (address.isV4()) return address.v4() == 0;
        return address.eql(any);
    }

    /// `::1`, or anything in IPv4's 127.0.0.0/8 mapped.
    pub fn isLoopback(address: Address) bool {
        if (address.isV4()) return address.bytes[12] == 127;
        return address.eql(loopback);
    }

    /// ff00::/8.
    pub fn isMulticast(address: Address) bool {
        return address.bytes[0] == 0xff;
    }

    /// fe80::/10.
    pub fn isLinkLocal(address: Address) bool {
        return address.bytes[0] == 0xfe and address.bytes[1] & 0xc0 == 0x80;
    }

    /// The 16-bit group `index` (0 to 7).
    pub fn group(address: Address, index: usize) u16 {
        return @as(u16, address.bytes[index * 2]) << 8 | address.bytes[index * 2 + 1];
    }

    /// Whether its first `length` bits are `prefix`'s.
    pub fn inPrefix(address: Address, prefix: Address, length: u8) bool {
        return address.commonBits(prefix) >= length;
    }

    /// How many leading bits it has in common with `other`.
    pub fn commonBits(address: Address, other: Address) u8 {
        for (address.bytes, other.bytes, 0..) |a, b, index| {
            const differ = a ^ b;
            if (differ != 0) return @intCast(index * 8 + @clz(differ));
        }
        return 128;
    }

    /// Its solicited-node group, `ff02::1:ff00:0/104` with its last 24
    /// bits (RFC 4291, 2.7.1): where a neighbor looking for it asks.
    pub fn solicitedNode(address: Address) Address {
        var made: Address = .{ .bytes = .{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0xff, 0, 0, 0 } };
        made.bytes[13..16].* = address.bytes[13..16].*;
        return made;
    }

    /// The scope a multicast address names in its fourth nibble, or the
    /// one a unicast address has: 1 interface, 2 link, 0xE global.
    pub fn scope(address: Address) u4 {
        if (address.isMulticast()) return @truncate(address.bytes[1]);
        if (address.isLinkLocal() or address.eql(loopback)) return 2;
        return 0xE;
    }
};

fn eql12(a: *const [12]u8, b: *const [12]u8) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

// --- writing -------------------------------------------------------------------

/// The longest text `format` writes, without its NUL: eight groups of four
/// and seven colons, or a mapped address's `::ffff:255.255.255.255`.
pub const text_max = 45;

const hex = "0123456789abcdef";

/// The address as RFC 5952 writes it, into `into`; answers the length.
pub fn format(address: Address, into: *[text_max]u8) usize {
    var at: usize = 0;
    if (address.isV4()) {
        const prefix = "::ffff:";
        @memcpy(into[0..prefix.len], prefix);
        at = prefix.len;
        var quad: [15]u8 = undefined;
        const length = formatV4(address.v4(), &quad);
        @memcpy(into[at .. at + length], quad[0..length]);
        return at + length;
    }
    // The longest run of zero groups, two or more long; the first of runs
    // equally long.
    var best_start: usize = 8;
    var best_length: usize = 0;
    var run_start: usize = 0;
    var run_length: usize = 0;
    for (0..8) |index| {
        if (address.group(index) == 0) {
            if (run_length == 0) run_start = index;
            run_length += 1;
            if (run_length > best_length) {
                best_start = run_start;
                best_length = run_length;
            }
        } else run_length = 0;
    }
    if (best_length < 2) best_start = 8;

    var index: usize = 0;
    while (index < 8) {
        if (index == best_start) {
            into[at] = ':';
            into[at + 1] = ':';
            at += 2;
            index += best_length;
            continue;
        }
        if (index != 0 and index != best_start + best_length) {
            into[at] = ':';
            at += 1;
        }
        const value = address.group(index);
        var shift: u4 = 12;
        var started = false;
        while (true) : (shift -= 4) {
            const digit: u16 = (value >> shift) & 0xf;
            if (digit != 0 or started or shift == 0) {
                into[at] = hex[digit];
                at += 1;
                started = true;
            }
            if (shift == 0) break;
        }
        index += 1;
    }
    return at;
}

/// An IPv4 address, in the chip's order, as a dotted quad; answers the
/// length.
pub fn formatV4(address: u32, into: *[15]u8) usize {
    var at: usize = 0;
    for (0..4) |place| {
        const octet: u8 = @truncate(address >> @intCast(24 - place * 8));
        if (octet >= 100) {
            into[at] = '0' + octet / 100;
            at += 1;
        }
        if (octet >= 10) {
            into[at] = '0' + octet / 10 % 10;
            at += 1;
        }
        into[at] = '0' + octet % 10;
        at += 1;
        if (place != 3) {
            into[at] = '.';
            at += 1;
        }
    }
    return at;
}

// --- reading -------------------------------------------------------------------

fn hexValue(char: u8) ?u16 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// A dotted quad, strictly: four decimal numbers from 0 to 255, no
/// leading zeros but a lone 0, and nothing else. Answers the address in
/// the chip's order, or null.
pub fn parseV4(text: []const u8) ?u32 {
    var value: u32 = 0;
    var part: u32 = 0;
    var digits: u32 = 0;
    var parts: u32 = 0;
    for (text, 0..) |char, at| {
        if (char >= '0' and char <= '9') {
            if (digits == 1 and part == 0) return null; // a leading zero
            part = part * 10 + (char - '0');
            digits += 1;
            if (part > 255) return null;
        } else if (char == '.') {
            if (digits == 0 or parts == 3) return null;
            value = value << 8 | part;
            parts += 1;
            part = 0;
            digits = 0;
        } else return null;
        _ = at;
    }
    if (digits == 0 or parts != 3) return null;
    return value << 8 | part;
}

/// An IPv6 address in any form RFC 4291 (2.2) allows: eight groups of one
/// to four hex digits, one run of them written `::`, and the last two
/// groups as a dotted IPv4 address if the writer liked. Null for anything
/// else - a zone (`%eth0`) included, which is not part of an address.
pub fn parse(text: []const u8) ?Address {
    var groups: [8]u16 = @splat(0);
    var count: usize = 0;
    var gap: ?usize = null;
    var at: usize = 0;
    if (text.len == 0) return null;
    if (text[0] == ':') {
        if (text.len < 2 or text[1] != ':') return null;
        gap = 0;
        at = 2;
        if (at == text.len) return Address.any;
    }
    while (at < text.len) {
        // A dotted IPv4 tail: the rest of the text, taking two groups.
        var dot = false;
        var end = at;
        while (end < text.len and text[end] != ':') : (end += 1) {
            if (text[end] == '.') dot = true;
        }
        if (dot) {
            if (end != text.len or count > 6) return null;
            const quad = parseV4(text[at..end]) orelse return null;
            groups[count] = @truncate(quad >> 16);
            groups[count + 1] = @truncate(quad);
            count += 2;
            at = end;
            break;
        }
        if (end == at or end - at > 4 or count == 8) return null;
        var value: u16 = 0;
        for (text[at..end]) |char| value = value << 4 | (hexValue(char) orelse return null);
        groups[count] = value;
        count += 1;
        at = end;
        if (at == text.len) break;
        // A colon, or two for the gap.
        at += 1;
        if (at < text.len and text[at] == ':') {
            if (gap != null) return null;
            gap = count;
            at += 1;
            if (at == text.len) break;
        } else if (at == text.len) return null; // a trailing single colon
    }
    var made: Address = .{};
    if (gap) |start| {
        if (count > 7) return null;
        const tail = count - start;
        for (0..start) |index| setGroup(&made, index, groups[index]);
        for (0..tail) |index| setGroup(&made, 8 - tail + index, groups[start + index]);
    } else {
        if (count != 8) return null;
        for (0..8) |index| setGroup(&made, index, groups[index]);
    }
    return made;
}

fn setGroup(address: *Address, index: usize, value: u16) void {
    address.bytes[index * 2] = @truncate(value >> 8);
    address.bytes[index * 2 + 1] = @truncate(value);
}

// SPDX-License-Identifier: MIT
//! The hosts file, ENVARC:Sys/net/hosts: names this machine knows without
//! asking anyone. A line is an address and the names it has, the first
//! its own name and the rest aliases; `#` starts a comment to the end of
//! the line.
//!
//! ```
//! 127.0.0.1     localhost
//! ::1           localhost
//! 192.168.1.10  printer printer.home.lan
//! fd00::10      printer
//! ```
//!
//! An address is IPv4's dotted quad or IPv6 text. These read the file's
//! text, already in memory, and nothing else.

const bsd = @import("sdk").bsdsocket;
const dns = @import("dns.zig");
const address_file = @import("../ip6/address.zig");
const Address = address_file.Address;

/// An address as the file writes it: a dotted IPv4 one (mapped), or IPv6
/// text.
pub fn addressOf(text: []const u8) ?Address {
    if (dotted(text)) |network| return Address.fromV4(bsd.ntohl(network));
    return address_file.parse(text);
}

/// The first address of `family` (AF_INET or AF_INET6) that `name` has
/// in `text`, or null. Names match without regard to case.
pub fn find(text: []const u8, name: []const u8, family: u8) ?Address {
    var lines = Lines{ .text = text };
    while (lines.next()) |line| {
        var words = Words{ .text = line };
        const address_text = words.next() orelse continue;
        const address = addressOf(address_text) orelse continue;
        if (address.isV4() != (family == bsd.AF_INET)) continue;
        while (words.next()) |word| {
            if (same(word, name)) return address;
        }
    }
    return null;
}

/// The first name `address` has in `text`, or null.
pub fn reverse(text: []const u8, address: Address) ?[]const u8 {
    var lines = Lines{ .text = text };
    while (lines.next()) |line| {
        var words = Words{ .text = line };
        const address_text = words.next() orelse continue;
        if (!(addressOf(address_text) orelse continue).eql(address)) continue;
        return words.next();
    }
    return null;
}

const Lines = struct {
    text: []const u8,
    at: usize = 0,

    fn next(lines: *Lines) ?[]const u8 {
        if (lines.at >= lines.text.len) return null;
        const start = lines.at;
        while (lines.at < lines.text.len and lines.text[lines.at] != '\n') lines.at += 1;
        var line = lines.text[start..lines.at];
        lines.at += 1;
        for (line, 0..) |char, index| {
            if (char == '#') {
                line = line[0..index];
                break;
            }
        }
        return line;
    }
};

const Words = struct {
    text: []const u8,
    at: usize = 0,

    fn next(words: *Words) ?[]const u8 {
        while (words.at < words.text.len and blank(words.text[words.at])) words.at += 1;
        if (words.at >= words.text.len) return null;
        const start = words.at;
        while (words.at < words.text.len and !blank(words.text[words.at])) words.at += 1;
        return words.text[start..words.at];
    }

    fn blank(char: u8) bool {
        return char == ' ' or char == '\t' or char == '\r';
    }
};

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

/// Whether two names are the same, case aside.
pub fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (lower(x) != lower(y)) return false;
    }
    return true;
}

/// A dotted address in network order, or null.
pub fn dotted(text: []const u8) ?u32 {
    var octets: [4]u8 = @splat(0);
    var part: usize = 0;
    var value: u32 = 0;
    var digits: u32 = 0;
    for (text) |char| {
        if (char >= '0' and char <= '9') {
            value = value * 10 + (char - '0');
            digits += 1;
            if (value > 255 or digits > 3) return null;
        } else if (char == '.') {
            if (digits == 0 or part == 3) return null;
            octets[part] = @intCast(value);
            part += 1;
            value = 0;
            digits = 0;
        } else return null;
    }
    if (digits == 0 or part != 3) return null;
    octets[3] = @intCast(value);
    return @bitCast(octets);
}

comptime {
    _ = dns;
}

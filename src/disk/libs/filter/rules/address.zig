// SPDX-License-Identifier: MIT
//! An address in a rule, as text: IPv4's four decimal parts
//! (`192.168.1.20`), or IPv6's eight groups of hex with one `::` for a run
//! of zeros and maybe IPv4's parts at the end (`fd00::1`, `::ffff:10.0.0.1`).
//! Into the sixteen bytes rules keep - IPv4's mapped - and its family.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;

pub const Parsed = struct {
    bytes: [16]u8,
    family: u8,
};

const mapped_prefix = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF };

/// `text` as an address, or null when it is none. An IPv6 address that
/// maps an IPv4 one is IPv4's.
pub fn parse(text: []const u8) ?Parsed {
    if (v4(text)) |four| {
        var bytes: [16]u8 = undefined;
        bytes[0..12].* = mapped_prefix;
        bytes[12..16].* = four;
        return .{ .bytes = bytes, .family = bsd.AF_INET };
    }
    const bytes = v6(text) orelse return null;
    const is_mapped = for (bytes[0..12], mapped_prefix) |got, want| {
        if (got != want) break false;
    } else true;
    return .{ .bytes = bytes, .family = if (is_mapped) bsd.AF_INET else bsd.AF_INET6 };
}

/// Four decimal parts of 0-255, dots between.
fn v4(text: []const u8) ?[4]u8 {
    var parts: [4]u8 = undefined;
    var part: usize = 0;
    var value: u32 = 0;
    var digits: usize = 0;
    for (text) |char| {
        switch (char) {
            '0'...'9' => {
                value = value * 10 + (char - '0');
                digits += 1;
                if (digits > 3 or value > 255) return null;
            },
            '.' => {
                if (digits == 0 or part == 3) return null;
                parts[part] = @intCast(value);
                part += 1;
                value = 0;
                digits = 0;
            },
            else => return null,
        }
    }
    if (digits == 0 or part != 3) return null;
    parts[3] = @intCast(value);
    return parts;
}

fn hexValue(char: u8) ?u16 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// Eight groups, or fewer around one `::`; IPv4's parts may stand for the
/// last two.
fn v6(text: []const u8) ?[16]u8 {
    if (text.len < 2) return null;
    var groups: [8]u16 = @splat(0);
    var count: usize = 0;
    // Where `::` stands: the groups before it.
    var gap: ?usize = null;
    var at: usize = 0;
    if (text[0] == ':') {
        if (text[1] != ':') return null;
        gap = 0;
        at = 2;
    }
    while (at < text.len) {
        if (count == 8) return null;
        const start = at;
        // IPv4's parts for the last 32 bits.
        const rest = text[start..];
        if (for (rest) |char| {
            if (char == ':') break false;
            if (char == '.') break true;
        } else false) {
            if (count > 6) return null;
            const four = v4(rest) orelse return null;
            groups[count] = @as(u16, four[0]) << 8 | four[1];
            groups[count + 1] = @as(u16, four[2]) << 8 | four[3];
            count += 2;
            at = text.len;
            break;
        }
        var value: u16 = 0;
        var digits: usize = 0;
        while (at < text.len and text[at] != ':') : (at += 1) {
            const digit = hexValue(text[at]) orelse return null;
            digits += 1;
            if (digits > 4) return null;
            value = value << 4 | digit;
        }
        if (digits == 0) return null;
        groups[count] = value;
        count += 1;
        if (at == text.len) break;
        // A colon: another group, or `::`.
        at += 1;
        if (at < text.len and text[at] == ':') {
            if (gap != null) return null;
            gap = count;
            at += 1;
        } else if (at == text.len) {
            return null;
        }
    }
    var expanded: [8]u16 = @splat(0);
    if (gap) |before| {
        if (count == 8) return null;
        const after = count - before;
        for (0..before) |index| expanded[index] = groups[index];
        for (0..after) |index| expanded[8 - after + index] = groups[before + index];
    } else {
        if (count != 8) return null;
        expanded = groups;
    }
    var bytes: [16]u8 = undefined;
    for (expanded, 0..) |group, index| {
        bytes[index * 2] = @truncate(group >> 8);
        bytes[index * 2 + 1] = @truncate(group);
    }
    return bytes;
}

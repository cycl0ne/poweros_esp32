// SPDX-License-Identifier: MIT
//! A drawer's name and its neighbours' as text - a volume and the path
//! down from it, `Work:Pictures/Holiday` - the title of a disk's window,
//! and numbers as the default locale writes them. Text only: nothing
//! here asks dos.

const Locale = @import("sdk").locale.Locale;

/// The drawer `path` is in: `Work:Pictures` for `Work:Pictures/Holiday`,
/// `Work:` for `Work:Pictures`; null for a volume's own `Work:`.
pub fn parent(path: []const u8) ?[]const u8 {
    var colon: ?usize = null;
    var slash: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == ':') colon = i;
        if (c == '/') slash = i;
    }
    const after = colon orelse return null;
    if (after + 1 == path.len) return null;
    if (slash) |cut| if (cut > after) return path[0..cut];
    return path[0 .. after + 1];
}

/// `name` in the drawer `path`, written into `into`, NUL after it: its
/// length, or null when it does not fit.
pub fn join(into: []u8, path: []const u8, name: []const u8) ?usize {
    const separator: usize = if (path.len > 0 and path[path.len - 1] != ':') 1 else 0;
    const total = path.len + separator + name.len;
    if (total + 1 > into.len) return null;
    @memcpy(into[0..path.len], path);
    if (separator != 0) into[path.len] = '/';
    @memcpy(into[path.len + separator ..][0..name.len], name);
    into[total] = 0;
    return total;
}

/// The last part of `path`, what its window is called: `Holiday` for
/// `Work:Pictures/Holiday`, `Work` for `Work:`.
pub fn lastPart(path: []const u8) []const u8 {
    var end = path.len;
    if (end > 0 and path[end - 1] == ':') end -= 1;
    var start = end;
    while (start > 0 and path[start - 1] != '/' and path[start - 1] != ':') start -= 1;
    return path[start..end];
}

/// What parts groups of digits and what comes before the decimals, as
/// the default locale writes numbers: `locale`'s, or "," and "." without
/// one.
pub const Separators = struct {
    group: [*:0]const u8 = ",",
    point: [*:0]const u8 = ".",

    pub fn of(locale: ?*const Locale) Separators {
        const known = locale orelse return .{};
        return .{ .group = known.group_separator, .point = known.decimal_point };
    }
};

/// A disk's window title's words, in the language the desktop speaks,
/// and what parts its numbers' thousands; English as built in.
pub const Words = struct {
    full: [*:0]const u8 = "full",
    free: [*:0]const u8 = "free",
    in_use: [*:0]const u8 = "in use",
    group: [*:0]const u8 = ",",
};

/// A disk's window title: its name and how full it is, as "Work  45%
/// full, 1,234K free, 980K in use" - in the units `amount` picks, in
/// `words`. NUL after it, cut to fit; its length.
pub fn diskTitle(into: []u8, name: []const u8, total_blocks: u64, used_blocks: u64, bytes_per_block: u32, words: *const Words) usize {
    var line: [256]u8 = undefined;
    var n: usize = 0;
    n += put(line[n..], name);
    if (total_blocks != 0) {
        const percent = (used_blocks * 100 + total_blocks / 2) / total_blocks;
        const free_bytes = (total_blocks - @min(used_blocks, total_blocks)) * bytes_per_block;
        const used_bytes = used_blocks * bytes_per_block;
        var figure: [32]u8 = undefined;
        n += put(line[n..], "  ");
        n += put(line[n..], figure[0..number(&figure, percent, words.group)]);
        n += put(line[n..], "% ");
        n += put(line[n..], textOf(words.full));
        n += put(line[n..], ", ");
        n += put(line[n..], figure[0..amount(&figure, free_bytes, words.group)]);
        n += put(line[n..], " ");
        n += put(line[n..], textOf(words.free));
        n += put(line[n..], ", ");
        n += put(line[n..], figure[0..amount(&figure, used_bytes, words.group)]);
        n += put(line[n..], " ");
        n += put(line[n..], textOf(words.in_use));
    }
    const length = @min(n, into.len - 1);
    @memcpy(into[0..length], line[0..length]);
    into[length] = 0;
    return length;
}

fn textOf(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}

/// `text` copied, as much of it as there is room for; how much.
fn put(into: []u8, text: []const u8) usize {
    const take = @min(text.len, into.len);
    @memcpy(into[0..take], text[0..take]);
    return take;
}

/// Bytes as K, or as M past 9,999K, G past 9,999M, T past 9,999G and
/// P past 9,999T, each rounded down: never more than four digits but in
/// P, which a u64 holds no more than 16,383 of. No NUL; its length.
pub fn amount(into: []u8, bytes: u64, group: [*:0]const u8) usize {
    const letters = "KMGTP";
    var units = bytes / 1024;
    var unit: usize = 0;
    while (units > 9999 and unit + 1 < letters.len) : (unit += 1) units /= 1024;
    const n = number(into, units, group);
    return n + put(into[n..], letters[unit..][0..1]);
}

/// A number, the thousands parted by `group`; cut at the end of `into`.
pub fn number(into: []u8, value: u64, group: [*:0]const u8) usize {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    const separator = textOf(group);
    var n: usize = 0;
    var i = count;
    while (i > 0) {
        i -= 1;
        n += put(into[n..], digits[i..][0..1]);
        if (i > 0 and i % 3 == 0) n += put(into[n..], separator);
    }
    return n;
}

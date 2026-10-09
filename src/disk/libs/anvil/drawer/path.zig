// SPDX-License-Identifier: MIT
//! A drawer's name and its neighbours' as text - a volume and the path
//! down from it, `Work:Pictures/Holiday` - and the title of a disk's
//! window. Text only: nothing here asks dos.

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

/// A disk's window title: its name and how full it is, as "Work  45%
/// full, 1,234K free, 980K in use" - kilobytes, or megabytes past 9,999K.
/// NUL after it; its length.
pub fn diskTitle(into: []u8, name: []const u8, total_blocks: u64, used_blocks: u64, bytes_per_block: u32) usize {
    var n: usize = 0;
    n += put(into[n..], name);
    if (total_blocks != 0) {
        const percent = (used_blocks * 100 + total_blocks / 2) / total_blocks;
        const free_bytes = (total_blocks - @min(used_blocks, total_blocks)) * bytes_per_block;
        const used_bytes = used_blocks * bytes_per_block;
        n += put(into[n..], "  ");
        n += number(into[n..], percent);
        n += put(into[n..], "% full, ");
        n += amount(into[n..], free_bytes);
        n += put(into[n..], " free, ");
        n += amount(into[n..], used_bytes);
        n += put(into[n..], " in use");
    }
    into[n] = 0;
    return n;
}

fn put(into: []u8, text: []const u8) usize {
    @memcpy(into[0..text.len], text);
    return text.len;
}

/// Bytes as K, or as M past 9,999K.
fn amount(into: []u8, bytes: u64) usize {
    var units = bytes / 1024;
    var letter: u8 = 'K';
    if (units > 9999) {
        units /= 1024;
        letter = 'M';
    }
    const n = number(into, units);
    into[n] = letter;
    return n + 1;
}

/// A number, the thousands parted by commas.
pub fn number(into: []u8, value: u64) usize {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    var n: usize = 0;
    var i = count;
    while (i > 0) {
        i -= 1;
        into[n] = digits[i];
        n += 1;
        if (i > 0 and i % 3 == 0) {
            into[n] = ',';
            n += 1;
        }
    }
    return n;
}

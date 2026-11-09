// SPDX-License-Identifier: MIT
//! `autoboot.txt`: the file a bootloader with a pair of boot partitions
//! reads to pick one, and the only thing that says which of the two a
//! machine starts from. It lies in the first of them, whichever is in
//! use, and holds two sections:
//!
//!     [all]
//!     tryboot_a_b=1
//!     boot_partition=1
//!     [tryboot]
//!     boot_partition=2
//!
//! `[all] boot_partition` is the partition the firmware starts from, and
//! `[tryboot] boot_partition` the one it starts from instead for a single
//! start, when it was reset with the flag for it set (`C:Reboot
//! TRYBOOT`). The flag goes away by itself, so a kernel that does not
//! come up costs one start and the machine is back on the other
//! partition; a system that did come up makes the swap permanent by
//! writing this file with the two numbers the other way round
//! (`swapped`), which is what `C:Update CONFIRM` does.
//!
//! Only that system may: once the swap is made the file names the other
//! partition to try, and it names the new one before the restart and
//! after a try that did not come up as well. So keeping goes by where
//! the firmware says it started this system from (`keeping`), held
//! against the partition being tried.
//!
//! `tryboot_a_b=1` says the tried partition is read as the other one is -
//! its own `config.txt`, and the kernel beside it - rather than from
//! files of another name, which is what makes a pair of partitions
//! holding the same thing enough.
//!
//! Partitions are numbered from 1, as they are in the table. 0 means the
//! firmware's own choice, which is the first partition it can start
//! from, so a file that says nothing and no file at all come to the same
//! thing.
//!
//! The form is a line at a time: a section in brackets, a key and its
//! value, `#` to the end of a line a comment, blanks and empty lines
//! passed over. Nothing here is written for a board whose firmware reads
//! one partition.

/// What the file is called, in the first boot partition.
pub const file_name = "autoboot.txt";

/// The most bytes `write` writes.
pub const max_bytes = 64;

/// What the file says.
pub const Settings = struct {
    /// `[all] boot_partition`: where the firmware starts from. 0 where
    /// the file does not say, which is the firmware's own choice.
    normal: u32 = 0,
    /// `[tryboot] boot_partition`: where it starts from for one start
    /// after a reset with the flag set. 0 where the file does not say.
    tried: u32 = 0,
    /// `[all] tryboot_a_b`: whether the tried partition is read the way
    /// the other one is.
    a_b: bool = false,

    /// The two the other way round, which is the tried partition made
    /// the one the machine starts from.
    pub fn swapped(settings: Settings) Settings {
        return .{ .normal = settings.tried, .tried = settings.normal, .a_b = settings.a_b };
    }
};

/// What keeping the tried partition comes to on this system.
pub const Keeping = enum {
    /// No partition is named to try: there is nothing to keep.
    nothing_tried,
    /// The firmware did not say where it started this system from, so
    /// whether it is the one being tried is not known.
    start_unknown,
    /// This system was started from another partition than the one being
    /// tried - before the restart that tries it, after a try that did not
    /// come up, or after the swap was made: nothing of it is to be kept.
    not_this_one,
    /// This system was started from the partition being tried: keeping
    /// it is the swap.
    this_one,
};

/// What keeping comes to where the file says `settings` and the firmware
/// started this system from the partition `started` (0 where it did not
/// say).
pub fn keeping(settings: Settings, started: u32) Keeping {
    if (settings.tried == 0) return .nothing_tried;
    if (started == 0) return .start_unknown;
    if (started != settings.tried) return .not_this_one;
    return .this_one;
}

/// The file read. A file that is not there at all is `Settings{}`, which
/// says the same as one that names no partition.
pub fn parse(text: []const u8) Settings {
    var settings: Settings = .{};
    var all = false;
    var tried = false;
    var lines = Lines{ .text = text };
    while (lines.next()) |line| {
        const words = trim(cut(line));
        if (words.len == 0) continue;
        if (words[0] == '[') {
            const name = section(words);
            all = same(name, "all");
            tried = same(name, "tryboot");
            continue;
        }
        const pair = keyValue(words) orelse continue;
        if (same(pair.key, "boot_partition")) {
            const which = decimal(pair.value) orelse continue;
            if (all) settings.normal = which;
            if (tried) settings.tried = which;
        } else if (same(pair.key, "tryboot_a_b")) {
            const on = decimal(pair.value) orelse continue;
            if (all) settings.a_b = on != 0;
        }
    }
    return settings;
}

/// The settings as the whole of the file: how many bytes, newline ended.
/// A section is left out where it names no partition, so a board with
/// one is never told about a second.
pub fn write(settings: Settings, into: []u8) usize {
    var at: usize = 0;
    put(into, &at, "[all]\n");
    if (settings.a_b) put(into, &at, "tryboot_a_b=1\n");
    if (settings.normal != 0) {
        put(into, &at, "boot_partition=");
        number(settings.normal, into, &at);
        put(into, &at, "\n");
    }
    if (settings.tried != 0) {
        put(into, &at, "[tryboot]\nboot_partition=");
        number(settings.tried, into, &at);
        put(into, &at, "\n");
    }
    return at;
}

/// A line's text up to a `#`.
fn cut(line: []const u8) []const u8 {
    for (line, 0..) |char, at| {
        if (char == '#') return line[0..at];
    }
    return line;
}

/// A line without the blanks at either end, and without a carriage
/// return a host's editor left on it.
fn trim(line: []const u8) []const u8 {
    var start: usize = 0;
    var end = line.len;
    while (start < end and blank(line[start])) start += 1;
    while (end > start and blank(line[end - 1])) end -= 1;
    return line[start..end];
}

fn blank(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\r';
}

/// A section's name, without its brackets.
fn section(line: []const u8) []const u8 {
    var end: usize = 1;
    while (end < line.len and line[end] != ']') end += 1;
    return line[1..end];
}

/// A `key=value` line, or null.
fn keyValue(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    for (line, 0..) |char, at| {
        if (char != '=') continue;
        return .{ .key = trim(line[0..at]), .value = trim(line[at + 1 ..]) };
    }
    return null;
}

/// Two texts the same, letters as if lower case.
fn same(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| {
        if (lower(a) != lower(b)) return false;
    }
    return true;
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

/// A number, or null where the text is not one.
fn decimal(text: []const u8) ?u32 {
    if (text.len == 0) return null;
    var value: u32 = 0;
    for (text) |char| {
        if (char < '0' or char > '9') return null;
        value = value * 10 + (char - '0');
    }
    return value;
}

fn number(value: u32, into: []u8, at: *usize) void {
    if (value >= 10) number(value / 10, into, at);
    into[at.*] = '0' + @as(u8, @intCast(value % 10));
    at.* += 1;
}

fn put(into: []u8, at: *usize, from: []const u8) void {
    @memcpy(into[at.*..][0..from.len], from);
    at.* += from.len;
}

/// The lines of a text.
const Lines = struct {
    text: []const u8,
    at: usize = 0,

    fn next(lines: *Lines) ?[]const u8 {
        if (lines.at >= lines.text.len) return null;
        var end = lines.at;
        while (end < lines.text.len and lines.text[end] != '\n') end += 1;
        const line = lines.text[lines.at..end];
        lines.at = end + 1;
        return line;
    }
};

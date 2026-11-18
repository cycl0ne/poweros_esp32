// SPDX-License-Identifier: MIT
//! What a file says it is, for the row that says what happens to it: the
//! version of the file on this machine and the version of the package's.
//!
//! **The file here** is read for its compare already, where the two lists
//! differ about it (`system/_system.zig`), and `Scan` finds its "$VER:"
//! string in the same pieces as they go by - so a version costs no read
//! of its own. Where the lists agree the file is not read, and nothing is
//! said about it either.
//!
//! **The package's file** is not read at all: the package says what each
//! of its files is in `versions` (`install.package_versions`), read once
//! beside the list and walked with it - both are in the manifest's order,
//! so one line in hand is enough. A package without one is whole, and its
//! rows carry no package version.
//!
//! **The rule is the build's** (tools/mkpackage): the number of the first
//! "$VER:" string whose name is followed by one, the string ending at a
//! NUL or its line's end and looked at for `install.version_room` bytes -
//! so the two versions are the same kind of text.

const sdk = @import("sdk");
const install = sdk.install;
const manifest = install.manifest;
const prefs = sdk.prefs;

/// A version as text - `1.26`, `40` - empty where there is none.
pub const Text = struct {
    bytes: [install.max_version:0]u8 = @splat(0),

    pub fn cstr(text: *const Text) [*:0]const u8 {
        return @ptrCast(&text.bytes);
    }

    fn set(text: *Text, from: []const u8) void {
        text.* = .{};
        const length = @min(from.len, install.max_version);
        @memcpy(text.bytes[0..length], from[0..length]);
    }
};

const tag = "$VER: ";

/// A file's "$VER:" string looked for in the pieces it is read in: `add`
/// each, `finish` at its end, and `found` is what it says.
pub const Scan = struct {
    found: Text = .{},
    done: bool = false,
    /// How much of the tag the bytes so far end with.
    matched: usize = 0,
    /// Past a tag, gathering the string up to its end.
    inside: bool = false,
    string: [install.version_room]u8 = undefined,
    used: usize = 0,

    pub fn add(scan: *Scan, bytes: []const u8) void {
        if (scan.done) return;
        for (bytes) |c| {
            if (scan.inside) {
                if (c == 0 or c == '\r' or c == '\n') {
                    scan.end();
                    if (scan.done) return;
                } else if (scan.used < scan.string.len) {
                    scan.string[scan.used] = c;
                    scan.used += 1;
                }
                continue;
            }
            if (c == tag[scan.matched]) {
                scan.matched += 1;
                if (scan.matched == tag.len) {
                    scan.matched = 0;
                    scan.inside = true;
                    scan.used = 0;
                }
            } else scan.matched = @intFromBool(c == tag[0]);
        }
    }

    /// The file has ended, and a string that ran to its end with it.
    pub fn finish(scan: *Scan) void {
        if (scan.inside and !scan.done) scan.end();
    }

    fn end(scan: *Scan) void {
        scan.inside = false;
        const number = numberIn(scan.string[0..scan.used]) orelse return;
        scan.found.set(number);
        scan.done = true;
    }
};

/// The number in what follows "$VER: ": the name is every word up to one
/// that begins with a digit, and the number is that word's digits, with
/// a `.` and the digits after it where they follow. Null where no word
/// after the name's first begins with a digit, or the number is longer
/// than `install.max_version`.
pub fn numberIn(text: []const u8) ?[]const u8 {
    var at: usize = 0;
    var first = true;
    while (true) {
        while (at < text.len and text[at] == ' ') at += 1;
        if (at == text.len) return null;
        const start = at;
        while (at < text.len and text[at] != ' ') at += 1;
        const word = text[start..at];
        if (first or !digit(word[0])) {
            first = false;
            continue;
        }
        var end: usize = 0;
        while (end < word.len and digit(word[end])) end += 1;
        if (end + 1 < word.len and word[end] == '.' and digit(word[end + 1])) {
            end += 1;
            while (end < word.len and digit(word[end])) end += 1;
        }
        if (end > install.max_version) return null;
        return word[0..end];
    }
}

fn digit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// The package's `versions`, walked beside its list. Empty - no text -
/// where the package has none.
pub const Versions = struct {
    lines: prefs.Lines = .{ .text = &.{} },
    /// The line in hand, where there is one.
    held: bool = false,
    path: []const u8 = &.{},
    version: []const u8 = &.{},

    pub fn init(text: []const u8) Versions {
        var versions: Versions = .{ .lines = .{ .text = text } };
        versions.step();
        return versions;
    }

    /// What the package's file at `path` says it is, into `into`, empty
    /// where `versions` has no line for it. The paths asked for come in
    /// the manifest's order; a line out of it is passed over.
    pub fn of(versions: *Versions, path: []const u8, into: *Text) void {
        into.* = .{};
        while (versions.held) {
            switch (manifest.orderPaths(versions.path, path)) {
                .before => versions.step(),
                .same => {
                    into.set(versions.version);
                    versions.step();
                    return;
                },
                .after => return,
            }
        }
    }

    /// The next line that is a version and a path.
    fn step(versions: *Versions) void {
        versions.held = false;
        while (versions.lines.next()) |line| {
            var text = line.text;
            while (text.len != 0 and (text[text.len - 1] == '\r' or text[text.len - 1] == ' ')) text = text[0 .. text.len - 1];
            if (text.len == 0 or text[0] == '#') continue;
            var space: usize = 0;
            while (space < text.len and text[space] != ' ') space += 1;
            if (space == text.len or space > install.max_version) continue;
            versions.version = text[0..space];
            versions.path = text[space + 1 ..];
            versions.held = true;
            return;
        }
    }
};

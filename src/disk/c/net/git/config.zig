// SPDX-License-Identifier: MIT
//! A git config file read: `[section]` or `[section "subsection"]`
//! lines, then `key = value` lines under them, `#` or `;` starting a
//! comment. A value may be quoted, and holds the escapes `\"`, `\\`,
//! `\n`, `\t` and `\b`; a `\` at a line's end goes on on the next. A
//! key with no `=` is true. Section and key names are matched without
//! their case, a subsection with it; the last value given wins.
//!
//! The repository's `.git/config` is read, then - for what it does not
//! give - `ENVARC:Sys/net/gitconfig`, which holds the settings every
//! repository shares (the author's name, say).
//!
//! `.git/config` is changed by `edit`: keys of a section - or the whole
//! section - taken out, and new lines put at its end; everything else in
//! it stays as it was written, comments and all.

const _git = @import("_git.zig");
const files = @import("files.zig");
const refs = @import("refs.zig");
const Repository = @import("repo.zig").Repository;
const Git = @import("context.zig").Git;

pub const GLOBAL = "ENVARC:Sys/net/gitconfig";
const config_most = 1024 * 1024;

pub const Config = struct {
    git: *Git,
    /// The repository's file, then the global one.
    texts: [2][]u8 = .{ &.{}, &.{} },

    /// The repository's config and the global one read; a file that is
    /// not there is empty.
    pub fn read(config: *Config, repo: ?*Repository, git: *Git) void {
        config.* = .{ .git = git };
        if (repo) |found| {
            var path: files.Path = undefined;
            if (found.path(&path, &.{"config"})) |name| {
                config.texts[0] = files.readWhole(git, name, config_most) orelse &.{};
            }
        }
        config.texts[1] = files.readWhole(git, GLOBAL, config_most) orelse &.{};
    }

    pub fn free(config: *Config) void {
        for (&config.texts) |*text| {
            if (text.len != 0) config.git.free(text.ptr);
            text.* = &.{};
        }
    }

    /// The value of `section.subsection.key` (no subsection for null),
    /// decoded into `into`: null when it is not set, or longer.
    pub fn get(config: *const Config, section: []const u8, subsection: ?[]const u8, key: []const u8, into: []u8) ?[]u8 {
        for (config.texts) |text| {
            if (lastValue(text, section, subsection, key, into)) |value| return value;
        }
        return null;
    }

    /// Every value of `section.subsection.key` in the repository's file,
    /// in order, each decoded into `into` for the call; false from
    /// `each` stops.
    pub fn each(config: *const Config, section: []const u8, subsection: ?[]const u8, key: []const u8, into: []u8, each_value: ValueFn, each_context: *anyopaque) void {
        _ = forEachValue(config.texts[0], section, subsection, key, into, each_value, each_context);
    }

    /// The subsection of every `[section "subsection"]` header in the
    /// repository's file, in order - one written twice comes twice;
    /// false from `each_name` stops.
    pub fn subsections(config: *const Config, section: []const u8, each_name: ValueFn, each_context: *anyopaque) void {
        const text = config.texts[0];
        var at: usize = 0;
        while (at < text.len) {
            const start = skipBlanks(text, at);
            if (start < text.len and text[start] == '[') {
                if (parseHeader(text, start + 1)) |header| {
                    if (sameNoCase(header.section, section)) {
                        if (header.subsection) |name| {
                            if (!each_name(each_context, name)) return;
                        }
                    }
                }
            }
            at = lineEnd(text, start) + 1;
        }
    }

    /// A boolean value: true, yes, on and 1 are true; `default` when it
    /// is not set.
    pub fn flag(config: *const Config, section: []const u8, subsection: ?[]const u8, key: []const u8, default: bool) bool {
        var value: [16]u8 = undefined;
        const text = config.get(section, subsection, key, &value) orelse return default;
        for ([_][]const u8{ "true", "yes", "on", "1" }) |word| {
            if (sameNoCase(text, word)) return true;
        }
        return false;
    }
};

/// A value found; false stops the search.
pub const ValueFn = *const fn (context: *anyopaque, value: []const u8) bool;

fn lastValue(text: []const u8, section: []const u8, subsection: ?[]const u8, key: []const u8, into: []u8) ?[]u8 {
    var last: Last = .{};
    if (!forEachValue(text, section, subsection, key, into, Last.take, &last)) return null;
    return if (last.length) |length| into[0..length] else null;
}

/// The last value seen: decoded into the same buffer each time, so its
/// length is what is kept.
const Last = struct {
    length: ?usize = null,

    fn take(context: *anyopaque, value: []const u8) bool {
        const last: *Last = @ptrCast(@alignCast(context));
        last.length = value.len;
        return true;
    }
};

/// Each value of `key` handed to `each_value`: false when one did not
/// fit `into`.
fn forEachValue(text: []const u8, section: []const u8, subsection: ?[]const u8, key: []const u8, into: []u8, each_value: ValueFn, each_context: *anyopaque) bool {
    var inside = false;
    var at: usize = 0;
    while (at < text.len) {
        at = skipBlanks(text, at);
        if (at >= text.len) break;
        const char = text[at];
        if (char == '\n') {
            at += 1;
            continue;
        }
        if (char == '#' or char == ';') {
            at = lineEnd(text, at);
            continue;
        }
        if (char == '[') {
            const header = parseHeader(text, at + 1) orelse {
                inside = false;
                at = lineEnd(text, at);
                continue;
            };
            inside = sameNoCase(header.section, section) and sameSubsection(header.subsection, subsection);
            at = header.end;
            continue;
        }
        // A key, and its value.
        var end = at;
        while (end < text.len and (isNameChar(text[end]))) end += 1;
        const name = text[at..end];
        at = skipBlanks(text, end);
        if (!inside or !sameNoCase(name, key)) {
            at = valueEnd(text, at);
            continue;
        }
        if (at >= text.len or text[at] != '=') {
            // No value: true.
            if (into.len < 4) return false;
            @memcpy(into[0..4], "true");
            if (!each_value(each_context, into[0..4])) return true;
            at = valueEnd(text, at);
            continue;
        }
        const value = decodeValue(text, at + 1, into) orelse return false;
        if (!each_value(each_context, value.bytes)) return true;
        at = value.end;
    }
    return true;
}

fn isNameChar(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or (char >= '0' and char <= '9') or char == '-' or char == '.' or char == '_';
}

fn skipBlanks(text: []const u8, from: usize) usize {
    var at = from;
    while (at < text.len and (text[at] == ' ' or text[at] == '\t' or text[at] == '\r')) at += 1;
    return at;
}

fn lineEnd(text: []const u8, from: usize) usize {
    var at = from;
    while (at < text.len and text[at] != '\n') at += 1;
    return at;
}

/// Past a value not wanted: its continued lines and quoted parts too.
fn valueEnd(text: []const u8, from: usize) usize {
    var at = from;
    var quoted = false;
    while (at < text.len) : (at += 1) {
        const char = text[at];
        if (char == '\\' and at + 1 < text.len) {
            at += 1;
            continue;
        }
        if (char == '"') quoted = !quoted;
        if (char == '\n' and !quoted) break;
    }
    return at;
}

const Header = struct { section: []const u8, subsection: ?[]const u8, end: usize };

/// `section]`, `section "subsection"]` or the old `section.subsection]`.
fn parseHeader(text: []const u8, from: usize) ?Header {
    var at = from;
    while (at < text.len and isNameChar(text[at]) and text[at] != '.') at += 1;
    const section = text[from..at];
    if (at < text.len and text[at] == '.') {
        const start = at + 1;
        while (at < text.len and text[at] != ']' and text[at] != '\n') at += 1;
        if (at >= text.len or text[at] != ']') return null;
        return .{ .section = section, .subsection = text[start..at], .end = at + 1 };
    }
    at = skipBlanks(text, at);
    if (at < text.len and text[at] == ']') return .{ .section = section, .subsection = null, .end = at + 1 };
    if (at >= text.len or text[at] != '"') return null;
    const start = at + 1;
    at = start;
    while (at < text.len and text[at] != '"' and text[at] != '\n') : (at += 1) {
        if (text[at] == '\\') at += 1;
    }
    if (at >= text.len or text[at] != '"') return null;
    const subsection = text[start..at];
    at += 1;
    if (at >= text.len or text[at] != ']') return null;
    return .{ .section = section, .subsection = subsection, .end = at + 1 };
}

fn sameSubsection(given: ?[]const u8, wanted: ?[]const u8) bool {
    if (given == null and wanted == null) return true;
    const a = given orelse return false;
    const b = wanted orelse return false;
    return _git.same(a, b);
}

/// A value from after its `=` to its line's end, decoded into `into`.
fn decodeValue(text: []const u8, from: usize, into: []u8) ?struct { bytes: []u8, end: usize } {
    var at = skipBlanks(text, from);
    var length: usize = 0;
    var quoted = false;
    // Blanks outside quotes at the end are not part of the value.
    var kept: usize = 0;
    while (at < text.len) : (at += 1) {
        const char = text[at];
        if (char == '\n' and !quoted) break;
        if (!quoted and (char == '#' or char == ';')) {
            at = lineEnd(text, at);
            break;
        }
        var out = char;
        if (char == '"') {
            quoted = !quoted;
            kept = length;
            continue;
        }
        if (char == '\\') {
            if (at + 1 >= text.len) return null;
            at += 1;
            switch (text[at]) {
                '\n' => continue,
                '\r' => {
                    if (at + 1 < text.len and text[at + 1] == '\n') at += 1;
                    continue;
                },
                'n' => out = '\n',
                't' => out = '\t',
                'b' => {
                    if (length > 0) length -= 1;
                    continue;
                },
                '"', '\\' => out = text[at],
                else => return null,
            }
        }
        if (char == '\r') continue;
        if (length == into.len) return null;
        into[length] = out;
        length += 1;
        if (quoted or (out != ' ' and out != '\t')) kept = length;
    }
    return .{ .bytes = into[0..kept], .end = at };
}

fn sameNoCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lower_x = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const lower_y = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (lower_x != lower_y) return false;
    }
    return true;
}

/// `.git/config` changed: in the section `section.subsection`, the
/// lines of `keys` taken out - all of its lines for no keys - and
/// `append` put at the end. False, said, when it could not be written.
pub fn edit(repo: *Repository, section: []const u8, subsection: ?[]const u8, keys: []const []const u8, append: []const u8) bool {
    const git = repo.git;
    var path: files.Path = undefined;
    const name = repo.path(&path, &.{"config"}) orelse return false;
    const text: []const u8 = files.readWhole(git, name, config_most) orelse &.{};
    defer if (text.len != 0) git.free(text.ptr);
    const memory = git.alloc(text.len + 1) orelse return false;
    defer git.free(memory);
    const kept = without(text, section, subsection, keys, memory[0 .. text.len + 1]);
    return refs.writeFile(repo, "config", &.{ kept, append });
}

/// `text` without the lines of `keys` in `section.subsection` - all of
/// its lines for no keys - into `into`, a byte longer than `text` for
/// the line end its last line may lack. A section left with no key
/// loses its header, and the comments and blank lines in it.
fn without(text: []const u8, section: []const u8, subsection: ?[]const u8, keys: []const []const u8, into: []u8) []u8 {
    var length: usize = 0;
    var inside = false;
    // The edited section's header, held until one of its keys is kept.
    var held: ?[]const u8 = null;
    var at: usize = 0;
    while (at < text.len) {
        const start = at;
        const first = skipBlanks(text, at);
        var end: usize = undefined;
        var keep = true;
        if (first >= text.len or text[first] == '\n' or text[first] == '#' or text[first] == ';') {
            end = lineEnd(text, first);
            keep = !(inside and held != null);
        } else if (text[first] == '[') {
            end = lineEnd(text, first);
            inside = if (parseHeader(text, first + 1)) |header| sameNoCase(header.section, section) and sameSubsection(header.subsection, subsection) else false;
            held = null;
            if (inside) {
                held = text[start..@min(end + 1, text.len)];
                keep = false;
            }
        } else {
            var name_end = first;
            while (name_end < text.len and isNameChar(text[name_end])) name_end += 1;
            end = valueEnd(text, name_end);
            if (inside) {
                if (keys.len == 0 or listed(text[first..name_end], keys)) {
                    keep = false;
                } else if (held) |header| {
                    @memcpy(into[length..][0..header.len], header);
                    length += header.len;
                    held = null;
                }
            }
        }
        const stop = @min(end + 1, text.len);
        if (keep) {
            @memcpy(into[length..][0 .. stop - start], text[start..stop]);
            length += stop - start;
        }
        at = stop;
    }
    if (length > 0 and into[length - 1] != '\n') {
        into[length] = '\n';
        length += 1;
    }
    return into[0..length];
}

fn listed(name: []const u8, keys: []const []const u8) bool {
    for (keys) |key| {
        if (sameNoCase(name, key)) return true;
    }
    return false;
}

/// `value` as a config value: in quotes when a comment character or a
/// blank at an end would take some of it away, `"` and `\` escaped.
pub fn putValue(out: *_git.Out, value: []const u8) void {
    var quote = value.len > 0 and (value[0] == ' ' or value[0] == '\t' or value[value.len - 1] == ' ' or value[value.len - 1] == '\t');
    for (value) |char| {
        if (char == '#' or char == ';') quote = true;
    }
    if (quote) out.byte('"');
    for (value) |char| {
        if (char == '"' or char == '\\') out.byte('\\');
        out.byte(char);
    }
    if (quote) out.byte('"');
}

// --- tests (host) ------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "config values: sections, subsections, quotes, escapes, the last one winning" {
    const text =
        \\# a comment
        \\[core]
        \\    filemode = false
        \\    bare
        \\[remote "origin"]
        \\    url = https://example.org/x.git ; a comment
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\[Branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
        \\[user]
        \\    name = "Ann \"A\" Tester"
        \\    email = ann@example.org
        \\    note = one \
        \\two
        \\[core]
        \\    FileMode = true
        \\[old.Sub]
        \\    key = value
        \\
    ;
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("true", lastValue(text, "core", null, "filemode", &buffer).?);
    try testing.expectEqualStrings("true", lastValue(text, "core", null, "bare", &buffer).?);
    try testing.expectEqualStrings("https://example.org/x.git", lastValue(text, "remote", "origin", "url", &buffer).?);
    try testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", lastValue(text, "remote", "origin", "fetch", &buffer).?);
    try testing.expectEqualStrings("refs/heads/main", lastValue(text, "branch", "main", "merge", &buffer).?);
    try testing.expect(lastValue(text, "branch", "Main", "merge", &buffer) == null);
    try testing.expectEqualStrings("Ann \"A\" Tester", lastValue(text, "user", null, "name", &buffer).?);
    try testing.expectEqualStrings("one two", lastValue(text, "user", null, "note", &buffer).?);
    try testing.expectEqualStrings("value", lastValue(text, "old", "Sub", "key", &buffer).?);
    try testing.expect(lastValue(text, "remote", null, "url", &buffer) == null);
    try testing.expect(lastValue(text, "core", null, "missing", &buffer) == null);
    var small: [4]u8 = undefined;
    try testing.expect(lastValue(text, "remote", "origin", "url", &small) == null);
}

test "config edited: a section taken out with its comments, keys of one, a header left with none" {
    const text =
        "[core]\n" ++
        "\tbare = false\n" ++
        "[remote \"origin\"]\n" ++
        "\turl = https://example.org/x.git\n" ++
        "\tfetch = +refs/heads/*:refs/remotes/origin/*\n" ++
        "# the branch\n" ++
        "[branch \"main\"]\n" ++
        "\tremote = origin\n" ++
        "\tmerge = refs/heads/main\n" ++
        "\trebase = true\n" ++
        "[remote \"other\"]\n" ++
        "\turl = \"one \\\n" ++
        "two\"";
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "[core]\n\tbare = false\n[branch \"main\"]\n\tremote = origin\n\tmerge = refs/heads/main\n\trebase = true\n[remote \"other\"]\n\turl = \"one \\\ntwo\"\n",
        without(text, "remote", "origin", &.{}, &buffer),
    );
    try testing.expectEqualStrings(
        "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = https://example.org/x.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n# the branch\n[branch \"main\"]\n\trebase = true\n[remote \"other\"]\n\turl = \"one \\\ntwo\"\n",
        without(text, "branch", "main", &.{ "remote", "Merge" }, &buffer),
    );
    const edited = without(text, "branch", "main", &.{ "remote", "merge", "rebase" }, &buffer);
    try testing.expect(std.mem.indexOf(u8, edited, "[branch") == null);
    try testing.expectEqualStrings("one two", lastValue(edited, "remote", "other", "url", buffer[edited.len..]).?);
    // A key continued over two lines goes whole.
    const gone = without(text, "remote", "other", &.{"url"}, &buffer);
    try testing.expect(std.mem.indexOf(u8, gone, "two") == null);

    var value: [64]u8 = undefined;
    var out: _git.Out = .{ .into = &value };
    putValue(&out, "https://h/a#b");
    try testing.expectEqualStrings("\"https://h/a#b\"", out.written());
    out = .{ .into = &value };
    putValue(&out, "C:\\x\"y");
    try testing.expectEqualStrings("C:\\\\x\\\"y", out.written());
}

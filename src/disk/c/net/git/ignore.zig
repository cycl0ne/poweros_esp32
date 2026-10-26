// SPDX-License-Identifier: MIT
//! What git ignores: the patterns of `.gitignore` files and of
//! `.git/info/exclude`, matched as git's wildmatch matches them.
//!
//! A line is a pattern; an empty one, or one starting with `#`, is none.
//! `!` before it lets in again what an earlier pattern left out; `/` at
//! its end matches only a directory. A pattern with a `/` in it (other
//! than at its end) is matched against the whole path from the
//! directory of its file - a leading `/` only says so - one without
//! against the last name of the path alone. `*` matches any run of
//! characters but `/`, `?` one, `[a-z]` one of a set (`[!...]` one not
//! in it); `**` as a whole name matches any run of directories, none
//! too. `\` takes the next character as it is. Case is not counted,
//! since a dos volume does not count it.
//!
//! A deeper `.gitignore` overrides one above it, a later line an
//! earlier one; `.git/info/exclude` is overridden by all of them. What
//! is in a directory left out is left out as well - it is not looked at.

const _git = @import("_git.zig");
const files = @import("files.zig");
const context = @import("context.zig");
const Git = context.Git;

/// How many directories deep `.gitignore` files are read.
pub const depth_most = 64;
const file_most = 1024 * 1024;

pub const Rule = struct {
    pattern: []const u8,
    negate: bool,
    dir_only: bool,
    /// Matched against the last name of a path only.
    basename: bool,
};

/// The rules of one file, and the directory they are for (`docs/`, or
/// empty for the top).
pub const RuleSet = struct {
    base: []const u8,
    rules: []Rule,
};

/// The rule sets in effect: `.git/info/exclude` at the bottom, then a
/// `.gitignore` for each directory on the way down.
pub const Ignores = struct {
    sets: [depth_most + 1]RuleSet = undefined,
    count: usize = 0,

    /// The rules of the file at `path` - for the directory `base` - put
    /// on top, or none when there is none. Their text is kept in
    /// `arena`.
    pub fn push(ignores: *Ignores, git: *Git, arena: *context.Arena, path: [*:0]const u8, base: []const u8) bool {
        if (ignores.count == ignores.sets.len) return false;
        var rules: []Rule = &.{};
        if (files.readWhole(git, path, file_most)) |text| {
            defer git.free(text.ptr);
            rules = parse(arena, text) orelse &.{};
        }
        const kept_base = arena.copy(base) orelse return false;
        ignores.sets[ignores.count] = .{ .base = kept_base, .rules = rules };
        ignores.count += 1;
        return true;
    }

    pub fn pop(ignores: *Ignores) void {
        if (ignores.count > 0) ignores.count -= 1;
    }

    /// Whether `path` (a directory when `directory`) is ignored.
    pub fn ignored(ignores: *const Ignores, path: []const u8, directory: bool) bool {
        var set_number = ignores.count;
        while (set_number > 0) {
            set_number -= 1;
            const set = &ignores.sets[set_number];
            var rule_number = set.rules.len;
            while (rule_number > 0) {
                rule_number -= 1;
                if (matches(&set.rules[rule_number], set.base, path, directory)) return !set.rules[rule_number].negate;
            }
        }
        return false;
    }
};

/// The rules of a file's `text`, copied into `arena`.
pub fn parse(arena: *context.Arena, text: []const u8) ?[]Rule {
    var count: usize = 0;
    var lines = lineIterator(text);
    while (lines.next()) |line| {
        if (ruleOf(line) != null) count += 1;
    }
    const memory = arena.take(@sizeOf(Rule) * (count + 1), @alignOf(Rule)) orelse return null;
    const rules = @as([*]Rule, @ptrCast(@alignCast(memory)))[0..count];
    count = 0;
    lines = lineIterator(text);
    while (lines.next()) |line| {
        var rule = ruleOf(line) orelse continue;
        rule.pattern = arena.copy(rule.pattern) orelse return null;
        rules[count] = rule;
        count += 1;
    }
    return rules;
}

const LineIterator = struct {
    text: []const u8,
    at: usize = 0,

    fn next(lines: *LineIterator) ?[]const u8 {
        if (lines.at >= lines.text.len) return null;
        var end = lines.at;
        while (end < lines.text.len and lines.text[end] != '\n') end += 1;
        const line = lines.text[lines.at..end];
        lines.at = end + 1;
        return line;
    }
};

fn lineIterator(text: []const u8) LineIterator {
    return .{ .text = text };
}

/// A line's rule; null for an empty line or a comment.
pub fn ruleOf(given: []const u8) ?Rule {
    var line = given;
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    // Trailing blanks go, unless the last is escaped.
    while (line.len > 0 and line[line.len - 1] == ' ') {
        if (line.len >= 2 and line[line.len - 2] == '\\') break;
        line = line[0 .. line.len - 1];
    }
    if (line.len == 0 or line[0] == '#') return null;
    var rule: Rule = .{ .pattern = line, .negate = false, .dir_only = false, .basename = true };
    if (rule.pattern[0] == '!') {
        rule.negate = true;
        rule.pattern = rule.pattern[1..];
    }
    if (rule.pattern.len > 0 and rule.pattern[rule.pattern.len - 1] == '/') {
        rule.dir_only = true;
        rule.pattern = rule.pattern[0 .. rule.pattern.len - 1];
    }
    for (rule.pattern) |char| {
        if (char == '/') rule.basename = false;
    }
    if (rule.pattern.len > 0 and rule.pattern[0] == '/') rule.pattern = rule.pattern[1..];
    if (rule.pattern.len == 0) return null;
    return rule;
}

/// Whether `rule`, of the file in `base`, matches `path` - one in
/// that directory, or below it.
pub fn matches(rule: *const Rule, base: []const u8, path: []const u8, directory: bool) bool {
    if (rule.dir_only and !directory) return false;
    if (!_git.startsWith(path, base)) return false;
    if (rule.basename) {
        var start = path.len;
        while (start > 0 and path[start - 1] != '/') start -= 1;
        return wildmatch(rule.pattern, path[start..], false);
    }
    return wildmatch(rule.pattern, path[base.len..], true);
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

/// Whether `text` matches `pattern`; with `pathname`, `*`, `?` and a set
/// match no `/`, and `**` as a whole name matches directories.
pub fn wildmatch(pattern: []const u8, text: []const u8, pathname: bool) bool {
    var pattern_at: usize = 0;
    var text_at: usize = 0;
    while (pattern_at < pattern.len) {
        const char = pattern[pattern_at];
        switch (char) {
            '?' => {
                if (text_at >= text.len or (pathname and text[text_at] == '/')) return false;
                pattern_at += 1;
                text_at += 1;
            },
            '*' => {
                const start = pattern_at;
                while (pattern_at < pattern.len and pattern[pattern_at] == '*') pattern_at += 1;
                const double = pattern_at - start >= 2;
                const whole_name = (start == 0 or pattern[start - 1] == '/') and (pattern_at == pattern.len or pattern[pattern_at] == '/');
                if (double and pathname and whole_name) {
                    if (pattern_at == pattern.len) return true;
                    // `**/`: no directory, or any run of them.
                    const rest = pattern[pattern_at + 1 ..];
                    if (wildmatch(rest, text[text_at..], true)) return true;
                    var at = text_at;
                    while (at < text.len) : (at += 1) {
                        if (text[at] == '/' and wildmatch(rest, text[at + 1 ..], true)) return true;
                    }
                    return false;
                }
                const rest = pattern[pattern_at..];
                if (rest.len == 0) {
                    if (!pathname) return true;
                    for (text[text_at..]) |each| {
                        if (each == '/') return false;
                    }
                    return true;
                }
                var at = text_at;
                while (at <= text.len) : (at += 1) {
                    if (wildmatch(rest, text[at..], pathname)) return true;
                    if (at < text.len and pathname and text[at] == '/') return false;
                }
                return false;
            },
            '[' => {
                if (text_at >= text.len or (pathname and text[text_at] == '/')) return false;
                const set = matchSet(pattern[pattern_at + 1 ..], text[text_at]) orelse return false;
                if (!set.matched) return false;
                pattern_at += 1 + set.length;
                text_at += 1;
            },
            else => {
                var literal = char;
                if (char == '\\' and pattern_at + 1 < pattern.len) {
                    pattern_at += 1;
                    literal = pattern[pattern_at];
                }
                if (text_at >= text.len or lower(text[text_at]) != lower(literal)) return false;
                pattern_at += 1;
                text_at += 1;
            },
        }
    }
    return text_at == text.len;
}

const SetMatch = struct { matched: bool, length: usize };

/// A set after its `[`: whether `char` is in it, and how long it is to
/// its `]`, which it includes; null when it has none.
fn matchSet(set: []const u8, char: u8) ?SetMatch {
    var at: usize = 0;
    var negate = false;
    if (at < set.len and (set[at] == '!' or set[at] == '^')) {
        negate = true;
        at += 1;
    }
    var found = false;
    var first = true;
    while (at < set.len) {
        if (set[at] == ']' and !first) {
            return .{ .matched = found != negate, .length = at + 1 };
        }
        first = false;
        if (set[at] == '[' and at + 1 < set.len and set[at + 1] == ':') {
            const close = indexOf(set[at + 2 ..], ":]") orelse return null;
            const name = set[at + 2 ..][0..close];
            if (inClass(name, char)) found = true;
            at += 2 + close + 2;
            continue;
        }
        var low = set[at];
        if (low == '\\' and at + 1 < set.len) {
            at += 1;
            low = set[at];
        }
        at += 1;
        var high = low;
        if (at + 1 < set.len and set[at] == '-' and set[at + 1] != ']') {
            high = set[at + 1];
            if (high == '\\' and at + 2 < set.len) {
                high = set[at + 2];
                at += 1;
            }
            at += 2;
        }
        const folded = lower(char);
        if ((char >= low and char <= high) or (folded >= lower(low) and folded <= lower(high))) found = true;
    }
    return null;
}

fn indexOf(text: []const u8, needle: []const u8) ?usize {
    if (text.len < needle.len) return null;
    var at: usize = 0;
    while (at + needle.len <= text.len) : (at += 1) {
        if (_git.same(text[at..][0..needle.len], needle)) return at;
    }
    return null;
}

fn inClass(name: []const u8, char: u8) bool {
    const alpha = (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
    const digit = char >= '0' and char <= '9';
    if (_git.same(name, "alpha")) return alpha;
    if (_git.same(name, "digit")) return digit;
    if (_git.same(name, "alnum")) return alpha or digit;
    if (_git.same(name, "lower")) return char >= 'a' and char <= 'z';
    if (_git.same(name, "upper")) return char >= 'A' and char <= 'Z';
    if (_git.same(name, "space")) return char == ' ' or (char >= '\t' and char <= '\r');
    if (_git.same(name, "xdigit")) return digit or (lower(char) >= 'a' and lower(char) <= 'f');
    if (_git.same(name, "punct")) return char > ' ' and char < 0x7F and !alpha and !digit;
    return false;
}

// --- tests (host) ------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "wildmatch as git matches" {
    const cases = [_]struct { pattern: []const u8, text: []const u8, pathname: bool, want: bool }{
        .{ .pattern = "*.o", .text = "main.o", .pathname = false, .want = true },
        .{ .pattern = "*.o", .text = "main.c", .pathname = false, .want = false },
        .{ .pattern = "*.O", .text = "main.o", .pathname = false, .want = true },
        .{ .pattern = "a?c", .text = "abc", .pathname = true, .want = true },
        .{ .pattern = "a?c", .text = "a/c", .pathname = true, .want = false },
        .{ .pattern = "a*", .text = "a/b", .pathname = true, .want = false },
        .{ .pattern = "a*", .text = "a/b", .pathname = false, .want = true },
        .{ .pattern = "doc/*.txt", .text = "doc/a.txt", .pathname = true, .want = true },
        .{ .pattern = "doc/*.txt", .text = "doc/x/a.txt", .pathname = true, .want = false },
        .{ .pattern = "**/foo", .text = "foo", .pathname = true, .want = true },
        .{ .pattern = "**/foo", .text = "a/b/foo", .pathname = true, .want = true },
        .{ .pattern = "a/**/b", .text = "a/b", .pathname = true, .want = true },
        .{ .pattern = "a/**/b", .text = "a/x/y/b", .pathname = true, .want = true },
        .{ .pattern = "a/**", .text = "a/x/y", .pathname = true, .want = true },
        .{ .pattern = "a/**", .text = "b/x", .pathname = true, .want = false },
        .{ .pattern = "[a-c]x", .text = "bx", .pathname = true, .want = true },
        .{ .pattern = "[!a-c]x", .text = "bx", .pathname = true, .want = false },
        .{ .pattern = "[!a-c]x", .text = "dx", .pathname = true, .want = true },
        .{ .pattern = "[[:digit:]]*", .text = "7up", .pathname = true, .want = true },
        .{ .pattern = "[]]", .text = "]", .pathname = true, .want = true },
        .{ .pattern = "\\*", .text = "*", .pathname = true, .want = true },
        .{ .pattern = "\\*", .text = "x", .pathname = true, .want = false },
        .{ .pattern = "zig-*", .text = "zig-out", .pathname = false, .want = true },
    };
    for (cases) |case| {
        testing.expectEqual(case.want, wildmatch(case.pattern, case.text, case.pathname)) catch |err| {
            std.debug.print("{s} against {s}\n", .{ case.pattern, case.text });
            return err;
        };
    }
}

test "gitignore rules, deeper and later winning" {
    try testing.expect(ruleOf("# comment") == null);
    try testing.expect(ruleOf("   ") == null);
    const dir_rule = ruleOf("build/").?;
    try testing.expect(dir_rule.dir_only and dir_rule.basename);
    try testing.expectEqualStrings("build", dir_rule.pattern);
    const anchored = ruleOf("/top.txt").?;
    try testing.expect(!anchored.basename);
    try testing.expectEqualStrings("top.txt", anchored.pattern);
    const negated = ruleOf("!keep.o\r").?;
    try testing.expect(negated.negate);
    try testing.expectEqualStrings("keep.o", negated.pattern);

    var top_rules = [_]Rule{ ruleOf("*.o").?, ruleOf("build/").?, ruleOf("/top.txt").? };
    var doc_rules = [_]Rule{ ruleOf("!keep.o").?, ruleOf("sub/*.tmp").? };
    var ignores: Ignores = .{};
    ignores.sets[0] = .{ .base = "", .rules = &top_rules };
    ignores.sets[1] = .{ .base = "doc/", .rules = &doc_rules };
    ignores.count = 2;
    try testing.expect(ignores.ignored("main.o", false));
    try testing.expect(ignores.ignored("doc/main.o", false));
    try testing.expect(!ignores.ignored("doc/keep.o", false));
    try testing.expect(ignores.ignored("keep.o", false) == true);
    try testing.expect(ignores.ignored("build", true));
    try testing.expect(!ignores.ignored("build", false));
    try testing.expect(ignores.ignored("top.txt", false));
    try testing.expect(!ignores.ignored("doc/top.txt", false));
    try testing.expect(ignores.ignored("doc/sub/x.tmp", false));
    try testing.expect(!ignores.ignored("sub/x.tmp", false));
}

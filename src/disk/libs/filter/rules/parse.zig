// SPDX-License-Identifier: MIT
//! The rules' text into a rule set (the language is sdk.filter's). Words
//! are split at spaces and tabs, `#` begins a comment, keywords are taken
//! in either case and interface names in lower case. A line is a rule or
//! a default, or nothing; the first word that does not fit stops the
//! parse, with its line, column and text.

const sdk = @import("sdk");
const filter = sdk.filter;
const bsd = sdk.bsdsocket;
const _rules = @import("_rules.zig");
const Rule = _rules.Rule;
const Default = _rules.Default;
const RuleSet = _rules.RuleSet;
const End = _rules.End;
const Action = _rules.Action;
const address = @import("address.zig");

/// How many lines `text` has: room enough for its rules and defaults.
pub fn lines(text: []const u8) u32 {
    var count: u32 = 1;
    for (text) |char| {
        if (char == '\n') count += 1;
    }
    return count;
}

/// `text` parsed into `set`, which has room for a rule and a default per
/// line: FILTERERR_OK, or why not and where in `err`.
pub fn parse(text: []const u8, set: *RuleSet, err: *filter.FilterError) u32 {
    var number: u32 = 0;
    var start: usize = 0;
    while (start <= text.len) {
        var end = start;
        while (end < text.len and text[end] != '\n') end += 1;
        number += 1;
        const code = line(text[start..end], number, set, err);
        if (code != filter.FILTERERR_OK) return code;
        start = end + 1;
    }
    return filter.FILTERERR_OK;
}

/// The words of a line, each with its column.
const Words = struct {
    text: []const u8,
    at: usize = 0,

    const Word = struct { text: []const u8, column: usize };

    fn next(words: *Words) ?Word {
        while (words.at < words.text.len and isSpace(words.text[words.at])) words.at += 1;
        if (words.at >= words.text.len) return null;
        const start = words.at;
        while (words.at < words.text.len and !isSpace(words.text[words.at])) words.at += 1;
        return .{ .text = words.text[start..words.at], .column = start + 1 };
    }

    fn peek(words: *Words) ?Word {
        const saved = words.at;
        defer words.at = saved;
        return words.next();
    }
};

fn isSpace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\r';
}

/// A line's text without its comment and the spaces around it.
fn content(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len and text[end] != '#') end += 1;
    var start: usize = 0;
    while (start < end and isSpace(text[start])) start += 1;
    while (end > start and isSpace(text[end - 1])) end -= 1;
    return text[start..end];
}

/// Whether `word` is `keyword`, case aside.
fn is(word: []const u8, keyword: []const u8) bool {
    if (word.len != keyword.len) return false;
    for (word, keyword) |got, want| {
        const lower = if (got >= 'A' and got <= 'Z') got + 32 else got;
        if (lower != want) return false;
    }
    return true;
}

/// The parse stopped at `word`: `code`, with where.
fn fail(err: *filter.FilterError, code: u32, number: u32, word: ?Words.Word) u32 {
    err.* = .{ .code = code, .line = number };
    if (word) |found| {
        err.column = @intCast(found.column);
        const length = @min(found.text.len, err.word.len - 1);
        @memcpy(err.word[0..length], found.text[0..length]);
    }
    return code;
}

fn action(word: []const u8) ?Action {
    if (is(word, "pass")) return .pass;
    if (is(word, "block")) return .block;
    if (is(word, "refuse")) return .refuse;
    return null;
}

/// An interface's name, in lower case, into `into`: false when too long.
fn name(word: []const u8, into: *[bsd.IFNAMSIZ]u8) bool {
    if (word.len >= into.len) return false;
    into.* = @splat(0);
    for (word, 0..) |char, index| into[index] = if (char >= 'A' and char <= 'Z') char + 32 else char;
    return true;
}

fn keepText(into: *[filter.FILTER_TEXT_MAX]u8, text: []const u8) void {
    const length = @min(text.len, into.len - 1);
    @memcpy(into[0..length], text[0..length]);
}

fn line(raw: []const u8, number: u32, set: *RuleSet, err: *filter.FilterError) u32 {
    const text = content(raw);
    var words = Words{ .text = text };
    const first = words.next() orelse return filter.FILTERERR_OK;
    if (is(first.text, "default")) return defaultLine(&words, text, number, set, err);
    const what = action(first.text) orelse return fail(err, filter.FILTERERR_SYNTAX, number, first);
    const direction = words.next() orelse return fail(err, filter.FILTERERR_SYNTAX, number, null);
    if (!is(direction.text, "in")) return fail(err, filter.FILTERERR_SYNTAX, number, direction);
    const rule = set.addRule() orelse return fail(err, filter.FILTERERR_NOMEM, number, first);
    rule.action = what;
    rule.line = number;
    keepText(&rule.text, text);
    var seen: u32 = 0;
    while (words.next()) |word| {
        const option = optionOf(word.text) orelse return fail(err, filter.FILTERERR_SYNTAX, number, word);
        const bit = @as(u32, 1) << @intFromEnum(option);
        if (seen & bit != 0) return fail(err, filter.FILTERERR_TWICE, number, word);
        seen |= bit;
        switch (option) {
            .all => {},
            .on => {
                const interface = words.next() orelse return fail(err, filter.FILTERERR_SYNTAX, number, word);
                if (!name(interface.text, &rule.interface)) return fail(err, filter.FILTERERR_SYNTAX, number, interface);
            },
            .inet, .inet6 => {
                if (seen & (@as(u32, 1) << @intFromEnum(Option.inet)) != 0 and seen & (@as(u32, 1) << @intFromEnum(Option.inet6)) != 0) {
                    return fail(err, filter.FILTERERR_TWICE, number, word);
                }
                rule.family = if (option == .inet) bsd.AF_INET else bsd.AF_INET6;
            },
            .proto => {
                const protocol = words.next() orelse return fail(err, filter.FILTERERR_SYNTAX, number, word);
                rule.protocol = protocolOf(protocol.text) orelse return fail(err, filter.FILTERERR_SYNTAX, number, protocol);
            },
            .from, .to => {
                const end = if (option == .from) &rule.from else &rule.to;
                if (!takeEnd(&words, end, &rule.ports)) {
                    const bad = words.peek();
                    return fail(err, filter.FILTERERR_SYNTAX, number, bad orelse word);
                }
            },
            .type => {
                const kind = words.next() orelse return fail(err, filter.FILTERERR_SYNTAX, number, word);
                if (is(kind.text, "echo")) {
                    rule.type_match = .echo;
                } else if (is(kind.text, "echo-reply")) {
                    rule.type_match = .echo_reply;
                } else {
                    rule.type_number = @intCast(decimal(kind.text, 255) orelse return fail(err, filter.FILTERERR_SYNTAX, number, kind));
                    rule.type_match = .number;
                }
            },
            .flags => {
                const flags = words.next() orelse return fail(err, filter.FILTERERR_SYNTAX, number, word);
                if (!is(flags.text, "s")) return fail(err, filter.FILTERERR_SYNTAX, number, flags);
                rule.syn_only = 1;
            },
        }
    }
    // What the matches take of each other: a port is TCP's and UDP's, a
    // type ICMP's, flags TCP's.
    const tcp: u8 = @intCast(bsd.IPPROTO_TCP);
    const udp: u8 = @intCast(bsd.IPPROTO_UDP);
    const icmp: u8 = @intCast(bsd.IPPROTO_ICMP);
    const icmp6: u8 = @intCast(bsd.IPPROTO_ICMPV6);
    if (rule.ports != 0 and rule.protocol != 0 and rule.protocol != tcp and rule.protocol != udp) return fail(err, filter.FILTERERR_SYNTAX, number, null);
    if (rule.type_match != .any and rule.protocol != 0 and rule.protocol != icmp and rule.protocol != icmp6) return fail(err, filter.FILTERERR_SYNTAX, number, null);
    if (rule.syn_only != 0) {
        if (rule.protocol != 0 and rule.protocol != tcp) return fail(err, filter.FILTERERR_SYNTAX, number, null);
        rule.protocol = tcp;
    }
    if (rule.ports != 0 and rule.type_match != .any) return fail(err, filter.FILTERERR_SYNTAX, number, null);
    // An address of one family makes the rule that family's.
    for ([_]*const End{ &rule.from, &rule.to }) |end| {
        if (end.family == 0) continue;
        if (rule.family != 0 and rule.family != end.family) return fail(err, filter.FILTERERR_SYNTAX, number, null);
        rule.family = end.family;
    }
    if (rule.protocol == icmp and rule.family == bsd.AF_INET6) return fail(err, filter.FILTERERR_SYNTAX, number, null);
    if (rule.protocol == icmp6 and rule.family == bsd.AF_INET) return fail(err, filter.FILTERERR_SYNTAX, number, null);
    return filter.FILTERERR_OK;
}

fn defaultLine(words: *Words, text: []const u8, number: u32, set: *RuleSet, err: *filter.FilterError) u32 {
    const direction = words.next() orelse return fail(err, filter.FILTERERR_SYNTAX, number, null);
    if (!is(direction.text, "in")) return fail(err, filter.FILTERERR_SYNTAX, number, direction);
    var interface: [bsd.IFNAMSIZ]u8 = @splat(0);
    var word = words.next() orelse return fail(err, filter.FILTERERR_SYNTAX, number, null);
    if (is(word.text, "on")) {
        const named = words.next() orelse return fail(err, filter.FILTERERR_SYNTAX, number, word);
        if (!name(named.text, &interface)) return fail(err, filter.FILTERERR_SYNTAX, number, named);
        word = words.next() orelse return fail(err, filter.FILTERERR_SYNTAX, number, null);
    }
    const what = action(word.text) orelse return fail(err, filter.FILTERERR_SYNTAX, number, word);
    if (words.next()) |extra| return fail(err, filter.FILTERERR_SYNTAX, number, extra);
    for (set.defaults()) |*other| {
        if (_rules.sameName(&other.interface, &interface)) return fail(err, filter.FILTERERR_TWICE, number, word);
    }
    const made = set.addDefault() orelse return fail(err, filter.FILTERERR_NOMEM, number, word);
    made.* = .{ .action = what, .interface = interface, .line = number };
    keepText(&made.text, text);
    return filter.FILTERERR_OK;
}

const Option = enum(u5) { all, on, inet, inet6, proto, from, to, type, flags };

fn optionOf(word: []const u8) ?Option {
    inline for (@typeInfo(Option).@"enum".fields) |field| {
        if (is(word, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn protocolOf(word: []const u8) ?u8 {
    if (is(word, "tcp")) return @intCast(bsd.IPPROTO_TCP);
    if (is(word, "udp")) return @intCast(bsd.IPPROTO_UDP);
    if (is(word, "icmp")) return @intCast(bsd.IPPROTO_ICMP);
    if (is(word, "icmp6")) return @intCast(bsd.IPPROTO_ICMPV6);
    return null;
}

/// After `from` or `to`: `any`, an address with a prefix length, or
/// neither; then maybe `port n` or `port n-m`. False when what follows
/// is none of these.
fn takeEnd(words: *Words, end: *End, ports: *u8) bool {
    var word = words.peek() orelse return false;
    if (is(word.text, "any")) {
        _ = words.next();
    } else if (!is(word.text, "port")) {
        if (!net(word.text, end)) return false;
        _ = words.next();
    }
    word = words.peek() orelse return true;
    if (!is(word.text, "port")) return true;
    _ = words.next();
    const range = words.peek() orelse return false;
    if (!portRange(range.text, end)) return false;
    _ = words.next();
    ports.* = 1;
    return true;
}

/// An address, maybe with `/length`.
fn net(text: []const u8, end: *End) bool {
    var length_at: ?usize = null;
    for (text, 0..) |char, index| {
        if (char == '/') length_at = index;
    }
    const address_text = if (length_at) |slash| text[0..slash] else text;
    const parsed = address.parse(address_text) orelse return false;
    const most: u32 = if (parsed.family == bsd.AF_INET) 32 else 128;
    const given: u32 = if (length_at) |slash| (decimal(text[slash + 1 ..], most) orelse return false) else most;
    end.bytes = parsed.bytes;
    end.family = parsed.family;
    end.prefix = @intCast(if (parsed.family == bsd.AF_INET) given + 96 else given);
    // Bits past the prefix count for nothing: cleared, so two rules that
    // say the same net look the same.
    var bit: u32 = end.prefix;
    while (bit < 128) : (bit += 1) end.bytes[bit / 8] &= ~(@as(u8, 0x80) >> @intCast(bit % 8));
    return true;
}

fn portRange(text: []const u8, end: *End) bool {
    var dash: ?usize = null;
    for (text, 0..) |char, index| {
        if (char == '-') dash = index;
    }
    if (dash) |at| {
        const low = decimal(text[0..at], 65535) orelse return false;
        const high = decimal(text[at + 1 ..], 65535) orelse return false;
        if (low > high) return false;
        end.low_port = @intCast(low);
        end.high_port = @intCast(high);
    } else {
        const port = decimal(text, 65535) orelse return false;
        end.low_port = @intCast(port);
        end.high_port = @intCast(port);
    }
    return true;
}

/// `text` as a decimal number no greater than `most`.
fn decimal(text: []const u8, most: u32) ?u32 {
    if (text.len == 0 or text.len > 5) return null;
    var value: u32 = 0;
    for (text) |char| {
        if (char < '0' or char > '9') return null;
        value = value * 10 + (char - '0');
    }
    if (value > most) return null;
    return value;
}

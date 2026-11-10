// SPDX-License-Identifier: MIT
//! The CSS of an SVG file's `style` elements: its rules, each selector
//! of a group its own, and which elements they are for.
//!
//! A selector is one element's: its type or `*`, then any number of
//! `.class` and one `#id` - `rect`, `.st0`, `path.cls-1.cls-2`, `#logo`.
//! That is what the drawing programs write (Illustrator's `.st0`, the
//! `.cls-1` of the programs after it); a selector with more - another
//! element before it, an attribute, a pseudo-class - is passed over, and
//! so is an at-rule, `@media` or `@font-face`, with whatever block it
//! has. The rules of a group are kept as one each, and sorted by their
//! specificity - ids, then classes, then a type - and then by the order
//! they came in, which is the order their declarations go on in.
//!
//! The declarations are kept as their text, read as a `style`
//! attribute's are (`values.Declarations`).

const std = @import("std");
const document = @import("document.zig");
const Tag = document.Tag;

/// The most rules kept, a selector each; the rest are passed over.
pub const max_rules = 256;
/// The most classes one selector names.
pub const max_classes = 4;

pub const Rule = struct {
    /// The type the element is, or null for any.
    tag: ?Tag = null,
    id: []const u8 = "",
    classes: [max_classes][]const u8 = undefined,
    class_count: u8 = 0,
    /// Ids, classes and the type, in that order of weight.
    specificity: u32 = 0,
    order: u32 = 0,
    declarations: []const u8 = "",

    /// Whether the rule is for an element of `tag` with the `id` and the
    /// `class` attribute given.
    pub fn matches(rule: *const Rule, tag: Tag, id: ?[]const u8, class: ?[]const u8) bool {
        if (rule.tag) |t| if (t != tag) return false;
        if (rule.id.len != 0) {
            const own = std.mem.trim(u8, id orelse return false, spaces);
            if (!std.mem.eql(u8, own, rule.id)) return false;
        }
        for (rule.classes[0..rule.class_count]) |wanted| {
            var words = std.mem.tokenizeAny(u8, class orelse return false, spaces);
            const found = while (words.next()) |word| {
                if (std.mem.eql(u8, word, wanted)) break true;
            } else false;
            if (!found) return false;
        }
        return true;
    }
};

const spaces = " \t\r\n\x0C";

/// The rules of `text` added to `rules[count.*..]`, `count` moved on.
/// Those past the room are passed over.
pub fn parse(text: []const u8, rules: []Rule, count: *u32) void {
    var i: usize = 0;
    while (true) {
        i = skipSpaceAndComments(text, i);
        if (i >= text.len) return;
        if (text[i] == '@') {
            i = afterAtRule(text, i);
            continue;
        }
        if (text[i] == '}') {
            i += 1;
            continue;
        }
        const open = std.mem.indexOfScalarPos(u8, text, i, '{') orelse return;
        const prelude = text[i..open];
        const close = endOfBlock(text, open + 1);
        const declarations = text[open + 1 .. close];
        i = if (close < text.len) close + 1 else close;
        var selectors = std.mem.splitScalar(u8, prelude, ',');
        while (selectors.next()) |one| {
            if (count.* >= rules.len) return;
            var rule = selectorOf(withoutComments(one)) orelse continue;
            rule.order = count.*;
            rule.declarations = declarations;
            rules[count.*] = rule;
            count.* += 1;
        }
    }
}

/// The rules in the order they apply: the least specific first, and of
/// those alike the first written first.
pub fn sort(rules: []Rule) void {
    std.sort.insertion(Rule, rules, {}, before);
}

fn before(_: void, x: Rule, y: Rule) bool {
    if (x.specificity != y.specificity) return x.specificity < y.specificity;
    return x.order < y.order;
}

/// One selector, or null for one that is more than one element's.
fn selectorOf(text_in: []const u8) ?Rule {
    const text = std.mem.trim(u8, text_in, spaces);
    if (text.len == 0) return null;
    var rule = Rule{};
    var i: usize = 0;
    if (text[0] == '*') {
        i = 1;
    } else if (isNameStart(text[0])) {
        const end = nameEnd(text, 0);
        // A type this reader does not draw is for no element it does.
        const tag = document.tagOf(text[0..end]);
        if (tag == .other) return null;
        rule.tag = tag;
        rule.specificity = 1;
        i = end;
    }
    while (i < text.len) {
        const c = text[i];
        if (c != '.' and c != '#') return null;
        const end = nameEnd(text, i + 1);
        if (end == i + 1) return null;
        const name = text[i + 1 .. end];
        if (c == '.') {
            if (rule.class_count == max_classes) return null;
            rule.classes[rule.class_count] = name;
            rule.class_count += 1;
            rule.specificity += 1 << 8;
        } else {
            if (rule.id.len != 0 and !std.mem.eql(u8, rule.id, name)) return null;
            rule.id = name;
            rule.specificity += 1 << 16;
        }
        i = end;
    }
    return rule;
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '-' or c >= 0x80;
}

fn nameEnd(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and (isNameStart(text[i]) or std.ascii.isDigit(text[i]))) i += 1;
    return i;
}

fn skipSpaceAndComments(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len) {
        if (std.mem.indexOfScalar(u8, spaces, text[i]) != null) {
            i += 1;
        } else if (std.mem.startsWith(u8, text[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |end| end + 2 else text.len;
        } else if (std.mem.startsWith(u8, text[i..], "<!--")) {
            i += 4;
        } else if (std.mem.startsWith(u8, text[i..], "-->")) {
            i += 3;
        } else break;
    }
    return i;
}

/// Past an at-rule: its `;`, or the block it has and what is in it.
fn afterAtRule(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            ';' => return i + 1,
            '{' => {
                const end = endOfBlock(text, i + 1);
                return if (end < text.len) end + 1 else end;
            },
            else => {},
        }
    }
    return i;
}

/// The `}` that ends a block begun just before `from`, past the blocks
/// in it, quotes and comments; the text's end without one.
fn endOfBlock(text: []const u8, from: usize) usize {
    var depth: u32 = 0;
    var quote: u8 = 0;
    var i = from;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else switch (c) {
            '"', '\'' => quote = c,
            '/' => if (i + 1 < text.len and text[i + 1] == '*') {
                i = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |end| end + 1 else text.len;
            },
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return i;
                depth -= 1;
            },
            else => {},
        }
    }
    return text.len;
}

/// A selector's text with a comment in it taken out: as its end, which
/// is all a selector of these needs.
fn withoutComments(text: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, text, "/*") orelse return text;
    const end = std.mem.indexOfPos(u8, text, start + 2, "*/") orelse return text[0..start];
    if (std.mem.trim(u8, text[0..start], spaces).len == 0) return text[end + 2 ..];
    return text[0..start];
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

test "Illustrator's classes, a group of selectors, an id, a type; what is passed over" {
    const text =
        \\/* by hand */ .st0{fill:#FFFFFF;} .st1,.st2 { stroke : #000 }
        \\@media print { .st0 { fill: black } } @import url(x.css);
        \\rect.big.red{opacity:.5} #logo{display:none} g > path{fill:red} a:hover{fill:blue}
        \\*{stroke-width:2} tspan{fill:red}
    ;
    var rules: [max_rules]Rule = undefined;
    var n: u32 = 0;
    parse(text, &rules, &n);
    try testing.expectEqual(@as(u32, 6), n);
    try testing.expectEqualStrings("st0", rules[0].classes[0]);
    try testing.expectEqualStrings("fill:#FFFFFF;", rules[0].declarations);
    try testing.expectEqualStrings(" stroke : #000 ", rules[2].declarations);
    try testing.expectEqual(@as(?Tag, .rect), rules[3].tag);
    try testing.expectEqual(@as(u8, 2), rules[3].class_count);
    try testing.expectEqualStrings("logo", rules[4].id);
    try testing.expectEqual(@as(?Tag, null), rules[5].tag);
    sort(rules[0..n]);
    // The type-less one first, then the classes as they came, then the
    // two classes with a type, then the id.
    try testing.expectEqual(@as(u32, 5), rules[0].order);
    try testing.expectEqual(@as(u32, 0), rules[1].order);
    try testing.expectEqual(@as(u32, 1), rules[2].order);
    try testing.expectEqual(@as(u32, 3), rules[4].order);
    try testing.expectEqual(@as(u32, 4), rules[5].order);
    // Which elements they are for.
    try testing.expect(rules[4].matches(.rect, null, " red  big other"));
    try testing.expect(!rules[4].matches(.rect, null, "big"));
    try testing.expect(!rules[4].matches(.circle, null, "big red"));
    try testing.expect(rules[5].matches(.g, " logo", null));
    try testing.expect(!rules[5].matches(.g, "logo2", null));
    try testing.expect(rules[0].matches(.path, null, null));
}

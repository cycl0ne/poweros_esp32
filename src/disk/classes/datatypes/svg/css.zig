// SPDX-License-Identifier: MIT
//! The CSS of an SVG file's `style` elements: its rules, each selector
//! of a group its own, and which elements they are for.
//!
//! A selector is a chain of compound selectors joined by combinators -
//! a descendant (a space), a child (`>`), the next sibling (`+`) or any
//! sibling before (`~`). A compound is a type or `*`, then any number of
//! `.class`, `#id`, attribute selectors - `[x]`, `[x=v]`, `[x~=v]`,
//! `[x|=v]`, `[x^=v]`, `[x$=v]`, `[x*=v]` - and `:first-child`:
//! `g > path.cls-1`, `#logo rect`, `[fill=red]`. A selector with
//! anything else - another pseudo-class, a pseudo-element, a type no
//! element drawn has - is passed over, and so is an at-rule, `@media` or
//! `@font-face`, with whatever block it has. The rules of a group are
//! kept as one each, and sorted by their specificity - ids, then classes,
//! attributes and pseudo-classes, then types - and then by the order
//! they came in, which is the order their declarations go on in.
//!
//! A rule keeps its selector as its text, checked when it is read and
//! read again, from its right end, as an element is matched: the rules
//! of a picture stay small, and only what is written is read.
//!
//! The declarations are kept as their text, read as a `style`
//! attribute's are (`values.Declarations`).

const std = @import("std");
const document = @import("document.zig");
const Tag = document.Tag;
const Document = document.Document;
const none = document.none;

/// The most rules kept, a selector each; the rest are passed over.
pub const max_rules = 256;
/// The most compound selectors one selector chains.
pub const max_steps = 8;

pub const Rule = struct {
    /// The selector's text, read whole once.
    selector: []const u8 = "",
    /// Ids, then classes, attributes and pseudo-classes, then types, in
    /// that order of weight.
    specificity: u32 = 0,
    order: u32 = 0,
    declarations: []const u8 = "",

    /// Whether the rule is for element `node` of `doc`.
    pub fn matches(rule: *const Rule, doc: *const Document, node: u32) bool {
        var chain: [max_steps]Step = undefined;
        const count = stepsOf(rule.selector, &chain) orelse return false;
        return matchFrom(doc, chain[0..count], count - 1, node);
    }
};

const spaces = " \t\r\n\x0C";

/// A compound selector of a chain, and the combinator joining it to the
/// one before: ' ', '>', '+' or '~'; 0 for the first.
const Step = struct { text: []const u8, combinator: u8 };

/// A selector cut into its compounds; null for more than `max_steps` or
/// a combinator with nothing on one side.
fn stepsOf(text: []const u8, chain: *[max_steps]Step) ?usize {
    var count: usize = 0;
    var i: usize = 0;
    var combinator: u8 = 0;
    while (true) {
        // Spaces and at most one combinator between two compounds.
        var space = false;
        while (i < text.len) : (i += 1) {
            const char = text[i];
            if (std.mem.indexOfScalar(u8, spaces, char) != null) {
                space = true;
            } else if (char == '>' or char == '+' or char == '~') {
                if (combinator != 0 and combinator != ' ') return null;
                combinator = char;
            } else break;
        }
        if (i >= text.len) return if (count != 0 and (combinator == 0 or combinator == ' ')) count else null;
        if (count != 0 and combinator == 0) {
            if (!space) return null;
            combinator = ' ';
        }
        if (count == 0 and combinator != 0) return null;
        // The compound: up to a space or a combinator outside brackets.
        const start = i;
        var quote: u8 = 0;
        var depth: u32 = 0;
        while (i < text.len) : (i += 1) {
            const char = text[i];
            if (quote != 0) {
                if (char == quote) quote = 0;
            } else if (char == '"' or char == '\'') {
                quote = char;
            } else if (char == '[') {
                depth += 1;
            } else if (char == ']') {
                depth -|= 1;
            } else if (depth == 0 and (std.mem.indexOfScalar(u8, spaces, char) != null or char == '>' or char == '+' or char == '~')) break;
        }
        if (count == max_steps) return null;
        chain[count] = .{ .text = text[start..i], .combinator = combinator };
        count += 1;
        combinator = 0;
    }
}

/// Whether the compounds `chain[0..index + 1]` match, the last for
/// `node` and each before it for the element its combinator says.
fn matchFrom(doc: *const Document, chain: []const Step, index: usize, node: u32) bool {
    if (!compoundMatches(doc, chain[index].text, node)) return false;
    if (index == 0) return true;
    switch (chain[index].combinator) {
        '>' => {
            const parent = doc.nodes[node].parent;
            return parent != none and matchFrom(doc, chain, index - 1, parent);
        },
        '+' => {
            const sibling = previousElement(doc, node) orelse return false;
            return matchFrom(doc, chain, index - 1, sibling);
        },
        '~' => {
            var at = previousElement(doc, node);
            while (at) |sibling| : (at = previousElement(doc, sibling)) {
                if (matchFrom(doc, chain, index - 1, sibling)) return true;
            }
            return false;
        },
        else => {
            var at = doc.nodes[node].parent;
            while (at != none) : (at = doc.nodes[at].parent) {
                if (matchFrom(doc, chain, index - 1, at)) return true;
            }
            return false;
        },
    }
}

/// The element before `node` among its parent's children, text passed
/// over; null for the first.
fn previousElement(doc: *const Document, node: u32) ?u32 {
    const parent = doc.nodes[node].parent;
    if (parent == none) return null;
    var previous: ?u32 = null;
    var at = doc.nodes[parent].first_child;
    while (at != none and at != node) : (at = doc.nodes[at].next) {
        if (doc.nodes[at].tag != .@"#text") previous = at;
    }
    return previous;
}

/// What a compound selector weighs: ids, classes and the like, types.
const Weight = struct { ids: u32 = 0, classes: u32 = 0, types: u32 = 0 };

/// A compound read through: its weight, or null for one this reader
/// does not match. With `doc`, whether it is for element `node`, as
/// `ids` 1 and anything else null.
fn readCompound(text: []const u8, doc: ?*const Document, node: u32) ?Weight {
    var weight = Weight{};
    if (text.len == 0) return null;
    var i: usize = 0;
    if (text[0] == '*') {
        i = 1;
    } else if (isNameStart(text[0])) {
        const end = nameEnd(text, 0);
        // A type this reader does not draw is for no element it does.
        const tag = document.tagOf(text[0..end]);
        if (tag == .other) return null;
        if (doc) |tree| if (tree.nodes[node].tag != tag) return null;
        weight.types += 1;
        i = end;
    }
    if (doc) |tree| if (tree.nodes[node].tag == .@"#text") return null;
    while (i < text.len) {
        const char = text[i];
        switch (char) {
            '.', '#' => {
                const end = nameEnd(text, i + 1);
                if (end == i + 1) return null;
                const name = text[i + 1 .. end];
                if (char == '.') {
                    weight.classes += 1;
                    if (doc) |tree| if (!hasWord(tree.get(node, .class) orelse return null, name)) return null;
                } else {
                    weight.ids += 1;
                    if (doc) |tree| if (!std.mem.eql(u8, std.mem.trim(u8, tree.get(node, .id) orelse return null, spaces), name)) return null;
                }
                i = end;
            },
            '[' => {
                const close = closingBracket(text, i + 1) orelse return null;
                const selector = attributeOf(text[i + 1 .. close]) orelse return null;
                weight.classes += 1;
                if (doc) |tree| if (!selector.matches(tree, node)) return null;
                i = close + 1;
            },
            ':' => {
                const end = nameEnd(text, i + 1);
                if (!std.ascii.eqlIgnoreCase(text[i + 1 .. end], "first-child")) return null;
                weight.classes += 1;
                if (doc) |tree| if (previousElement(tree, node) != null) return null;
                i = end;
            },
            else => return null,
        }
    }
    return weight;
}

fn compoundMatches(doc: *const Document, text: []const u8, node: u32) bool {
    return readCompound(text, doc, node) != null;
}

/// An attribute selector: the attribute, how its value is compared and
/// with what; `value` null for one that only asks it to be there.
const AttributeSelector = struct {
    name: document.Name,
    operator: u8,
    value: ?[]const u8,

    fn matches(selector: AttributeSelector, doc: *const Document, node: u32) bool {
        const own = doc.get(node, selector.name) orelse return false;
        const wanted = selector.value orelse return true;
        return switch (selector.operator) {
            '=' => std.mem.eql(u8, own, wanted),
            '~' => hasWord(own, wanted),
            '|' => std.mem.eql(u8, own, wanted) or (std.mem.startsWith(u8, own, wanted) and own.len > wanted.len and own[wanted.len] == '-'),
            '^' => wanted.len != 0 and std.mem.startsWith(u8, own, wanted),
            '$' => wanted.len != 0 and std.mem.endsWith(u8, own, wanted),
            '*' => wanted.len != 0 and std.mem.indexOf(u8, own, wanted) != null,
            else => false,
        };
    }
};

/// What is between an attribute selector's brackets read; null for one
/// in error or of an attribute this reader does not keep.
fn attributeOf(text_in: []const u8) ?AttributeSelector {
    const text = std.mem.trim(u8, text_in, spaces);
    const end = nameEnd(text, 0);
    if (end == 0) return null;
    const name = document.nameOf(text[0..end]);
    if (name == .other) return null;
    var rest = std.mem.trim(u8, text[end..], spaces);
    if (rest.len == 0) return .{ .name = name, .operator = 0, .value = null };
    var operator: u8 = '=';
    if (rest[0] != '=') {
        if (rest.len < 2 or rest[1] != '=' or std.mem.indexOfScalar(u8, "~|^$*", rest[0]) == null) return null;
        operator = rest[0];
        rest = rest[1..];
    }
    rest = std.mem.trim(u8, rest[1..], spaces);
    if (rest.len == 0) return null;
    if (rest[0] == '"' or rest[0] == '\'') {
        if (rest.len < 2 or rest[rest.len - 1] != rest[0]) return null;
        return .{ .name = name, .operator = operator, .value = rest[1 .. rest.len - 1] };
    }
    if (nameEnd(rest, 0) != rest.len) return null;
    return .{ .name = name, .operator = operator, .value = rest };
}

/// The `]` closing an attribute selector opened before `from`, past
/// quotes; null without one.
fn closingBracket(text: []const u8, from: usize) ?usize {
    var quote: u8 = 0;
    var at = from;
    while (at < text.len) : (at += 1) {
        const char = text[at];
        if (quote != 0) {
            if (char == quote) quote = 0;
        } else if (char == '"' or char == '\'') {
            quote = char;
        } else if (char == ']') return at;
    }
    return null;
}

/// Whether `word` is one of the words of `list`, spaces between.
fn hasWord(list: []const u8, word: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, list, spaces);
    while (words.next()) |one| if (std.mem.eql(u8, one, word)) return true;
    return false;
}

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

/// One selector checked and weighed, or null for one this reader does
/// not match.
fn selectorOf(text_in: []const u8) ?Rule {
    const text = std.mem.trim(u8, text_in, spaces);
    var chain: [max_steps]Step = undefined;
    const count = stepsOf(text, &chain) orelse return null;
    var total = Weight{};
    for (chain[0..count]) |step| {
        const weight = readCompound(step.text, null, 0) orelse return null;
        total.ids += weight.ids;
        total.classes += weight.classes;
        total.types += weight.types;
    }
    const ids: u32 = @min(total.ids, 255);
    const classes: u32 = @min(total.classes, 255);
    const types: u32 = @min(total.types, 255);
    return .{ .selector = text, .specificity = (ids << 16) | (classes << 8) | types };
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

test "Illustrator's classes, a group of selectors, an id, a type, chains; what is passed over" {
    const text =
        \\/* by hand */ .st0{fill:#FFFFFF;} .st1,.st2 { stroke : #000 }
        \\@media print { .st0 { fill: black } } @import url(x.css);
        \\rect.big.red{opacity:.5} #logo{display:none} g > path{fill:red} a:hover{fill:blue}
        \\*{stroke-width:2} foreignObject{fill:red} g + {fill:red} [fill="x" {fill:red}
    ;
    var rules: [max_rules]Rule = undefined;
    var n: u32 = 0;
    parse(text, &rules, &n);
    try testing.expectEqual(@as(u32, 7), n);
    try testing.expectEqualStrings(".st0", rules[0].selector);
    try testing.expectEqualStrings("fill:#FFFFFF;", rules[0].declarations);
    try testing.expectEqualStrings(" stroke : #000 ", rules[2].declarations);
    try testing.expectEqual(@as(u32, (2 << 8) | 1), rules[3].specificity);
    try testing.expectEqual(@as(u32, 1 << 16), rules[4].specificity);
    try testing.expectEqual(@as(u32, 2), rules[5].specificity);
    try testing.expectEqual(@as(u32, 0), rules[6].specificity);
    sort(rules[0..n]);
    // The type-less one first, then the chain of two types, then the
    // classes as they came, then the two classes with a type, then the
    // id.
    try testing.expectEqual(@as(u32, 6), rules[0].order);
    try testing.expectEqual(@as(u32, 5), rules[1].order);
    try testing.expectEqual(@as(u32, 0), rules[2].order);
    try testing.expectEqual(@as(u32, 1), rules[3].order);
    try testing.expectEqual(@as(u32, 3), rules[5].order);
    try testing.expectEqual(@as(u32, 4), rules[6].order);
}

test "which elements a rule is for: classes, ids, attributes, first children, the four combinators" {
    var source =
        \\<svg xmlns="http://www.w3.org/2000/svg">
        \\  <g id="logo" class="a b"><rect class="red big other" x="1" fill="red-ish"/><circle r="2"/><path d="M0 0"/></g>
        \\  <rect class="big"/>
        \\</svg>
    .*;
    var block: [4096]u8 align(8) = undefined;
    const counts = document.count(&source) orelse return error.NotSvg;
    const doc = document.build(&source, counts, block[0..document.bytesFor(counts)]);
    const group = doc.nodes[0].first_child;
    const rect = doc.nodes[group].first_child;
    const circle = doc.nodes[rect].next;
    const path = doc.nodes[circle].next;
    const outer = doc.nodes[group].next;
    const Case = struct { selector: []const u8, node: u32, matches: bool };
    const cases = [_]Case{
        .{ .selector = "rect.big.red", .node = rect, .matches = true },
        .{ .selector = "rect.big.red", .node = outer, .matches = false },
        .{ .selector = "circle.big", .node = circle, .matches = false },
        .{ .selector = "#logo", .node = group, .matches = true },
        .{ .selector = "#logo2", .node = group, .matches = false },
        .{ .selector = "*", .node = path, .matches = true },
        .{ .selector = "[x]", .node = rect, .matches = true },
        .{ .selector = "[x]", .node = outer, .matches = false },
        .{ .selector = "[x='1']", .node = rect, .matches = true },
        .{ .selector = "[fill|=red]", .node = rect, .matches = true },
        .{ .selector = "[fill^=red]", .node = rect, .matches = true },
        .{ .selector = "[fill$=ish]", .node = rect, .matches = true },
        .{ .selector = "[fill*=d-i]", .node = rect, .matches = true },
        .{ .selector = "[fill=red]", .node = rect, .matches = false },
        .{ .selector = "[class~=big]", .node = rect, .matches = true },
        .{ .selector = "rect:first-child", .node = rect, .matches = true },
        .{ .selector = "circle:first-child", .node = circle, .matches = false },
        .{ .selector = "svg rect", .node = rect, .matches = true },
        .{ .selector = "svg > rect", .node = rect, .matches = false },
        .{ .selector = "svg > rect", .node = outer, .matches = true },
        .{ .selector = "g#logo.a > rect", .node = rect, .matches = true },
        .{ .selector = "rect + circle", .node = circle, .matches = true },
        .{ .selector = "rect + path", .node = path, .matches = false },
        .{ .selector = "rect ~ path", .node = path, .matches = true },
        .{ .selector = "g ~ rect.big", .node = outer, .matches = true },
        .{ .selector = "svg g g rect", .node = rect, .matches = false },
    };
    for (cases) |one| {
        const rule = selectorOf(one.selector) orelse return error.NotRead;
        if (rule.matches(&doc, one.node) != one.matches) {
            std.debug.print("{s}\n", .{one.selector});
            return error.WrongMatch;
        }
    }
}

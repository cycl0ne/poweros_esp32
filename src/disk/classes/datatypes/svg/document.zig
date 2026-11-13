// SPDX-License-Identifier: MIT
//! An SVG file's elements as a tree, in one block of the caller's.
//!
//! The file is read twice: once to count its elements, attributes and
//! ids (`count`), and once, into a block of the size that gives
//! (`bytesFor`), to build them (`build`). Nothing is copied: an element
//! knows its kind, where it is in the tree, and its attributes, whose
//! names are known by number and whose values are slices of the file -
//! their references undone in place, so the file is the caller's to
//! keep as long as the document.
//!
//! An element in a namespace other than SVG's - `inkscape:`,
//! `sodipodi:`, `rdf:` and the rest - is an element of no kind, which is
//! never drawn and nor is anything in it; `svg:rect` is a `rect`. Of an
//! attribute's names both `href` and `xlink:href` are known; one in
//! another namespace is not.
//!
//! **A `style` element's text** - its CSS, a CDATA section's as it is,
//! the rest with its references undone - is kept as attributes of it
//! named `text`, one for each piece between tags, in the order they
//! come (since 1.2): an attribute of no other element has that name.
//!
//! **A `text` element's characters** (since 1.3) are nodes of their own
//! among its children and its `tspan`s', a node of the kind `#text` for
//! each piece between tags, holding it - decoded, or a CDATA section's as
//! it is - as its one attribute, `#text`. They are in the tree where
//! they are in the file, so a `tspan` is between the pieces before and
//! after it.
//!
//! **A file that is not well formed** is read as far as it is: closing
//! tags close the element open, whatever they name, and the file's end
//! closes them all. Its first element has to be `svg`.

const std = @import("std");
const xml = @import("xml.zig");

/// What an element is, as far as drawing goes.
pub const Tag = enum(u8) {
    other,
    svg,
    g,
    a,
    @"switch",
    defs,
    symbol,
    use,
    path,
    rect,
    circle,
    ellipse,
    line,
    polyline,
    polygon,
    linearGradient,
    radialGradient,
    stop,
    clipPath,
    mask,
    pattern,
    marker,
    image,
    text,
    style,
    filter,
    // Since 1.3.
    tspan,
    textPath,
    feGaussianBlur,
    feFlood,
    feBlend,
    /// A filter primitive of any other kind.
    feOther,
    /// A piece of a `text` element's characters, not an element.
    @"#text",
};

/// The attributes and properties read, by number.
pub const Name = enum(u8) {
    other,
    id,
    href,
    style,
    transform,
    d,
    x,
    y,
    width,
    height,
    rx,
    ry,
    cx,
    cy,
    r,
    fx,
    fy,
    fr,
    x1,
    y1,
    x2,
    y2,
    points,
    viewBox,
    preserveAspectRatio,
    offset,
    gradientUnits,
    gradientTransform,
    spreadMethod,
    fill,
    @"fill-opacity",
    @"fill-rule",
    stroke,
    @"stroke-width",
    @"stroke-opacity",
    @"stroke-linecap",
    @"stroke-linejoin",
    @"stroke-miterlimit",
    @"stroke-dasharray",
    @"stroke-dashoffset",
    opacity,
    color,
    display,
    visibility,
    @"stop-color",
    @"stop-opacity",
    filter,
    @"clip-path",
    mask,
    // Since 1.2.
    class,
    @"clip-rule",
    clipPathUnits,
    maskUnits,
    maskContentUnits,
    @"mask-type",
    overflow,
    /// A `style` element's text, or a piece of a `text` element's: not an
    /// attribute.
    @"#text",
    // Since 1.3.
    font,
    @"font-family",
    @"font-size",
    @"font-weight",
    @"font-style",
    @"text-anchor",
    @"letter-spacing",
    @"word-spacing",
    @"text-decoration",
    @"white-space",
    @"xml:space",
    /// The language a text is in (`xml:lang`, or `lang`): since 1.6.
    lang,
    dx,
    dy,
    filterUnits,
    primitiveUnits,
    stdDeviation,
    in,
    in2,
    result,
    mode,
    @"flood-opacity",
    @"paint-order",
};

pub const none: u32 = std.math.maxInt(u32);

pub const Node = struct {
    tag: Tag,
    parent: u32,
    first_child: u32 = none,
    next: u32 = none,
    /// Its attributes: `attributes[first_attribute..][0..attribute_count]`.
    first_attribute: u32,
    attribute_count: u32,
};

pub const Attribute = struct {
    name: Name,
    value: []const u8,
};

/// An id and the element that has it, sorted by the id.
pub const Id = struct {
    value: []const u8,
    node: u32,
};

pub const Counts = struct {
    nodes: u32 = 0,
    attributes: u32 = 0,
    ids: u32 = 0,
};

pub const Document = struct {
    nodes: []Node,
    attributes: []Attribute,
    ids: []Id,

    pub fn attributesOf(doc: *const Document, node: u32) []const Attribute {
        const n = doc.nodes[node];
        return doc.attributes[n.first_attribute..][0..n.attribute_count];
    }

    /// The value of an element's attribute, or null.
    pub fn get(doc: *const Document, node: u32, name: Name) ?[]const u8 {
        for (doc.attributesOf(node)) |a| if (a.name == name) return a.value;
        return null;
    }

    /// The element with this id, the first of them when there are two.
    pub fn byId(doc: *const Document, id: []const u8) ?u32 {
        var low: usize = 0;
        var high: usize = doc.ids.len;
        while (low < high) {
            const mid = (low + high) / 2;
            switch (std.mem.order(u8, doc.ids[mid].value, id)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => {
                    var first = mid;
                    while (first > 0 and std.mem.eql(u8, doc.ids[first - 1].value, id)) first -= 1;
                    return doc.ids[first].node;
                },
            }
        }
        return null;
    }

    /// The element an `href` names, `#id` within the file; null for any
    /// other, which this reader never goes to.
    pub fn byHref(doc: *const Document, href: []const u8) ?u32 {
        const trimmed = std.mem.trim(u8, href, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '#') return null;
        return doc.byId(trimmed[1..]);
    }
};

/// How much there is of it; null when it is not XML whose first element
/// is `svg`.
pub fn count(text: []u8) ?Counts {
    var counts = Counts{};
    var in_style = false;
    var texts = Texts{};
    var r = xml.Reader{ .text = text };
    while (r.next() catch return null) |event| switch (event) {
        .open => |open| {
            if (counts.nodes == 0 and tagOf(open.name) != .svg) return null;
            counts.nodes += 1;
            if (counts.nodes == none) return null;
            var attributes = xml.Attributes{ .text = open.attributes };
            while (attributes.next() catch return null) |a| {
                const name = nameOf(a.name);
                if (name == .other) continue;
                counts.attributes += 1;
                if (name == .id) counts.ids += 1;
            }
            in_style = !open.empty and tagOf(open.name) == .style;
            texts.open(tagOf(open.name), open.empty);
        },
        .close => {
            in_style = false;
            texts.close();
        },
        .text => if (in_style) {
            counts.attributes += 1;
        } else if (texts.inside()) {
            counts.nodes += 1;
            counts.attributes += 1;
            if (counts.nodes == none) return null;
        },
    };
    if (counts.nodes == 0) return null;
    return counts;
}

/// Whether the reader is inside a `text` element: how deep it is in the
/// tree, and how deep the `text` element it is in starts.
const Texts = struct {
    depth: u32 = 0,
    text_at: u32 = none,

    fn open(t: *Texts, tag: Tag, empty: bool) void {
        if (empty) return;
        t.depth += 1;
        if (tag == .text and t.text_at == none) t.text_at = t.depth;
    }

    fn close(t: *Texts) void {
        if (t.depth == t.text_at) t.text_at = none;
        t.depth -|= 1;
    }

    fn inside(t: *const Texts) bool {
        return t.text_at != none;
    }
};

/// The bytes a document of these counts takes.
pub fn bytesFor(counts: Counts) usize {
    return @as(usize, counts.nodes) * @sizeOf(Node) +
        @as(usize, counts.attributes) * @sizeOf(Attribute) +
        @as(usize, counts.ids) * @sizeOf(Id);
}

/// The document built in `block`, `bytesFor(counts)` long, from the same
/// text `count` counted. References in the values are undone in the
/// text.
pub fn build(text: []u8, counts: Counts, block: []align(8) u8) Document {
    const node_bytes = @as(usize, counts.nodes) * @sizeOf(Node);
    const attribute_bytes = @as(usize, counts.attributes) * @sizeOf(Attribute);
    const nodes: []Node = @as([*]Node, @ptrCast(@alignCast(block.ptr)))[0..counts.nodes];
    const attributes: []Attribute = @as([*]Attribute, @ptrCast(@alignCast(block.ptr + node_bytes)))[0..counts.attributes];
    const ids: []Id = @as([*]Id, @ptrCast(@alignCast(block.ptr + node_bytes + attribute_bytes)))[0..counts.ids];
    var doc = Document{ .nodes = nodes, .attributes = attributes, .ids = ids };

    var n: u32 = 0;
    var a: u32 = 0;
    var i: u32 = 0;
    // The element open, and the last child of each open one.
    var open_node: u32 = none;
    var last_child: u32 = none;
    // A `style` element open, its text to be kept: right after its
    // attributes, nothing between.
    var in_style = false;
    var texts = Texts{};
    var r = xml.Reader{ .text = text };
    while (r.next() catch null) |event| switch (event) {
        .open => |open| {
            if (n == counts.nodes) break;
            const node = n;
            n += 1;
            nodes[node] = .{ .tag = tagOf(open.name), .parent = open_node, .first_attribute = a, .attribute_count = 0 };
            var list = xml.Attributes{ .text = open.attributes };
            while (list.next() catch null) |attribute| {
                const name = nameOf(attribute.name);
                if (name == .other or a == counts.attributes) continue;
                const value = xml.decode(attribute.value);
                attributes[a] = .{ .name = name, .value = value };
                a += 1;
                nodes[node].attribute_count += 1;
                if (name == .id and i < counts.ids) {
                    ids[i] = .{ .value = std.mem.trim(u8, value, " \t\r\n"), .node = node };
                    i += 1;
                }
            }
            // Linked in after the last child of the element it is in.
            if (open_node != none) {
                if (last_child == none) nodes[open_node].first_child = node else nodes[last_child].next = node;
            }
            if (open.empty) {
                last_child = node;
            } else {
                open_node = node;
                last_child = none;
            }
            in_style = !open.empty and nodes[node].tag == .style;
            texts.open(nodes[node].tag, open.empty);
            if (open_node == none) break; // the root closed itself
        },
        .close => {
            in_style = false;
            texts.close();
            if (open_node == none) break;
            last_child = open_node;
            open_node = nodes[open_node].parent;
            if (open_node == none) break; // past the root: the rest is not the picture's
        },
        .text => |piece| if (in_style and a < counts.attributes) {
            attributes[a] = .{ .name = .@"#text", .value = textOf(text, piece) };
            a += 1;
            nodes[open_node].attribute_count += 1;
        } else if (texts.inside() and open_node != none and n < counts.nodes and a < counts.attributes) {
            // A piece of a text's characters: a node of its own, after
            // the last child.
            const node = n;
            n += 1;
            nodes[node] = .{ .tag = .@"#text", .parent = open_node, .first_attribute = a, .attribute_count = 1 };
            attributes[a] = .{ .name = .@"#text", .value = textOf(text, piece) };
            a += 1;
            if (last_child == none) nodes[open_node].first_child = node else nodes[last_child].next = node;
            last_child = node;
        },
    };
    doc.nodes = nodes[0..n];
    doc.attributes = attributes[0..a];
    doc.ids = ids[0..i];
    std.mem.sort(Id, doc.ids, {}, idBefore);
    return doc;
}

/// A piece of text between tags: a CDATA section's as it is - it starts
/// after the `[` that opens it, where any other starts after a `>` - and
/// any other with its references undone.
fn textOf(text: []u8, piece: []u8) []const u8 {
    const at = @intFromPtr(piece.ptr) - @intFromPtr(text.ptr);
    const cdata = at > 0 and text[at - 1] == '[';
    return if (cdata) piece else xml.decode(piece);
}

fn idBefore(_: void, x: Id, y: Id) bool {
    return switch (std.mem.order(u8, x.value, y.value)) {
        .lt => true,
        .gt => false,
        .eq => x.node < y.node,
    };
}

/// An element's kind by its name, `svg:` before it or not.
pub fn tagOf(full: []const u8) Tag {
    const name = if (std.mem.startsWith(u8, full, "svg:")) full[4..] else full;
    if (std.mem.indexOfScalar(u8, name, ':') != null) return .other;
    if (std.meta.stringToEnum(Tag, name)) |tag| return if (tag == .@"#text") .other else tag;
    // A filter primitive this reader does not make.
    if (name.len > 2 and name[0] == 'f' and name[1] == 'e' and std.ascii.isUpper(name[2])) return .feOther;
    return .other;
}

/// An attribute's or a property's name by number.
pub fn nameOf(full: []const u8) Name {
    if (std.mem.eql(u8, full, "xlink:href")) return .href;
    if (std.mem.eql(u8, full, "xml:space")) return .@"xml:space";
    if (std.mem.eql(u8, full, "xml:lang")) return .lang;
    if (std.mem.indexOfScalar(u8, full, ':') != null) return .other;
    return std.meta.stringToEnum(Name, full) orelse .other;
}

/// Whether the first element of a text is `svg`: past a byte order
/// mark, spaces, the declaration, comments, processing instructions and
/// a DOCTYPE. Only the start of the element is looked at, so a text cut
/// off inside it still says.
pub fn startsSvg(text: []const u8) bool {
    var i: usize = 0;
    if (text.len >= 3 and text[0] == 0xEF and text[1] == 0xBB and text[2] == 0xBF) i = 3;
    while (i < text.len) {
        const c = text[i];
        if (xml.isSpace(c)) {
            i += 1;
            continue;
        }
        if (c != '<') return false;
        const rest = text[i..];
        if (startsWith(rest, "<!--")) {
            i = after(text, i + 4, "-->") orelse return false;
        } else if (startsWith(rest, "<?")) {
            i = after(text, i + 2, "?>") orelse return false;
        } else if (startsWith(rest, "<!")) {
            i = afterDeclaration(text, i + 2) orelse return false;
        } else {
            const name = if (startsWith(rest, "<svg:svg")) "<svg:svg" else "<svg";
            if (!startsWith(rest, name) or rest.len == name.len) return false;
            const next = rest[name.len];
            return xml.isSpace(next) or next == '>' or next == '/';
        }
    }
    return false;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and xml.eql(text[0..prefix.len], prefix);
}

fn after(text: []const u8, from: usize, end: []const u8) ?usize {
    var i = from;
    while (i + end.len <= text.len) : (i += 1) {
        if (startsWith(text[i..], end)) return i + end.len;
    }
    return null;
}

fn afterDeclaration(text: []const u8, from: usize) ?usize {
    var depth: u32 = 0;
    var quote: u8 = 0;
    var i = from;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else switch (c) {
            '"', '\'' => quote = c,
            '[' => depth += 1,
            ']' => depth -|= 1,
            '>' => if (depth == 0) return i + 1,
            else => {},
        }
    }
    return null;
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

fn parse(text: []u8, block: []align(8) u8) !Document {
    const counts = count(text) orelse return error.NotSvg;
    if (bytesFor(counts) > block.len) return error.TooBig;
    return build(text, counts, block[0..bytesFor(counts)]);
}

test "a tree of elements, namespaced ones of no kind, ids looked up" {
    var text =
        \\<?xml version="1.0"?>
        \\<svg xmlns="http://www.w3.org/2000/svg" width="48" inkscape:version="0.46">
        \\  <defs><linearGradient id="b" xlink:href="#a"/><linearGradient id="a"><stop offset="0"/></linearGradient></defs>
        \\  <sodipodi:namedview id="view"><inkscape:grid/></sodipodi:namedview>
        \\  <g id="layer1" style="fill:red"><svg:rect width="1" height="2"/><path d="M0 0" id="b"/></g>
        \\</svg>
        \\<!-- after -->
    .*;
    var block: [4096]u8 align(8) = undefined;
    const doc = try parse(&text, &block);
    try testing.expectEqual(@as(usize, 10), doc.nodes.len);
    try testing.expectEqual(Tag.svg, doc.nodes[0].tag);
    try testing.expectEqualStrings("48", doc.get(0, .width).?);
    // The defs, the view, the group: the root's three children.
    const defs = doc.nodes[0].first_child;
    try testing.expectEqual(Tag.defs, doc.nodes[defs].tag);
    const view = doc.nodes[defs].next;
    try testing.expectEqual(Tag.other, doc.nodes[view].tag);
    const group = doc.nodes[view].next;
    try testing.expectEqual(Tag.g, doc.nodes[group].tag);
    try testing.expectEqual(none, doc.nodes[group].next);
    const rect = doc.nodes[group].first_child;
    try testing.expectEqual(Tag.rect, doc.nodes[rect].tag);
    try testing.expectEqual(group, doc.nodes[rect].parent);
    try testing.expectEqualStrings("2", doc.get(rect, .height).?);
    // Two elements with the id "b": the first of them is the one.
    const b = doc.byId("b").?;
    try testing.expectEqual(Tag.linearGradient, doc.nodes[b].tag);
    try testing.expectEqualStrings("#a", doc.get(b, .href).?);
    try testing.expectEqual(doc.byId("a").?, doc.byHref("#a").?);
    try testing.expect(doc.byId("nothing") == null);
    try testing.expect(doc.byHref("other.svg#a") == null);
}

test "a style element's text kept as its own, CDATA as it is" {
    var text =
        \\<svg><style type="text/css">.a{fill:red} b&gt;c{}<![CDATA[ .b>.c{fill:&amp;} ]]></style><rect class="a"/></svg>
    .*;
    var block: [4096]u8 align(8) = undefined;
    const doc = try parse(&text, &block);
    const style = doc.nodes[0].first_child;
    try testing.expectEqual(Tag.style, doc.nodes[style].tag);
    const kept = doc.attributesOf(style);
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqual(Name.@"#text", kept[0].name);
    try testing.expectEqualStrings(".a{fill:red} b>c{}", kept[0].value);
    try testing.expectEqualStrings(" .b>.c{fill:&amp;} ", kept[1].value);
    const rect = doc.nodes[style].next;
    try testing.expectEqualStrings("a", doc.get(rect, .class).?);
    try testing.expectEqual(none, doc.nodes[rect].first_child);
}

test "a text's characters as nodes among its tspans, in the order they come" {
    var text =
        \\<svg><text x="1">Hello, <tspan font-weight="bold">big</tspan> <![CDATA[w<o>rld]]> &amp; you</text><g>no</g><text/><feTile/></svg>
    .*;
    var block: [4096]u8 align(8) = undefined;
    const doc = try parse(&text, &block);
    const t = doc.nodes[0].first_child;
    try testing.expectEqual(Tag.text, doc.nodes[t].tag);
    const first = doc.nodes[t].first_child;
    try testing.expectEqual(Tag.@"#text", doc.nodes[first].tag);
    try testing.expectEqualStrings("Hello, ", doc.get(first, .@"#text").?);
    const span = doc.nodes[first].next;
    try testing.expectEqual(Tag.tspan, doc.nodes[span].tag);
    try testing.expectEqualStrings("big", doc.get(doc.nodes[span].first_child, .@"#text").?);
    const space = doc.nodes[span].next;
    try testing.expectEqualStrings(" ", doc.get(space, .@"#text").?);
    try testing.expectEqualStrings("w<o>rld", doc.get(doc.nodes[space].next, .@"#text").?);
    const last = doc.nodes[doc.nodes[space].next].next;
    try testing.expectEqualStrings(" & you", doc.get(last, .@"#text").?);
    try testing.expectEqual(none, doc.nodes[last].next);
    // Text outside a text element is no node; nor is an empty text's.
    const g = doc.nodes[t].next;
    try testing.expectEqual(none, doc.nodes[g].first_child);
    const empty = doc.nodes[g].next;
    try testing.expectEqual(none, doc.nodes[empty].first_child);
    try testing.expectEqual(Tag.feOther, doc.nodes[doc.nodes[empty].next].tag);
    try testing.expectEqual(Tag.other, tagOf("#text"));
}

test "not an SVG file, and one that is cut short" {
    var html = "<html><svg/></html>".*;
    try testing.expect(count(&html) == null);
    var cut = "<svg><g><rect width='5' height='&amp;5'/><path d='M 0".*;
    var block: [1024]u8 align(8) = undefined;
    try testing.expect(count(&cut) == null);
    // Cut between tags, it is read as far as it goes.
    var short = "<svg><g><rect width='5' height='&#53;'/>".*;
    const doc = try parse(&short, &block);
    try testing.expectEqual(@as(usize, 3), doc.nodes.len);
    try testing.expectEqualStrings("5", doc.get(2, .height).?);
}

test "an SVG file known by its first element, past what may come before it" {
    try testing.expect(startsSvg("<svg/>"));
    try testing.expect(startsSvg("\xEF\xBB\xBF<?xml version='1.0'?>\n<!-- by hand -->\n" ++
        "<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"x\" [ <!ENTITY ns \"a>b\"> ]>\n<svg\n width='1'"));
    try testing.expect(startsSvg("<svg:svg xmlns:svg='http://www.w3.org/2000/svg'>"));
    try testing.expect(!startsSvg("<svgx/>"));
    try testing.expect(!startsSvg("<html><svg/></html>"));
    try testing.expect(!startsSvg("{\"w\": 1}"));
    try testing.expect(!startsSvg("<!-- never ends <svg>"));
    try testing.expect(!startsSvg("<svg"));
}

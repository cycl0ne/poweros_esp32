// SPDX-License-Identifier: MIT
//! References that close a loop (since 1.7): a clip, a mask, a pattern,
//! a filter or a marker that reaches itself again through what it draws.
//! The reference that closes the loop is dropped - the element is drawn
//! as if it named none there - and all else is drawn as it is.
//!
//! **Which one.** The resources are gone through in the document's
//! order, the references of each followed depth first as it draws them:
//! a `clipPath` its own `clip-path` and its content's; a `mask` its own
//! `mask` and every reference of its content; a `pattern` and a `marker`
//! every reference of their content; a `filter` the elements its
//! `feImage`s name, and an element so named its own references and its
//! content's. The reference that reaches one still being followed is the
//! one dropped. A pattern or a filter without children of its own is the
//! one along its `href`s it takes them from.
//!
//! An element's references are its `clip-path`, its `mask`, the filters
//! of its `filter`, the patterns of its `fill` and `stroke`, and a
//! shape's markers outside a `clipPath`; the last three as it inherits
//! them. A resource's content is the elements inside it, past the
//! resources, `defs` and `symbol`s among them, whose own content is
//! drawn only where they are named. What a `use` names is not followed.

const document = @import("document.zig");
const values = @import("values.zig");
const filter_ = @import("filter.zig");
const Name = document.Name;
const Tag = document.Tag;
const none = document.none;

/// A reference dropped: the element that names the resource, and the
/// property it names it by.
pub const Dropped = struct { node: u32, name: Name };

/// How many are kept. A loop past them is still cut where it is drawn,
/// as deep as the drawing follows references.
pub const max_dropped = 32;

/// How many resources deep references are followed.
const max_chain = 32;

/// What each node is to the search, one byte each.
const unseen: u8 = 0;
const following: u8 = 1;
const followed: u8 = 2;

/// Which references a resource draws.
const Kind = enum { clip, mask, server, filter, element };

/// A resource's references in turn: those of `at`, one property after
/// another, then of the next element of its content.
const Walk = struct {
    root: u32,
    kind: Kind,
    at: u32,
    property: u8 = 0,
    /// The next of a `filter` list's entries.
    entry: u8 = 0,

    fn of(doc: *const document.Document, root: u32) Walk {
        const kind: Kind = switch (doc.nodes[root].tag) {
            .clipPath => .clip,
            .mask => .mask,
            .pattern, .marker => .server,
            .filter => .filter,
            else => .element,
        };
        var walk = Walk{ .root = root, .kind = kind, .at = root };
        // Patterns, markers and filters name nothing of their own.
        if (kind == .server or kind == .filter) walk.at = walk.after(doc, root);
        return walk;
    }

    /// The element of the content after `at`, in the document's order;
    /// `none` past the last.
    fn after(walk: *const Walk, doc: *const document.Document, at: u32) u32 {
        const every = walk.kind == .filter;
        var from = at;
        var candidate = doc.nodes[at].first_child;
        while (true) {
            if (candidate != none) {
                const tag = doc.nodes[candidate].tag;
                if (tag != .@"#text" and (every or !isDefinition(tag))) return candidate;
                candidate = doc.nodes[candidate].next;
                continue;
            }
            if (from == walk.root) return none;
            candidate = doc.nodes[from].next;
            from = doc.nodes[from].parent;
        }
    }
};

/// A reference: who names what, by which property.
const Reference = struct { user: u32, name: Name, target: u32 };

/// The properties an element's references are by, in the order they are
/// followed.
const properties = [_]Name{ .@"clip-path", .mask, .filter, .fill, .stroke, .@"marker-start", .@"marker-mid", .@"marker-end", .href };

/// The references that close loops into `dropped`, `states` a byte for
/// each node of the document; how many there are.
pub fn find(p: anytype, states: []u8, dropped: *[max_dropped]Dropped) u32 {
    const doc = p.doc;
    @memset(states, unseen);
    var count: u32 = 0;
    var chain: [max_chain]Walk = undefined;
    for (doc.nodes, 0..) |node, index| {
        if (!isResource(node.tag)) continue;
        const start = contentOf(doc, @intCast(index));
        if (states[start] != unseen) continue;
        states[start] = following;
        chain[0] = Walk.of(doc, start);
        var depth: usize = 1;
        while (depth > 0) {
            const top = &chain[depth - 1];
            const reference = next(p, top) orelse {
                states[top.root] = followed;
                depth -= 1;
                continue;
            };
            const content = contentOf(doc, reference.target);
            switch (states[content]) {
                following => if (count < max_dropped) {
                    dropped[count] = .{ .node = reference.user, .name = reference.name };
                    count += 1;
                },
                followed => {},
                else => if (depth < max_chain) {
                    states[content] = following;
                    chain[depth] = Walk.of(doc, content);
                    depth += 1;
                },
            }
        }
    }
    return count;
}

/// The walk's next reference; null past its last.
fn next(p: anytype, walk: *Walk) ?Reference {
    const doc = p.doc;
    while (walk.at != none) {
        while (walk.property < properties.len) {
            const name = properties[walk.property];
            if (name == .filter) {
                if (walk.entry < 0xFF and drawn(walk, name)) {
                    if (filterEntry(p, walk.at, walk.entry)) |found| {
                        walk.entry = found.after;
                        return .{ .user = walk.at, .name = name, .target = found.target };
                    }
                }
                walk.property += 1;
                continue;
            }
            walk.property += 1;
            if (!drawn(walk, name)) continue;
            if (referenceOf(p, walk.at, name)) |target| return .{ .user = walk.at, .name = name, .target = target };
        }
        walk.at = walk.after(doc, walk.at);
        walk.property = 0;
        walk.entry = 0;
    }
    return null;
}

/// Whether a resource of `kind` follows the reference by `name` of the
/// element the walk is at.
fn drawn(walk: *const Walk, name: Name) bool {
    const own = walk.at == walk.root;
    return switch (walk.kind) {
        .clip => name == .@"clip-path",
        .mask => if (own) name == .mask else name != .href,
        .server, .element => name != .href,
        .filter => name == .href,
    };
}

/// The resource `node` names by `name`, as it inherits it where it
/// does; null for none.
fn referenceOf(p: anytype, node: u32, name: Name) ?u32 {
    const doc = p.doc;
    const tag = doc.nodes[node].tag;
    switch (name) {
        .@"clip-path" => return named(p, p.propertyOf(node, name) orelse return null, .clipPath),
        .mask => return named(p, p.propertyOf(node, name) orelse return null, .mask),
        .fill, .stroke => return named(p, inherited(p, node, name) orelse return null, .pattern),
        .@"marker-start", .@"marker-mid", .@"marker-end" => {
            if (!isShape(tag) or insideClip(doc, node)) return null;
            return named(p, inherited(p, node, name) orelse return null, .marker);
        },
        .href => {
            if (tag != .feImage) return null;
            const target = doc.byHref(doc.get(node, .href) orelse return null) orelse return null;
            const target_tag = doc.nodes[target].tag;
            return if (isShape(target_tag) or isGraphic(target_tag)) target else null;
        },
        else => return null,
    }
}

/// The filter of the `filter` list's entry `from` on, and where the one
/// after it is; null past the last.
fn filterEntry(p: anytype, node: u32, from: u8) ?struct { target: u32, after: u8 } {
    const text = p.propertyOf(node, .filter) orelse return null;
    var entries = filter_.Entries.of(text, 16);
    var index: u8 = 0;
    while (entries.next()) |entry| : (index += 1) {
        if (index < from) continue;
        if (index == 0xFE) return null;
        switch (entry) {
            .url => |id| {
                const target = p.doc.byId(id) orelse continue;
                if (p.doc.nodes[target].tag == .filter) return .{ .target = target, .after = index + 1 };
            },
            .function => {},
        }
    }
    return null;
}

/// A property as `node` inherits it: its own, or the nearest of the
/// elements round it that gives one.
fn inherited(p: anytype, node: u32, name: Name) ?[]const u8 {
    var at = node;
    while (at != none) : (at = p.doc.nodes[at].parent) {
        if (p.propertyOf(at, name)) |text| return text;
    }
    return null;
}

/// The element a `url(#id)` names, if it is a `tag`.
fn named(p: anytype, text: []const u8, tag: Tag) ?u32 {
    const paint = values.paint(text) orelse return null;
    if (paint != .url) return null;
    const node = p.doc.byId(paint.url.id) orelse return null;
    return if (p.doc.nodes[node].tag == tag) node else null;
}

/// The pattern or the filter whose children `node` draws: its own, or
/// the first along its `href`s that has any.
fn contentOf(doc: *const document.Document, node: u32) u32 {
    const tag = doc.nodes[node].tag;
    if (tag != .pattern and tag != .filter) return node;
    var at = node;
    var hops: u32 = 0;
    while (hops < max_chain) : (hops += 1) {
        if (hasElements(doc, at)) return at;
        const link = doc.byHref(doc.get(at, .href) orelse return node) orelse return node;
        if (doc.nodes[link].tag != tag) return node;
        at = link;
    }
    return node;
}

fn hasElements(doc: *const document.Document, node: u32) bool {
    var child = doc.nodes[node].first_child;
    while (child != none) : (child = doc.nodes[child].next) {
        if (doc.nodes[child].tag != .@"#text") return true;
    }
    return false;
}

fn insideClip(doc: *const document.Document, node: u32) bool {
    var at = doc.nodes[node].parent;
    while (at != none) : (at = doc.nodes[at].parent) {
        if (doc.nodes[at].tag == .clipPath) return true;
    }
    return false;
}

fn isResource(tag: Tag) bool {
    return switch (tag) {
        .clipPath, .mask, .pattern, .filter, .marker => true,
        else => false,
    };
}

/// What is drawn only where it is named: a resource, `defs`, `symbol`.
fn isDefinition(tag: Tag) bool {
    return isResource(tag) or tag == .defs or tag == .symbol;
}

fn isShape(tag: Tag) bool {
    return switch (tag) {
        .path, .rect, .circle, .ellipse, .line, .polyline, .polygon => true,
        else => false,
    };
}

/// What an `feImage` may draw besides a shape.
fn isGraphic(tag: Tag) bool {
    return switch (tag) {
        .g, .@"switch", .svg, .text, .image, .use => true,
        else => false,
    };
}

// SPDX-License-Identifier: MIT
//! A `filter` property made into vector.library's filter primitives
//! (since 1.7), for `FilterLayer` to run on the layer the element is
//! drawn on.
//!
//! **The list.** A `filter` is a list: `url(#id)`s of `filter` elements
//! and the filter functions - `blur()`, `drop-shadow()`, `brightness()`,
//! `contrast()`, `grayscale()`, `hue-rotate()`, `invert()`, `opacity()`,
//! `saturate()` and `sepia()` - each run on what the one before it made.
//! A list a part of which does not read - a value below 0, a percentage
//! where a length goes, an angle without its unit - is no filter, and
//! the element is drawn as it is. A `url` that names no filter, or one
//! that comes to nothing - a region of no size, a region in the units of
//! the box of an element of no box, no primitives - is left out, and
//! when that leaves none the element is not drawn at all. A function on
//! an element of no box is left out.
//!
//! **A `filter` element**'s region is in the units of the box of what the
//! element draws unless `filterUnits` says the user's, by default a tenth
//! of the box more each way; its primitives' `x`, `y`, `width` and
//! `height`, and their lengths, are in the user's units unless
//! `primitiveUnits` says the box's. What a filter leaves out of these
//! comes from the filters its `href` names, and so do its primitives,
//! from the first along the way that has any. A primitive's subregion not
//! given is the union of those of the results it reads, or the filter's
//! region when it reads the element or nothing; one of no size ends the
//! list there. An element that is not a primitive is passed over.
//!
//! **Inputs**: `SourceGraphic` and `SourceAlpha`; `BackgroundImage`,
//! `BackgroundAlpha`, `FillPaint` and `StrokePaint` are read as the
//! element. A primitive whose `in` is not given, or names no result before
//! it, reads the result before it, or the element for the first.
//!
//! **Primitives**: SVG's seventeen, each made as vector.library makes it,
//! in linear light unless `color-interpolation-filters` - inherited -
//! says sRGB. A lighting with no light, a shine whose exponent is not 1
//! to 128, and a convolution whose kernel is not `order` by `order`
//! numbers, whose divisor is 0 or whose target is outside it, make the
//! region clear. `feImage` draws its picture, or the element it names,
//! through the painter (`ext.Aside`).
//!
//! **Pixels**: the regions go through the element's matrix, as the box
//! round each, and a length is stretched as much as the matrix stretches
//! its way: across by its first row, down by its second.

const std = @import("std");
const sdk = @import("sdk");
const vector = sdk.vector;
const document = @import("document.zig");
const values = @import("values.zig");
const Name = document.Name;
const Tag = document.Tag;
const none = document.none;
const Matrix = vector.Matrix;
const Colour = vector.Colour;
const Rect = vector.Rect;

const most_primitives = vector.MAX_FILTER_PRIMITIVES;
/// The most numbers a filter's tables and kernels hold together.
pub const max_numbers = 1024;
/// The most inputs a filter's merges read together.
pub const max_inputs = 128;
/// How far a filter's `href` chain is followed.
const max_hops = 16;

/// A filter made: its primitives, its region, and what they read.
pub const Built = struct {
    primitives: [most_primitives]vector.FilterPrimitive = undefined,
    /// Each primitive's `result` name, null for none given, and its
    /// subregion in user units.
    names: [most_primitives]?[]const u8 = undefined,
    rects: [most_primitives]Rect = undefined,
    count: u32 = 0,
    /// The filter's region in user units, and in pixels.
    region: Rect = .{},
    pixels: Rect = .{},
    numbers: [max_numbers]f32 = undefined,
    number_count: u32 = 0,
    inputs: [max_inputs]i32 = undefined,
    input_count: u32 = 0,

    fn add(built: *Built, primitive: vector.FilterPrimitive, name: ?[]const u8, rect: Rect) void {
        built.primitives[built.count] = primitive;
        built.names[built.count] = name;
        built.rects[built.count] = rect;
        built.count += 1;
    }

    /// Room for `count` numbers; null when there is none left.
    fn numbersFor(built: *Built, count: usize) ?[]f32 {
        if (count > max_numbers - built.number_count) return null;
        const start = built.number_count;
        built.number_count += @intCast(count);
        return built.numbers[start..][0..count];
    }
};

/// What the element a filter is on is to the filter.
pub const Setup = struct {
    /// Its units into pixels.
    space: Matrix,
    /// The box of what it draws, in its units; null for none.
    box: ?Rect,
    /// What percentages are of.
    viewport: [2]f32,
    /// Its `color`, and its font's size, which an `em` is.
    colour: Colour,
    font_size: f32,
};

// --- the list -------------------------------------------------------------------

pub const FunctionKind = enum { blur, drop_shadow, brightness, contrast, grayscale, hue_rotate, invert, opacity, saturate, sepia };

/// A filter function and what it was given, its lengths in user units.
pub const Function = struct {
    kind: FunctionKind,
    amount: f32 = 1,
    dx: f32 = 0,
    dy: f32 = 0,
    deviation: f32 = 0,
    /// A drop shadow's colour; null for the element's `color`.
    colour: ?Colour = null,
};

pub const Entry = union(enum) {
    /// A filter element's id.
    url: []const u8,
    function: Function,
};

/// The entries of a `filter` value, one at a time. `failed` tells an end
/// at one that does not read from the end of the list.
pub const Entries = struct {
    scanner: values.Scanner,
    font_size: f32,
    failed: bool = false,

    pub fn of(text: []const u8, font_size: f32) Entries {
        return .{ .scanner = .{ .text = text }, .font_size = font_size };
    }

    pub fn next(entries: *Entries) ?Entry {
        if (entries.failed) return null;
        const scanner = &entries.scanner;
        scanner.skipSpace();
        if (scanner.at >= scanner.text.len) return null;
        const entry = entries.read() orelse {
            entries.failed = true;
            return null;
        };
        return entry;
    }

    fn read(entries: *Entries) ?Entry {
        const scanner = &entries.scanner;
        const word = scanner.word();
        if (word.len == 0 or scanner.at >= scanner.text.len or scanner.text[scanner.at] != '(') return null;
        scanner.at += 1;
        // What is inside the brackets, as far as the one that closes them.
        const start = scanner.at;
        var depth: u32 = 1;
        while (scanner.at < scanner.text.len) : (scanner.at += 1) {
            if (scanner.text[scanner.at] == '(') depth += 1;
            if (scanner.text[scanner.at] == ')') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (depth != 0) return null;
        const inside = scanner.text[start..scanner.at];
        scanner.at += 1;
        if (values.eqlLower(word, "url")) {
            var id = values.trim(inside);
            if (id.len >= 2 and (id[0] == '"' or id[0] == '\'') and id[id.len - 1] == id[0]) id = id[1 .. id.len - 1];
            if (id.len < 2 or id[0] != '#') return null;
            return .{ .url = id[1..] };
        }
        const kinds = [_]struct { name: []const u8, kind: FunctionKind }{
            .{ .name = "blur", .kind = .blur },
            .{ .name = "drop-shadow", .kind = .drop_shadow },
            .{ .name = "brightness", .kind = .brightness },
            .{ .name = "contrast", .kind = .contrast },
            .{ .name = "grayscale", .kind = .grayscale },
            .{ .name = "hue-rotate", .kind = .hue_rotate },
            .{ .name = "invert", .kind = .invert },
            .{ .name = "opacity", .kind = .opacity },
            .{ .name = "saturate", .kind = .saturate },
            .{ .name = "sepia", .kind = .sepia },
        };
        for (kinds) |known| {
            if (!values.eqlLower(word, known.name)) continue;
            var function = Function{ .kind = known.kind };
            switch (known.kind) {
                .blur => {
                    if (values.trim(inside).len != 0) function.deviation = entries.positiveLength(inside) orelse return null;
                },
                .drop_shadow => if (!entries.shadow(inside, &function)) return null,
                .hue_rotate => function.amount = if (values.trim(inside).len == 0) 0 else angleOf(inside) orelse return null,
                else => {
                    if (values.trim(inside).len != 0) {
                        var amount = amountOf(inside) orelse return null;
                        switch (known.kind) {
                            .grayscale, .invert, .opacity, .sepia => amount = @min(amount, 1),
                            else => {},
                        }
                        function.amount = amount;
                    }
                },
            }
            return .{ .function = function };
        }
        return null;
    }

    /// A length of no percentage, 0 or more, in user units.
    fn positiveLength(entries: *const Entries, text: []const u8) ?f32 {
        const value = lengthIn(text, entries.font_size) orelse return null;
        return if (value >= 0) value else null;
    }

    /// `drop-shadow([colour] dx dy [deviation] [colour])`: the colour
    /// first or last, two lengths or three, spaces between.
    fn shadow(entries: *const Entries, text: []const u8, function: *Function) bool {
        var parts: [5][]const u8 = undefined;
        var count: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            while (i < text.len and isSpace(text[i])) i += 1;
            if (i >= text.len) break;
            const start = i;
            var depth: u32 = 0;
            while (i < text.len and (depth > 0 or !isSpace(text[i]))) : (i += 1) {
                if (text[i] == '(') depth += 1;
                if (text[i] == ')' and depth > 0) depth -= 1;
            }
            if (count == parts.len) return false;
            parts[count] = text[start..i];
            count += 1;
        }
        var lengths: [3]f32 = undefined;
        var length_count: usize = 0;
        var coloured = false;
        for (parts[0..count], 0..) |part, index| {
            if (lengthIn(part, entries.font_size)) |value| {
                if (length_count == 3) return false;
                lengths[length_count] = value;
                length_count += 1;
                continue;
            }
            // A colour, only first or last, and only once; `currentColor`
            // leaves it null, the element's.
            if (coloured or (index != 0 and index != count - 1)) return false;
            coloured = true;
            if (values.eqlLower(values.trim(part), "currentcolor")) continue;
            function.colour = values.colour(part) orelse return false;
        }
        if (length_count < 2) return false;
        function.dx = lengths[0];
        function.dy = lengths[1];
        if (length_count == 3) {
            if (lengths[2] < 0) return false;
            function.deviation = lengths[2];
        }
        return true;
    }
};

/// A length in user units, `em` being `font_size`; null for none, or for
/// a percentage.
fn lengthIn(text: []const u8, font_size: f32) ?f32 {
    var scanner = values.Scanner{ .text = text };
    const number = scanner.number() orelse return null;
    const unit = scanner.unit();
    if (!scanner.done()) return null;
    if (unit.len == 0 or values.eqlLower(unit, "px")) return number;
    if (values.eqlLower(unit, "em")) return number * font_size;
    if (values.eqlLower(unit, "ex")) return number * font_size / 2;
    if (unit[0] == '%') return null;
    const given = values.length(text) orelse return null;
    return given.value;
}

/// A number or a percentage, 0 or more.
fn amountOf(text: []const u8) ?f32 {
    var scanner = values.Scanner{ .text = text };
    var amount = scanner.number() orelse return null;
    if (scanner.take('%')) amount /= 100;
    if (!scanner.done() or amount < 0) return null;
    return amount;
}

/// An angle in degrees, its unit given - `deg`, `grad`, `rad`, `turn` -
/// unless it is 0.
fn angleOf(text: []const u8) ?f32 {
    var scanner = values.Scanner{ .text = text };
    const number = scanner.number() orelse return null;
    const unit = scanner.unit();
    if (!scanner.done()) return null;
    if (unit.len == 0) return if (number == 0) 0 else null;
    if (values.eqlLower(unit, "deg")) return number;
    if (values.eqlLower(unit, "grad")) return number * 0.9;
    if (values.eqlLower(unit, "rad")) return number * 180 / std.math.pi;
    if (values.eqlLower(unit, "turn")) return number * 360;
    return null;
}

fn isSpace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\n' or char == '\r';
}

// --- building ---------------------------------------------------------------------

/// How much a matrix stretches across and down: the lengths of its rows.
pub fn stretchOf(m: Matrix) [2]f32 {
    return .{ @sqrt(m.a * m.a + m.c * m.c), @sqrt(m.b * m.b + m.d * m.d) };
}

/// The box round a rectangle through a matrix.
pub fn boxThrough(m: Matrix, rect: Rect) Rect {
    const corners = [_]vector.Point{
        m.apply(.{ .x = rect.x, .y = rect.y }),
        m.apply(.{ .x = rect.x + rect.width, .y = rect.y }),
        m.apply(.{ .x = rect.x, .y = rect.y + rect.height }),
        m.apply(.{ .x = rect.x + rect.width, .y = rect.y + rect.height }),
    };
    var left = corners[0].x;
    var right = left;
    var top = corners[0].y;
    var bottom = top;
    for (corners[1..]) |corner| {
        left = @min(left, corner.x);
        right = @max(right, corner.x);
        top = @min(top, corner.y);
        bottom = @max(bottom, corner.y);
    }
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

/// A filter function made into a filter of one primitive; false for an
/// element of no box.
pub fn buildFunction(function: Function, setup: *const Setup, built: *Built) bool {
    const box = setup.box orelse return false;
    built.* = .{};
    const wide = function.kind == .blur or function.kind == .drop_shadow;
    // The region round the box, in parts of it.
    const around = if (wide) Rect{ .x = -0.5, .y = -0.5, .width = 2, .height = 2 } else Rect{ .x = -0.1, .y = -0.1, .width = 1.2, .height = 1.2 };
    const region = Rect{ .x = box.x + around.x * box.width, .y = box.y + around.y * box.height, .width = around.width * box.width, .height = around.height * box.height };
    built.region = region;
    built.pixels = boxThrough(setup.space, region);
    const stretch = stretchOf(setup.space);
    var primitive = vector.FilterPrimitive{ .region = built.pixels, .flags = 0 };
    const amount = function.amount;
    switch (function.kind) {
        .blur => {
            primitive.kind = vector.FILTER_GAUSSIAN_BLUR;
            primitive.as = .{ .blur = .{ .deviation_x = function.deviation * stretch[0], .deviation_y = function.deviation * stretch[1] } };
        },
        .drop_shadow => {
            const colour = function.colour orelse setup.colour;
            primitive.kind = vector.FILTER_DROP_SHADOW;
            primitive.as = .{ .drop_shadow = .{
                .dx = function.dx * stretch[0],
                .dy = function.dy * stretch[1],
                .deviation_x = function.deviation * stretch[0],
                .deviation_y = function.deviation * stretch[1],
                .colour = colour,
            } };
        },
        .grayscale, .sepia => {
            const rest = 1 - amount;
            primitive.kind = vector.FILTER_COLOUR_MATRIX;
            primitive.as = .{ .colour_matrix = .{ .values = if (function.kind == .grayscale) .{
                0.2126 + 0.7874 * rest, 0.7152 - 0.7152 * rest, 0.0722 - 0.0722 * rest, 0, 0,
                0.2126 - 0.2126 * rest, 0.7152 + 0.2848 * rest, 0.0722 - 0.0722 * rest, 0, 0,
                0.2126 - 0.2126 * rest, 0.7152 - 0.7152 * rest, 0.0722 + 0.9278 * rest, 0, 0,
                0,                      0,                      0,                      1, 0,
            } else .{
                0.393 + 0.607 * rest, 0.769 - 0.769 * rest, 0.189 - 0.189 * rest, 0, 0,
                0.349 - 0.349 * rest, 0.686 + 0.314 * rest, 0.168 - 0.168 * rest, 0, 0,
                0.272 - 0.272 * rest, 0.534 - 0.534 * rest, 0.131 + 0.869 * rest, 0, 0,
                0,                    0,                    0,                    1, 0,
            } } };
        },
        .saturate => {
            primitive.kind = vector.FILTER_COLOUR_MATRIX;
            primitive.as = .{ .colour_matrix = .{ .values = saturation(amount) } };
        },
        .hue_rotate => {
            primitive.kind = vector.FILTER_COLOUR_MATRIX;
            primitive.as = .{ .colour_matrix = .{ .values = hueRotation(amount) } };
        },
        .invert, .opacity, .brightness, .contrast => {
            var transfer = vector.FilterComponentTransfer{};
            const table = built.numbersFor(2) orelse return false;
            switch (function.kind) {
                .invert => {
                    table[0] = amount;
                    table[1] = 1 - amount;
                    for (transfer.functions[0..3]) |*channel| channel.* = .{ .kind = vector.TRANSFER_TABLE, .table = table.ptr, .table_count = 2 };
                },
                .opacity => {
                    table[0] = 0;
                    table[1] = amount;
                    transfer.functions[3] = .{ .kind = vector.TRANSFER_TABLE, .table = table.ptr, .table_count = 2 };
                },
                .brightness => for (transfer.functions[0..3]) |*channel| {
                    channel.* = .{ .kind = vector.TRANSFER_LINEAR, .slope = amount, .intercept = 0 };
                },
                else => for (transfer.functions[0..3]) |*channel| {
                    channel.* = .{ .kind = vector.TRANSFER_LINEAR, .slope = amount, .intercept = -0.5 * amount + 0.5 };
                },
            }
            primitive.kind = vector.FILTER_COMPONENT_TRANSFER;
            primitive.as = .{ .transfer = transfer };
        },
    }
    built.add(primitive, null, region);
    return true;
}

/// `feColorMatrix`'s `saturate`, of 0 to 1.
fn saturation(amount: f32) [20]f32 {
    const level = @max(amount, 0);
    return .{
        0.213 + 0.787 * level, 0.715 - 0.715 * level, 0.072 - 0.072 * level, 0, 0,
        0.213 - 0.213 * level, 0.715 + 0.285 * level, 0.072 - 0.072 * level, 0, 0,
        0.213 - 0.213 * level, 0.715 - 0.715 * level, 0.072 + 0.928 * level, 0, 0,
        0,                     0,                     0,                     1, 0,
    };
}

/// `feColorMatrix`'s `hueRotate`, by degrees.
fn hueRotation(degrees: f32) [20]f32 {
    const radians = degrees * std.math.pi / 180;
    const cos = @cos(radians);
    const sin = @sin(radians);
    return .{
        0.213 + 0.787 * cos - 0.213 * sin, 0.715 - 0.715 * cos - 0.715 * sin, 0.072 - 0.072 * cos + 0.928 * sin, 0, 0,
        0.213 - 0.213 * cos + 0.143 * sin, 0.715 + 0.285 * cos + 0.140 * sin, 0.072 - 0.072 * cos - 0.283 * sin, 0, 0,
        0.213 - 0.213 * cos - 0.787 * sin, 0.715 - 0.715 * cos + 0.715 * sin, 0.072 + 0.928 * cos + 0.072 * sin, 0, 0,
        0,                                 0,                                 0,                                 1, 0,
    };
}

/// `feColorMatrix`'s `luminanceToAlpha`.
const luminance_to_alpha = [20]f32{
    0,      0,      0,      0, 0,
    0,      0,      0,      0, 0,
    0,      0,      0,      0, 0,
    0.2125, 0.7154, 0.0721, 0, 0,
};

/// The filter element `filter` made for an element; false for one that
/// comes to nothing - which leaves the element undrawn when no other
/// filter of its list is made. `p` is the painter: it gives a property
/// as the element's style has it (`propertyOf`), the `color` an element
/// has (`colourAt`), and an `feImage`'s picture (`filterPicture`).
pub fn build(p: anytype, filter: u32, setup: *const Setup, built: *Built) bool {
    const doc = p.doc;
    built.* = .{};
    const box_units = unitsAre(doc, filter, .filterUnits, true);
    const primitive_box = unitsAre(doc, filter, .primitiveUnits, false);
    // The region, in the box's units or the user's.
    var region: Rect = undefined;
    const names = [4]Name{ .x, .y, .width, .height };
    const axes = [4]values.Axis{ .x, .y, .x, .y };
    const defaults = [4]f32{ -10, -10, 120, 120 };
    var sides: [4]f32 = undefined;
    for (names, axes, defaults, &sides) |name, axis, default, *side| {
        const text = chainAttribute(doc, filter, name);
        const length = (if (text) |given| values.length(given) else null) orelse values.Length{ .value = default, .percent = true };
        side.* = if (box_units) (if (length.percent) length.value / 100 else length.value) else length.resolve(axis, setup.viewport);
    }
    region = .{ .x = sides[0], .y = sides[1], .width = sides[2], .height = sides[3] };
    if (!(region.width > 0) or !(region.height > 0)) return false;
    if (box_units) {
        const box = setup.box orelse return false;
        region = .{ .x = box.x + region.x * box.width, .y = box.y + region.y * box.height, .width = region.width * box.width, .height = region.height * box.height };
    }
    built.region = region;
    built.pixels = boxThrough(setup.space, region);
    const holder = primitivesOf(doc, filter) orelse return false;
    // Lengths in the box's units are its size; in the user's, as they are.
    var scale = [2]f32{ 1, 1 };
    if (primitive_box) {
        const box = setup.box orelse return false;
        scale = .{ box.width, box.height };
    }
    var builder = Builder{ .p_doc = doc, .built = built, .setup = setup, .scale = scale, .primitive_box = primitive_box, .stretch = stretchOf(setup.space) };
    var child = doc.nodes[holder].first_child;
    while (child != none and built.count < most_primitives) : (child = doc.nodes[child].next) {
        const tag = doc.nodes[child].tag;
        if (!isPrimitive(tag)) continue;
        const rect = builder.subregionOf(child, tag) orelse break;
        var primitive = vector.FilterPrimitive{ .region = boxThrough(setup.space, rect) };
        primitive.flags = if (linearIn(p, child)) vector.FILTERF_LINEARRGB else 0;
        if (!builder.make(p, child, tag, rect, &primitive)) primitive = clear(primitive);
        built.add(primitive, doc.get(child, .result), rect);
    }
    return built.count != 0;
}

/// A primitive that makes its subregion clear.
fn clear(primitive: vector.FilterPrimitive) vector.FilterPrimitive {
    return .{ .kind = vector.FILTER_FLOOD, .region = primitive.region, .flags = primitive.flags, .as = .{ .flood = .{ .colour = .{ .a = 0 } } } };
}

fn isPrimitive(tag: Tag) bool {
    return switch (tag) {
        .feBlend, .feColorMatrix, .feComponentTransfer, .feComposite, .feConvolveMatrix, .feDiffuseLighting, .feDisplacementMap, .feDropShadow, .feFlood, .feGaussianBlur, .feImage, .feMerge, .feMorphology, .feOffset, .feSpecularLighting, .feTile, .feTurbulence => true,
        else => false,
    };
}

/// Whether `filterUnits` or `primitiveUnits`, wherever along the `href`
/// chain it is first given, says the box's.
fn unitsAre(doc: anytype, filter: u32, name: Name, default: bool) bool {
    const text = values.trim(chainAttribute(doc, filter, name) orelse return default);
    if (std.mem.eql(u8, text, "objectBoundingBox")) return true;
    if (std.mem.eql(u8, text, "userSpaceOnUse")) return false;
    return default;
}

/// An attribute of a filter, or of the first filter along its `href`
/// chain that has it.
fn chainAttribute(doc: anytype, filter: u32, name: Name) ?[]const u8 {
    var node = filter;
    var hops: u32 = 0;
    while (hops < max_hops) : (hops += 1) {
        if (doc.get(node, name)) |text| return text;
        const next = doc.byHref(doc.get(node, .href) orelse return null) orelse return null;
        if (doc.nodes[next].tag != .filter) return null;
        node = next;
    }
    return null;
}

/// The filter along the `href` chain whose primitives are drawn: the
/// first with children. Null for none, or for a chain that names
/// something other than a filter.
fn primitivesOf(doc: anytype, filter: u32) ?u32 {
    var node = filter;
    var hops: u32 = 0;
    while (hops < max_hops) : (hops += 1) {
        if (doc.nodes[node].first_child != none) return node;
        const next = doc.byHref(doc.get(node, .href) orelse return null) orelse return null;
        if (doc.nodes[next].tag != .filter) return null;
        node = next;
    }
    return null;
}

/// Whether a primitive works in linear light: its
/// `color-interpolation-filters`, or the nearest of its ancestors' - all
/// but `sRGB` being linear.
fn linearIn(p: anytype, node: u32) bool {
    var at = node;
    while (at != none) : (at = p.doc.nodes[at].parent) {
        const text = values.trim(p.propertyOf(at, .@"color-interpolation-filters") orelse continue);
        if (std.mem.eql(u8, text, "inherit")) continue;
        return !std.mem.eql(u8, text, "sRGB");
    }
    return true;
}

const Builder = struct {
    p_doc: *const document.Document,
    built: *Built,
    setup: *const Setup,
    /// Lengths' units in user units each way.
    scale: [2]f32,
    primitive_box: bool,
    /// User units into pixels each way.
    stretch: [2]f32,

    /// A primitive's subregion in user units; null for one of no size.
    fn subregionOf(builder: *const Builder, node: u32, tag: Tag) ?Rect {
        const doc = builder.p_doc;
        const default = builder.defaultSubregion(node, tag);
        var sides = [4]f32{ default.x, default.y, default.width, default.height };
        const names = [4]Name{ .x, .y, .width, .height };
        const axes = [4]values.Axis{ .x, .y, .x, .y };
        for (names, axes, 0..) |name, axis, index| {
            const length = values.length(doc.get(node, name) orelse continue) orelse continue;
            if (builder.primitive_box) {
                const box = builder.setup.box orelse return null;
                const value = if (length.percent) length.value / 100 else length.value;
                sides[index] = switch (index) {
                    0 => box.x + value * box.width,
                    1 => box.y + value * box.height,
                    2 => value * box.width,
                    else => value * box.height,
                };
            } else sides[index] = length.resolve(axis, builder.setup.viewport);
        }
        const rect = Rect{ .x = sides[0], .y = sides[1], .width = sides[2], .height = sides[3] };
        if (!(rect.width > 0) or !(rect.height > 0)) return null;
        return rect;
    }

    /// The union of the subregions of the results a primitive reads; the
    /// filter's region when it reads the element, or nothing.
    fn defaultSubregion(builder: *const Builder, node: u32, tag: Tag) Rect {
        const doc = builder.p_doc;
        const built = builder.built;
        const reads: []const Name = switch (tag) {
            .feBlend, .feComposite, .feDisplacementMap => &.{ .in, .in2 },
            .feColorMatrix, .feComponentTransfer, .feConvolveMatrix, .feDiffuseLighting, .feDropShadow, .feGaussianBlur, .feMorphology, .feOffset, .feSpecularLighting => &.{.in},
            else => &.{},
        };
        var all: ?Rect = null;
        if (tag == .feMerge) {
            var child = doc.nodes[node].first_child;
            while (child != none) : (child = doc.nodes[child].next) {
                const input = builder.inputOf(child, .in);
                if (input < 0) return built.region;
                all = unite(all, built.rects[@intCast(input)]);
            }
        }
        for (reads) |name| {
            const input = builder.inputOf(node, name);
            if (input < 0) return built.region;
            all = unite(all, built.rects[@intCast(input)]);
        }
        const found = all orelse return built.region;
        if (!(found.width > 0) or !(found.height > 0)) return built.region;
        return found;
    }

    /// What a primitive's `in` or `in2` names: `FILTERIN_*`, or the
    /// latest result by the name before it. Not given, or naming none,
    /// the one before it, or the element for the first.
    fn inputOf(builder: *const Builder, node: u32, name: Name) i32 {
        const built = builder.built;
        const previous: i32 = if (built.count == 0) vector.FILTERIN_SOURCE else @intCast(built.count - 1);
        const text = values.trim(builder.p_doc.get(node, name) orelse return previous);
        if (std.mem.eql(u8, text, "SourceAlpha")) return vector.FILTERIN_SOURCEALPHA;
        for ([_][]const u8{ "SourceGraphic", "BackgroundImage", "BackgroundAlpha", "FillPaint", "StrokePaint" }) |known| {
            if (std.mem.eql(u8, text, known)) return vector.FILTERIN_SOURCE;
        }
        var index = built.count;
        while (index > 0) {
            index -= 1;
            if (built.names[index]) |kept| {
                if (std.mem.eql(u8, values.trim(kept), text)) return @intCast(index);
            }
        }
        return previous;
    }

    fn numberOf(builder: *const Builder, node: u32, name: Name, default: f32) f32 {
        return values.number(builder.p_doc.get(node, name) orelse return default) orelse default;
    }

    fn word(builder: *const Builder, node: u32, name: Name) []const u8 {
        return values.trim(builder.p_doc.get(node, name) orelse "");
    }

    /// Up to `room.len` numbers of a list into `room`; how many there
    /// were, which may be more than it holds; null for a list in error.
    fn listOf(text: []const u8, room: []f32) ?usize {
        var scanner = values.Scanner{ .text = text };
        var count: usize = 0;
        while (true) {
            scanner.skipSeparator();
            if (scanner.at >= scanner.text.len) return count;
            const number = scanner.number() orelse return null;
            if (count < room.len) room[count] = number;
            count += 1;
        }
    }

    /// A primitive's parameters; false for one that makes its region
    /// clear.
    fn make(builder: *Builder, p: anytype, node: u32, tag: Tag, rect: Rect, primitive: *vector.FilterPrimitive) bool {
        const doc = builder.p_doc;
        const built = builder.built;
        const stretch = builder.stretch;
        primitive.in = builder.inputOf(node, .in);
        switch (tag) {
            .feBlend => {
                primitive.kind = vector.FILTER_BLEND;
                primitive.in2 = builder.inputOf(node, .in2);
                // `plus-lighter` is a mode of `mix-blend-mode` alone.
                const mode = blendMode(builder.word(node, .mode)) orelse vector.BLEND_NORMAL;
                primitive.as = .{ .blend = .{ .mode = if (mode == vector.BLEND_PLUS_LIGHTER) vector.BLEND_NORMAL else mode } };
            },
            .feColorMatrix => {
                primitive.kind = vector.FILTER_COLOUR_MATRIX;
                primitive.as = .{ .colour_matrix = .{} };
                const kind = builder.word(node, .type);
                var list: [20]f32 = undefined;
                const given = doc.get(node, .values);
                const count = if (given) |text| listOf(text, &list) else null;
                if (std.mem.eql(u8, kind, "saturate")) {
                    if (count) |count_read| primitive.as.colour_matrix.values = saturation(if (count_read == 0) 1 else @min(@max(list[0], 0), 1));
                } else if (std.mem.eql(u8, kind, "hueRotate")) {
                    if (count) |count_read| primitive.as.colour_matrix.values = hueRotation(if (count_read == 0) 0 else list[0]);
                } else if (std.mem.eql(u8, kind, "luminanceToAlpha")) {
                    primitive.as.colour_matrix.values = luminance_to_alpha;
                } else if (count) |count_read| {
                    if (count_read == 20) primitive.as.colour_matrix.values = list;
                }
            },
            .feComponentTransfer => {
                primitive.kind = vector.FILTER_COMPONENT_TRANSFER;
                var transfer = vector.FilterComponentTransfer{};
                var child = doc.nodes[node].first_child;
                while (child != none) : (child = doc.nodes[child].next) {
                    const channel: usize = switch (doc.nodes[child].tag) {
                        .feFuncR => 0,
                        .feFuncG => 1,
                        .feFuncB => 2,
                        .feFuncA => 3,
                        else => continue,
                    };
                    if (builder.transferOf(child)) |function| transfer.functions[channel] = function;
                }
                primitive.as = .{ .transfer = transfer };
            },
            .feComposite => {
                primitive.kind = vector.FILTER_COMPOSITE;
                primitive.in2 = builder.inputOf(node, .in2);
                const operator = builder.word(node, .operator);
                var composite = vector.FilterComposite{};
                const operators = [_]struct { name: []const u8, value: u32 }{
                    .{ .name = "in", .value = vector.COMPOSITE_IN },
                    .{ .name = "out", .value = vector.COMPOSITE_OUT },
                    .{ .name = "atop", .value = vector.COMPOSITE_ATOP },
                    .{ .name = "xor", .value = vector.COMPOSITE_XOR },
                    .{ .name = "lighter", .value = vector.COMPOSITE_LIGHTER },
                    .{ .name = "arithmetic", .value = vector.COMPOSITE_ARITHMETIC },
                };
                for (operators) |known| {
                    if (std.mem.eql(u8, operator, known.name)) composite.operator = known.value;
                }
                if (composite.operator == vector.COMPOSITE_ARITHMETIC) {
                    composite.k = .{ builder.numberOf(node, .k1, 0), builder.numberOf(node, .k2, 0), builder.numberOf(node, .k3, 0), builder.numberOf(node, .k4, 0) };
                }
                primitive.as = .{ .composite = composite };
            },
            .feConvolveMatrix => return builder.convolve(node, primitive),
            .feDiffuseLighting, .feSpecularLighting => {
                const specular = tag == .feSpecularLighting;
                primitive.kind = if (specular) vector.FILTER_SPECULAR_LIGHTING else vector.FILTER_DIFFUSE_LIGHTING;
                var lighting = vector.FilterLighting{
                    .surface_scale = builder.numberOf(node, .surfaceScale, 1),
                    .constant = builder.numberOf(node, if (specular) .specularConstant else .diffuseConstant, 1),
                };
                if (specular) {
                    lighting.exponent = builder.numberOf(node, .specularExponent, 1);
                    if (!(lighting.exponent >= 1 and lighting.exponent <= 128)) return false;
                }
                lighting.colour = .{ .r = 1, .g = 1, .b = 1 };
                if (p.propertyOf(node, .@"lighting-color")) |text| {
                    if (values.eqlLower(values.trim(text), "currentcolor")) {
                        lighting.colour = p.colourAt(node);
                    } else if (p.colourOf(text)) |colour| lighting.colour = colour;
                }
                lighting.colour.a = 1;
                lighting.light = builder.lightOf(node) orelse return false;
                primitive.as = .{ .lighting = lighting };
            },
            .feDisplacementMap => {
                primitive.kind = vector.FILTER_DISPLACEMENT_MAP;
                primitive.in2 = builder.inputOf(node, .in2);
                const scale = builder.numberOf(node, .scale, 0) * (builder.scale[0] + builder.scale[1]) / 2;
                primitive.as = .{ .displacement = .{
                    .scale_x = scale * stretch[0],
                    .scale_y = scale * stretch[1],
                    .x_channel = channelOf(builder.word(node, .xChannelSelector)),
                    .y_channel = channelOf(builder.word(node, .yChannelSelector)),
                } };
            },
            .feDropShadow => {
                primitive.kind = vector.FILTER_DROP_SHADOW;
                const deviation = builder.deviationOf(node, 2);
                primitive.as = .{ .drop_shadow = .{
                    .dx = builder.numberOf(node, .dx, 2) * builder.scale[0] * stretch[0],
                    .dy = builder.numberOf(node, .dy, 2) * builder.scale[1] * stretch[1],
                    .deviation_x = deviation[0] * stretch[0],
                    .deviation_y = deviation[1] * stretch[1],
                    .colour = floodOf(p, node),
                } };
            },
            .feFlood => {
                primitive.kind = vector.FILTER_FLOOD;
                primitive.as = .{ .flood = .{ .colour = floodOf(p, node) } };
            },
            .feGaussianBlur => {
                primitive.kind = vector.FILTER_GAUSSIAN_BLUR;
                const deviation = builder.deviationOf(node, 0);
                primitive.as = .{ .blur = .{ .deviation_x = deviation[0] * stretch[0], .deviation_y = deviation[1] * stretch[1] } };
            },
            .feImage => {
                primitive.kind = vector.FILTER_IMAGE;
                primitive.as = .{ .image = p.filterPicture(node, rect, builder.setup) orelse return false };
            },
            .feMerge => {
                primitive.kind = vector.FILTER_MERGE;
                const start = built.input_count;
                var child = doc.nodes[node].first_child;
                while (child != none and built.input_count < max_inputs) : (child = doc.nodes[child].next) {
                    built.inputs[built.input_count] = builder.inputOf(child, .in);
                    built.input_count += 1;
                }
                primitive.as = .{ .merge = .{ .inputs = built.inputs[start..].ptr, .count = built.input_count - start } };
            },
            .feMorphology => {
                primitive.kind = vector.FILTER_MORPHOLOGY;
                var radius = [2]f32{ builder.scale[0], builder.scale[1] };
                if (doc.get(node, .radius)) |text| {
                    var list: [2]f32 = undefined;
                    var rx: f32 = 0;
                    var ry: f32 = 0;
                    if (listOf(text, &list)) |count_read| {
                        if (count_read == 2) {
                            rx = list[0];
                            ry = list[1];
                        } else if (count_read == 1) {
                            rx = list[0];
                            ry = list[0];
                        }
                    }
                    if (rx == 0 and ry == 0) {
                        rx = 1;
                        ry = 1;
                    }
                    if (rx == 0) rx = 1;
                    if (ry == 0) ry = 1;
                    if (rx > 0 and ry > 0) radius = .{ rx * builder.scale[0], ry * builder.scale[1] };
                }
                primitive.as = .{ .morphology = .{
                    .operator = if (std.mem.eql(u8, builder.word(node, .operator), "dilate")) vector.MORPHOLOGY_DILATE else vector.MORPHOLOGY_ERODE,
                    .radius_x = radius[0] * stretch[0],
                    .radius_y = radius[1] * stretch[1],
                } };
            },
            .feOffset => {
                primitive.kind = vector.FILTER_OFFSET;
                primitive.as = .{ .offset = .{
                    .dx = builder.numberOf(node, .dx, 0) * builder.scale[0] * stretch[0],
                    .dy = builder.numberOf(node, .dy, 0) * builder.scale[1] * stretch[1],
                } };
            },
            .feTile => primitive.kind = vector.FILTER_TILE,
            .feTurbulence => {
                primitive.kind = vector.FILTER_TURBULENCE;
                var turbulence = vector.FilterTurbulence{};
                if (doc.get(node, .baseFrequency)) |text| {
                    var list: [2]f32 = undefined;
                    if (listOf(text, &list)) |count_read| {
                        var fx: f32 = 0;
                        var fy: f32 = 0;
                        if (count_read == 2) {
                            fx = list[0];
                            fy = list[1];
                        } else if (count_read == 1) {
                            fx = list[0];
                            fy = list[0];
                        }
                        if (fx >= 0 and fy >= 0) {
                            turbulence.base_x = fx;
                            turbulence.base_y = fy;
                        }
                    }
                }
                const octaves = @max(builder.numberOf(node, .numOctaves, 1), 0);
                turbulence.octaves = @intFromFloat(@min(@round(octaves), 64));
                turbulence.seed = @trunc(builder.numberOf(node, .seed, 0));
                turbulence.fractal = @intFromBool(std.mem.eql(u8, builder.word(node, .type), "fractalNoise"));
                turbulence.stitch = @intFromBool(std.mem.eql(u8, builder.word(node, .stitchTiles), "stitch"));
                // User units into pixels: stretched, and moved, not turned.
                turbulence.matrix = .{ .a = stretch[0], .d = stretch[1], .e = builder.setup.space.e, .f = builder.setup.space.f };
                turbulence.tile_x = rect.x;
                turbulence.tile_y = rect.y;
                turbulence.tile_width = rect.width;
                turbulence.tile_height = rect.height;
                primitive.as = .{ .turbulence = turbulence };
            },
            else => return false,
        }
        return true;
    }

    /// A `stdDeviation` - one number for both ways, or two - in the
    /// primitive's units; 0 both ways for one in error or below 0.
    fn deviationOf(builder: *const Builder, node: u32, default: f32) [2]f32 {
        var deviation = [2]f32{ default, default };
        if (builder.p_doc.get(node, .stdDeviation)) |text| {
            var list: [2]f32 = undefined;
            const count = listOf(text, &list) orelse 0;
            deviation = if (count == 2) list else if (count == 1) .{ list[0], list[0] } else .{ 0, 0 };
        }
        return .{ @max(deviation[0] * builder.scale[0], 0), @max(deviation[1] * builder.scale[1], 0) };
    }

    fn transferOf(builder: *Builder, node: u32) ?vector.FilterTransfer {
        const kind = builder.word(node, .type);
        if (std.mem.eql(u8, kind, "identity")) return .{};
        const table = std.mem.eql(u8, kind, "table");
        if (table or std.mem.eql(u8, kind, "discrete")) {
            var function = vector.FilterTransfer{ .kind = if (table) vector.TRANSFER_TABLE else vector.TRANSFER_DISCRETE };
            const text = builder.p_doc.get(node, .tableValues) orelse return function;
            const room = builder.built.numbers[builder.built.number_count..];
            const count = listOf(text, room) orelse return function;
            if (count > room.len) return function;
            function.table = room.ptr;
            function.table_count = @intCast(count);
            builder.built.number_count += @intCast(count);
            return function;
        }
        if (std.mem.eql(u8, kind, "linear")) return .{
            .kind = vector.TRANSFER_LINEAR,
            .slope = builder.numberOf(node, .slope, 1),
            .intercept = builder.numberOf(node, .intercept, 0),
        };
        if (std.mem.eql(u8, kind, "gamma")) return .{
            .kind = vector.TRANSFER_GAMMA,
            .amplitude = builder.numberOf(node, .amplitude, 1),
            .exponent = builder.numberOf(node, .exponent, 1),
            .offset = builder.numberOf(node, .offset, 0),
        };
        return null;
    }

    /// `feConvolveMatrix`; false for one that makes its region clear.
    fn convolve(builder: *Builder, node: u32, primitive: *vector.FilterPrimitive) bool {
        const doc = builder.p_doc;
        primitive.kind = vector.FILTER_CONVOLVE;
        var order = [2]i32{ 3, 3 };
        if (doc.get(node, .order)) |text| {
            var list: [2]f32 = undefined;
            const count = listOf(text, &list) orelse 0;
            const x: i32 = if (count >= 1) @intFromFloat(@min(@max(@trunc(list[0]), -1e6), 1e6)) else 3;
            const y: i32 = if (count >= 2) @intFromFloat(@min(@max(@trunc(list[1]), -1e6), 1e6)) else x;
            if (x > 0 and y > 0) order = .{ x, y };
        }
        const count: usize = @intCast(@as(i64, order[0]) * order[1]);
        const kernel = builder.built.numbersFor(count) orelse return false;
        const given = listOf(doc.get(node, .kernelMatrix) orelse "", kernel) orelse 0;
        if (given != count) return false;
        var sum: f32 = 0;
        for (kernel) |weight| sum += weight;
        sum = @round(sum * 1_000_000) / 1_000_000;
        if (sum == 0) sum = 1;
        const divisor = builder.numberOf(node, .divisor, sum);
        if (divisor == 0) return false;
        var target: [2]i32 = undefined;
        for ([2]Name{ .targetX, .targetY }, 0..) |name, axis| {
            const default: f32 = @floor(@as(f32, @floatFromInt(order[axis])) / 2);
            const read = @trunc(builder.numberOf(node, name, default));
            if (!(read >= 0) or read >= @as(f32, @floatFromInt(order[axis]))) return false;
            target[axis] = @intFromFloat(read);
        }
        const edge = builder.word(node, .edgeMode);
        primitive.as = .{ .convolve = .{
            .order_x = @intCast(order[0]),
            .order_y = @intCast(order[1]),
            .kernel = kernel.ptr,
            .divisor = divisor,
            .bias = builder.numberOf(node, .bias, 0),
            .target_x = target[0],
            .target_y = target[1],
            .edge = if (std.mem.eql(u8, edge, "none")) vector.EDGE_NONE else if (std.mem.eql(u8, edge, "wrap")) vector.EDGE_WRAP else vector.EDGE_DUPLICATE,
            .preserve_alpha = @intFromBool(std.mem.eql(u8, builder.word(node, .preserveAlpha), "true")),
        } };
        return true;
    }

    /// A lighting's light - its first child that is one - in pixels.
    fn lightOf(builder: *const Builder, node: u32) ?vector.FilterLight {
        const doc = builder.p_doc;
        var child = doc.nodes[node].first_child;
        while (child != none) : (child = doc.nodes[child].next) {
            const tag = doc.nodes[child].tag;
            if (tag != .feDistantLight and tag != .fePointLight and tag != .feSpotLight) continue;
            if (tag == .feDistantLight) return .{
                .kind = vector.LIGHT_DISTANT,
                .azimuth = builder.numberOf(child, .azimuth, 0),
                .elevation = builder.numberOf(child, .elevation, 0),
            };
            const space = builder.setup.space;
            const depth = @sqrt(space.a * space.a + space.d * space.d) / std.math.sqrt2;
            const at = space.apply(.{ .x = builder.numberOf(child, .x, 0), .y = builder.numberOf(child, .y, 0) });
            var light = vector.FilterLight{
                .kind = if (tag == .fePointLight) vector.LIGHT_POINT else vector.LIGHT_SPOT,
                .x = at.x,
                .y = at.y,
                .z = builder.numberOf(child, .z, 0) * depth,
            };
            if (tag == .feSpotLight) {
                const to = space.apply(.{ .x = builder.numberOf(child, .pointsAtX, 0), .y = builder.numberOf(child, .pointsAtY, 0) });
                light.at_x = to.x;
                light.at_y = to.y;
                light.at_z = builder.numberOf(child, .pointsAtZ, 0) * depth;
                const exponent = builder.numberOf(child, .specularExponent, 1);
                light.spot_exponent = if (exponent >= 0) exponent else 1;
                if (doc.get(child, .limitingConeAngle)) |text| {
                    if (values.number(text)) |angle| light.cone = @max(@abs(angle), 1e-4);
                }
            }
            return light;
        }
        return null;
    }
};

/// A flood's colour: its `flood-color`, `currentColor` the element's
/// `color`, times its `flood-opacity`. Neither is inherited but by
/// `inherit`, which takes the parent's.
fn floodOf(p: anytype, node: u32) Colour {
    var colour = floodColour(p, node, 0);
    colour.a *= floodOpacity(p, node, 0);
    return colour;
}

fn floodColour(p: anytype, node: u32, depth: u32) Colour {
    const text = values.trim(p.propertyOf(node, .@"flood-color") orelse return .{});
    if (std.mem.eql(u8, text, "inherit")) {
        const parent = p.doc.nodes[node].parent;
        return if (parent == document.none or depth == max_inherit) .{} else floodColour(p, parent, depth + 1);
    }
    if (values.eqlLower(text, "currentcolor")) return p.colourAt(node);
    return p.colourOf(text) orelse .{};
}

fn floodOpacity(p: anytype, node: u32, depth: u32) f32 {
    const text = values.trim(p.propertyOf(node, .@"flood-opacity") orelse return 1);
    if (std.mem.eql(u8, text, "inherit")) {
        const parent = p.doc.nodes[node].parent;
        return if (parent == document.none or depth == max_inherit) 1 else floodOpacity(p, parent, depth + 1);
    }
    return values.fraction(text) orelse 1;
}

/// How many elements up an `inherit` is followed.
const max_inherit = 16;

fn channelOf(text: []const u8) u32 {
    if (std.mem.eql(u8, text, "R")) return vector.CHANNEL_R;
    if (std.mem.eql(u8, text, "G")) return vector.CHANNEL_G;
    if (std.mem.eql(u8, text, "B")) return vector.CHANNEL_B;
    return vector.CHANNEL_A;
}

/// A blend mode by its CSS name (`mix-blend-mode`, `feBlend`'s `mode`);
/// null for none known.
pub fn blendMode(text: []const u8) ?u32 {
    const modes = [_]struct { name: []const u8, mode: u32 }{
        .{ .name = "normal", .mode = vector.BLEND_NORMAL },
        .{ .name = "multiply", .mode = vector.BLEND_MULTIPLY },
        .{ .name = "screen", .mode = vector.BLEND_SCREEN },
        .{ .name = "overlay", .mode = vector.BLEND_OVERLAY },
        .{ .name = "darken", .mode = vector.BLEND_DARKEN },
        .{ .name = "lighten", .mode = vector.BLEND_LIGHTEN },
        .{ .name = "color-dodge", .mode = vector.BLEND_COLOUR_DODGE },
        .{ .name = "color-burn", .mode = vector.BLEND_COLOUR_BURN },
        .{ .name = "hard-light", .mode = vector.BLEND_HARD_LIGHT },
        .{ .name = "soft-light", .mode = vector.BLEND_SOFT_LIGHT },
        .{ .name = "difference", .mode = vector.BLEND_DIFFERENCE },
        .{ .name = "exclusion", .mode = vector.BLEND_EXCLUSION },
        .{ .name = "hue", .mode = vector.BLEND_HUE },
        .{ .name = "saturation", .mode = vector.BLEND_SATURATION },
        .{ .name = "color", .mode = vector.BLEND_COLOUR },
        .{ .name = "luminosity", .mode = vector.BLEND_LUMINOSITY },
        .{ .name = "plus-lighter", .mode = vector.BLEND_PLUS_LIGHTER },
    };
    for (modes) |known| {
        if (std.mem.eql(u8, text, known.name)) return known.mode;
    }
    return null;
}

fn unite(one: ?Rect, other: Rect) Rect {
    const x = one orelse return other;
    const left = @min(x.x, other.x);
    const top = @min(x.y, other.y);
    const right = @max(x.x + x.width, other.x + other.width);
    const bottom = @max(x.y + x.height, other.y + other.height);
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

/// A painter of nothing but the document, for the builder.
const Bare = struct {
    doc: *const document.Document,

    pub fn propertyOf(bare: *Bare, node: u32, name: Name) ?[]const u8 {
        return bare.doc.get(node, name);
    }
    pub fn colourAt(_: *Bare, _: u32) Colour {
        return .{ .r = 1 };
    }
    pub fn colourOf(_: *Bare, text: []const u8) ?Colour {
        return values.colour(text);
    }
    pub fn filterPicture(_: *Bare, _: u32, _: Rect, _: *const Setup) ?vector.FilterImage {
        return null;
    }
};

fn builtIn(comptime text: []const u8, box: ?Rect, built: *Built) !bool {
    var copy: [text.len]u8 = text[0..text.len].*;
    const counts = document.count(&copy) orelse return error.NotSvg;
    var block: [8192]u8 align(8) = undefined;
    const doc = document.build(&copy, counts, block[0..document.bytesFor(counts)]);
    var bare = Bare{ .doc = &doc };
    const setup = Setup{ .space = .{ .a = 2, .d = 2 }, .box = box, .viewport = .{ 100, 100 }, .colour = .{}, .font_size = 16 };
    return build(&bare, doc.byId("f") orelse return error.NoFilter, &setup, built);
}

test "a filter's region and primitives: units, inputs by name, subregions, pixels" {
    var built: Built = undefined;
    const box = Rect{ .x = 10, .y = 10, .width = 20, .height = 10 };
    try testing.expect(try builtIn(
        \\<svg><filter id="f"><feFlood flood-color="red" flood-opacity="0.5" result="a"/>
        \\<feOffset dx="3" in="SourceAlpha" x="5" width="10"/><feBlend in="a" in2="nothing" mode="multiply"/>
        \\<desc/><feGaussianBlur stdDeviation="1 2" color-interpolation-filters="sRGB"/></filter></svg>
    , box, &built));
    try testing.expectEqual(@as(u32, 4), built.count);
    // A tenth of the box more each way, through the matrix.
    try testing.expectEqual(Rect{ .x = 8, .y = 9, .width = 24, .height = 12 }, built.region);
    try testing.expectEqual(Rect{ .x = 16, .y = 18, .width = 48, .height = 24 }, built.pixels);
    const flood = built.primitives[0];
    try testing.expectEqual(vector.FILTER_FLOOD, flood.kind);
    try testing.expectEqual(@as(f32, 0.5), flood.as.flood.colour.a);
    const offset = built.primitives[1];
    try testing.expectEqual(vector.FILTERIN_SOURCEALPHA, offset.in);
    try testing.expectEqual(@as(f32, 6), offset.as.offset.dx);
    try testing.expectEqual(Rect{ .x = 10, .y = 18, .width = 20, .height = 24 }, offset.region);
    const blend = built.primitives[2];
    try testing.expectEqual(@as(i32, 0), blend.in);
    try testing.expectEqual(@as(i32, 1), blend.in2);
    try testing.expectEqual(vector.BLEND_MULTIPLY, blend.as.blend.mode);
    try testing.expectEqual(vector.FILTERF_LINEARRGB, blend.flags);
    const blur = built.primitives[3];
    try testing.expectEqual(@as(i32, 2), blur.in);
    try testing.expectEqual(@as(u32, 0), blur.flags);
    try testing.expectEqual(@as(f32, 4), blur.as.blur.deviation_y);
}

test "a filter of nothing, of no box, in error; a kernel of the wrong size clear" {
    var built: Built = undefined;
    try testing.expect(!try builtIn("<svg><filter id='f'/></svg>", .{ .width = 1, .height = 1 }, &built));
    try testing.expect(!try builtIn("<svg><filter id='f'><feFlood/></filter></svg>", null, &built));
    try testing.expect(try builtIn("<svg><filter id='f' filterUnits='userSpaceOnUse'><feFlood/></filter></svg>", null, &built));
    try testing.expect(!try builtIn("<svg><filter id='f' width='0'><feFlood/></filter></svg>", .{ .width = 1, .height = 1 }, &built));
    try testing.expect(try builtIn("<svg><filter id='f'><feConvolveMatrix kernelMatrix='1 2 3'/></filter></svg>", .{ .width = 1, .height = 1 }, &built));
    try testing.expectEqual(vector.FILTER_FLOOD, built.primitives[0].kind);
    try testing.expectEqual(@as(f32, 0), built.primitives[0].as.flood.colour.a);
    // Primitives from the filter the href names, the region its own.
    try testing.expect(try builtIn("<svg><filter id='g' x='0'><feTile/></filter><filter id='f' href='#g' y='0'/></svg>", .{ .width = 10, .height = 10 }, &built));
    try testing.expectEqual(vector.FILTER_TILE, built.primitives[0].kind);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 12, .height = 12 }, built.region);
}

test "the list: urls and functions, and one in error" {
    var list = Entries.of("url(#a) blur(2px) drop-shadow(red 1 2 3) hue-rotate(0.5turn) grayscale(50%)", 16);
    try testing.expectEqualStrings("a", list.next().?.url);
    try testing.expectEqual(@as(f32, 2), list.next().?.function.deviation);
    const shadow = list.next().?.function;
    try testing.expectEqual(@as(f32, 3), shadow.deviation);
    try testing.expectEqual(@as(f32, 1), shadow.colour.?.r);
    try testing.expectEqual(@as(f32, 180), list.next().?.function.amount);
    try testing.expectEqual(@as(f32, 0.5), list.next().?.function.amount);
    try testing.expect(list.next() == null);
    try testing.expect(!list.failed);
    for ([_][]const u8{ "blur(-1)", "blur(5%)", "hue-rotate(45)", "drop-shadow(4)", "drop-shadow(red, 1, 2)", "drop-shadow(1 2 3 4)", "invert(-1)", "nothing(1)" }) |text| {
        var bad = Entries.of(text, 16);
        while (bad.next()) |_| {}
        try testing.expect(bad.failed);
    }
    var em = Entries.of("drop-shadow(0.5em 1em)", 10);
    try testing.expectEqual(@as(f32, 5), em.next().?.function.dx);
}

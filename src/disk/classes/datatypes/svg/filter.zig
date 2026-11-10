// SPDX-License-Identifier: MIT
//! What a `filter` comes to (since 1.3): a blur of what the element
//! draws, what it draws as it is, nothing, or what this reader cannot
//! make.
//!
//! The primitives are followed in their order, each one's result kept by
//! its `result` name, and each is one of four things: clear, the element
//! as drawn (`SourceGraphic`), the element blurred by a deviation, or
//! something else. `feGaussianBlur` blurs the element as drawn, or one
//! blurred already - two blurs being one of the root of their squares
//! summed; `feFlood` of no opacity is clear; `feBlend` in its normal mode
//! over something clear is what it blends, and so is something clear
//! over it. That is what Inkscape writes for a blur, and what Figma does
//! for one - a clear flood with the element blended over it, then the
//! blur. Anything else - another primitive, `SourceAlpha`, a flood of a
//! colour - is something else, and the filter is one this reader cannot
//! make: the element is drawn without it, rather than not at all.
//!
//! The filter's result is its last primitive's. One with none is clear,
//! as SVG has it, and so is a filter whose last result is.

const std = @import("std");
const document = @import("document.zig");
const values = @import("values.zig");
const Document = document.Document;
const none = document.none;

/// A filter's result.
pub const Effect = union(enum) {
    /// The element as drawn: the filter changes nothing but its region.
    source,
    /// The element blurred, by a deviation across and down in the
    /// filter's primitive units.
    blur: [2]f32,
    /// Nothing is drawn.
    clear,
    /// What this reader cannot make.
    unknown,
};

/// The most results a filter's primitives are kept by.
const max_results = 16;

const Kept = struct { name: []const u8, effect: Effect };

/// What the `filter` element `filter` makes of an element.
pub fn effectOf(doc: *const Document, filter: u32) Effect {
    var kept: [max_results]Kept = undefined;
    var kept_count: usize = 0;
    var last: ?Effect = null;
    var child = doc.nodes[filter].first_child;
    while (child != none) : (child = doc.nodes[child].next) {
        const tag = doc.nodes[child].tag;
        const effect: Effect = switch (tag) {
            .feGaussianBlur => blur: {
                const input = inputOf(doc, child, .in, last, kept[0..kept_count]);
                const deviation = deviationOf(doc.get(child, .stdDeviation)) orelse break :blur .unknown;
                break :blur switch (input) {
                    .source => if (deviation[0] == 0 and deviation[1] == 0) .source else .{ .blur = deviation },
                    .blur => |had| .{ .blur = .{ hypot(had[0], deviation[0]), hypot(had[1], deviation[1]) } },
                    .clear => .clear,
                    .unknown => .unknown,
                };
            },
            .feFlood => flood: {
                const opacity = if (doc.get(child, .@"flood-opacity")) |t| values.fraction(t) orelse 1 else 1;
                break :flood if (opacity == 0) .clear else .unknown;
            },
            .feBlend => blend: {
                const mode = values.trim(doc.get(child, .mode) orelse "normal");
                if (!std.mem.eql(u8, mode, "normal")) break :blend .unknown;
                const top = inputOf(doc, child, .in, last, kept[0..kept_count]);
                const under = inputOf(doc, child, .in2, last, kept[0..kept_count]);
                if (under == .clear) break :blend top;
                if (top == .clear) break :blend under;
                break :blend .unknown;
            },
            .feOther => .unknown,
            // Not a primitive: a `desc`, a `title`.
            else => continue,
        };
        if (doc.get(child, .result)) |name| {
            if (kept_count < max_results) {
                kept[kept_count] = .{ .name = values.trim(name), .effect = effect };
                kept_count += 1;
            }
        }
        last = effect;
    }
    return last orelse .clear;
}

/// What a primitive's `in` or `in2` names: the element as drawn, a
/// result kept, or - when it names none - the primitive before's, and
/// the element as drawn for the first.
fn inputOf(doc: *const Document, node: u32, name: document.Name, last: ?Effect, kept: []const Kept) Effect {
    const text = values.trim(doc.get(node, name) orelse "");
    if (text.len == 0) return last orelse .source;
    if (std.mem.eql(u8, text, "SourceGraphic")) return .source;
    // The latest kept by the name.
    var i = kept.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, kept[i].name, text)) return kept[i].effect;
    }
    // `SourceAlpha`, the background, the fill and the stroke.
    for ([_][]const u8{ "SourceAlpha", "BackgroundImage", "BackgroundAlpha", "FillPaint", "StrokePaint" }) |known| {
        if (std.mem.eql(u8, text, known)) return .unknown;
    }
    // A name of no result: as if it named none.
    return last orelse .source;
}

/// A `stdDeviation`: one number for both ways, or two; null for one in
/// error or less than 0, which SVG draws as nothing - a blur this reader
/// leaves out.
fn deviationOf(text: ?[]const u8) ?[2]f32 {
    var s = values.Scanner{ .text = text orelse return .{ 0, 0 } };
    const x = s.number() orelse return null;
    s.skipSeparator();
    const y = if (s.done()) x else s.number() orelse return null;
    if (!s.done() or x < 0 or y < 0) return null;
    return .{ x, y };
}

fn hypot(a: f32, b: f32) f32 {
    return @sqrt(a * a + b * b);
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

fn effectIn(comptime text: []const u8) !Effect {
    var copy: [text.len]u8 = text[0..text.len].*;
    const counts = document.count(&copy) orelse return error.NotSvg;
    var block: [8192]u8 align(8) = undefined;
    const doc = document.build(&copy, counts, block[0..document.bytesFor(counts)]);
    return effectOf(&doc, doc.byId("f") orelse return error.NoFilter);
}

test "Inkscape's blur and Figma's, a drop shadow, nothing, a blur of a blur" {
    try testing.expectEqual(Effect{ .blur = .{ 2, 2 } }, try effectIn(
        \\<svg><filter id="f" x="-0.1" style="color-interpolation-filters:sRGB"><feGaussianBlur stdDeviation="2"/></filter></svg>
    ));
    try testing.expectEqual(Effect{ .blur = .{ 25, 25 } }, try effectIn(
        \\<svg><filter id="f"><feFlood flood-opacity="0" result="BackgroundImageFix"/>
        \\<feBlend mode="normal" in="SourceGraphic" in2="BackgroundImageFix" result="shape"/>
        \\<feGaussianBlur stdDeviation="25" result="effect1_foregroundBlur"/></filter></svg>
    ));
    // Figma's drop shadow: an offset, a colour matrix, a composite.
    try testing.expectEqual(Effect.unknown, try effectIn(
        \\<svg><filter id="f"><feFlood flood-opacity="0" result="BackgroundImageFix"/>
        \\<feColorMatrix in="SourceAlpha" type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0" result="hardAlpha"/>
        \\<feOffset dy="4"/><feGaussianBlur stdDeviation="2"/>
        \\<feBlend mode="normal" in2="BackgroundImageFix" result="effect1_dropShadow"/>
        \\<feBlend mode="normal" in="SourceGraphic" in2="effect1_dropShadow" result="shape"/></filter></svg>
    ));
    try testing.expectEqual(Effect.clear, try effectIn("<svg><filter id='f'/></svg>"));
    try testing.expectEqual(Effect.clear, try effectIn("<svg><filter id='f'><feFlood flood-opacity='0'/></filter></svg>"));
    try testing.expectEqual(Effect.source, try effectIn("<svg><filter id='f'><desc>x</desc><feGaussianBlur stdDeviation='0'/></filter></svg>"));
    try testing.expectEqual(Effect.unknown, try effectIn("<svg><filter id='f'><feGaussianBlur stdDeviation='-1'/></filter></svg>"));
    try testing.expectEqual(Effect.unknown, try effectIn("<svg><filter id='f'><feGaussianBlur in='SourceAlpha' stdDeviation='1'/></filter></svg>"));
    const twice = try effectIn("<svg><filter id='f'><feGaussianBlur stdDeviation='3 0' result='a'/><feGaussianBlur in='a' stdDeviation='4 1'/></filter></svg>");
    try testing.expectEqual(Effect{ .blur = .{ 5, 1 } }, twice);
}

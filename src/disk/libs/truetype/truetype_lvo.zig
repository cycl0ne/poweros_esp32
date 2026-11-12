// SPDX-License-Identifier: MIT
//! truetype.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const truetype = sdk.truetype;
const utility = sdk.utility;
const vec = exec.vec;
const TrueTypeBase = @import("truetype_base.zig").TrueTypeBase;
const truetype_init = @import("truetype_init.zig");

const OpenOutline = @import("outline/openoutline.zig").OpenOutline;
const RenderFontImage = @import("render/renderfontimage.zig").RenderFontImage;
const CloseOutline = @import("outline/closeoutline.zig").CloseOutline;
const GlyphIndex = @import("glyph/glyphindex.zig").GlyphIndex;
const GlyphMetrics = @import("glyph/glyphmetrics.zig").GlyphMetrics;
const GlyphSegments = @import("glyph/glyphsegments.zig").GlyphSegments;
const FontMetrics = @import("outline/fontmetrics.zig").FontMetrics;
const Kerning = @import("glyph/kerning.zig").Kerning;
const GlyphVariant = @import("glyph/glyphvariant.zig").GlyphVariant;
const FontName = @import("outline/fontname.zig").FontName;
const FontTable = @import("outline/fonttable.zig").FontTable;
const RenderGlyph = @import("render/renderglyph.zig").RenderGlyph;
const FontAxes = @import("outline/fontaxes.zig").FontAxes;
const FontInstance = @import("outline/fontinstance.zig").FontInstance;
const FontCoordinates = @import("outline/fontcoordinates.zig").FontCoordinates;
const GlyphAdvance = @import("glyph/glyphadvance.zig").GlyphAdvance;
const VariationDelta = @import("outline/variationdelta.zig").VariationDelta;

/// truetype.library's interface, as the SDK generates it from
/// sdk/fd/truetype_lib.fd.
const interface = sdk.interface.truetype;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("truetype.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "truetype.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("outline/openoutline.zig"),
    @embedFile("render/renderfontimage.zig"),
    @embedFile("outline/closeoutline.zig"),
    @embedFile("glyph/glyphindex.zig"),
    @embedFile("glyph/glyphmetrics.zig"),
    @embedFile("glyph/glyphsegments.zig"),
    @embedFile("outline/fontmetrics.zig"),
    @embedFile("glyph/kerning.zig"),
    @embedFile("glyph/glyphvariant.zig"),
    @embedFile("outline/fontname.zig"),
    @embedFile("outline/fonttable.zig"),
    @embedFile("render/renderglyph.zig"),
    @embedFile("outline/fontaxes.zig"),
    @embedFile("outline/fontinstance.zig"),
    @embedFile("outline/fontcoordinates.zig"),
    @embedFile("glyph/glyphadvance.zig"),
    @embedFile("outline/variationdelta.zig"),
};

fn lvoOpenOutline(tb: *TrueTypeBase, file: [*]const u8, size: u32, tags: ?[*]const utility.TagItem) callconv(.c) ?*truetype.Outline {
    return OpenOutline(tb, file, size, tags);
}
fn lvoRenderFontImage(tb: *TrueTypeBase, outline: *truetype.Outline, rows: u32, ranges: [*]const truetype.CodeRange, count: u32) callconv(.c) ?*graphics.fontimage.FontImage {
    return RenderFontImage(tb, outline, rows, ranges, count);
}
fn lvoCloseOutline(tb: *TrueTypeBase, outline: ?*truetype.Outline) callconv(.c) void {
    return CloseOutline(tb, outline);
}
fn lvoGlyphIndex(tb: *TrueTypeBase, outline: *truetype.Outline, code: u32) callconv(.c) u32 {
    return GlyphIndex(tb, outline, code);
}
fn lvoGlyphMetrics(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, metrics: *truetype.GlyphMetrics) callconv(.c) bool {
    return GlyphMetrics(tb, outline, glyph, metrics);
}
fn lvoGlyphSegments(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, segments: *truetype.Segments) callconv(.c) i32 {
    return GlyphSegments(tb, outline, glyph, segments);
}
fn lvoFontMetrics(tb: *TrueTypeBase, outline: *truetype.Outline, metrics: *truetype.FontMetrics) callconv(.c) void {
    return FontMetrics(tb, outline, metrics);
}
fn lvoKerning(tb: *TrueTypeBase, outline: *truetype.Outline, left: u32, right: u32) callconv(.c) i32 {
    return Kerning(tb, outline, left, right);
}
fn lvoGlyphVariant(tb: *TrueTypeBase, outline: *truetype.Outline, code: u32, selector: u32) callconv(.c) u32 {
    return GlyphVariant(tb, outline, code, selector);
}
fn lvoFontName(tb: *TrueTypeBase, outline: *truetype.Outline, name: u32, buffer: [*]u8, room: u32) callconv(.c) u32 {
    return FontName(tb, outline, name, buffer, room);
}
fn lvoFontTable(tb: *TrueTypeBase, outline: *truetype.Outline, tag: u32, length: *u32) callconv(.c) ?[*]const u8 {
    return FontTable(tb, outline, tag, length);
}
fn lvoRenderGlyph(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, rows: u32, image: *truetype.GlyphImage) callconv(.c) i32 {
    return RenderGlyph(tb, outline, glyph, rows, image);
}
fn lvoFontAxes(tb: *TrueTypeBase, outline: *truetype.Outline, axes: ?[*]truetype.Axis, room: u32) callconv(.c) u32 {
    return FontAxes(tb, outline, axes, room);
}
fn lvoFontInstance(tb: *TrueTypeBase, outline: *truetype.Outline, number: u32, values: ?[*]truetype.AxisValue, room: u32) callconv(.c) u32 {
    return FontInstance(tb, outline, number, values, room);
}
fn lvoFontCoordinates(tb: *TrueTypeBase, outline: *truetype.Outline, coords: ?[*]i16, room: u32) callconv(.c) u32 {
    return FontCoordinates(tb, outline, coords, room);
}
fn lvoGlyphAdvance(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32) callconv(.c) i32 {
    return GlyphAdvance(tb, outline, glyph);
}
fn lvoVariationDelta(tb: *TrueTypeBase, outline: *truetype.Outline, store: [*]const u8, size: u32, item: u32, regions: ?*u32) callconv(.c) i32 {
    return VariationDelta(tb, outline, store, size, item, regions);
}

pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(truetype_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoOpenOutline),
    vec(lvoRenderFontImage),
    vec(lvoCloseOutline),
    vec(lvoGlyphIndex),
    vec(lvoGlyphMetrics),
    vec(lvoGlyphSegments),
    vec(lvoFontMetrics),
    vec(lvoKerning),
    vec(lvoGlyphVariant),
    vec(lvoFontName),
    vec(lvoFontTable),
    vec(lvoRenderGlyph),
    vec(lvoFontAxes),
    vec(lvoFontInstance),
    vec(lvoFontCoordinates),
    vec(lvoGlyphAdvance),
    vec(lvoVariationDelta),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the standard four, then this library's own" {
    try testing.expectEqual(@as(usize, 4 + @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("truetype_lvo.zig"), LVO, &.{});
}

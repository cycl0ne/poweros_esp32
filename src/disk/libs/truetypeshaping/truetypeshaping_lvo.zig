// SPDX-License-Identifier: MIT
//! truetypeshaping.library's jump table: every `lvo<Name>` wrapper, the
//! table of them in slot order, and the checks that hold the table to the
//! SDK's contract - the signatures and the documented LVOs at compile
//! time, the slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const truetype = sdk.truetype;
const truetypeshaping = sdk.truetypeshaping;
const vec = exec.vec;
const TrueTypeShapingBase = @import("truetypeshaping_base.zig").TrueTypeShapingBase;
const truetypeshaping_init = @import("truetypeshaping_init.zig");

const ShapeGlyphs = @import("shape/shapeglyphs.zig").ShapeGlyphs;
const ShapeText = @import("shape/shapetext.zig").ShapeText;
const LigatureCarets = @import("shape/ligaturecarets.zig").LigatureCarets;

/// truetypeshaping.library's interface, as the SDK generates it from
/// sdk/fd/truetypeshaping_lib.fd.
const interface = sdk.interface.truetypeshaping;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("truetypeshaping.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "truetypeshaping.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("shape/shapeglyphs.zig"),
    @embedFile("shape/shapetext.zig"),
    @embedFile("shape/ligaturecarets.zig"),
};

fn lvoShapeGlyphs(sb: *TrueTypeShapingBase, outline: *truetype.Outline, script: u32, direction: u32, language: u32, features: ?[*]const truetypeshaping.Feature, run: *truetypeshaping.ShapedRun) callconv(.c) i32 {
    return ShapeGlyphs(sb, outline, script, direction, language, features, run);
}

fn lvoShapeText(sb: *TrueTypeShapingBase, outline: *truetype.Outline, text: [*]const u8, length: u32, direction: u32, language: u32, features: ?[*]const truetypeshaping.Feature, run: *truetypeshaping.ShapedRun) callconv(.c) i32 {
    return ShapeText(sb, outline, text, length, direction, language, features, run);
}

fn lvoLigatureCarets(sb: *TrueTypeShapingBase, outline: *truetype.Outline, glyph: u32, carets: [*]i32, room: u32) callconv(.c) u32 {
    return LigatureCarets(sb, outline, glyph, carets, room);
}

pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(truetypeshaping_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoShapeGlyphs),
    vec(lvoShapeText),
    vec(lvoLigatureCarets),
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
    try exec.libraries.checkForwarding(@embedFile("truetypeshaping_lvo.zig"), LVO, &.{});
}

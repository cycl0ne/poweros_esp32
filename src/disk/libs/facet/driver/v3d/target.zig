// SPDX-License-Identifier: MIT
//! What the V3D's tiles draw a colour attachment of each format as: the
//! output image format it is stored and loaded as, red and blue swapped on
//! the way or not, its internal type, and what follows from those - a
//! colour written to the TLB as floats of 32 bits, blended or not,
//! averaged into a resolve as a tile is stored or not, short of an alpha
//! or not. By v3dv's table (v3dvx_formats.c:124-196) for the formats
//! facet draws on the V3D: the three of 1.227 and, since 1.228, the
//! fourteen of docs/facet-vulkan10.md item 36.

const sdk = @import("sdk");
const facet = sdk.facet;
const cl = @import("cl.zig");

pub const Target = struct {
    /// The output image format a tile is stored and loaded as
    /// (`cl.OUTPUT_*`).
    output: u64,
    /// Red and blue swapped on the way, where v3dv's swizzle for the format
    /// has Z first and X third (`v3dv_format_swizzle_needs_rb_swap`,
    /// v3dv_formats.c:56-67).
    swap_rb: bool = false,
    /// An sRGB colour, kept in half-floats held to 0 to 1 and turned to
    /// sRGB as a tile is stored (`cl.typeClamp`).
    srgb: bool = false,
    /// The format has an alpha: where it has none, v3dv's swizzle reads
    /// alpha as 1, and a blend factor of the destination's alpha is taken
    /// as 1 (`dst_alpha_one`, v3dvx_pipeline.c:121).
    alpha: bool = true,

    pub fn internal(target: Target) cl.Internal {
        return cl.internalOf(target.output);
    }

    /// The TLB is written a 32-bit float a channel, not two half-floats a
    /// word: the target of the key's f32_color_rb, as v3dv sets it for a
    /// format whose first channel is a 32-bit float (v3dv_pipeline.c:
    /// 1240-1243).
    pub fn wide(target: Target) bool {
        return target.internal().kind == .float32;
    }

    /// The tile buffer as render target 0 of it, cleared to `words`, the
    /// four words of a ClearColorValue: for normalized bytes from
    /// `color`, the 0xAARRGGBB the pass made of the same clear, as until
    /// 1.228.
    pub fn renderTarget(target: Target, color: u32, words: [4]u32) cl.RenderTarget {
        const held = target.internal();
        return .{
            .bpp = held.bpp,
            .type_clamp = cl.typeClamp(held.kind, target.srgb, false),
            .clear = if (held.kind == .unorm8)
                .{ color & 0xFF00_FF00 | (color >> 16 & 0xFF) | (color & 0xFF) << 16, 0, 0, 0 }
            else
                cl.clearColor(held.kind, words),
        };
    }

    /// A clear's colour as the program that draws a rectangle of it is
    /// given it: four of 0 to 1 from the 0xAARRGGBB for normalized
    /// bytes, as until 1.228, and the four floats as they were given for a
    /// target that keeps what a byte does not.
    pub fn clearFloats(target: Target, color: u32, words: [4]u32) [4]f32 {
        if (target.internal().kind == .unorm8) {
            const channel = struct {
                fn of(value: u32, shift: u5) f32 {
                    return @as(f32, @floatFromInt(value >> shift & 0xFF)) / 255;
                }
            }.of;
            return .{ channel(color, 16), channel(color, 8), channel(color, 0), channel(color, 24) };
        }
        var floats: [4]f32 = undefined;
        for (&floats, words) |*one, word| one.* = @bitCast(word);
        return floats;
    }
};

/// What the tiles draw `format` as, or null for one the V3D draws no
/// colour attachment of.
pub fn of(format: facet.Format) ?Target {
    return switch (format) {
        .b8g8r8a8_unorm => .{ .output = cl.OUTPUT_RGBA8, .swap_rb = true },
        .r8g8b8a8_unorm, .a8b8g8r8_unorm_pack32 => .{ .output = cl.OUTPUT_RGBA8 },
        .r5g6b5_unorm_pack16 => .{ .output = cl.OUTPUT_BGR565, .alpha = false },
        // Since 1.228.
        .b8g8r8a8_srgb => .{ .output = cl.OUTPUT_SRGB8_ALPHA8, .swap_rb = true, .srgb = true },
        .r8g8b8a8_srgb, .a8b8g8r8_srgb_pack32 => .{ .output = cl.OUTPUT_SRGB8_ALPHA8, .srgb = true },
        .a2b10g10r10_unorm_pack32 => .{ .output = cl.OUTPUT_RGB10_A2 },
        .a1r5g5b5_unorm_pack16 => .{ .output = cl.OUTPUT_RGBA5551, .swap_rb = true },
        .r8_unorm => .{ .output = cl.OUTPUT_R8, .alpha = false },
        .r8g8_unorm => .{ .output = cl.OUTPUT_RG8, .alpha = false },
        .r16_sfloat => .{ .output = cl.OUTPUT_R16F, .alpha = false },
        .r16g16_sfloat => .{ .output = cl.OUTPUT_RG16F, .alpha = false },
        .r16g16b16a16_sfloat => .{ .output = cl.OUTPUT_RGBA16F },
        .r32_sfloat => .{ .output = cl.OUTPUT_R32F, .alpha = false },
        .r32g32_sfloat => .{ .output = cl.OUTPUT_RG32F, .alpha = false },
        .r32g32b32a32_sfloat => .{ .output = cl.OUTPUT_RGBA32F },
        else => null,
    };
}

/// The format the V3D draws, and blends: the target the tiles mix in,
/// normalized bytes and half-floats (`cl.tilesBlend`).
pub fn blends(format: facet.Format) bool {
    const target = of(format) orelse return false;
    return cl.tilesBlend(target.internal().kind);
}

const std = @import("std");

test "the V3D's targets: the three of 1.227 as they were, the fourteen as v3dv draws them" {
    // As 1.227 drew them: normalized bytes at 32 bits, red and blue
    // swapped for B8G8R8A8, its clear the same word.
    const bgra = of(.b8g8r8a8_unorm).?;
    try std.testing.expect(bgra.swap_rb and !bgra.wide());
    const old = bgra.renderTarget(0x80FF_4020, @splat(0));
    try std.testing.expectEqual(cl.RenderTarget{ .clear = .{ 0x8020_40FF, 0, 0, 0 } }, old);
    try std.testing.expect(!of(.r5g6b5_unorm_pack16).?.alpha);
    // sRGB in half-floats held to 0 to 1, of 64 bits.
    const srgb = of(.b8g8r8a8_srgb).?;
    const made = srgb.renderTarget(0, .{ @bitCast(@as(f32, 0.25)), 0, 0, @bitCast(@as(f32, 1)) });
    try std.testing.expectEqual(cl.Bpp.@"64", made.bpp);
    try std.testing.expectEqual(@as(u5, 24), made.type_clamp);
    try std.testing.expect(srgb.swap_rb);
    // Floats of 32 bits are written as floats, kept at their width,
    // cleared to their own words, and not blended; half-floats blend.
    const four = of(.r32g32b32a32_sfloat).?;
    try std.testing.expect(four.wide() and four.alpha);
    const words = [4]u32{ @bitCast(@as(f32, 1.5)), @bitCast(@as(f32, -2)), 7, 8 };
    try std.testing.expectEqual(cl.RenderTarget{ .bpp = .@"128", .type_clamp = 10, .clear = words }, four.renderTarget(0, words));
    try std.testing.expectEqual([4]f32{ 1.5, -2, @bitCast(@as(u32, 7)), @bitCast(@as(u32, 8)) }, four.clearFloats(0, words));
    try std.testing.expect(!blends(.r32_sfloat) and !blends(.r32g32_sfloat) and !blends(.r32g32b32a32_sfloat));
    try std.testing.expect(blends(.r16g16b16a16_sfloat) and blends(.r8_unorm) and blends(.a2b10g10r10_unorm_pack32) and blends(.r8g8b8a8_srgb));
    try std.testing.expect(!of(.r32_sfloat).?.alpha and !of(.r8g8_unorm).?.alpha and !of(.r16_sfloat).?.alpha);
    // Normalized bytes' rectangle floats from the 0xAARRGGBB.
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, bgra.clearFloats(0xFFFF_0000, @splat(0)));
    // Each of the fourteen has a target; whole numbers have none yet.
    const fourteen = [_]facet.Format{ .r8_unorm, .r8g8_unorm, .a8b8g8r8_unorm_pack32, .r8g8b8a8_srgb, .a8b8g8r8_srgb_pack32, .b8g8r8a8_srgb, .a2b10g10r10_unorm_pack32, .a1r5g5b5_unorm_pack16, .r16_sfloat, .r16g16_sfloat, .r16g16b16a16_sfloat, .r32_sfloat, .r32g32_sfloat, .r32g32b32a32_sfloat };
    for (fourteen) |format| try std.testing.expect(of(format) != null);
    try std.testing.expect(of(.r32_uint) == null and of(.r8g8b8a8_sint) == null);
}

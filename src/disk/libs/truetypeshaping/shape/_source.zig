// SPDX-License-Identifier: MIT
//! What a call's shaping reaches the system and the font through: exec's
//! memory, and truetype.library for the font's tables, its glyphs and
//! their measures. `Source` is the context every callback of `Memory`
//! and `Font` gets.

const sdk = @import("sdk");
const exec = sdk.exec;
const truetype = sdk.truetype;
const TrueTypeShapingBase = @import("../truetypeshaping_base.zig").TrueTypeShapingBase;
const Table = @import("_tables.zig").Table;
const _buffer = @import("_buffer.zig");
const _shape = @import("_shape.zig");

pub const Source = struct {
    sb: *TrueTypeShapingBase,
    outline: *truetype.Outline,

    /// The memory a call shapes with.
    pub fn memory(source: *Source) _buffer.Memory {
        return .{ .context = source, .allocFn = allocate, .freeFn = release };
    }

    /// The font as the shaping reads it.
    pub fn font(source: *Source) _shape.Font {
        return .{
            .gdef = tableOf(source, "GDEF"),
            .gsub = tableOf(source, "GSUB"),
            .gpos = tableOf(source, "GPOS"),
            .context = source,
            .advanceFn = advanceOf,
            .kerningFn = kerningOf,
            .glyphFn = glyphOf,
            .variantFn = variantOf,
        };
    }
};

fn allocate(context: *anyopaque, bytes: usize) ?[*]u8 {
    const source: *Source = @ptrCast(@alignCast(context));
    const block = source.sb.sys_base.AllocVec(bytes, exec.MEMF_ANY) orelse return null;
    return @ptrCast(block);
}

fn release(context: *anyopaque, block: [*]u8) void {
    const source: *Source = @ptrCast(@alignCast(context));
    source.sb.sys_base.FreeVec(block);
}

fn advanceOf(context: *anyopaque, glyph: u32) i32 {
    const source: *Source = @ptrCast(@alignCast(context));
    var metrics: truetype.GlyphMetrics = .{};
    _ = source.sb.truetype_base.GlyphMetrics(source.outline, glyph, &metrics);
    return metrics.advance;
}

fn kerningOf(context: *anyopaque, left: u32, right: u32) i32 {
    const source: *Source = @ptrCast(@alignCast(context));
    return source.sb.truetype_base.Kerning(source.outline, left, right);
}

fn glyphOf(context: *anyopaque, char: u32) u32 {
    const source: *Source = @ptrCast(@alignCast(context));
    return source.sb.truetype_base.GlyphIndex(source.outline, char);
}

fn variantOf(context: *anyopaque, char: u32, selector: u32) u32 {
    const source: *Source = @ptrCast(@alignCast(context));
    return source.sb.truetype_base.GlyphVariant(source.outline, char, selector);
}

/// The font's table of the tag `letters`; of no length when it has none.
fn tableOf(source: *Source, comptime letters: *const [4]u8) Table {
    var length: u32 = 0;
    const start = source.sb.truetype_base.FontTable(source.outline, truetype.tableTag(letters), &length) orelse return Table.none;
    return .{ .bytes = start[0..length] };
}

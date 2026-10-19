// SPDX-License-Identifier: MPL-2.0
//! Textures: pictures a triangle is painted with, and how a pixel finds
//! its colour in one.
//!
//! A texture has a width and a height that are powers of two, and its
//! levels: the picture itself and each half the size of the one before,
//! down to as many as it was given - they are made by whoever makes the
//! texture, not here. Each level is kept in blocks of 4 x 4 texels, block
//! after block along its rows: the texels a pixel's neighbours and a
//! bilinear filter read lie in one or two blocks, a cache line or two,
//! where rows kept whole would put them in as many lines as rows. A level
//! smaller than a block takes a whole one.
//!
//! An 8888 texel is kept in 64 bits, each channel in 16 of them, as a
//! bilinear filter mixes it (`spread`): twice the memory, for the four
//! texels of a sample read ready to mix - spreading them as they are read
//! is a fifth of what a pixel costs on the U74.
//!
//! A pipeline samples one at a time, and its format, its filter and what
//! it does past the edges are the pipeline's, fixed at compile time
//! (`Sampling`): the sample is built for them. Coordinates are 0 to 1
//! across the texture, whatever its size; a texel's centre is at
//! (x + 0.5) / width. The level is chosen a 2 x 2 quad at a time from how
//! far the coordinates move from one pixel of the quad to the next
//! (`levelFor`), the nearest of the levels the texture has.
//!
//! Every colour comes out as 0xAARRGGBB, RGB565 with an alpha of 255.

const std = @import("std");

/// How a texel is kept.
pub const Format = enum {
    /// 32 bits, 0xAARRGGBB; kept spread, in 64.
    rgba8888,
    /// 16 bits, red in the top 5, green in the middle 6, blue in the low 5.
    rgb565,

    /// The bytes a texel is kept in.
    pub fn bytes(format: Format) u32 {
        return @as(u32, 1) << format.shift();
    }

    /// The same, as a power of two.
    pub fn shift(format: Format) u5 {
        return switch (format) {
            .rgba8888 => 3,
            .rgb565 => 1,
        };
    }
};

/// How a texel is found for a point between texels.
pub const Filter = enum {
    /// The one the point lies in.
    nearest,
    /// The four round it, mixed by how near the point is to each.
    bilinear,
};

/// What a coordinate past the texture's edge reads.
pub const Address = enum {
    /// The texture again, as tiles.
    wrap,
    /// The edge's texels.
    clamp,
};

/// What a pipeline does with its texture.
pub const Sampling = struct {
    format: Format = .rgba8888,
    filter: Filter = .bilinear,
    address: Address = .wrap,
};

/// The most levels a texture has: 32768 across, down to 1.
pub const most_levels = 16;

/// The side of a block, in texels.
const block = 4;

pub const Texture = struct {
    format: Format,
    width_log2: u5,
    height_log2: u5,
    levels: u32,
    /// Each level as a sample reads it, worked out once; those past
    /// `levels` undefined.
    layout: [most_levels]Level,
    memory: [*]u8,

    pub const Error = error{BadSize};

    /// The bytes a texture `across` by `down` texels keeps, with `levels`
    /// levels: what `init` is given.
    pub fn bytes(format: Format, across: u32, down: u32, levels: u32) Error!usize {
        const sizes = try Sizes.of(across, down, levels);
        var texels: usize = 0;
        for (0..levels) |lod| texels += sizes.texels(@intCast(lod));
        return texels * format.bytes();
    }

    /// A texture over `memory`, at least `bytes` long and aligned for a
    /// texel as it is kept, its texels undefined until they are put in (`put`,
    /// `load`). error.BadSize for a side that is not a power of two, or
    /// more levels than halving it gives.
    pub fn init(format: Format, across: u32, down: u32, levels: u32, memory: [*]u8) Error!Texture {
        const sizes = try Sizes.of(across, down, levels);
        var texture = Texture{
            .format = format,
            .width_log2 = sizes.width_log2,
            .height_log2 = sizes.height_log2,
            .levels = levels,
            .layout = undefined,
            .memory = memory,
        };
        var at: u32 = 0;
        for (0..levels) |lod| {
            texture.layout[lod] = .of(format, sizes, @intCast(lod), at);
            at += sizes.texels(@intCast(lod)) * format.bytes();
        }
        return texture;
    }

    /// A level's width and height.
    pub inline fn width(texture: *const Texture, lod: u32) u32 {
        return @as(u32, 1) << @intCast(texture.width_log2 -| lod);
    }

    pub inline fn height(texture: *const Texture, lod: u32) u32 {
        return @as(u32, 1) << @intCast(texture.height_log2 -| lod);
    }

    /// Where texel (x, y) of a level is kept, in texels from `memory`.
    pub fn index(texture: *const Texture, lod: u32, x: u32, y: u32) u32 {
        return texture.layout[lod].offset(texture.format, x, y) / texture.format.bytes();
    }

    /// Texel (x, y) of a level set, in the texture's format.
    pub fn put(texture: *Texture, lod: u32, x: u32, y: u32, texel: u32) void {
        const at = texture.memory + texture.layout[lod].offset(texture.format, x, y);
        switch (texture.format) {
            .rgba8888 => @as(*u64, @ptrCast(@alignCast(at))).* = spread(texel),
            .rgb565 => @as(*u16, @ptrCast(@alignCast(at))).* = @truncate(texel),
        }
    }

    /// A level from a picture kept row by row, `pitch` bytes from one row
    /// to the next, in the texture's format.
    pub fn load(texture: *Texture, lod: u32, pixels: [*]const u8, pitch: usize) void {
        for (0..texture.height(lod)) |y| {
            const row = pixels + y * pitch;
            for (0..texture.width(lod)) |x| {
                const texel: u32 = switch (texture.format) {
                    .rgba8888 => std.mem.readInt(u32, row[x * 4 ..][0..4], .little),
                    .rgb565 => std.mem.readInt(u16, row[x * 2 ..][0..2], .little),
                };
                texture.put(lod, @intCast(x), @intCast(y), texel);
            }
        }
    }
};

/// A texture's size, checked.
const Sizes = struct {
    width_log2: u5,
    height_log2: u5,

    fn of(width: u32, height: u32, levels: u32) Texture.Error!Sizes {
        if (width == 0 or height == 0 or !std.math.isPowerOfTwo(width) or !std.math.isPowerOfTwo(height)) return error.BadSize;
        const width_log2: u5 = @intCast(std.math.log2_int(u32, width));
        const height_log2: u5 = @intCast(std.math.log2_int(u32, height));
        if (levels == 0 or levels > most_levels or levels > @as(u32, @max(width_log2, height_log2)) + 1) return error.BadSize;
        return .{ .width_log2 = width_log2, .height_log2 = height_log2 };
    }

    /// The texels a level keeps: its blocks, whole.
    fn texels(sizes: Sizes, level: u5) u32 {
        const across = ((@as(u32, 1) << (sizes.width_log2 -| level)) + block - 1) / block;
        const down = ((@as(u32, 1) << (sizes.height_log2 -| level)) + block - 1) / block;
        return across * down * block * block;
    }
};

/// The level for a quad: from how far the coordinates move, in texels of
/// the first level, a pixel across (`du_dx`, `dv_dx`) and a pixel down,
/// the larger of the two - 1 texel or less a pixel is the first level,
/// 2 the second, 4 the third - rounded to the nearest level the texture
/// has. Worked out from the exponent of the larger step squared, so it
/// costs no logarithm: a level changes where a step is about 1.4, 2.8 and
/// so on, a power of two times the root of two.
pub inline fn levelFor(texture: *const Texture, du_dx: f32, dv_dx: f32, du_dy: f32, dv_dy: f32) u32 {
    @setRuntimeSafety(false);
    const across = du_dx * du_dx + dv_dx * dv_dx;
    const down = du_dy * du_dy + dv_dy * dv_dy;
    // A NaN or an infinity - a quad with a w of nothing - falls to the
    // last level, a step of nothing to the first. Squares are not below
    // 0, so their bits are in the order they are, and a NaN's above all.
    const bits = @max(@as(u32, @bitCast(across)), @as(u32, @bitCast(down)));
    const exponent: i32 = @as(i32, @intCast(bits >> 23 & 0xFF)) - 127;
    if (exponent <= 0) return 0;
    const chosen: u32 = @intCast((exponent + 1) >> 1);
    return @min(chosen, texture.levels - 1);
}

/// A level of a texture as a sample reads it.
///
/// A texel's place in the level, in bytes, is its column's and its row's
/// added together, the bits of each spread apart: a column's low two pick
/// the texel in a block's row and its others the block along the row of
/// blocks, a row's low two the row in a block and its others the row of
/// blocks. A sample moves a coordinate's bits straight to where they go,
/// masked with the last column's or row's place to wrap round, and finds
/// the next column or row by carrying one over the bits between.
pub const Level = struct {
    /// Where the level starts, in bytes from the texture's memory.
    start: u32,
    width: u32,
    height: u32,
    /// The size in 1/256ths of a texel, as floats: what a coordinate is
    /// multiplied by.
    across: f32,
    down: f32,
    /// The places of the last column and the last row, which have every
    /// bit another does.
    last_column: u32,
    last_row: u32,
    /// The last column's low two bits and its others, at their places.
    column_low: u32,
    column_high: u32,
    /// The last row's low two bits at their place, and its others as they
    /// are in the row's number.
    row_low: u32,
    row_high: u32,
    /// Where a row's bits above its low two go: the bytes of a row of
    /// blocks, as a power of two.
    blocks_shift: u5,
    /// The bits between a row's low two and its others, set to carry one
    /// over them.
    row_gap: u32,

    fn of(format: Format, sizes: Sizes, lod: u5, start: u32) Level {
        const width_log2 = sizes.width_log2 -| lod;
        const height_log2 = sizes.height_log2 -| lod;
        const texel = format.shift();
        var level = Level{
            .start = start,
            .width = @as(u32, 1) << width_log2,
            .height = @as(u32, 1) << height_log2,
            .across = powerOfTwo(width_log2 + 8),
            .down = powerOfTwo(height_log2 + 8),
            .last_column = undefined,
            .last_row = undefined,
            .column_low = undefined,
            .column_high = undefined,
            .row_low = undefined,
            .row_high = undefined,
            .blocks_shift = (width_log2 -| 2) + 4 + texel,
            .row_gap = undefined,
        };
        level.last_column = columnAt(texel, level.width - 1);
        level.last_row = level.rowAt(texel, level.height - 1);
        level.column_low = level.last_column & lowColumn(texel);
        level.column_high = level.last_column & ~lowColumn(texel);
        level.row_low = level.last_row & lowRow(texel);
        level.row_high = (level.height - 1) / block;
        level.row_gap = (@as(u32, 1) << level.blocks_shift) - (@as(u32, 1) << (texel + 4));
        return level;
    }

    /// Texel (x, y)'s place, in bytes from the level's start.
    fn offset(level: Level, format: Format, x: u32, y: u32) u32 {
        return level.start + level.rowAt(format.shift(), y) + columnAt(format.shift(), x);
    }

    /// Row `y`'s place, for texels of 2 to the `texel` bytes.
    inline fn rowAt(level: Level, texel: u5, y: u32) u32 {
        @setRuntimeSafety(false);
        return (y % block) << (texel + 2) | (y / block) << level.blocks_shift;
    }

    /// 2 to the `exponent` as a float, made from its bits rather than
    /// converted.
    fn powerOfTwo(exponent: u32) f32 {
        return @bitCast((127 + exponent) << 23);
    }
};

/// Column `x`'s place, for texels of 2 to the `texel` bytes.
inline fn columnAt(texel: u5, x: u32) u32 {
    @setRuntimeSafety(false);
    return (x % block) << texel | (x / block) << (texel + 4);
}

/// Where a column's low two bits are, and a row's.
inline fn lowColumn(texel: u5) u32 {
    return @as(u32, block - 1) << texel;
}

inline fn lowRow(texel: u5) u32 {
    return @as(u32, block - 1) << (texel + 2);
}

/// The colour at (u, v) in a level, 0xAARRGGBB.
pub inline fn sample(comptime sampling: Sampling, texture: *const Texture, level: *const Level, u: f32, v: f32) u32 {
    return sampleAt(sampling, texture, level, place(u * level.across - bias(sampling)), place(v * level.down - bias(sampling)));
}

/// What a coordinate in 1/256ths of a texel is moved by before `sampleAt`:
/// a bilinear filter mixes from the centre of the texel up and to the
/// left, half a texel back.
pub fn bias(comptime sampling: Sampling) f32 {
    return switch (sampling.filter) {
        .nearest => 0,
        .bilinear => 128,
    };
}

/// The colour at (s, t) in a level, in 1/256ths of a texel from its top
/// left, moved by `bias`; 0xAARRGGBB.
pub inline fn sampleAt(comptime sampling: Sampling, texture: *const Texture, level: *const Level, s: i32, t: i32) u32 {
    // This runs for every pixel; what it works out is held inside the
    // level, and checks would cost more than the work.
    @setRuntimeSafety(false);
    const base = texture.memory + level.start;
    const left, const right = columns(sampling, level, s);
    const top, const bottom = rows(sampling, level, t);
    switch (sampling.filter) {
        .nearest => return fetch(sampling.format, base + top + left),
        .bilinear => {
            // Each texel's weight of 256, the four adding up to it.
            const across: u64 = @as(u32, @bitCast(s)) & 0xFF;
            const down: u64 = @as(u32, @bitCast(t)) & 0xFF;
            const both = across * down >> 8;
            const sum = fetchSpread(sampling.format, base + top + left) * (256 + both - across - down) +
                fetchSpread(sampling.format, base + top + right) * (across - both) +
                fetchSpread(sampling.format, base + bottom + left) * (down - both) +
                fetchSpread(sampling.format, base + bottom + right) * both;
            return gather(sum >> 8 & lanes);
        },
    }
}

/// The places of column s / 256 and the next one, inside the level.
inline fn columns(comptime sampling: Sampling, level: *const Level, s: i32) [2]usize {
    @setRuntimeSafety(false);
    const texel = comptime sampling.format.shift();
    switch (sampling.address) {
        .wrap => {
            // Moved straight from the coordinate, its sign's bits as well,
            // and masked: round the level.
            const wide: usize = @bitCast(@as(isize, s));
            const column = (wide >> (8 - texel) & level.column_low) | (wide >> (6 - texel) & level.column_high);
            const gap = comptime @as(usize, block - 1) << (texel + 2);
            return .{ column, ((column | gap) + (1 << texel)) & level.last_column };
        },
        .clamp => {
            const last: i32 = @intCast(level.width - 1);
            const x = s >> 8;
            return .{ columnAt(texel, @intCast(std.math.clamp(x, 0, last))), columnAt(texel, @intCast(std.math.clamp(x +% 1, 0, last))) };
        },
    }
}

/// The places of row t / 256 and the next one, inside the level.
inline fn rows(comptime sampling: Sampling, level: *const Level, t: i32) [2]usize {
    @setRuntimeSafety(false);
    const texel = comptime sampling.format.shift();
    switch (sampling.address) {
        .wrap => {
            const wide: usize = @bitCast(@as(isize, t));
            const row = (wide >> (6 - texel) & level.row_low) | (wide >> 10 & level.row_high) << level.blocks_shift;
            return .{ row, ((row | level.row_gap) + (4 << texel)) & level.last_row };
        },
        .clamp => {
            const last: i32 = @intCast(level.height - 1);
            const y = t >> 8;
            return .{ level.rowAt(texel, @intCast(std.math.clamp(y, 0, last))), level.rowAt(texel, @intCast(std.math.clamp(y +% 1, 0, last))) };
        },
    }
}

/// A coordinate in 1/256ths of a texel as an integer: past any texture it
/// is held at a texel far beyond the edge, and a NaN somewhere, so that it
/// always converts.
pub inline fn place(at: f32) i32 {
    @setRuntimeSafety(false);
    const limit: f32 = 1 << 30;
    return @intFromFloat(@min(@max(at, -limit), limit));
}

/// A step from one pixel to the next in 1/256ths of a texel, held so that
/// a place and two steps stay inside 32 bits.
pub inline fn step(by: f32) i32 {
    @setRuntimeSafety(false);
    const limit: f32 = 1 << 28;
    return @intFromFloat(@min(@max(by, -limit), limit));
}

/// The texel kept at `at` as 0xAARRGGBB.
inline fn fetch(comptime format: Format, at: [*]const u8) u32 {
    @setRuntimeSafety(false);
    return switch (format) {
        .rgba8888 => gather(fetchSpread(format, at)),
        .rgb565 => widen(@as(*const u16, @ptrCast(@alignCast(at))).*),
    };
}

/// The texel kept at `at`, spread.
inline fn fetchSpread(comptime format: Format, at: [*]const u8) u64 {
    @setRuntimeSafety(false);
    return switch (format) {
        .rgba8888 => @as(*const u64, @ptrCast(@alignCast(at))).*,
        .rgb565 => spread(fetch(format, at)),
    };
}

/// RGB565 as 0xAARRGGBB: each channel's top bits again below, so that the
/// largest value of 5 or 6 bits is 255.
pub inline fn widen(texel: u16) u32 {
    const red: u32 = texel >> 11;
    const green: u32 = texel >> 5 & 0x3F;
    const blue: u32 = texel & 0x1F;
    return 0xFF00_0000 | (red << 3 | red >> 2) << 16 | (green << 2 | green >> 4) << 8 | (blue << 3 | blue >> 2);
}

/// Each channel's 16 bits in a spread colour.
const lanes: u64 = 0x00FF_00FF_00FF_00FF;

/// 0xAARRGGBB as 0x00AA_00GG_00RR_00BB: each channel in 16 bits, room for
/// it times a weight of up to 256. Green and alpha go up, red and blue
/// stay: two masks and a shift.
pub inline fn spread(color: u32) u64 {
    const stays = color & 0x00FF_00FF;
    return stays | @as(u64, color ^ stays) << 24;
}

/// A spread colour, each channel below 256, as 0xAARRGGBB again.
pub inline fn gather(wide: u64) u32 {
    return @truncate(wide | wide >> 24);
}

/// Two spread colours mixed, `weight` of 256 the second's.
pub inline fn mix(first: u64, second: u64, weight: u32) u64 {
    @setRuntimeSafety(false);
    return (first * (256 - weight) + second * weight) >> 8 & lanes;
}

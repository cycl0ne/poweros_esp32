// SPDX-License-Identifier: MIT
//! Textures: pictures a triangle is painted with, and how a pixel finds
//! its colour in one.
//!
//! A texture has a width and a height of any size, and its levels: the
//! picture itself and each half the size of the one before - `width >> lod`
//! and no less than one, as Vulkan has it - down to as many as it was given;
//! they are made by whoever makes the texture, not here. Each level is kept
//! in blocks of 4 x 4 texels, block after block along its rows: the texels a
//! pixel's neighbours and a bilinear filter read lie in one or two blocks, a
//! cache line or two, where rows kept whole would put them in as many lines
//! as rows. A level smaller than a block takes a whole one.
//!
//! **A width that is not a power of two is laid out as the next one up**
//! (since 1.42), so that the bytes from one row of blocks to the next stay a
//! shift and a texel's place costs what it always did. That is as much as
//! 2 x the memory for the widest levels - 100 across is kept as 128 - and
//! nothing for a height, which is kept in as many rows of blocks as it has.
//! The texels past the width are never read: a sample is held inside the
//! level's own width, which `Level.width` carries.
//!
//! A level whose sides are both powers of two tiles by masking bits, which
//! is how `wrap` reads round the edges. One of any other size cannot, and
//! has its coordinate brought inside by a division instead (`Level.tiles`):
//! correct, and some cycles a sample. `clamp` costs the same whatever the
//! size.
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
//! **A sampler is the same settled later** (`Sampler`, CreateSampler): a
//! draw binds one beside the texture, and `sampleBy` reads it for every
//! sample. It costs floats where the fixed path costs fixed point, and
//! gives what that path has no room for - the two levels round a point
//! mixed, a bias on the level and a clamp, mirrored and bordered edges,
//! several samples along the longer axis, and a comparison with a
//! reference instead of a colour.
//!
//! Every colour comes out as 0xAARRGGBB, RGB565 with an alpha of 255.
//!
//! **A depth is sampled too** (`Format.d16`, since 1.39): 16 bits a texel,
//! and kept in rows rather than blocks, because that is how a render pass
//! stores a depth attachment - so a shadow map is drawn into an image and
//! sampled out of it with nothing copied. Such a texture carries the bytes
//! from one row to the next (`Texture.pitch`), has one level, and is
//! sampled by `sampleBy` alone: the fixed forms' fast path is built for
//! blocks, so a form handed one reads it through the run-time sampler
//! instead. A shadow sample compares the depth at all 16 bits (`valueOf`);
//! a sample of the colour reads the depth as a grey, its top 8 bits.
//!
//! **A compressed texture is kept in its blocks** (`Format.bc1`, `bc1_rgb`,
//! `bc2`, `bc3`, since 1.44): 8 bytes to a block of 4 x 4 texels for BC1
//! and 16 for the others, where the same texels unpacked take 128, and a
//! sample decodes the block it reads (`blockOf`) - once for the four texels
//! a bilinear filter mixes, where they share a block. The decoding is some
//! twenty cycles a block against a load, which is the trade: a quarter to
//! an eighth of the memory and of the cache it fills. Nothing writes a
//! texel of one (`putLayer` leaves it be): the blocks are copied in whole
//! (`putBlock`).

const std = @import("std");

/// How a texel is kept.
pub const Format = enum {
    /// 32 bits, 0xAARRGGBB; kept spread, in 64.
    rgba8888,
    /// 16 bits, red in the top 5, green in the middle 6, blue in the low 5.
    rgb565,
    /// 16 bits of depth, 0 nearest, as a depth attachment holds one: a
    /// texture of this is kept in rows (`Texture.pitch`) and sampled by
    /// `sampleBy` alone.
    d16,
    /// BC1 as it lies: a block of 4 x 4 texels in 8 bytes, two endpoint
    /// colours of 565 and two bits a texel. Where the first endpoint is
    /// not above the second, the third colour is the two mixed evenly and
    /// the fourth is clear - DXT1's punch-through alpha. (Since 1.44.)
    bc1,
    /// The same, read as wholly opaque: Vulkan's BC1_RGB, whose alpha is
    /// 1 whatever the block says. (Since 1.44.)
    bc1_rgb,
    /// BC2: 16 bytes a block, four bits of alpha a texel and then BC1's
    /// colours, always the four of them. (Since 1.44.)
    bc2,
    /// BC3: 16 bytes a block, two endpoint alphas with three bits a texel
    /// between them, and then BC1's colours. (Since 1.44.)
    bc3,
    /// Four half floats a texel, red first: Vulkan's R16G16B16A16_SFLOAT as
    /// it lies, 8 bytes. A sample reads it as 0xAARRGGBB, each channel held
    /// between 0 and 1 and rounded to 8 bits, the tiles having no more.
    /// (Since 1.45.)
    rgba16f,
    /// Four floats a texel, 16 bytes: R32G32B32A32_SFLOAT. (Since 1.45.)
    rgba32f,
    /// B10G11R11_UFLOAT_PACK32: one word a texel, no sign and no alpha -
    /// 11 bits of red and of green, 10 of blue. (Since 1.45.)
    rg11b10f,
    /// E5B9G9R9_UFLOAT_PACK32: one word, three mantissas of 9 bits over one
    /// exponent of 5 they share. (Since 1.45.)
    rgb9e5,

    /// The bytes a texel is kept in; 0 for a compressed format, whose
    /// texels have no size of their own (`blockLog2`).
    pub fn bytes(format: Format) u32 {
        if (format.compressed()) return 0;
        return @as(u32, 1) << format.shift();
    }

    /// The same, as a power of two. Nothing for a compressed format: the
    /// block is what is addressed there.
    pub fn shift(format: Format) u5 {
        return switch (format) {
            .rgba8888, .rgba16f => 3,
            .rgba32f => 4,
            .rg11b10f, .rgb9e5 => 2,
            .rgb565, .d16 => 1,
            .bc1, .bc1_rgb, .bc2, .bc3 => 0,
        };
    }

    /// The bytes a block of 4 x 4 texels takes, as a power of two: what one
    /// level's row of blocks counts in, whether the texels lie in it one by
    /// one or compressed together.
    pub fn blockLog2(format: Format) u5 {
        return switch (format) {
            // 16 texels of 8 bytes, and of 2.
            .rgba8888, .rgba16f => 7,
            .rgba32f => 8,
            .rg11b10f, .rgb9e5 => 6,
            .rgb565, .d16 => 5,
            .bc1, .bc1_rgb => 3,
            .bc2, .bc3 => 4,
        };
    }

    /// The bytes a block takes.
    pub fn blockBytes(format: Format) u32 {
        return @as(u32, 1) << format.blockLog2();
    }

    /// Whether the texels of a block lie compressed together, so that a
    /// sample decodes the block rather than reading a texel
    /// (`blockOf`). (Since 1.44.)
    pub fn compressed(format: Format) bool {
        return switch (format) {
            .bc1, .bc1_rgb, .bc2, .bc3 => true,
            .rgba8888, .rgb565, .d16, .rgba16f, .rgba32f, .rg11b10f, .rgb9e5 => false,
        };
    }

    /// Whether a texel holds floats, which a sample reads and rounds to 8
    /// bits a channel (`floatTexel`): the texel is kept as it was copied
    /// in, so nothing of it is lost on the way out again, and nothing
    /// writes one a texel at a time. (Since 1.45.)
    pub fn floats(format: Format) bool {
        return switch (format) {
            .rgba16f, .rgba32f, .rg11b10f, .rgb9e5 => true,
            .rgba8888, .rgb565, .d16, .bc1, .bc1_rgb, .bc2, .bc3 => false,
        };
    }

    /// Whether a texel's bytes are moved as they are rather than through a
    /// colour of 8 bits a channel: a compressed format's blocks and a
    /// float one's texels. (Since 1.45.)
    pub fn kept(format: Format) bool {
        return format.compressed() or format.floats();
    }

    /// Whether a texture of this holds a depth rather than a colour: read
    /// at all 16 bits by a shadow sample, and as a grey by one of the
    /// colour.
    pub fn depth(format: Format) bool {
        return format == .d16;
    }
};

/// How a texel is found for a point between texels.
pub const Filter = enum(u8) {
    /// The one the point lies in.
    nearest,
    /// The four round it, mixed by how near the point is to each.
    bilinear,
};

/// What a coordinate past the texture's edge reads, for a fixed form,
/// whose two the fast path has its bit tricks for (`columns`, `rows`). A
/// sampler has `Wrap`'s four instead.
pub const Address = enum(u8) {
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

/// How a sampler goes between the two levels a point falls between.
pub const Mipmap = enum(u8) {
    /// The nearer level alone, as a fixed form's sample reads it.
    nearest,
    /// Both, mixed by how far the point is between them.
    linear,
};

/// What a sampler reads past the texture's edge: `Address`'s two, and two
/// more that only a sampler can ask for.
pub const Wrap = enum(u8) {
    /// The texture again, as tiles.
    repeat,
    /// The texture again, every other time turned round, so that the edges
    /// meet.
    mirrored_repeat,
    /// The edge's texels.
    clamp_to_edge,
    /// `Sampler.border`, and nothing of the texture.
    clamp_to_border,
};

/// How a shadow sample compares what it read with the reference it was
/// given. `none` for an ordinary sample, which reads the colour instead.
pub const Compare = enum(u8) {
    none,
    never,
    less,
    equal,
    less_or_equal,
    greater,
    not_equal,
    greater_or_equal,
    always,

    /// Whether `value` stands to `reference` as this asks, both 0 to 1.
    pub inline fn passes(compare: Compare, value: f32, reference: f32) bool {
        return switch (compare) {
            .none, .never => false,
            .less => reference < value,
            .equal => reference == value,
            .less_or_equal => reference <= value,
            .greater => reference > value,
            .not_equal => reference != value,
            .greater_or_equal => reference >= value,
            .always => true,
        };
    }
};

/// The samples a point takes along its longer axis at most, however much
/// anisotropy it asks for: `PhysicalDeviceLimits.max_sampler_anisotropy`.
pub const most_taps = 16;

/// A `Sampler.max_lod` held by nothing but the levels the texture has.
pub const lod_unclamped: f32 = 1000;

/// What a sampler does, as CreateSampler was given it: how a point between
/// texels is filtered, how its level is chosen and held, what lies past the
/// edges, and what a shadow sample compares with.
///
/// It is read as a sample is taken - by `sampleBy` and `sampleVolumeBy`
/// here, which a fragment function reaches through
/// `shader.Resources.samplerOf` - and never written, so one sampler serves
/// every core at once. Where a fixed form's `Sampling` is settled when the
/// program is compiled, this is settled when the sampler is made, and a
/// draw may bind another.
pub const Sampler = extern struct {
    /// Where a texel covers more than a pixel: the level is 0 or below.
    mag_filter: Filter = .bilinear,
    /// Where it covers less, which is where the levels are of use.
    min_filter: Filter = .bilinear,
    mipmap: Mipmap = .nearest,
    /// Past the edges: across, down, and through a 3D texture.
    wrap: [3]Wrap = @splat(.repeat),
    /// 0xAARRGGBB, read where `clamp_to_border` is past the edge.
    border: u32 = 0,
    /// Added to the level a point falls on, before it is held.
    lod_bias: f32 = 0,
    /// The levels the sample is held to, over and above those the texture
    /// has.
    min_lod: f32 = 0,
    max_lod: f32 = lod_unclamped,
    /// The samples taken along the longer axis at most: 1 for one, which is
    /// no anisotropic filtering, up to `most_taps`.
    anisotropy: f32 = 1,
    /// What a shadow sample does; `none` for a sample of the colour.
    compare: Compare = .none,
};

/// A point in a texture, and how fast its coordinates change round it:
/// what a sampler is given to choose a level and how many samples to take.
/// The changes are a pixel's, 0 to 1 across the texture like the point
/// itself; all 0 asks for level 0, one sample.
pub const Point = extern struct {
    u: f32,
    v: f32,
    du_dx: f32 = 0,
    dv_dx: f32 = 0,
    du_dy: f32 = 0,
    dv_dy: f32 = 0,
    /// What a shadow sample compares with, 0 to 1: the red channel's value
    /// is what it is compared against.
    reference: f32 = 0,
};

/// The most levels a texture has: 32768 across, down to 1.
pub const most_levels = 16;

/// The widest and highest a texture is: what `most_levels` levels halve, and
/// what a side's place in 1/256ths of a texel stays exact for.
pub const most_side = 1 << 15;

/// The side of a block, in texels.
const block = 4;

pub const Texture = struct {
    format: Format,
    /// The sides the blocks are laid out by, as powers of two: each the
    /// side itself where it is one, the next one up where it is not. The
    /// sides themselves are each level's own (`Level.width`).
    width_log2: u5,
    height_log2: u5,
    levels: u32,
    /// The bytes from one row to the next, for a texture kept in rows
    /// rather than blocks: a depth attachment's image, sampled where it
    /// lies (`linear`). 0 for the blocks every other texture is kept in.
    pitch: u32 = 0,
    /// Each level as a sample reads it, worked out once; those past
    /// `levels` undefined.
    layout: [most_levels]Level,
    memory: [*]u8,
    /// An array's layers, a cube's faces, or a 3D texture's slices: each
    /// a texture's worth, `layer_bytes` from the one before.
    layer_count: u32 = 1,
    layer_bytes: u32 = 0,

    pub const Error = error{BadSize};

    /// The bytes a texture `across` by `down` texels keeps, with `levels`
    /// levels: what `init` is given.
    pub fn bytes(format: Format, across: u32, down: u32, levels: u32) Error!usize {
        const sizes = try Sizes.of(across, down, levels);
        var blocks: usize = 0;
        for (0..levels) |lod| blocks += sizes.blocks(@intCast(lod));
        return blocks * format.blockBytes();
    }

    /// A texture of one level over rows of `pitch` bytes: how a depth
    /// attachment's image is sampled, where it lies, with no copy and no
    /// second layout. Its sides are whatever the image's are, powers of
    /// two or not, and only `sampleBy` reads it.
    pub fn linear(format: Format, across: u32, down: u32, pitch: u32, memory: [*]u8) Texture {
        var made = Texture{
            .format = format,
            .width_log2 = 0,
            .height_log2 = 0,
            .levels = 1,
            .pitch = pitch,
            .layout = undefined,
            .memory = memory,
        };
        made.layout[0] = .{
            .start = 0,
            .width = across,
            .height = down,
            .across = @floatFromInt(across * 256),
            .down = @floatFromInt(down * 256),
            .last_column = 0,
            .last_row = 0,
            .column_low = 0,
            .column_high = 0,
            .row_low = 0,
            .row_high = 0,
            .blocks_shift = 0,
            .row_gap = 0,
            // Nothing masks here: such a texture is sampled by `sampleBy`,
            // which holds a coordinate inside the level itself.
            .tiles = false,
        };
        return made;
    }

    /// A texture over `memory`, at least `bytes` long and aligned for a
    /// texel as it is kept, its texels undefined until they are put in (`put`,
    /// `load`). error.BadSize for a side of nothing or over `most_side`, or
    /// more levels than halving the longer side gives.
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
            at += sizes.blocks(@intCast(lod)) * format.blockBytes();
        }
        return texture;
    }

    /// A texture of `count` levels of `whole`, from `base` on, over
    /// `memory`, which is where level `base` lies: the levels laid out as
    /// `whole` laid them out, each start counted from the first of them, so
    /// that a view of some of an image's levels reads the texels the image
    /// holds. (Since 1.42.)
    pub fn from(whole: *const Texture, base: u32, count: u32, memory: [*]u8) Texture {
        const first = @min(base, whole.levels - 1);
        var made = whole.*;
        made.memory = memory;
        made.levels = @max(@min(count, whole.levels - first), 1);
        made.width_log2 = whole.width_log2 -| @as(u5, @intCast(@min(first, 31)));
        made.height_log2 = whole.height_log2 -| @as(u5, @intCast(@min(first, 31)));
        const start = whole.layout[first].start;
        for (0..made.levels) |k| {
            made.layout[k] = whole.layout[first + k];
            made.layout[k].start -= start;
        }
        return made;
    }

    /// A level's width and height, as the level itself carries them: a
    /// level past the last reads as the last. One kept in rows has the one
    /// level, of whatever size the image is.
    pub inline fn width(texture: *const Texture, lod: u32) u32 {
        return texture.layout[@min(lod, texture.levels - 1)].width;
    }

    pub inline fn height(texture: *const Texture, lod: u32) u32 {
        return texture.layout[@min(lod, texture.levels - 1)].height;
    }

    /// Where texel (x, y) of a level of a layer lies, in bytes from the
    /// texture's memory: its row and column for one kept in rows, and the
    /// level's own spread places for one kept in blocks.
    inline fn placeOf(texture: *const Texture, layer: u32, lod: u32, x: u32, y: u32) usize {
        if (texture.pitch != 0) return @as(usize, y) * texture.pitch + @as(usize, x) * texture.format.bytes();
        return @as(usize, layer) * texture.layer_bytes + texture.layout[lod].offset(texture.format, x, y);
    }

    /// Where texel (x, y) of a level is kept, in texels from `memory`; 0 for
    /// a compressed format, whose texels are not addressed one by one.
    pub fn index(texture: *const Texture, lod: u32, x: u32, y: u32) u32 {
        if (texture.format.compressed()) return 0;
        return @intCast(texture.placeOf(0, lod, x, y) / texture.format.bytes());
    }

    /// Where the block holding texel (x, y) of a level of a layer lies, in
    /// bytes from `memory`: `blockBytes` of them, as a copy of a compressed
    /// image moves them. (Since 1.44.)
    pub fn blockPlace(texture: *const Texture, layer: u32, lod: u32, x: u32, y: u32) usize {
        return texture.placeOf(layer, lod, x & ~@as(u32, block - 1), y & ~@as(u32, block - 1));
    }

    /// Texel (x, y) of a level set, in the texture's format.
    pub fn put(texture: *Texture, lod: u32, x: u32, y: u32, texel: u32) void {
        texture.putLayer(0, lod, x, y, texel);
    }

    /// Texel (x, y) of a level, as `put` was given it.
    pub fn peek(texture: *const Texture, lod: u32, x: u32, y: u32) u32 {
        return texture.peekLayer(0, lod, x, y);
    }

    /// Texel (x, y) of a level of a layer set, in the texture's format.
    /// Nothing of a compressed format: its texels are not written one at a
    /// time, only block by block (`putBlock`).
    pub fn putLayer(texture: *Texture, layer: u32, lod: u32, x: u32, y: u32, texel: u32) void {
        const at = texture.memory + texture.placeOf(layer, lod, x, y);
        switch (texture.format) {
            .rgba8888 => @as(*u64, @ptrCast(@alignCast(at))).* = spread(texel),
            .rgb565, .d16 => @as(*u16, @ptrCast(@alignCast(at))).* = @truncate(texel),
            // Nothing is written a texel at a time into a texture that
            // keeps what it was given: `putTexels` moves the bytes.
            .bc1, .bc1_rgb, .bc2, .bc3, .rgba16f, .rgba32f, .rg11b10f, .rgb9e5 => {},
        }
    }

    /// Texel (x, y) of a level of a layer, as `putLayer` was given it; a
    /// compressed texture's texel as `colorAt` reads it, there being no
    /// texel of its own to give back.
    pub fn peekLayer(texture: *const Texture, layer: u32, lod: u32, x: u32, y: u32) u32 {
        const at = texture.memory + texture.placeOf(layer, lod, x, y);
        return switch (texture.format) {
            .rgba8888 => gather(@as(*const u64, @ptrCast(@alignCast(at))).*),
            .rgb565, .d16 => @as(*const u16, @ptrCast(@alignCast(at))).*,
            inline .bc1, .bc1_rgb, .bc2, .bc3 => |one| blockOf(one, at)[(y % block) * block + (x % block)],
            inline .rgba16f, .rgba32f, .rg11b10f, .rgb9e5 => |one| floatTexel(one, at),
        };
    }

    /// The bytes of the block holding texel (x, y) of a level of a layer
    /// set, `format.blockBytes()` of them: how a copy into a compressed
    /// image moves it, the texels staying as they lie. Nothing of a format
    /// that is not compressed. (Since 1.44.)
    pub fn putBlock(texture: *Texture, layer: u32, lod: u32, x: u32, y: u32, given: []const u8) void {
        if (!texture.format.compressed()) return;
        const wide = texture.format.blockBytes();
        if (given.len < wide) return;
        const at = texture.memory + texture.blockPlace(layer, lod, x, y);
        @memcpy(at[0..wide], given[0..wide]);
    }

    /// The bytes of texel (x, y) of a level of a layer, `format.bytes()` of
    /// them, as they lie: how a copy into a texture that keeps its texels -
    /// a float one - moves one, nothing converted. Nothing of a compressed
    /// format, whose texels have no bytes of their own. (Since 1.45.)
    pub fn putTexels(texture: *Texture, layer: u32, lod: u32, x: u32, y: u32, given: []const u8) void {
        if (texture.format.compressed()) return;
        const wide = texture.format.bytes();
        if (given.len < wide) return;
        const at = texture.memory + texture.placeOf(layer, lod, x, y);
        @memcpy(at[0..wide], given[0..wide]);
    }

    /// The same read back, into `into`. (Since 1.45.)
    pub fn texelsAt(texture: *const Texture, layer: u32, lod: u32, x: u32, y: u32, into: []u8) void {
        if (texture.format.compressed()) return;
        const wide = texture.format.bytes();
        if (into.len < wide) return;
        const at = texture.memory + texture.placeOf(layer, lod, x, y);
        @memcpy(into[0..wide], at[0..wide]);
    }

    /// The same read back, into `into`. (Since 1.44.)
    pub fn blockBytesAt(texture: *const Texture, layer: u32, lod: u32, x: u32, y: u32, into: []u8) void {
        if (!texture.format.compressed()) return;
        const wide = texture.format.blockBytes();
        if (into.len < wide) return;
        const at = texture.memory + texture.blockPlace(layer, lod, x, y);
        @memcpy(into[0..wide], at[0..wide]);
    }

    /// A texel of a layer set from 0xAARRGGBB, whatever its format:
    /// `colorAt` undone. What a shader function writes through a storage
    /// image with (`shader.Resources.written`).
    pub fn setColor(texture: *Texture, layer: u32, lod: u32, x: u32, y: u32, color: u32) void {
        texture.putLayer(layer, lod, x, y, switch (texture.format) {
            .rgba8888 => color,
            .rgb565 => as565(color),
            // The red channel as a depth, its 8 bits in the top of the 16.
            .d16 => (color >> 16 & 0xFF) * 0x101,
            // Nothing is written through a texture that keeps what it was
            // given: `putLayer` leaves it as it lies.
            .bc1, .bc1_rgb, .bc2, .bc3, .rgba16f, .rgba32f, .rg11b10f, .rgb9e5 => 0,
        });
    }

    /// A texel of a layer as 0xAARRGGBB, whatever its format.
    pub fn colorAt(texture: *const Texture, layer: u32, lod: u32, x: u32, y: u32) u32 {
        const texel = texture.peekLayer(layer, lod, x, y);
        return switch (texture.format) {
            .rgba8888 => texel,
            .rgb565 => expanded565(texel),
            // A depth as an opaque grey: its top 8 bits.
            .d16 => greyOf8(@truncate(texel >> 8)),
            // Decoded already: `peekLayer` read it out of its block, or
            // out of its floats.
            .bc1, .bc1_rgb, .bc2, .bc3, .rgba16f, .rgba32f, .rg11b10f, .rgb9e5 => texel,
        };
    }

    /// The colour at (u, v) of a level of a layer. A pixel at a time and by
    /// floats: what `textured` does for a texture of one layer, far faster.
    pub fn sampleLayer(texture: *const Texture, sampling: Sampling, layer: u32, lod: u32, u: f32, v: f32) u32 {
        const across = texture.width(lod);
        const down = texture.height(lod);
        const x = sane(u) * @as(f32, @floatFromInt(across));
        const y = sane(v) * @as(f32, @floatFromInt(down));
        if (sampling.filter == .nearest) {
            return texture.colorAt(layer, lod, placeIn(sampling.address, @intFromFloat(@floor(x)), across), placeIn(sampling.address, @intFromFloat(@floor(y)), down));
        }
        const low_x = @floor(x - 0.5);
        const low_y = @floor(y - 0.5);
        const left: i32 = @intFromFloat(low_x);
        const top: i32 = @intFromFloat(low_y);
        const x0 = placeIn(sampling.address, left, across);
        const x1 = placeIn(sampling.address, left + 1, across);
        const y0 = placeIn(sampling.address, top, down);
        const y1 = placeIn(sampling.address, top + 1, down);
        const part_x = x - 0.5 - low_x;
        const upper = mixColors(texture.colorAt(layer, lod, x0, y0), texture.colorAt(layer, lod, x1, y0), part_x);
        const lower = mixColors(texture.colorAt(layer, lod, x0, y1), texture.colorAt(layer, lod, x1, y1), part_x);
        return mixColors(upper, lower, y - 0.5 - low_y);
    }

    /// A 3D texture's colour at (u, v, r), each 0 to 1 across it.
    pub fn sampleVolume(texture: *const Texture, sampling: Sampling, u: f32, v: f32, r: f32) u32 {
        const z = sane(r) * @as(f32, @floatFromInt(texture.layer_count));
        if (sampling.filter == .nearest) return texture.sampleLayer(sampling, placeIn(sampling.address, @intFromFloat(@floor(z)), texture.layer_count), 0, u, v);
        const low = @floor(z - 0.5);
        const first: i32 = @intFromFloat(low);
        const near = texture.sampleLayer(sampling, placeIn(sampling.address, first, texture.layer_count), 0, u, v);
        const far = texture.sampleLayer(sampling, placeIn(sampling.address, first + 1, texture.layer_count), 0, u, v);
        return mixColors(near, far, z - 0.5 - low);
    }

    /// A cube's colour the way (x, y, z) looks. Filtered, what lies past
    /// a face's edge is read from the face next to it, as a GPU has it.
    pub fn sampleCube(texture: *const Texture, sampling: Sampling, lod: u32, x: f32, y: f32, z: f32) u32 {
        const hit = cubeHit(sane(x), sane(y), sane(z));
        var edged = sampling;
        edged.address = .clamp;
        if (sampling.filter == .nearest) return texture.sampleLayer(edged, hit.face, lod, hit.u, hit.v);
        const size: i32 = @intCast(texture.width(lod));
        const across = hit.u * @as(f32, @floatFromInt(size)) - 0.5;
        const down = hit.v * @as(f32, @floatFromInt(size)) - 0.5;
        const left: i32 = @intFromFloat(@floor(across));
        const top: i32 = @intFromFloat(@floor(down));
        const part_x = across - @floor(across);
        const upper = mixColors(texture.cubeTexel(hit.face, lod, left, top), texture.cubeTexel(hit.face, lod, left + 1, top), part_x);
        const lower = mixColors(texture.cubeTexel(hit.face, lod, left, top + 1), texture.cubeTexel(hit.face, lod, left + 1, top + 1), part_x);
        return mixColors(upper, lower, down - @floor(down));
    }

    /// Texel (x, y) of a face, or if that is past its edge, the one of the
    /// next face in the same direction.
    fn cubeTexel(texture: *const Texture, face: u32, lod: u32, x: i32, y: i32) u32 {
        const size: i32 = @intCast(texture.width(lod));
        if (x >= 0 and y >= 0 and x < size and y < size) return texture.colorAt(face, lod, @intCast(x), @intCast(y));
        const whole: f32 = @floatFromInt(size);
        const towards = cubeDirection(face, (@as(f32, @floatFromInt(x)) + 0.5) / whole * 2 - 1, (@as(f32, @floatFromInt(y)) + 0.5) / whole * 2 - 1);
        const next = cubeHit(towards[0], towards[1], towards[2]);
        return texture.colorAt(next.face, lod, placeIn(.clamp, @intFromFloat(@floor(next.u * whole)), texture.width(lod)), placeIn(.clamp, @intFromFloat(@floor(next.v * whole)), texture.width(lod)));
    }

    /// The layer of an array `r` falls on: the nearest there is.
    pub fn layerNear(texture: *const Texture, r: f32) u32 {
        const whole = @floor(sane(r) + 0.5);
        if (whole < 0) return 0;
        return @min(@as(u32, @intFromFloat(whole)), texture.layer_count - 1);
    }

    /// A level from a picture kept row by row, `pitch` bytes from one row
    /// to the next, in the texture's format. Nothing of a texture that
    /// keeps what it was given - a compressed one or a float one:
    /// `putBlock` and `putTexels` write those.
    pub fn load(texture: *Texture, lod: u32, pixels: [*]const u8, pitch: usize) void {
        if (texture.format.kept()) return;
        for (0..texture.height(lod)) |y| {
            const row = pixels + y * pitch;
            for (0..texture.width(lod)) |x| {
                const texel: u32 = switch (texture.format) {
                    .rgba8888 => std.mem.readInt(u32, row[x * 4 ..][0..4], .little),
                    .rgb565, .d16 => std.mem.readInt(u16, row[x * 2 ..][0..2], .little),
                    .bc1, .bc1_rgb, .bc2, .bc3, .rgba16f, .rgba32f, .rg11b10f, .rgb9e5 => unreachable,
                };
                texture.put(lod, @intCast(x), @intCast(y), texel);
            }
        }
    }
};

/// A coordinate that a float's slip cannot make a NaN or too large for a
/// whole number.
fn sane(value: f32) f32 {
    if (!(value > -1_000_000)) return if (value != value) 0 else -1_000_000;
    return @min(value, 1_000_000);
}

/// Where a whole coordinate lands in a side of `size`.
fn placeIn(address: Address, at: i32, size: u32) u32 {
    const whole: i32 = @intCast(size);
    return switch (address) {
        .wrap => @intCast(@mod(at, whole)),
        .clamp => @intCast(std.math.clamp(at, 0, whole - 1)),
    };
}

/// 0xAARRGGBB as the 16 bits of 565, each channel's top bits kept:
/// `expanded565` undone, as far as it goes.
fn as565(color: u32) u32 {
    return color >> 8 & 0xF800 | color >> 5 & 0x07E0 | color >> 3 & 0x001F;
}

/// 16 bits of colour as 0xFFRRGGBB, each channel's top bits over its bottom.
fn expanded565(texel: u32) u32 {
    const r = texel >> 11 & 0x1F;
    const g = texel >> 5 & 0x3F;
    const b = texel & 0x1F;
    return 0xFF00_0000 | (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2);
}

/// Two 0xAARRGGBB, `part` of the way from one to the other.
fn mixColors(a: u32, b: u32, part: f32) u32 {
    const by: u32 = @intFromFloat(part * 256);
    var made: u32 = 0;
    inline for ([4]u5{ 0, 8, 16, 24 }) |shift| {
        const from = a >> shift & 0xFF;
        const to = b >> shift & 0xFF;
        made |= ((from * (256 - by) + to * by + 128) >> 8) << shift;
    }
    return made;
}

/// Which face of a cube a direction looks at, and where on it, 0 to 1: the
/// faces +x, -x, +y, -y, +z, -z, as Vulkan has them.
pub const CubeHit = struct { face: u32, u: f32, v: f32 };

pub fn cubeHit(x: f32, y: f32, z: f32) CubeHit {
    const ax = @abs(x);
    const ay = @abs(y);
    const az = @abs(z);
    var face: u32 = undefined;
    var sc: f32 = undefined;
    var tc: f32 = undefined;
    var ma: f32 = undefined;
    if (ax >= ay and ax >= az) {
        face = if (x >= 0) 0 else 1;
        sc = if (x >= 0) -z else z;
        tc = -y;
        ma = ax;
    } else if (ay >= az) {
        face = if (y >= 0) 2 else 3;
        sc = x;
        tc = if (y >= 0) z else -z;
        ma = ay;
    } else {
        face = if (z >= 0) 4 else 5;
        sc = if (z >= 0) x else -x;
        tc = -y;
        ma = az;
    }
    if (ma == 0) return .{ .face = face, .u = 0.5, .v = 0.5 };
    return .{ .face = face, .u = (sc / ma + 1) / 2, .v = (tc / ma + 1) / 2 };
}

/// The way through (a, b), each -1 to 1 across a face: what `cubeHit` undoes.
fn cubeDirection(face: u32, a: f32, b: f32) [3]f32 {
    return switch (face) {
        0 => .{ 1, -b, -a },
        1 => .{ -1, -b, a },
        2 => .{ a, 1, b },
        3 => .{ a, -1, -b },
        4 => .{ a, -b, 1 },
        else => .{ -a, -b, -1 },
    };
}

/// A texture's size, checked.
const Sizes = struct {
    /// Level 0 as it was asked for.
    width: u32,
    height: u32,
    /// The width the blocks are laid out by, as a power of two: the width
    /// itself where that is one, and the next one up where it is not.
    width_log2: u5,
    /// The height's, which the layout does not go by: what `Texture`
    /// carries for `from`.
    height_log2: u5,

    fn of(width: u32, height: u32, levels: u32) Texture.Error!Sizes {
        if (width == 0 or height == 0 or width > most_side or height > most_side) return error.BadSize;
        const width_log2: u5 = @intCast(std.math.log2_int_ceil(u32, width));
        const height_log2: u5 = @intCast(std.math.log2_int_ceil(u32, height));
        // As many levels as halving the longer side gives, Vulkan's way:
        // floor(log2(side)) + 1.
        const most = std.math.log2_int(u32, @max(width, height)) + 1;
        if (levels == 0 or levels > most_levels or levels > most) return error.BadSize;
        return .{ .width = width, .height = height, .width_log2 = width_log2, .height_log2 = height_log2 };
    }

    /// A level's width and height: halved each time, and never nothing.
    fn widthAt(sizes: Sizes, lod: u5) u32 {
        return @max(sizes.width >> lod, 1);
    }

    fn heightAt(sizes: Sizes, lod: u5) u32 {
        return @max(sizes.height >> lod, 1);
    }

    /// The width a level's blocks are laid out by, as a power of two: no
    /// narrower than the level, so its texels all lie inside.
    fn pitchLog2At(sizes: Sizes, lod: u5) u5 {
        return sizes.width_log2 -| lod;
    }

    /// The blocks of 4 x 4 texels a level keeps, whole: as wide as the
    /// layout goes by and as deep as the level is.
    fn blocks(sizes: Sizes, level: u5) u32 {
        const across = ((@as(u32, 1) << sizes.pitchLog2At(level)) + block - 1) / block;
        const down = (sizes.heightAt(level) + block - 1) / block;
        return across * down;
    }
};

/// The level for a quad: from how far the coordinates move, in texels of
/// the first level, a pixel across (`du_dx`, `dv_dx`) and a pixel down,
/// the larger of the two - 1 texel or less a pixel is the first level,
/// 2 the second, 4 the third - rounded to the nearest level the texture
/// has. Worked out from the exponent of the larger step squared, so it
/// costs no logarithm: a level changes where a step is about 1.4, 2.8 and
/// so on, a power of two times the root of two.
/// The level for a quad, from how far the coordinates move across it: the
/// nearest of the texture's levels to log2 of the longer step. Working on
/// the exponent alone is exact for that, not an approximation - the nearest
/// level changes where the squared step crosses 2^(2k+1), which is an
/// exponent and never a mantissa.
///
/// Being exact, it is also a step: a step either side of that boundary picks
/// a different level, and on a patterned texture that is a visible change of
/// colour rather than a small one. Something to know before trusting a
/// comparison of two renderings - see `c/test/raster/facetcube.zig` on what
/// `CHECK CORES` measures on the CM5.
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

test "a cube's faces, as Vulkan has them" {
    const testing = std.testing;
    const eps = 1e-6;
    for (0..6) |face| {
        const towards = cubeDirection(@intCast(face), 0.5, -0.25);
        const back = cubeHit(towards[0], towards[1], towards[2]);
        try testing.expectEqual(@as(u32, @intCast(face)), back.face);
        try testing.expectApproxEqAbs(@as(f32, 0.75), back.u, eps);
        try testing.expectApproxEqAbs(@as(f32, 0.375), back.v, eps);
    }
    var hit = cubeHit(1, 0.5, -0.5);
    try testing.expectEqual(@as(u32, 0), hit.face);
    try testing.expectApproxEqAbs(@as(f32, 0.75), hit.u, eps);
    try testing.expectApproxEqAbs(@as(f32, 0.25), hit.v, eps);
    hit = cubeHit(-1, 0, 0.5);
    try testing.expectEqual(@as(u32, 1), hit.face);
    try testing.expectApproxEqAbs(@as(f32, 0.75), hit.u, eps);
    hit = cubeHit(0.5, 2, 1);
    try testing.expectEqual(@as(u32, 2), hit.face);
    try testing.expectApproxEqAbs(@as(f32, 0.75), hit.v, eps);
    hit = cubeHit(0.5, -1, 0.5);
    try testing.expectEqual(@as(u32, 3), hit.face);
    try testing.expectApproxEqAbs(@as(f32, 0.25), hit.v, eps);
    hit = cubeHit(0.5, 0, 1);
    try testing.expectEqual(@as(u32, 4), hit.face);
    try testing.expectApproxEqAbs(@as(f32, 0.75), hit.u, eps);
    hit = cubeHit(0.5, 0, -1);
    try testing.expectEqual(@as(u32, 5), hit.face);
    try testing.expectApproxEqAbs(@as(f32, 0.25), hit.u, eps);
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
    /// blocks, as a power of two. It goes by the width the blocks are laid
    /// out by, which for a width that is not a power of two is the next one
    /// up.
    blocks_shift: u5,
    /// The bits between a row's low two and its others, set to carry one
    /// over them.
    row_gap: u32,
    /// Whether the level tiles by masking bits: both its sides powers of
    /// two, so that `wrap` is bits rather than a division. The fields above
    /// that mask - `last_column`, `last_row`, the lows and the highs - mean
    /// something only then.
    tiles: bool,

    fn of(format: Format, sizes: Sizes, lod: u5, start: u32) Level {
        const width = sizes.widthAt(lod);
        const height = sizes.heightAt(lod);
        const texel = format.shift();
        var level = Level{
            .start = start,
            .width = width,
            .height = height,
            .across = @floatFromInt(width * 256),
            .down = @floatFromInt(height * 256),
            .last_column = undefined,
            .last_row = undefined,
            .column_low = undefined,
            .column_high = undefined,
            .row_low = undefined,
            .row_high = undefined,
            .blocks_shift = (sizes.pitchLog2At(lod) -| 2) + format.blockLog2(),
            .row_gap = undefined,
            .tiles = std.math.isPowerOfTwo(width) and std.math.isPowerOfTwo(height),
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

    /// Texel (x, y)'s place, in bytes from the texture's memory - the place
    /// of the block it lies in, for a compressed format, whose texels are
    /// read by decoding that block.
    fn offset(level: Level, format: Format, x: u32, y: u32) u32 {
        if (format.compressed()) return level.start + level.blockAt(format, x, y);
        return level.start + level.rowAt(format.shift(), y) + columnAt(format.shift(), x);
    }

    /// Where the block holding texel (x, y) lies, in bytes from the level's
    /// start.
    pub inline fn blockAt(level: Level, format: Format, x: u32, y: u32) u32 {
        @setRuntimeSafety(false);
        return ((y / block) << level.blocks_shift) + ((x / block) << format.blockLog2());
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

// --- the float texels -------------------------------------------------------

/// One float texel at `at` as 0xAARRGGBB: each channel held between 0 and
/// 1 and rounded to 8 bits, which is what the tiles and the formats the
/// library draws into hold. What is above 1 reads as 255 and what is below
/// 0 as 0, a NaN among them. (Since 1.45.)
pub fn floatTexel(comptime format: Format, at: [*]const u8) u32 {
    @setRuntimeSafety(false);
    return switch (format) {
        .rgba16f => made: {
            var channels: [4]u32 = undefined;
            inline for (&channels, 0..) |*channel, k| channel.* = byteOfFloat(ofHalf(readLittle(u16, at + k * 2)));
            break :made channels[3] << 24 | channels[0] << 16 | channels[1] << 8 | channels[2];
        },
        .rgba32f => made: {
            var channels: [4]u32 = undefined;
            inline for (&channels, 0..) |*channel, k| channel.* = byteOfFloat(@bitCast(readLittle(u32, at + k * 4)));
            break :made channels[3] << 24 | channels[0] << 16 | channels[1] << 8 | channels[2];
        },
        .rg11b10f => made: {
            const word = readLittle(u32, at);
            const r = ofParts(word >> 6 & 0x1F, word & 0x3F, 6, 15);
            const g = ofParts(word >> 17 & 0x1F, word >> 11 & 0x3F, 6, 15);
            const b = ofParts(word >> 27 & 0x1F, word >> 22 & 0x1F, 5, 15);
            break :made 0xFF00_0000 | @as(u32, byteOfFloat(r)) << 16 | @as(u32, byteOfFloat(g)) << 8 | byteOfFloat(b);
        },
        .rgb9e5 => made: {
            const word = readLittle(u32, at);
            // One exponent for the three, biased by 15, over mantissas of
            // 9 bits that are whole numbers rather than 1.something.
            const scale = std.math.ldexp(@as(f32, 1), @as(i32, @intCast(word >> 27)) - 15 - 9);
            const r: f32 = @floatFromInt(word & 0x1FF);
            const g: f32 = @floatFromInt(word >> 9 & 0x1FF);
            const b: f32 = @floatFromInt(word >> 18 & 0x1FF);
            break :made 0xFF00_0000 | @as(u32, byteOfFloat(r * scale)) << 16 | @as(u32, byteOfFloat(g * scale)) << 8 | byteOfFloat(b * scale);
        },
        else => missing_texel,
    };
}

/// A float to 8 bits, held inside 0 to 1 and rounded; a NaN reads 0, which
/// the first comparison catches.
inline fn byteOfFloat(value: f32) u8 {
    if (!(value > 0)) return 0;
    if (value >= 1) return 255;
    return @intFromFloat(value * 255 + 0.5);
}

/// A half float's value, worked out by hand: not every processor the
/// library runs on has f16 to spare. A NaN comes back as one, and the
/// infinities as the largest finite value of that exponent. (Since 1.45.)
pub inline fn ofHalf(half: u16) f32 {
    const negative = half & 0x8000 != 0;
    const exponent: u32 = half >> 10 & 0x1F;
    const mantissa: u32 = half & 0x3FF;
    if (exponent == 31 and mantissa != 0) return std.math.nan(f32);
    const value = ofParts(exponent, mantissa, 10, 15);
    return if (negative) -value else value;
}

/// An unsigned float of `bits` of mantissa, its exponent biased by `bias`:
/// 0 for the lowest exponent is a number below the smallest normal one.
inline fn ofParts(exponent: u32, mantissa: u32, comptime bits: u5, comptime biased_by: i32) f32 {
    const whole: f32 = @floatFromInt(mantissa);
    const scale = @as(f32, @floatFromInt(@as(u32, 1) << bits));
    if (exponent == 0) return std.math.ldexp(whole / scale, 1 - biased_by);
    return std.math.ldexp(1 + whole / scale, @as(i32, @intCast(exponent)) - biased_by);
}

// --- the compressed blocks --------------------------------------------------

/// The sixteen texels of one compressed block at `at`, in rows, each
/// 0xAARRGGBB. BC1 reads 8 bytes and the rest 16; nothing is read past
/// them.
///
/// The block holds two endpoint colours of 565 and two bits for each texel,
/// which pick one of four: the endpoints and two between them. Where the
/// format punches through - BC1 - and the first endpoint is not above the
/// second, there are three colours and the fourth is clear. BC2 holds four
/// bits of alpha for each texel before the colours, and BC3 two endpoint
/// alphas with three bits for each texel between them. (Since 1.44.)
pub fn blockOf(comptime format: Format, at: [*]const u8) [16]u32 {
    @setRuntimeSafety(false);
    const colors_at = comptime if (format.blockBytes() == 16) 8 else 0;
    const colors = at + colors_at;
    const low = readLittle(u16, colors);
    const high = readLittle(u16, colors + 2);
    const table = endpoints(format == .bc1 or format == .bc1_rgb, low, high);
    const picks = readLittle(u32, colors + 4);
    var made: [16]u32 = undefined;
    for (&made, 0..) |*texel, k| texel.* = table[picks >> @intCast(k * 2) & 3];
    switch (format) {
        // Whatever the block says, such a texture is opaque.
        .bc1_rgb => for (&made) |*texel| {
            texel.* |= 0xFF00_0000;
        },
        // Four bits a texel, the low ones first.
        .bc2 => {
            const bits = readLittle(u64, at);
            for (&made, 0..) |*texel, k| {
                const alpha: u32 = @intCast(bits >> @intCast(k * 4) & 15);
                texel.* = texel.* & 0x00FF_FFFF | (alpha << 4 | alpha) << 24;
            }
        },
        // Two endpoints and three bits a texel between them.
        .bc3 => {
            const values = blockAlphas(at);
            for (&made, values) |*texel, alpha| texel.* = texel.* & 0x00FF_FFFF | @as(u32, alpha) << 24;
        },
        else => {},
    }
    return made;
}

/// The four colours a block's two endpoints make, 0xAARRGGBB, the first
/// three opaque; the fourth is clear where the format punches through and
/// the endpoints are in that order.
inline fn endpoints(comptime punches: bool, low: u16, high: u16) [4]u32 {
    @setRuntimeSafety(false);
    const first = channels565(low);
    const second = channels565(high);
    var made: [4]u32 = undefined;
    made[0] = opaqueOf(first);
    made[1] = opaqueOf(second);
    if (punches and low <= high) {
        var middle: [3]u32 = undefined;
        inline for (&middle, first, second) |*channel, a, b| channel.* = (a + b + 1) / 2;
        made[2] = opaqueOf(middle);
        // Clear, and black with it: what a GPU reads there.
        made[3] = 0;
        return made;
    }
    var third: [3]u32 = undefined;
    var fourth: [3]u32 = undefined;
    // Rounded, as an unpacking copy rounds it (`image/_decode.zig`): the
    // texel a sample reads is the one that copy would have written.
    inline for (&third, &fourth, first, second) |*one, *other, a, b| {
        one.* = (2 * a + b + 1) / 3;
        other.* = (a + 2 * b + 1) / 3;
    }
    made[2] = opaqueOf(third);
    made[3] = opaqueOf(fourth);
    return made;
}

/// A 565 colour's red, green and blue, each to 8 bits: the bits repeated
/// into the low ones, which is `channel * 255 / 31` (or 63) to the nearest.
inline fn channels565(color: u16) [3]u32 {
    const r: u32 = color >> 11 & 0x1F;
    const g: u32 = color >> 5 & 0x3F;
    const b: u32 = color & 0x1F;
    return .{ r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2 };
}

/// Red, green and blue as an opaque 0xAARRGGBB.
inline fn opaqueOf(channels: [3]u32) u32 {
    return 0xFF00_0000 | channels[0] << 16 | channels[1] << 8 | channels[2];
}

/// A BC3 block's sixteen alphas: two endpoints, and three bits for each
/// texel choosing between them - six values between, or four and the two
/// ends, as the endpoints' order says.
inline fn blockAlphas(at: [*]const u8) [16]u8 {
    @setRuntimeSafety(false);
    const first: u32 = at[0];
    const second: u32 = at[1];
    var table: [8]u8 = undefined;
    table[0] = @intCast(first);
    table[1] = @intCast(second);
    if (first > second) {
        inline for (2..8) |k| table[k] = @intCast(((8 - k) * first + (k - 1) * second + 3) / 7);
    } else {
        inline for (2..6) |k| table[k] = @intCast(((6 - k) * first + (k - 1) * second + 2) / 5);
        table[6] = 0;
        table[7] = 255;
    }
    var bits: u64 = 0;
    for (0..6) |k| bits |= @as(u64, at[2 + k]) << @intCast(k * 8);
    var made: [16]u8 = undefined;
    for (&made, 0..) |*alpha, k| alpha.* = table[@intCast(bits >> @intCast(k * 3) & 7)];
    return made;
}

/// `T` read from `at`, least significant byte first, whatever the alignment.
inline fn readLittle(comptime T: type, at: [*]const u8) T {
    @setRuntimeSafety(false);
    var made: T = 0;
    inline for (0..@sizeOf(T)) |k| made |= @as(T, at[k]) << @intCast(k * 8);
    return made;
}

/// Texel (x, y) of a level of a compressed texture, 0xAARRGGBB: its block
/// decoded, and the one of its sixteen picked out. (Since 1.44.)
pub inline fn texelIn(comptime format: Format, texture: *const Texture, level: *const Level, x: u32, y: u32) u32 {
    @setRuntimeSafety(false);
    const texels = blockIn(format, texture, level, x, y);
    return texels[(y % block) * block + (x % block)];
}

/// The sixteen texels of the block holding (x, y), in rows. (Since 1.44.)
pub inline fn blockIn(comptime format: Format, texture: *const Texture, level: *const Level, x: u32, y: u32) [16]u32 {
    @setRuntimeSafety(false);
    return blockOf(format, texture.memory + level.start + level.blockAt(format, x, y));
}

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
    if (comptime sampling.format.compressed()) return sampleBlocked(sampling, texture, level, s, t);
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

/// A sample of a texture whose texels lie compressed: the block the point
/// falls in decoded, and the texels picked out of it. One block for a
/// `nearest` sample, one for a `bilinear` sample whose four texels lie in
/// the same block - which three pixels in four do - and up to four where
/// they do not. (Since 1.44.)
inline fn sampleBlocked(comptime sampling: Sampling, texture: *const Texture, level: *const Level, s: i32, t: i32) u32 {
    @setRuntimeSafety(false);
    const left, const right = texelColumns(sampling, level, s);
    const top, const bottom = texelRows(sampling, level, t);
    if (comptime sampling.filter == .nearest) return texelIn(sampling.format, texture, level, left, top);
    // The four texels round the point, from as few blocks as they lie in.
    var corners: [4]u32 = undefined;
    if (left / block == right / block and top / block == bottom / block) {
        const texels = blockIn(sampling.format, texture, level, left, top);
        const row = (top % block) * block;
        const under = (bottom % block) * block;
        corners = .{
            texels[row + left % block],
            texels[row + right % block],
            texels[under + left % block],
            texels[under + right % block],
        };
    } else {
        corners = .{
            texelIn(sampling.format, texture, level, left, top),
            texelIn(sampling.format, texture, level, right, top),
            texelIn(sampling.format, texture, level, left, bottom),
            texelIn(sampling.format, texture, level, right, bottom),
        };
    }
    // Mixed as `sampleAt` mixes its four: weights of 256 that add up to it.
    const across: u64 = @as(u32, @bitCast(s)) & 0xFF;
    const down: u64 = @as(u32, @bitCast(t)) & 0xFF;
    const both = across * down >> 8;
    const sum = spread(corners[0]) * (256 + both - across - down) +
        spread(corners[1]) * (across - both) +
        spread(corners[2]) * (down - both) +
        spread(corners[3]) * both;
    return gather(sum >> 8 & lanes);
}

/// Texel column s / 256 and the next one, held inside the level as
/// `sampling.address` says. (Since 1.44.)
inline fn texelColumns(comptime sampling: Sampling, level: *const Level, s: i32) [2]u32 {
    @setRuntimeSafety(false);
    const x = s >> 8;
    switch (sampling.address) {
        .wrap => {
            if (level.tiles) {
                const last = level.width - 1;
                const inside = @as(u32, @bitCast(x)) & last;
                return .{ inside, (inside + 1) & last };
            }
            const inside: u32 = @intCast(@mod(x, @as(i32, @intCast(level.width))));
            return .{ inside, if (inside + 1 == level.width) 0 else inside + 1 };
        },
        .clamp => {
            const last: i32 = @intCast(level.width - 1);
            return .{ @intCast(std.math.clamp(x, 0, last)), @intCast(std.math.clamp(x +% 1, 0, last)) };
        },
    }
}

/// Texel row t / 256 and the next one, the same way. (Since 1.44.)
inline fn texelRows(comptime sampling: Sampling, level: *const Level, t: i32) [2]u32 {
    @setRuntimeSafety(false);
    const y = t >> 8;
    switch (sampling.address) {
        .wrap => {
            if (level.tiles) {
                const last = level.height - 1;
                const inside = @as(u32, @bitCast(y)) & last;
                return .{ inside, (inside + 1) & last };
            }
            const inside: u32 = @intCast(@mod(y, @as(i32, @intCast(level.height))));
            return .{ inside, if (inside + 1 == level.height) 0 else inside + 1 };
        },
        .clamp => {
            const last: i32 = @intCast(level.height - 1);
            return .{ @intCast(std.math.clamp(y, 0, last)), @intCast(std.math.clamp(y +% 1, 0, last)) };
        },
    }
}

/// The places of column s / 256 and the next one, inside the level.
inline fn columns(comptime sampling: Sampling, level: *const Level, s: i32) [2]usize {
    @setRuntimeSafety(false);
    const texel = comptime sampling.format.shift();
    switch (sampling.address) {
        .wrap => {
            // A level of any other size than two powers of two cannot be
            // tiled by masking: its column is brought inside by a division,
            // which is what such a texture costs a sample.
            if (!level.tiles) {
                const inside: u32 = @intCast(@mod(s >> 8, @as(i32, @intCast(level.width))));
                const next: u32 = if (inside + 1 == level.width) 0 else inside + 1;
                return .{ columnAt(texel, inside), columnAt(texel, next) };
            }
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
            if (!level.tiles) {
                const inside: u32 = @intCast(@mod(t >> 8, @as(i32, @intCast(level.height))));
                const next: u32 = if (inside + 1 == level.height) 0 else inside + 1;
                return .{ level.rowAt(texel, inside), level.rowAt(texel, next) };
            }
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
        // A depth as a grey, as `Texture.colorAt` reads one: the fast path
        // is built for blocks and never reads a texture of this.
        .d16 => greyOf8(@truncate(@as(*const u16, @ptrCast(@alignCast(at))).* >> 8)),
        // Never read a texel at a time: `sampleBlocked` has the block.
        .bc1, .bc1_rgb, .bc2, .bc3 => missing_texel,
        // A float texel read and rounded where it lies (since 1.45): the
        // decoding is the cost of keeping the floats.
        .rgba16f, .rgba32f, .rg11b10f, .rgb9e5 => floatTexel(format, at),
    };
}

/// The texel kept at `at`, spread.
inline fn fetchSpread(comptime format: Format, at: [*]const u8) u64 {
    @setRuntimeSafety(false);
    return switch (format) {
        .rgba8888 => @as(*const u64, @ptrCast(@alignCast(at))).*,
        .rgb565, .d16, .bc1, .bc1_rgb, .bc2, .bc3, .rgba16f, .rgba32f, .rg11b10f, .rgb9e5 => spread(fetch(format, at)),
    };
}

/// What a texel of a compressed format reads as where something asks for one
/// a texel at a time: a sample of such a texture decodes its block instead.
pub const missing_texel: u32 = 0xFFFF_00FF;

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

// --- sampling through a sampler ---------------------------------------------

/// The level a point falls on, as a float: log2 of the longer of the
/// distances the coordinates move in texels of level 0. Below 0 where a
/// texel covers more than a pixel, which is magnification.
///
/// `levelFor` is this rounded to a whole level, worked out on the exponent
/// alone; a sampler needs the fraction, to mix two levels and to spread its
/// samples along an axis, and so takes the logarithm.
pub fn levelOf(texture: *const Texture, point: Point) f32 {
    const sides = sidesOf(texture);
    const across = axisLength(point.du_dx * sides[0], point.dv_dx * sides[1]);
    const down = axisLength(point.du_dy * sides[0], point.dv_dy * sides[1]);
    const longer = @max(across, down);
    if (!(longer > 0)) return 0; // a NaN as well
    return @log2(longer);
}

/// The colour at a point of a layer, as `sampler` says: 0xAARRGGBB. With a
/// comparison it is how much of the sample passed instead - white where all
/// of it did, black where none - the alpha opaque.
///
/// The level comes from how fast the point's coordinates change
/// (`levelOf`), with the sampler's bias added and its clamp and the
/// texture's levels put over it; `mipmap` says whether the nearer level is
/// read alone or both are mixed. Anisotropy takes up to `anisotropy`
/// samples along the longer axis, at a level chosen for the shorter, which
/// is what keeps a surface seen edge-on from blurring into one colour.
pub fn sampleBy(texture: *const Texture, sampler: *const Sampler, layer: u32, point: Point) u32 {
    const last: f32 = @floatFromInt(texture.levels - 1);
    const wanted = levelOf(texture, point);
    // Vulkan's rule: the level before it is held says which filter it is.
    const filter = if (wanted + sampler.lod_bias <= 0) sampler.mag_filter else sampler.min_filter;
    var taps: u32 = 1;
    var level = wanted;
    if (sampler.anisotropy > 1 and texture.levels > 0) {
        const sides = sidesOf(texture);
        const across = axisLength(point.du_dx * sides[0], point.dv_dx * sides[1]);
        const down = axisLength(point.du_dy * sides[0], point.dv_dy * sides[1]);
        const longer = @max(across, down);
        const shorter = @min(across, down);
        if (shorter > 0 and longer > shorter) {
            const wide = @min(sampler.anisotropy, @as(f32, most_taps));
            const ratio = @min(longer / shorter, wide);
            taps = @intFromFloat(@ceil(ratio));
            taps = @min(@max(taps, 1), most_taps);
            // The samples spread along the longer axis stand for it, so the
            // level is the shorter axis's: longer / taps, not longer.
            level = @log2(longer / @as(f32, @floatFromInt(taps)));
        }
    }
    level = held(level + sampler.lod_bias, sampler, last);
    if (sampler.mipmap == .nearest or texture.levels == 1) {
        return tapped(texture, sampler, layer, @intFromFloat(@round(level)), point, taps, filter);
    }
    const lower = @floor(level);
    const low: u32 = @intFromFloat(lower);
    const high: u32 = @intFromFloat(@min(lower + 1, last));
    const part = level - lower;
    if (low == high or part <= 0) return tapped(texture, sampler, layer, low, point, taps, filter);
    return mixColors(
        tapped(texture, sampler, layer, low, point, taps, filter),
        tapped(texture, sampler, layer, high, point, taps, filter),
        part,
    );
}

/// A 3D texture's colour at (u, v) of `point` and `r` through it, each 0 to
/// 1, as `sampler` says: its slices are its layers, read as `wrap[2]` says
/// and mixed where the filter is bilinear.
pub fn sampleVolumeBy(texture: *const Texture, sampler: *const Sampler, point: Point, r: f32) u32 {
    const slices = texture.layer_count;
    const z = sane(r) * @as(f32, @floatFromInt(slices));
    if (sampler.min_filter == .nearest and sampler.mag_filter == .nearest) {
        const slice = slicedIn(sampler, @intFromFloat(@floor(z)), slices) orelse return sampler.border;
        return sampleBy(texture, sampler, slice, point);
    }
    const lower = @floor(z - 0.5);
    const first: i32 = @intFromFloat(lower);
    const near = if (slicedIn(sampler, first, slices)) |slice| sampleBy(texture, sampler, slice, point) else sampler.border;
    const far = if (slicedIn(sampler, first + 1, slices)) |slice| sampleBy(texture, sampler, slice, point) else sampler.border;
    return mixColors(near, far, z - 0.5 - lower);
}

/// The texture's level 0 as floats: how many texels a coordinate of 1 is.
inline fn sidesOf(texture: *const Texture) [2]f32 {
    return .{ @floatFromInt(texture.width(0)), @floatFromInt(texture.height(0)) };
}

/// How far a point moves along an axis, in texels: the length of (du, dv).
inline fn axisLength(du: f32, dv: f32) f32 {
    return @sqrt(du * du + dv * dv);
}

/// A level held inside the sampler's clamp and the texture's levels. A NaN
/// falls to the first level, as `levelFor` has it.
inline fn held(level: f32, sampler: *const Sampler, last: f32) f32 {
    const lowest = @max(sampler.min_lod, 0);
    const highest = @min(sampler.max_lod, last);
    if (!(level > lowest)) return lowest; // a NaN as well
    return @min(level, @max(highest, lowest));
}

/// `taps` samples of a level along the longer axis, averaged: the point's
/// own where there is one.
fn tapped(texture: *const Texture, sampler: *const Sampler, layer: u32, lod: u32, point: Point, taps: u32, filter: Filter) u32 {
    const level = @min(lod, texture.levels - 1);
    if (taps <= 1) return sampledAt(texture, sampler, layer, level, point.u, point.v, filter, point.reference);
    const sides = sidesOf(texture);
    const across = axisLength(point.du_dx * sides[0], point.dv_dx * sides[1]);
    const down = axisLength(point.du_dy * sides[0], point.dv_dy * sides[1]);
    // Along the longer of the two, from half a pixel back to half a pixel on.
    const du = if (across >= down) point.du_dx else point.du_dy;
    const dv = if (across >= down) point.dv_dx else point.dv_dy;
    const count: f32 = @floatFromInt(taps);
    var sums: [4]u32 = @splat(0);
    for (0..taps) |k| {
        const at = (@as(f32, @floatFromInt(k)) + 0.5) / count - 0.5;
        const color = sampledAt(texture, sampler, layer, level, point.u + du * at, point.v + dv * at, filter, point.reference);
        inline for (&sums, [4]u5{ 0, 8, 16, 24 }) |*sum, shift| sum.* += color >> shift & 0xFF;
    }
    var made: u32 = 0;
    inline for (sums, [4]u5{ 0, 8, 16, 24 }) |sum, shift| made |= ((sum + taps / 2) / taps) << shift;
    return made;
}

/// One sample of a level at (u, v), filtered as `filter` says and compared
/// where the sampler asks for it.
fn sampledAt(texture: *const Texture, sampler: *const Sampler, layer: u32, lod: u32, u: f32, v: f32, filter: Filter, reference: f32) u32 {
    const across: f32 = @floatFromInt(texture.width(lod));
    const down: f32 = @floatFromInt(texture.height(lod));
    const x = sane(u) * across;
    const y = sane(v) * down;
    if (filter == .nearest) {
        const left: i32 = @intFromFloat(@floor(x));
        const top: i32 = @intFromFloat(@floor(y));
        if (sampler.compare == .none) return texelBy(texture, sampler, layer, lod, left, top);
        const value = valueBy(texture, sampler, layer, lod, left, top);
        return greyOf(if (sampler.compare.passes(value, reference)) 1 else 0);
    }
    const low_x = @floor(x - 0.5);
    const low_y = @floor(y - 0.5);
    const left: i32 = @intFromFloat(low_x);
    const top: i32 = @intFromFloat(low_y);
    const part_x = x - 0.5 - low_x;
    const part_y = y - 0.5 - low_y;
    const corners = [4]u32{
        texelBy(texture, sampler, layer, lod, left, top),
        texelBy(texture, sampler, layer, lod, left + 1, top),
        texelBy(texture, sampler, layer, lod, left, top + 1),
        texelBy(texture, sampler, layer, lod, left + 1, top + 1),
    };
    if (sampler.compare != .none) {
        // A shadow sample mixes what passed, not what was read: Vulkan's
        // percentage-closer filtering. Each corner is read as a value, so
        // a depth texture is compared at all 16 bits of it.
        var passed: f32 = 0;
        const weights = [4]f32{ (1 - part_x) * (1 - part_y), part_x * (1 - part_y), (1 - part_x) * part_y, part_x * part_y };
        const places = [4][2]i32{ .{ left, top }, .{ left + 1, top }, .{ left, top + 1 }, .{ left + 1, top + 1 } };
        inline for (places, weights) |place_at, weight| {
            if (sampler.compare.passes(valueBy(texture, sampler, layer, lod, place_at[0], place_at[1]), reference)) passed += weight;
        }
        return greyOf(passed);
    }
    const upper = mixColors(corners[0], corners[1], part_x);
    const lower = mixColors(corners[2], corners[3], part_x);
    return mixColors(upper, lower, part_y);
}

/// Texel (x, y) of a level of a layer, whole numbers that may lie past the
/// level: where they do, what `Sampler.wrap` says, which may be the border.
fn texelBy(texture: *const Texture, sampler: *const Sampler, layer: u32, lod: u32, x: i32, y: i32) u32 {
    const column = wrapped(sampler.wrap[0], x, texture.width(lod)) orelse return sampler.border;
    const row = wrapped(sampler.wrap[1], y, texture.height(lod)) orelse return sampler.border;
    return texture.colorAt(@min(layer, texture.layer_count - 1), lod, column, row);
}

/// What a shadow sample compares with the reference, 0 to 1: the depth of
/// a depth texture, at all 16 bits of it, and the red channel of any
/// other. Past a bordered edge the border's own red channel.
fn valueBy(texture: *const Texture, sampler: *const Sampler, layer: u32, lod: u32, x: i32, y: i32) f32 {
    const border = @as(f32, @floatFromInt(sampler.border >> 16 & 0xFF)) / 255;
    const column = wrapped(sampler.wrap[0], x, texture.width(lod)) orelse return border;
    const row = wrapped(sampler.wrap[1], y, texture.height(lod)) orelse return border;
    const at = @min(layer, texture.layer_count - 1);
    if (texture.format.depth()) {
        const kept = texture.peekLayer(at, lod, column, row);
        return @as(f32, @floatFromInt(kept & 0xFFFF)) / 65535;
    }
    return @as(f32, @floatFromInt(texture.colorAt(at, lod, column, row) >> 16 & 0xFF)) / 255;
}

/// Where a whole coordinate lands in a side of `size`; null for one past a
/// bordered edge, which reads the border instead.
fn wrapped(wrap: Wrap, at: i32, size: u32) ?u32 {
    const whole: i32 = @intCast(size);
    return switch (wrap) {
        .repeat => @intCast(@mod(at, whole)),
        .mirrored_repeat => mirrored: {
            const twice = @mod(at, 2 * whole);
            break :mirrored @intCast(if (twice < whole) twice else 2 * whole - 1 - twice);
        },
        .clamp_to_edge => @intCast(std.math.clamp(at, 0, whole - 1)),
        .clamp_to_border => if (at < 0 or at >= whole) null else @intCast(at),
    };
}

/// A 3D texture's slice `at`, as `wrap[2]` says; null past a bordered edge.
fn slicedIn(sampler: *const Sampler, at: i32, slices: u32) ?u32 {
    return wrapped(sampler.wrap[2], at, slices);
}

/// How much of a shadow sample passed, 0 to 1, as an opaque grey.
inline fn greyOf(passed: f32) u32 {
    const value: u32 = @intFromFloat(@min(@max(passed, 0), 1) * 255 + 0.5);
    return 0xFF00_0000 | value << 16 | value << 8 | value;
}

/// A channel as an opaque grey of it.
pub inline fn greyOf8(value: u8) u32 {
    const part: u32 = value;
    return 0xFF00_0000 | part << 16 | part << 8 | part;
}

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
//! **Two formats keep a texel smaller than the colour it reads as** (since
//! 1.48): `Format.argb8888`, the same 0xAARRGGBB in the 32 bits of one
//! word, spread as it is read; and `Format.r8`, one byte of red, read as
//! (red, 0, 0, 1) the way Vulkan reads R8_UNORM. Half the memory of
//! `rgba8888` and an eighth of it, for a spread a sample does itself - the
//! trade the other way round from the one above, and the one to make where
//! a texture is big enough to miss the cache. A level of `r8` is kept in
//! blocks of 4 x 4 bytes all the same, so its rows lie as every other
//! format's do.
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
    /// The same 0xAARRGGBB in 32 bits, one word a texel: half the memory
    /// `rgba8888` takes, for the spread a sample does as it reads each of
    /// its four texels. An image asks to be kept this way with
    /// IMAGE_CREATE_PACKED_TEXELS (`PhysicalDeviceFeatures.small_texels`,
    /// since 1.48). (Since 1.48.)
    argb8888,
    /// 16 bits, red in the top 5, green in the middle 6, blue in the low 5.
    rgb565,
    /// One byte of red a texel: Vulkan's R8_UNORM, read as (red, 0, 0, 1)
    /// - 0xFF0000RR as a colour, the green and the blue 0 and the alpha
    /// whole, as Vulkan reads a one-channel format. An eighth of the
    /// memory of the same texels kept as `rgba8888`, which is what a mask,
    /// a height field or a lightmap of one channel costs there
    /// (`PhysicalDeviceFeatures.small_texels`). (Since 1.48.)
    r8,
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
    /// One float a texel, 4 bytes: Vulkan's R32_SFLOAT, read as
    /// (red, 0, 0, 1) the way `r8` is, the float held between 0 and 1 and
    /// rounded to 8 bits for a sample. What a height field, a mask or an
    /// accumulation buffer a function writes is kept in
    /// (`Texture.setParts`, `partsAt`). (Since 1.57.)
    r32f,
    /// Two bytes a texel, red and green: Vulkan's R8G8_UNORM, read as
    /// (red, green, 0, 1). A quarter of the memory of the same texels
    /// spread as `rgba8888`, for a normal map of two channels, a flow
    /// field or a pair of masks
    /// (`PhysicalDeviceFeatures.wide_channels`). (Since 1.69.)
    rg8,
    /// 16 bits a channel, as they lie: Vulkan's R16_UNORM, read as
    /// (red, 0, 0, 1), R16G16_UNORM and R16G16B16A16_UNORM. A sample
    /// reads the top 8 bits of each channel, which is all a tile's colour
    /// holds, while `Texture.partsAt` gives the whole of them - a height
    /// field, a shadow map of a program's own or a texture a function
    /// writes through at more than 8 bits
    /// (`PhysicalDeviceFeatures.wide_channels`). (Since 1.69.)
    r16,
    rg16,
    rgba16,
    /// Whole numbers rather than a colour or a part of one: Vulkan's
    /// `_uint` and `_sint` formats, one channel, two or four, of 8, 16 or
    /// 32 bits. A counter, an index into a table, an object id or a
    /// bitfield a function reads or writes a texel at a time - what a
    /// colour of 8 bits a channel cannot carry at all, 300 being no
    /// colour.
    ///
    /// `Texture.wholesAt` reads them and `setWholes` writes them, each as
    /// the number it is; `partsAt` and `setParts` give and take the same
    /// numbers as floats, which carry 24 bits of one exactly; and a
    /// sample holds each to 0 to 1 and over 255, the way a texel buffer's
    /// `shader.Texels.colorAt` reads one, so that a whole number above 0
    /// is a channel at the full (`PhysicalDeviceFeatures.whole_textures`).
    /// (Since 1.70.)
    r8u,
    rg8u,
    rgba8u,
    r8i,
    rg8i,
    rgba8i,
    r16u,
    rg16u,
    rgba16u,
    r16i,
    rg16i,
    rgba16i,
    r32u,
    rg32u,
    rgba32u,
    r32i,
    rg32i,
    rgba32i,
    /// BC4 and BC5: one channel of red, and two of red and green, each a
    /// block of two endpoints and three bits for every texel between
    /// them - the very block BC3 keeps its alpha in. Read as
    /// (red, 0, 0, 1) and (red, green, 0, 1), as Vulkan reads a format of
    /// fewer channels, and kept in their blocks on a device that samples
    /// them (`PhysicalDeviceFeatures.kept_compressed`): 8 bytes a block
    /// and 16, against the 64 and 128 the unpacked texels take.
    /// (Since 1.72.)
    bc4,
    bc5,
    /// BC7: four channels in 16 bytes a block, where BC1 to BC3 hold
    /// three of 565 and a coarse alpha. A block is cut into one, two or
    /// three subsets by one of 64 patterns, each with two endpoints and
    /// an index for every texel saying how far between them it stands;
    /// one of eight modes says how many bits each of those takes, whether
    /// the endpoints carry an alpha of their own, and whether a second
    /// set of indices moves the alpha apart from the colour. It is the
    /// one block of these that holds a smooth alpha and a sharp colour at
    /// once, at the same quarter of the memory `bc1` costs an eighth of.
    /// Kept in its blocks on a device that samples them
    /// (`PhysicalDeviceFeatures.kept_compressed`). (Since 1.73.)
    bc7,
    /// BC6H, the one block of these to hold floats: three channels of
    /// half float in 16 bytes, with no alpha, for a texture whose
    /// channels run past 1 - a light probe, a sky, an exposure a frame is
    /// drawn from. The block is cut into one subset or two as BC7's is,
    /// and one of fourteen modes says how many bits the first endpoint's
    /// channels take and how many the others take as offsets on it. The
    /// `_ufloat` form holds nothing under 0 and the `_sfloat` one runs
    /// either way (`bc6hu`, `bc6hs`). A sample reads such a texel held
    /// between 0 and 1 and rounded to 8 bits, the way a float texel is,
    /// and `Texture.partsAt` gives a function the halves themselves.
    /// (Since 1.74.)
    bc6hu,
    bc6hs,

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
            .rgba8888, .rgba16f, .rgba16 => 3,
            .rgba32f => 4,
            .argb8888, .rg11b10f, .rgb9e5, .r32f, .rg16 => 2,
            .rgb565, .d16, .rg8, .r16 => 1,
            .r8, .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5, .bc6hu, .bc6hs, .bc7 => 0,
            // The whole numbers of 1.70: one channel, two or four, of 8,
            // 16 or 32 bits, which is 1 to 16 bytes a texel.
            .r8u, .r8i => 0,
            .rg8u, .rg8i, .r16u, .r16i => 1,
            .rgba8u, .rgba8i, .rg16u, .rg16i, .r32u, .r32i => 2,
            .rgba16u, .rgba16i, .rg32u, .rg32i => 3,
            .rgba32u, .rgba32i => 4,
        };
    }

    /// The bytes a block of 4 x 4 texels takes, as a power of two: what one
    /// level's row of blocks counts in, whether the texels lie in it one by
    /// one or compressed together.
    pub fn blockLog2(format: Format) u5 {
        return switch (format) {
            // 16 texels of 8 bytes, and of 2.
            .rgba8888, .rgba16f, .rgba16 => 7,
            .rgba32f => 8,
            .argb8888, .rg11b10f, .rgb9e5, .r32f, .rg16 => 6,
            .rgb565, .d16, .rg8, .r16 => 5,
            // The whole numbers of 1.70, 16 texels of each width.
            .rgba32u, .rgba32i => 8,
            .rgba16u, .rgba16i, .rg32u, .rg32i => 7,
            .rgba8u, .rgba8i, .rg16u, .rg16i, .r32u, .r32i => 6,
            .rg8u, .rg8i, .r16u, .r16i => 5,
            .r8u, .r8i => 4,
            // 16 texels of one byte, and the blocks of 8 and of 16.
            .r8, .bc2, .bc3, .bc5, .bc6hu, .bc6hs, .bc7 => 4,
            .bc1, .bc1_rgb, .bc4 => 3,
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
            .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5, .bc6hu, .bc6hs, .bc7 => true,
            .rgba8888, .argb8888, .rgb565, .r8, .d16, .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => false,
            .rg8, .r16, .rg16, .rgba16 => false,
            .r8u, .rg8u, .rgba8u, .r8i, .rg8i, .rgba8i, .r16u, .rg16u, .rgba16u, .r16i, .rg16i, .rgba16i, .r32u, .rg32u, .rgba32u, .r32i, .rg32i, .rgba32i => false,
        };
    }

    /// Whether a texel holds floats, which a sample reads and rounds to 8
    /// bits a channel (`floatTexel`): the texel is kept as it was copied
    /// in, so nothing of it is lost on the way out again. A function
    /// writes one by floats as well since 1.57 (`setParts`), where
    /// `putLayer`'s one word of a texel would have nothing to say.
    /// (Since 1.45.)
    pub fn floats(format: Format) bool {
        return switch (format) {
            .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => true,
            .rgba8888, .argb8888, .rgb565, .r8, .d16, .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5, .bc6hu, .bc6hs, .bc7 => false,
            .rg8, .r16, .rg16, .rgba16 => false,
            .r8u, .rg8u, .rgba8u, .r8i, .rg8i, .rgba8i, .r16u, .rg16u, .rgba16u, .r16i, .rg16i, .rgba16i, .r32u, .rg32u, .rgba32u, .r32i, .rg32i, .rgba32i => false,
        };
    }

    /// Whether a texel holds channels of its own that are not the 8888
    /// colour a sample makes of them: two bytes of red and green, or 16
    /// bits a channel. The texel is kept as it was copied in, as a float
    /// one is, so nothing of it is lost on the way out again: a sample
    /// reads the top 8 bits of each channel and `Texture.partsAt` the
    /// whole of them, and `setParts` writes the whole of them
    /// (`PhysicalDeviceFeatures.wide_channels`). (Since 1.69.)
    pub fn channels(format: Format) bool {
        return switch (format) {
            .rg8, .r16, .rg16, .rgba16 => true,
            .rgba8888, .argb8888, .rgb565, .r8, .d16, .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5, .bc6hu, .bc6hs, .bc7 => false,
            .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => false,
            // Whole numbers are their own kind: `wholes` (since 1.70).
            .r8u, .rg8u, .rgba8u, .r8i, .rg8i, .rgba8i, .r16u, .rg16u, .rgba16u, .r16i, .rg16i, .rgba16i, .r32u, .rg32u, .rgba32u, .r32i, .rg32i, .rgba32i => false,
        };
    }

    /// Whether a texel holds whole numbers rather than a colour, a part
    /// of one or a float: Vulkan's `_uint` and `_sint` formats, one
    /// channel, two or four, of 8, 16 or 32 bits. The texel is kept as it
    /// was copied in, as a float one and a channel one are, so nothing of
    /// it is lost on the way out again: `Texture.wholesAt` reads the
    /// numbers and `setWholes` writes them, while a sample holds each to
    /// 0 to 1 and over 255, a whole number being no colour
    /// (`PhysicalDeviceFeatures.whole_textures`). (Since 1.70.)
    pub fn wholes(format: Format) bool {
        return format.wholesOf() != null;
    }

    /// How many whole numbers a `wholes` format holds, how many bits each
    /// takes and whether it is signed: nothing for every other format.
    /// (Since 1.70.)
    pub fn wholesOf(format: Format) ?struct { parts: u32, bits: u32, signed: bool } {
        return switch (format) {
            .r8u => .{ .parts = 1, .bits = 8, .signed = false },
            .rg8u => .{ .parts = 2, .bits = 8, .signed = false },
            .rgba8u => .{ .parts = 4, .bits = 8, .signed = false },
            .r8i => .{ .parts = 1, .bits = 8, .signed = true },
            .rg8i => .{ .parts = 2, .bits = 8, .signed = true },
            .rgba8i => .{ .parts = 4, .bits = 8, .signed = true },
            .r16u => .{ .parts = 1, .bits = 16, .signed = false },
            .rg16u => .{ .parts = 2, .bits = 16, .signed = false },
            .rgba16u => .{ .parts = 4, .bits = 16, .signed = false },
            .r16i => .{ .parts = 1, .bits = 16, .signed = true },
            .rg16i => .{ .parts = 2, .bits = 16, .signed = true },
            .rgba16i => .{ .parts = 4, .bits = 16, .signed = true },
            .r32u => .{ .parts = 1, .bits = 32, .signed = false },
            .rg32u => .{ .parts = 2, .bits = 32, .signed = false },
            .rgba32u => .{ .parts = 4, .bits = 32, .signed = false },
            .r32i => .{ .parts = 1, .bits = 32, .signed = true },
            .rg32i => .{ .parts = 2, .bits = 32, .signed = true },
            .rgba32i => .{ .parts = 4, .bits = 32, .signed = true },
            else => null,
        };
    }

    /// How many channels a `channels` format holds, and how many bits
    /// each takes: nothing for every other format. (Since 1.69.)
    pub fn channelsOf(format: Format) ?struct { parts: u32, bits: u32 } {
        return switch (format) {
            .rg8 => .{ .parts = 2, .bits = 8 },
            .r16 => .{ .parts = 1, .bits = 16 },
            .rg16 => .{ .parts = 2, .bits = 16 },
            .rgba16 => .{ .parts = 4, .bits = 16 },
            else => null,
        };
    }

    /// Whether a texel's bytes are moved as they are rather than through a
    /// colour of 8 bits a channel: a compressed format's blocks and a
    /// float one's texels. (Since 1.45.)
    pub fn kept(format: Format) bool {
        return format.compressed() or format.floats() or format.channels() or format.wholes();
    }

    /// Whether a texel is kept in fewer bytes than the colour it reads as:
    /// `argb8888` in the four of its word rather than the eight it is
    /// spread in, and `r8` in one
    /// (`PhysicalDeviceFeatures.small_texels`). A sample reads such a
    /// texel and makes the colour of it, where the others are read as they
    /// lie. (Since 1.48.)
    pub fn small(format: Format) bool {
        return switch (format) {
            .argb8888, .r8, .rg8, .r16, .rg16 => true,
            .rgba8888, .rgb565, .d16, .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5, .bc6hu, .bc6hs, .bc7, .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => false,
            // Eight bytes, as a spread colour is, and still read channel
            // by channel (since 1.69).
            .rgba16 => false,
            // The whole numbers of 1.70 under eight bytes a texel, and
            // the three above it.
            .r8u, .r8i, .rg8u, .rg8i, .rgba8u, .rgba8i, .r16u, .r16i, .rg16u, .rg16i, .r32u, .r32i => true,
            .rgba16u, .rgba16i, .rg32u, .rg32i, .rgba32u, .rgba32i => false,
        };
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

/// What `sampler` comes to as a `Sampling`, or null where it asks for
/// something a `Sampling` cannot say.
///
/// A `Sampling` is what a *pipeline* does with a texture: one filter for
/// both directions, one addressing for every axis, and two of the five
/// wraps a sampler has. It says nothing of mipmapping, of a level held or
/// shifted, of anisotropy, of a comparison or of a border.
///
/// This is here, and not in either device, because **both** of them need
/// the same answer. Vulkan puts filtering in the sampler object and
/// SPIR-V has nowhere to carry what a shader asked, so a generated
/// shader's sampling is the bound sampler's on whichever device draws it;
/// and a sampler this cannot answer for is drawn by neither - the pixel
/// is `shader.missing`, which is a wrong colour on purpose rather than
/// two devices quietly drawing different right ones. (Since 1.79.)
pub fn samplingOf(sampler: *const Sampler, format: Format) ?Sampling {
    if (sampler.mag_filter != sampler.min_filter) return null;
    if (sampler.wrap[0] != sampler.wrap[1]) return null;
    if (sampler.mipmap != .nearest) return null;
    if (sampler.lod_bias != 0 or sampler.min_lod != 0 or sampler.max_lod != lod_unclamped) return null;
    if (sampler.anisotropy != 1 or sampler.compare != .none or sampler.unnormalized) return null;
    return .{
        .format = format,
        .filter = sampler.mag_filter,
        .address = switch (sampler.wrap[0]) {
            .repeat => .wrap,
            .clamp_to_edge => .clamp,
            else => return null,
        },
    };
}

/// How a sampler goes between the two levels a point falls between.
pub const Mipmap = enum(u8) {
    /// The nearer level alone, as a fixed form's sample reads it.
    nearest,
    /// Both, mixed by how far the point is between them.
    linear,
};

/// What a sampler reads past the texture's edge: `Address`'s two, and
/// three more that only a sampler can ask for.
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
    /// The texture turned round once and then held at its edge: a
    /// coordinate below 0 reads the texture mirrored, and one past the far
    /// side the far edge's texels. Vulkan's MIRROR_CLAMP_TO_EDGE, which it
    /// has from VK_KHR_sampler_mirror_clamp_to_edge. (Since 1.49.)
    mirror_clamp_to_edge,
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
    /// The point is in texels of the level read rather than 0 to 1 across
    /// the texture: Vulkan's `unnormalizedCoordinates`, for a program that
    /// reads a texture as a table of values. What it asks of the rest of
    /// the sampler is Vulkan's too, and CreateSampler holds to it: one
    /// filter for both, `nearest` mipmapping, no levels but the first
    /// (`min_lod` and `max_lod` both 0), one sample (no anisotropy), no
    /// comparison, and an edge held or bordered across and down.
    /// (Since 1.67.)
    unnormalized: bool = false,
};

/// A point in a texture, and how fast its coordinates change round it:
/// what a sampler is given to choose a level and how many samples to take.
/// The changes are a pixel's, 0 to 1 across the texture like the point
/// itself; all 0 asks for level 0, one sample.
///
/// A sampler whose coordinates are not normalized (`Sampler.unnormalized`)
/// reads `u` and `v` in texels instead - the first texel being 0 to 1, as
/// Vulkan has it - and nothing else of the point: such a sampler is held
/// to the first level and to one sample, so the changes say nothing.
/// (Since 1.67.)
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
    /// The bytes from one texel to the next along a row, where that is not
    /// the format's own size: the stencil plane of a depth attachment that
    /// holds both, one byte of every four (`linearBy`, since 1.58). 0 for
    /// the format's own size, which is every other texture.
    stride: u32 = 0,
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
    /// second layout, and how a colour attachment written through as a
    /// storage image is written (since 1.56). Its sides are whatever the
    /// image's are, powers of two or not; `sampleBy` reads it, and
    /// `setColor` and `colorAt` write and read its texels.
    pub fn linear(format: Format, across: u32, down: u32, pitch: u32, memory: [*]u8) Texture {
        return linearBy(format, across, down, pitch, 0, memory);
    }

    /// The same with `stride` bytes from one texel to the next rather than
    /// the format's own size, and 0 for that size: how the stencil plane
    /// of a depth attachment that holds both is read, one byte of every
    /// four. (Since 1.58.)
    pub fn linearBy(format: Format, across: u32, down: u32, pitch: u32, stride: u32, memory: [*]u8) Texture {
        var made = Texture{
            .format = format,
            .width_log2 = 0,
            .height_log2 = 0,
            .levels = 1,
            .pitch = pitch,
            .stride = stride,
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

    /// Another level of a texture kept in rows, in rows of its own:
    /// `across` by `down` texels, `start` bytes into the layer, and
    /// `pitch` bytes from one row to the next. The levels are added in
    /// order after the first, which `linearBy` made, and a sample of one
    /// reads that level's own rows - which is how a depth attachment of
    /// levels is sampled, each level the rows a pass drew into
    /// (since 1.63). A level past `most_levels` is not added.
    pub fn linearLevel(texture: *Texture, across: u32, down: u32, start: u32, pitch: u32) void {
        if (texture.levels >= most_levels) return;
        texture.layout[texture.levels] = .{
            .start = start,
            .width = across,
            .height = down,
            .pitch = pitch,
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
            .tiles = false,
        };
        texture.levels += 1;
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
        if (texture.pitch != 0) {
            const apart = if (texture.stride != 0) texture.stride else texture.format.bytes();
            // The level's own rows, after the levels before it inside the
            // layer (since 1.63). `linearBy`'s one level starts at 0 and
            // has no pitch of its own, so it is the texture's.
            const level = &texture.layout[lod];
            const pitch = if (level.pitch != 0) level.pitch else texture.pitch;
            return @as(usize, layer) * texture.layer_bytes + level.start + @as(usize, y) * pitch + @as(usize, x) * apart;
        }
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
            .argb8888 => @as(*u32, @ptrCast(@alignCast(at))).* = texel,
            .rgb565, .d16 => @as(*u16, @ptrCast(@alignCast(at))).* = @truncate(texel),
            .r8 => at[0] = @truncate(texel),
            // Nothing is written a texel at a time into a texture that
            // keeps what it was given: `putTexels` moves the bytes.
            .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5, .bc6hu, .bc6hs, .bc7, .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => {},
            .rg8, .r16, .rg16, .rgba16 => {},
            .r8u, .rg8u, .rgba8u, .r8i, .rg8i, .rgba8i, .r16u, .rg16u, .rgba16u, .r16i, .rg16i, .rgba16i, .r32u, .rg32u, .rgba32u, .r32i, .rg32i, .rgba32i => {},
        }
    }

    /// Texel (x, y) of a level of a layer, as `putLayer` was given it; a
    /// compressed texture's texel as `colorAt` reads it, there being no
    /// texel of its own to give back.
    pub fn peekLayer(texture: *const Texture, layer: u32, lod: u32, x: u32, y: u32) u32 {
        const at = texture.memory + texture.placeOf(layer, lod, x, y);
        return switch (texture.format) {
            .rgba8888 => gather(@as(*const u64, @ptrCast(@alignCast(at))).*),
            .argb8888 => @as(*const u32, @ptrCast(@alignCast(at))).*,
            .rgb565, .d16 => @as(*const u16, @ptrCast(@alignCast(at))).*,
            .r8 => at[0],
            inline .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5, .bc6hu, .bc6hs, .bc7 => |one| blockOf(one, at)[(y % block) * block + (x % block)],
            inline .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => |one| floatTexel(one, at),
            // The channels made into a colour, as a float texel is
            // (since 1.69): the top 8 bits of each.
            .rg8, .r16, .rg16, .rgba16 => channelColor(texture.format, at),
            // And a texel of whole numbers as the colour they hold to
            // (since 1.70): nothing, or the channel at the full.
            .r8u, .rg8u, .rgba8u, .r8i, .rg8i, .rgba8i, .r16u, .rg16u, .rgba16u, .r16i, .rg16i, .rgba16i, .r32u, .rg32u, .rgba32u, .r32i, .rg32i, .rgba32i => wholeColor(texture.format, at),
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

    /// Whether the texture has level `lod` of layer `layer`, and texel
    /// (x, y) of it: what `setColor` writes nothing past and `colorAt`
    /// reads transparent black past. A 3D texture's layers are its slices
    /// at level 0, all of which lie in its memory, so a level past the
    /// first takes more of them than a sample of that level reads
    /// (`slicesAt`). (Since 1.55.)
    pub fn holds(texture: *const Texture, layer: u32, lod: u32, x: u32, y: u32) bool {
        if (lod >= texture.levels or layer >= texture.layer_count) return false;
        return x < texture.width(lod) and y < texture.height(lod);
    }

    /// A texel of a layer set from 0xAARRGGBB, whatever its format:
    /// `colorAt` undone. What a shader function writes through a storage
    /// image with (`shader.Resources.written`).
    ///
    /// The level, the layer and the place are held to what the texture has
    /// (`holds`): a function naming one it has not got writes nothing,
    /// rather than past the texture's memory. `putLayer` is the same write
    /// in the texture's own format and holds to nothing, which is what the
    /// library's own copies want. (Since 1.55.)
    pub fn setColor(texture: *Texture, layer: u32, lod: u32, x: u32, y: u32, color: u32) void {
        if (!texture.holds(layer, lod, x, y)) return;
        // A texel of floats takes the colour's channels as 0 to 1, which
        // is all a colour ever said (since 1.57); `setParts` is what such
        // a texture is written with where more than that is meant.
        if (texture.format.floats()) return texture.putParts(layer, lod, x, y, partsOfColor(color));
        // The same of a texel of channels of its own (since 1.69): the
        // colour's channels as 0 to 1, which is all a colour ever said.
        if (texture.format.channels()) return texture.putChannels(layer, lod, x, y, partsOfColor(color));
        // A texel of whole numbers takes the colour's four channels as
        // the numbers 0 to 255 they are (since 1.70), which is what
        // `shader.Texels.setInt` writes an 8888 texel from as well;
        // `setWholes` is what such a texture is written with where a
        // number of its own is meant.
        if (texture.format.wholes()) return texture.putWholes(layer, lod, x, y, wholesOfColor(color));
        texture.putLayer(layer, lod, x, y, switch (texture.format) {
            .rgba8888, .argb8888 => color,
            .rgb565 => as565(color),
            // The red channel alone, the only one such a texel has.
            .r8 => color >> 16 & 0xFF,
            // The red channel as a depth, its 8 bits in the top of the 16.
            .d16 => (color >> 16 & 0xFF) * 0x101,
            // Nothing is written a texel at a time into a compressed
            // texture: `putLayer` leaves it as it lies.
            .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5, .bc6hu, .bc6hs, .bc7 => 0,
            .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => unreachable,
            .rg8, .r16, .rg16, .rgba16 => unreachable,
            .r8u, .rg8u, .rgba8u, .r8i, .rg8i, .rgba8i, .r16u, .rg16u, .rgba16u, .r16i, .rg16i, .rgba16i, .r32u, .rg32u, .rgba32u, .r32i, .rg32i, .rgba32i => unreachable,
        });
    }

    /// A texel of a layer set from x, y, z and w: a colour format's
    /// channels 0 to 1, and a float format's as they are, which is what a
    /// texture of floats is written through with - `setColor`'s 8 bits a
    /// channel would be all such a texel ever held. The level, the layer
    /// and the place are held to what the texture has, as `setColor` has
    /// them, and a compressed texture takes nothing. (Since 1.57.)
    pub fn setParts(texture: *Texture, layer: u32, lod: u32, x: u32, y: u32, parts: [4]f32) void {
        if (!texture.holds(layer, lod, x, y)) return;
        if (texture.format.floats()) return texture.putParts(layer, lod, x, y, parts);
        // Channels of its own, the whole of each (since 1.69): 16 bits a
        // channel keeps what a colour of 8 could not.
        if (texture.format.channels()) return texture.putChannels(layer, lod, x, y, parts);
        // Whole numbers, rounded (since 1.70): a float carries 24 bits of
        // one exactly, and `setWholes` is the way to write a larger one.
        if (texture.format.wholes()) {
            var made: [4]i64 = undefined;
            for (&made, parts) |*one, part| one.* = wholeOfFloat(part);
            return texture.putWholes(layer, lod, x, y, made);
        }
        // A depth takes x as 0 to 1 over all 16 bits, where a colour of 8
        // bits a channel would keep the top 8 of them (since 1.58).
        if (texture.format == .d16) return texture.putLayer(layer, lod, x, y, @intFromFloat(@round(heldAt(parts[0], 1) * 65535)));
        if (texture.format.compressed()) return;
        texture.setColor(layer, lod, x, y, colorOfParts(parts));
    }

    /// The same for a format whose channels are its own: each held to 0
    /// to 1 and written at the width the channel has. (Since 1.69.)
    fn putChannels(texture: *Texture, layer: u32, lod: u32, x: u32, y: u32, parts: [4]f32) void {
        putChannelParts(texture.format, texture.memory + texture.placeOf(layer, lod, x, y), parts);
    }

    /// The same for a format of whole numbers, without holding to
    /// anything. (Since 1.70.)
    fn putWholes(texture: *Texture, layer: u32, lod: u32, x: u32, y: u32, parts: [4]i64) void {
        putWholeParts(texture.format, texture.memory + texture.placeOf(layer, lod, x, y), parts);
    }

    /// A texel of a layer as the four whole numbers its channels keep: an
    /// integer format's as they lie, where `partsAt`'s floats carry only
    /// 24 bits of a 32-bit one; a format whose channels are its own (1.69)
    /// the numbers those channels hold, 0 to 255 or 0 to 65535; and every
    /// other format the four channels of its colour, 0 to 255. What the
    /// format has not got reads as 0 and its alpha as 1, and a texel the
    /// texture has not got reads all zero, as `colorAt` has it.
    /// `shader.Texels.intAt` is the same read of a texel buffer.
    /// (Since 1.70.)
    pub fn wholesAt(texture: *const Texture, layer: u32, lod: u32, x: u32, y: u32) [4]i64 {
        if (!texture.holds(layer, lod, x, y)) return .{ 0, 0, 0, 0 };
        if (texture.format.wholes()) return wholeParts(texture.format, texture.memory + texture.placeOf(layer, lod, x, y));
        if (texture.format.channelsOf()) |one| {
            const at = texture.memory + texture.placeOf(layer, lod, x, y);
            var made = [4]i64{ 0, 0, 0, 1 };
            for (0..one.parts) |k| made[k] = channelAt(at, one.bits, k);
            return made;
        }
        const color = texture.texelColor(layer, lod, x, y);
        var made: [4]i64 = undefined;
        inline for (&made, [4]u5{ 16, 8, 0, 24 }) |*one, shift| one.* = color >> shift & 0xFF;
        return made;
    }

    /// A texel of a layer set from four whole numbers: an integer
    /// format's as they are, each held to what its channel holds; a
    /// format whose channels are its own as the numbers those channels
    /// hold; and every other format as the colour of their low 8 bits.
    /// The level, the layer and the place are held to what the texture
    /// has, as `setColor` has them, and a compressed texture takes
    /// nothing. (Since 1.70.)
    pub fn setWholes(texture: *Texture, layer: u32, lod: u32, x: u32, y: u32, parts: [4]i64) void {
        if (!texture.holds(layer, lod, x, y)) return;
        if (texture.format.wholes()) return texture.putWholes(layer, lod, x, y, parts);
        if (texture.format.channelsOf()) |one| {
            const most: f32 = if (one.bits == 8) 255 else 65535;
            var made: [4]f32 = undefined;
            for (&made, parts) |*part, whole| part.* = @as(f32, @floatFromInt(heldWhole(whole, one.bits, false))) / most;
            return texture.putChannels(layer, lod, x, y, made);
        }
        var color: u32 = 0;
        inline for (parts, [4]u5{ 16, 8, 0, 24 }) |one, shift| {
            color |= @as(u32, @intCast(heldWhole(one, 8, false))) << shift;
        }
        texture.setColor(layer, lod, x, y, color);
    }

    /// The same without holding to anything, for a format of floats.
    fn putParts(texture: *Texture, layer: u32, lod: u32, x: u32, y: u32, parts: [4]f32) void {
        const at = texture.memory + texture.placeOf(layer, lod, x, y);
        switch (texture.format) {
            inline .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => |one| putFloatTexel(one, at, parts),
            else => {},
        }
    }

    /// A texel of a layer as x, y, z and w: a float format's channels as
    /// they lie, and any other format's colour as 0 to 1. The level, the
    /// layer and the place are held to what the texture has, as `colorAt`
    /// has them, and one it has not got reads all zero. (Since 1.57.)
    pub fn partsAt(texture: *const Texture, layer: u32, lod: u32, x: u32, y: u32) [4]f32 {
        if (!texture.holds(layer, lod, x, y)) return .{ 0, 0, 0, 0 };
        // A depth as x, 0 to 1 over all 16 bits (since 1.58): `colorAt`
        // gives a grey of its top 8, which is all a colour holds.
        if (texture.format == .d16) return .{ @as(f32, @floatFromInt(texture.peekLayer(layer, lod, x, y))) / 65535, 0, 0, 1 };
        if (texture.format.floats()) {
            const at = texture.memory + texture.placeOf(layer, lod, x, y);
            return switch (texture.format) {
                inline .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => |one| floatParts(one, at),
                else => .{ 0, 0, 0, 0 },
            };
        }
        // The whole of each channel, where the format holds more of one
        // than a colour does (since 1.69): a sample reads the top 8 bits,
        // and this reads all 16.
        if (texture.format.channels()) return channelParts(texture.format, texture.memory + texture.placeOf(layer, lod, x, y));
        // The halves a BC6H block holds (since 1.74): the format is for
        // channels past 1, and this is where a function reads them, a
        // colour of 8 bits having nothing to say about what is above it.
        switch (texture.format) {
            inline .bc6hu, .bc6hs => |one| {
                const at = texture.memory + texture.placeOf(layer, lod, x, y);
                const halves = bc6hHalves(one == .bc6hs, at)[(y % block) * block + (x % block)];
                return .{ ofHalf(halves[0]), ofHalf(halves[1]), ofHalf(halves[2]), 1 };
            },
            else => {},
        }
        // The whole numbers as they are, not 0 to 1 (since 1.70): a float
        // carries 24 bits of one exactly, and `wholesAt` all 32.
        if (texture.format.wholes()) {
            const wholes = wholeParts(texture.format, texture.memory + texture.placeOf(layer, lod, x, y));
            var made: [4]f32 = undefined;
            for (&made, wholes) |*part, one| part.* = @floatFromInt(one);
            return made;
        }
        return partsOfColor(texture.texelColor(layer, lod, x, y));
    }

    /// A texel of a layer as 0xAARRGGBB, whatever its format: what a
    /// shader function reads a storage image back with
    /// (`shader.Resources.written`).
    ///
    /// The level, the layer and the place are held to what the texture has
    /// (`holds`): a texel it has not got reads as transparent black,
    /// rather than out of the texture's memory. `peekLayer` is the same
    /// read in the texture's own format and holds to nothing, which is
    /// what sampling and the library's own copies want. (Since 1.55.)
    pub fn colorAt(texture: *const Texture, layer: u32, lod: u32, x: u32, y: u32) u32 {
        if (!texture.holds(layer, lod, x, y)) return 0;
        return texture.texelColor(layer, lod, x, y);
    }

    /// The same without holding to anything: a texel that is there, which
    /// is what sampling reads, every place of it having been held to the
    /// level already.
    fn texelColor(texture: *const Texture, layer: u32, lod: u32, x: u32, y: u32) u32 {
        const texel = texture.peekLayer(layer, lod, x, y);
        return switch (texture.format) {
            .rgba8888, .argb8888 => texel,
            .rgb565 => expanded565(texel),
            // Red alone, as Vulkan reads a one-channel format: the green
            // and the blue 0, the alpha whole.
            .r8 => redOf8(@truncate(texel)),
            // A depth as an opaque grey: its top 8 bits.
            .d16 => greyOf8(@truncate(texel >> 8)),
            // Decoded already: `peekLayer` read it out of its block, out
            // of its floats, or out of its channels.
            .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5, .bc6hu, .bc6hs, .bc7, .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => texel,
            .rg8, .r16, .rg16, .rgba16 => texel,
            .r8u, .rg8u, .rgba8u, .r8i, .rg8i, .rgba8i, .r16u, .rg16u, .rgba16u, .r16i, .rg16i, .rgba16i, .r32u, .rg32u, .rgba32u, .r32i, .rg32i, .rgba32i => texel,
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
            return texture.texelColor(layer, lod, placeIn(sampling.address, @intFromFloat(@floor(x)), across), placeIn(sampling.address, @intFromFloat(@floor(y)), down));
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
        const upper = mixColors(texture.texelColor(layer, lod, x0, y0), texture.texelColor(layer, lod, x1, y0), part_x);
        const lower = mixColors(texture.texelColor(layer, lod, x0, y1), texture.texelColor(layer, lod, x1, y1), part_x);
        return mixColors(upper, lower, y - 0.5 - low_y);
    }

    /// A 3D texture's colour at (u, v, r), each 0 to 1 across it.
    pub fn sampleVolume(texture: *const Texture, sampling: Sampling, lod: u32, u: f32, v: f32, r: f32) u32 {
        const slices = texture.slicesAt(lod);
        const z = sane(r) * @as(f32, @floatFromInt(slices));
        if (sampling.filter == .nearest) return texture.sampleLayer(sampling, placeIn(sampling.address, @intFromFloat(@floor(z)), slices), lod, u, v);
        const low = @floor(z - 0.5);
        const first: i32 = @intFromFloat(low);
        const near = texture.sampleLayer(sampling, placeIn(sampling.address, first, slices), lod, u, v);
        const far = texture.sampleLayer(sampling, placeIn(sampling.address, first + 1, slices), lod, u, v);
        return mixColors(near, far, z - 0.5 - low);
    }

    /// The slices a level of a 3D texture has: the one before halved, never
    /// below one, as Vulkan has a 3D image's depth. A slice is a layer here,
    /// and a level of a slice lies where that layer's own level lies - so a
    /// level past the first leaves the layers past its depth unread.
    /// (Since 1.46.)
    pub fn slicesAt(texture: *const Texture, lod: u32) u32 {
        return @max(texture.layer_count >> @intCast(@min(lod, 31)), 1);
    }

    /// A cube's colour the way (x, y, z) looks. Filtered, what lies past
    /// a face's edge is read from the face next to it, as a GPU has it.
    pub fn sampleCube(texture: *const Texture, sampling: Sampling, lod: u32, x: f32, y: f32, z: f32) u32 {
        return texture.sampleCubeIn(sampling, 0, lod, x, y, z);
    }

    /// The same of one cube of an array: `first` is that cube's first face,
    /// a multiple of six, and the six after it are its faces. A view of
    /// `cube_array` carries as many cubes as its layers divided by six
    /// (`shader.FixedKind.texture_cube_array`). (Since 1.46.)
    pub fn sampleCubeIn(texture: *const Texture, sampling: Sampling, first: u32, lod: u32, x: f32, y: f32, z: f32) u32 {
        const hit = cubeHit(sane(x), sane(y), sane(z));
        var edged = sampling;
        edged.address = .clamp;
        if (sampling.filter == .nearest) return texture.sampleLayer(edged, first + hit.face, lod, hit.u, hit.v);
        const size: i32 = @intCast(texture.width(lod));
        const across = hit.u * @as(f32, @floatFromInt(size)) - 0.5;
        const down = hit.v * @as(f32, @floatFromInt(size)) - 0.5;
        const left: i32 = @intFromFloat(@floor(across));
        const top: i32 = @intFromFloat(@floor(down));
        const part_x = across - @floor(across);
        const upper = mixColors(texture.cubeTexel(first, hit.face, lod, left, top), texture.cubeTexel(first, hit.face, lod, left + 1, top), part_x);
        const lower = mixColors(texture.cubeTexel(first, hit.face, lod, left, top + 1), texture.cubeTexel(first, hit.face, lod, left + 1, top + 1), part_x);
        return mixColors(upper, lower, down - @floor(down));
    }

    /// Which cube of an array `index` falls on, as `layerNear` picks a
    /// layer: its first face, a multiple of six. (Since 1.46.)
    pub fn cubeNear(texture: *const Texture, which: f32) u32 {
        const cubes = texture.layer_count / 6;
        if (cubes == 0) return 0;
        const whole = @floor(sane(which) + 0.5);
        if (whole < 0) return 0;
        return @min(@as(u32, @intFromFloat(whole)), cubes - 1) * 6;
    }

    /// Where texel (x, y) of a face of the cube whose first face is
    /// `first` lies: that face itself, or - where x or y is past its edge
    /// - the next face of that cube in the same direction, at the texel
    /// the direction falls on. (Since 1.60 as a place of its own, which
    /// `cubeTexel` read the colour of since 1.46 and a sample through a
    /// sampler reads as well.)
    fn cubePlace(texture: *const Texture, first: u32, face: u32, lod: u32, x: i32, y: i32) struct { layer: u32, x: u32, y: u32 } {
        const size: i32 = @intCast(texture.width(lod));
        if (x >= 0 and y >= 0 and x < size and y < size) return .{ .layer = first + face, .x = @intCast(x), .y = @intCast(y) };
        const whole: f32 = @floatFromInt(size);
        const towards = cubeDirection(face, (@as(f32, @floatFromInt(x)) + 0.5) / whole * 2 - 1, (@as(f32, @floatFromInt(y)) + 0.5) / whole * 2 - 1);
        const next = cubeHit(towards[0], towards[1], towards[2]);
        return .{
            .layer = first + next.face,
            .x = placeIn(.clamp, @intFromFloat(@floor(next.u * whole)), texture.width(lod)),
            .y = placeIn(.clamp, @intFromFloat(@floor(next.v * whole)), texture.width(lod)),
        };
    }

    /// The colour of that texel.
    fn cubeTexel(texture: *const Texture, first: u32, face: u32, lod: u32, x: i32, y: i32) u32 {
        const at = texture.cubePlace(first, face, lod, x, y);
        return texture.texelColor(at.layer, lod, at.x, at.y);
    }

    /// And its value, as a comparison reads one: a depth at all 16 bits,
    /// or a colour's red. (Since 1.60, for a cube compared through a
    /// sampler - a shadow map of all six ways.)
    fn cubeValue(texture: *const Texture, first: u32, face: u32, lod: u32, x: i32, y: i32) f32 {
        const at = texture.cubePlace(first, face, lod, x, y);
        return texture.valueOf(at.layer, lod, at.x, at.y);
    }

    /// What a comparison reads of a texel that is there: a depth as 0 to 1
    /// over all 16 bits it keeps, and anything else as its red.
    fn valueOf(texture: *const Texture, layer: u32, lod: u32, x: u32, y: u32) f32 {
        if (texture.format.depth()) {
            const kept = texture.peekLayer(layer, lod, x, y);
            return @as(f32, @floatFromInt(kept & 0xFFFF)) / 65535;
        }
        return @as(f32, @floatFromInt(texture.texelColor(layer, lod, x, y) >> 16 & 0xFF)) / 255;
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
                    .rgba8888, .argb8888 => std.mem.readInt(u32, row[x * 4 ..][0..4], .little),
                    .rgb565, .d16 => std.mem.readInt(u16, row[x * 2 ..][0..2], .little),
                    .r8 => row[x],
                    .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5, .bc6hu, .bc6hs, .bc7, .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => unreachable,
                    .rg8, .r16, .rg16, .rgba16 => unreachable,
                    .r8u, .rg8u, .rgba8u, .r8i, .rg8i, .rgba8i, .r16u, .rg16u, .rgba16u, .r16i, .rg16i, .rgba16i, .r32u, .rg32u, .rgba32u, .r32i, .rg32i, .rgba32i => unreachable,
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
    /// The bytes from one row of this level to the next, where the texture
    /// is kept in rows and the level has a pitch of its own: the levels of
    /// a depth attachment, each in rows as wide as that level is
    /// (`linearLevel`, since 1.63). 0 is the texture's own `pitch`, which
    /// is what one level of rows takes, and means nothing for the blocks
    /// every other texture is kept in.
    pitch: u32 = 0,
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
        // One float, read as (red, 0, 0, 1) the way `r8` is (since 1.57).
        .r32f => 0xFF00_0000 | @as(u32, byteOfFloat(@bitCast(readLittle(u32, at)))) << 16,
        else => missing_texel,
    };
}

/// The four channels a float texel at `at` holds, as they lie: what the
/// format has not got reads as 0, and an alpha it has not got as 1. What
/// `Texture.partsAt` gives a shader function. (Since 1.57.)
pub fn floatParts(comptime format: Format, at: [*]const u8) [4]f32 {
    @setRuntimeSafety(false);
    return switch (format) {
        .rgba16f => made: {
            var parts: [4]f32 = undefined;
            inline for (&parts, 0..) |*part, k| part.* = ofHalf(readLittle(u16, at + k * 2));
            break :made parts;
        },
        .rgba32f => made: {
            var parts: [4]f32 = undefined;
            inline for (&parts, 0..) |*part, k| part.* = @bitCast(readLittle(u32, at + k * 4));
            break :made parts;
        },
        .rg11b10f => made: {
            const word = readLittle(u32, at);
            break :made .{
                ofParts(word >> 6 & 0x1F, word & 0x3F, 6, 15),
                ofParts(word >> 17 & 0x1F, word >> 11 & 0x3F, 6, 15),
                ofParts(word >> 27 & 0x1F, word >> 22 & 0x1F, 5, 15),
                1,
            };
        },
        .rgb9e5 => made: {
            const word = readLittle(u32, at);
            const scale = std.math.ldexp(@as(f32, 1), @as(i32, @intCast(word >> 27)) - 15 - 9);
            break :made .{
                @as(f32, @floatFromInt(word & 0x1FF)) * scale,
                @as(f32, @floatFromInt(word >> 9 & 0x1FF)) * scale,
                @as(f32, @floatFromInt(word >> 18 & 0x1FF)) * scale,
                1,
            };
        },
        .r32f => .{ @bitCast(readLittle(u32, at)), 0, 0, 1 },
        else => .{ 0, 0, 0, 0 },
    };
}

/// The channels of a texel of a `Format.channels` format at `at` as x, y,
/// z and w, 0 to 1: what the format has not got reads as 0, and an alpha
/// it has not got as 1. What `Texture.partsAt` gives a shader function of
/// such a texture, the whole of every channel. (Since 1.69.)
pub fn channelParts(format: Format, at: [*]const u8) [4]f32 {
    @setRuntimeSafety(false);
    const one = format.channelsOf() orelse return .{ 0, 0, 0, 0 };
    const most: f32 = if (one.bits == 8) 255 else 65535;
    var made = [4]f32{ 0, 0, 0, 1 };
    for (0..one.parts) |k| made[k] = @as(f32, @floatFromInt(channelAt(at, one.bits, k))) / most;
    return made;
}

/// The same written back, each channel held to 0 to 1 and rounded to the
/// width it has. What `Texture.setParts` writes such a texel with.
/// (Since 1.69.)
pub fn putChannelParts(format: Format, at: [*]u8, parts: [4]f32) void {
    @setRuntimeSafety(false);
    const one = format.channelsOf() orelse return;
    const most: f32 = if (one.bits == 8) 255 else 65535;
    for (0..one.parts) |k| {
        const value: u32 = @intFromFloat(@round(heldAt(parts[k], 1) * most));
        if (one.bits == 8) at[k] = @truncate(value) else writeLittle(u16, at + k * 2, @truncate(value));
    }
}

/// The colour a sample makes of such a texel, 0xAARRGGBB: the top 8 bits
/// of each channel, which is all a tile's colour holds; what the format
/// has not got is 0, and an alpha it has not got is whole, as Vulkan
/// reads a format of fewer channels. (Since 1.69.)
pub fn channelColor(format: Format, at: [*]const u8) u32 {
    @setRuntimeSafety(false);
    const one = format.channelsOf() orelse return 0;
    var channels = [4]u32{ 0, 0, 0, 255 };
    for (0..one.parts) |k| {
        const value = channelAt(at, one.bits, k);
        channels[k] = if (one.bits == 8) value else value >> 8;
    }
    return channels[3] << 24 | channels[0] << 16 | channels[1] << 8 | channels[2];
}

/// Channel `k` of a texel at `at`, as it lies. (Since 1.69.)
inline fn channelAt(at: [*]const u8, bits: u32, k: usize) u32 {
    return if (bits == 8) at[k] else readLittle(u16, at + k * 2);
}

/// The whole numbers a texel of a `Format.wholes` format at `at` keeps,
/// as they lie: what the format has not got reads as 0, and an alpha it
/// has not got as 1, as `shader.Texels.intAt` has them. What
/// `Texture.wholesAt` gives a shader function of such a texture.
/// (Since 1.70.)
pub fn wholeParts(format: Format, at: [*]const u8) [4]i64 {
    @setRuntimeSafety(false);
    const one = format.wholesOf() orelse return .{ 0, 0, 0, 0 };
    var made = [4]i64{ 0, 0, 0, 1 };
    for (0..one.parts) |k| made[k] = wholeAt(at, one.bits, one.signed, k);
    return made;
}

/// The same written back, each held to what its channel holds - 255,
/// 65535 or 4294967295 unsigned, -128 to 127 and so on signed - and
/// written at the width it has. What `Texture.setWholes` writes such a
/// texel with. (Since 1.70.)
pub fn putWholeParts(format: Format, at: [*]u8, parts: [4]i64) void {
    @setRuntimeSafety(false);
    const one = format.wholesOf() orelse return;
    for (0..one.parts) |k| {
        const bits: u64 = @bitCast(heldWhole(parts[k], one.bits, one.signed));
        switch (one.bits) {
            8 => at[k] = @truncate(bits),
            16 => writeLittle(u16, at + k * 2, @truncate(bits)),
            else => writeLittle(u32, at + k * 4, @truncate(bits)),
        }
    }
}

/// The colour a sample makes of such a texel, 0xAARRGGBB: each number
/// held to 0 to 1 and over 255, which is how a texel buffer of the format
/// reads one (`shader.Texels.colorAt`) - so 0 is nothing and any number
/// above it is the channel at the full, a whole number being no colour.
/// What the format has not got is 0, and an alpha it has not got whole.
/// (Since 1.70.)
pub fn wholeColor(format: Format, at: [*]const u8) u32 {
    @setRuntimeSafety(false);
    const one = format.wholesOf() orelse return 0;
    var channels = [4]u32{ 0, 0, 0, 255 };
    for (0..one.parts) |k| channels[k] = if (wholeAt(at, one.bits, one.signed, k) > 0) 255 else 0;
    return channels[3] << 24 | channels[0] << 16 | channels[1] << 8 | channels[2];
}

/// Whole number `k` of a texel at `at`, as it lies. (Since 1.70.)
inline fn wholeAt(at: [*]const u8, bits: u32, signed: bool, k: usize) i64 {
    const from = at + k * (bits / 8);
    return switch (bits) {
        8 => if (signed) @as(i8, @bitCast(from[0])) else @as(i64, from[0]),
        16 => if (signed) @as(i16, @bitCast(readLittle(u16, from))) else @as(i64, readLittle(u16, from)),
        else => if (signed) @as(i32, @bitCast(readLittle(u32, from))) else @as(i64, readLittle(u32, from)),
    };
}

/// A whole number held to what a channel of `bits` holds: 0 to 255,
/// 65535 or 4294967295 where it is unsigned, and -128 to 127, -32768 to
/// 32767 or the 32-bit pair where it is signed. (Since 1.70.)
inline fn heldWhole(value: i64, bits: u32, signed: bool) i64 {
    if (signed) {
        const most = (@as(i64, 1) << @intCast(bits - 1)) - 1;
        return @max(@min(value, most), -most - 1);
    }
    return @max(@min(value, (@as(i64, 1) << @intCast(bits)) - 1), 0);
}

/// Four channels written as a float texel at `at`, `floatParts` undone:
/// what the format has not got is dropped, and what it cannot hold is cut
/// to the largest it can. What `Texture.setParts` writes with.
/// (Since 1.57.)
pub fn putFloatTexel(comptime format: Format, at: [*]u8, parts: [4]f32) void {
    @setRuntimeSafety(false);
    switch (format) {
        .rgba16f => inline for (0..4) |k| writeLittle(u16, at + k * 2, halfOf(parts[k])),
        .rgba32f => inline for (0..4) |k| writeLittle(u32, at + k * 4, @bitCast(parts[k])),
        .rg11b10f => writeLittle(u32, at, partsOf(parts[0], 6, 15) | partsOf(parts[1], 6, 15) << 11 | partsOf(parts[2], 5, 15) << 22),
        .rgb9e5 => writeLittle(u32, at, sharedExponent(parts[0], parts[1], parts[2])),
        .r32f => writeLittle(u32, at, @bitCast(parts[0])),
        else => {},
    }
}

/// Red, green and blue as E5B9G9R9: one exponent of 5 bits for the three,
/// biased by 15, over mantissas of 9 bits that are whole numbers. The
/// exponent is the one the largest of them needs, and the three are then
/// written against it. (Since 1.57.)
fn sharedExponent(red: f32, green: f32, blue: f32) u32 {
    const most = @as(f32, 0x1FF) / 512 * 32768; // the largest the format holds
    const r = heldAt(red, most);
    const g = heldAt(green, most);
    const b = heldAt(blue, most);
    const largest = @max(r, @max(g, b));
    if (largest <= 0) return 0;
    // The exponent that puts the largest mantissa inside its 9 bits.
    var exponent: i32 = @max(std.math.frexp(largest).exponent, -15 + 1);
    var scale = std.math.ldexp(@as(f32, 1), 9 - exponent);
    if (@as(u32, @intFromFloat(largest * scale + 0.5)) > 0x1FF) {
        exponent += 1;
        scale = std.math.ldexp(@as(f32, 1), 9 - exponent);
    }
    const biased: u32 = @intCast(@min(exponent + 15, 31));
    const nine = struct {
        fn nine(value: f32, by: f32) u32 {
            return @min(@as(u32, @intFromFloat(value * by + 0.5)), 0x1FF);
        }
    }.nine;
    return biased << 27 | nine(b, scale) << 18 | nine(g, scale) << 9 | nine(r, scale);
}

/// 0 to `most`, a NaN as 0.
inline fn heldAt(value: f32, most: f32) f32 {
    return if (value > 0) @min(value, most) else 0;
}

/// A word of `T` written at `at`, little-endian and on no alignment.
inline fn writeLittle(comptime T: type, at: [*]u8, value: T) void {
    std.mem.writeInt(T, at[0..@sizeOf(T)], value, .little);
}

/// 0xAARRGGBB as the four whole numbers its channels are, 0 to 255, red
/// first. (Since 1.70.)
pub inline fn wholesOfColor(color: u32) [4]i64 {
    var parts: [4]i64 = undefined;
    inline for (&parts, [4]u5{ 16, 8, 0, 24 }) |*part, shift| {
        part.* = color >> shift & 0xFF;
    }
    return parts;
}

/// A float as the whole number nearest it, a NaN as 0 and anything past
/// what 64 bits hold as the end of it. (Since 1.70.)
inline fn wholeOfFloat(value: f32) i64 {
    if (!(value > -9.2e18)) return if (value < 0) std.math.minInt(i64) else 0;
    if (value > 9.2e18) return std.math.maxInt(i64);
    return @intFromFloat(@round(value));
}

/// 0xAARRGGBB as x, y, z and w, each channel 0 to 1. (Since 1.57.)
pub inline fn partsOfColor(color: u32) [4]f32 {
    var parts: [4]f32 = undefined;
    inline for (&parts, [4]u5{ 16, 8, 0, 24 }) |*part, shift| {
        part.* = @as(f32, @floatFromInt(color >> shift & 0xFF)) / 255;
    }
    return parts;
}

/// The same undone: x, y, z and w as 0xAARRGGBB, each held inside 0 to 1
/// and rounded to 8 bits. (Since 1.57.)
pub inline fn colorOfParts(parts: [4]f32) u32 {
    var made: u32 = 0;
    inline for (parts, [4]u5{ 16, 8, 0, 24 }) |part, shift| made |= @as(u32, byteOfFloat(part)) << shift;
    return made;
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

/// A half float made of a float, `ofHalf` undone, and by hand for the same
/// reason: the nearest half, an infinity and anything above the largest
/// half as that largest, and a NaN as one. (Since 1.57.)
pub inline fn halfOf(value: f32) u16 {
    const bits: u32 = @bitCast(value);
    const sign: u16 = @intCast(bits >> 31);
    const exponent: i32 = @intCast(bits >> 23 & 0xFF);
    const mantissa = bits & 0x7F_FFFF;
    // A NaN stays one, and an infinity comes back as the largest half, as
    // `ofHalf` reads the largest exponent.
    if (exponent == 0xFF) return sign << 15 | @as(u16, if (mantissa != 0) 0x7E00 else 0x7BFF);
    // The half's exponent is biased by 15 where the float's is by 127.
    const moved = exponent - 127 + 15;
    if (moved <= 0) {
        // Below the smallest normal half: one of the subnormals, whose
        // value is its mantissa over 2^24, or nothing at all.
        if (moved < -10) return sign << 15;
        const whole = mantissa | 0x80_0000;
        const shift: u5 = @intCast(14 - moved);
        return sign << 15 | @as(u16, @intCast(whole >> shift));
    }
    // The mantissa rounded to its 10 bits, a carry out of it moving into
    // the exponent of its own accord.
    const together = (@as(u32, @intCast(moved)) << 23) | mantissa;
    const half = (together + 0x1000) >> 13;
    if (half >= 0x7C00) return sign << 15 | 0x7BFF;
    return sign << 15 | @as(u16, @intCast(half));
}

/// An unsigned float of `bits` of mantissa biased by `biased_by`, made of
/// a float: `ofParts` undone, its exponent and its mantissa packed low.
/// Anything below the smallest it holds is 0 and anything above the
/// largest is that largest. (Since 1.57.)
inline fn partsOf(value: f32, comptime bits: u5, comptime biased_by: i32) u32 {
    const most_exponent: u32 = 31;
    const most_mantissa = (@as(u32, 1) << bits) - 1;
    if (!(value > 0)) return 0; // a NaN as well
    const whole = std.math.frexp(value);
    // frexp gives 0.5 to 1 times two to the exponent; a float of this
    // shape is 1 to 2 times two to its own, so the exponent is one less.
    const moved = whole.exponent - 1 + biased_by;
    if (moved >= most_exponent) return most_exponent << bits | most_mantissa;
    const scale: f32 = @floatFromInt(@as(u32, 1) << bits);
    if (moved <= 0) {
        // The subnormals: the mantissa alone, over two to one less than
        // the bias.
        const lowest = std.math.ldexp(value, biased_by - 1) * scale;
        return @min(@as(u32, @intFromFloat(lowest + 0.5)), most_mantissa);
    }
    const mantissa: u32 = @intFromFloat((whole.significand * 2 - 1) * scale + 0.5);
    if (mantissa > most_mantissa) {
        // Rounded up out of the mantissa, which is the next exponent.
        if (moved + 1 >= most_exponent) return most_exponent << bits | most_mantissa;
        return @as(u32, @intCast(moved + 1)) << bits;
    }
    return @as(u32, @intCast(moved)) << bits | mantissa;
}

// --- the compressed blocks --------------------------------------------------

/// The sixteen texels of one compressed block at `at`, in rows, each
/// 0xAARRGGBB. BC1 and BC4 read 8 bytes and the rest 16; nothing is read
/// past them.
///
/// The block holds two endpoint colours of 565 and two bits for each texel,
/// which pick one of four: the endpoints and two between them. Where the
/// format punches through - BC1 - and the first endpoint is not above the
/// second, there are three colours and the fourth is clear. BC2 holds four
/// bits of alpha for each texel before the colours, and BC3 two endpoint
/// alphas with three bits for each texel between them. (Since 1.44.)
///
/// BC4 and BC5 are that alpha block over one channel and over two, and
/// hold no endpoint colour: they read as (red, 0, 0, 1) and
/// (red, green, 0, 1). (Since 1.72.)
///
/// BC7 is another block altogether, read by `bc7Block`: subsets, modes
/// and up to four bits an index, in the same 16 bytes. (Since 1.73.)
///
/// BC6H is another again, read by `bc6hBlock`: three channels of half
/// float, held between 0 and 1 and rounded to 8 bits here the way a float
/// texel is, with the alpha whole. (Since 1.74.)
pub fn blockOf(comptime format: Format, at: [*]const u8) [16]u32 {
    @setRuntimeSafety(false);
    // BC7 shares nothing with the others but its size (since 1.73), and
    // BC6H holds floats rather than a colour at all (since 1.74).
    if (format == .bc7) return bc7Block(at);
    if (format == .bc6hu or format == .bc6hs) return bc6hBlock(format == .bc6hs, at);
    // BC4 and BC5 hold no endpoint colour at all: one channel and two,
    // each the block BC3 keeps its alpha in, read as (red, 0, 0, 1) and
    // (red, green, 0, 1) (since 1.72).
    if (format == .bc4 or format == .bc5) {
        var channels: [16]u32 = undefined;
        const reds = blockAlphas(at);
        for (&channels, reds) |*texel, red| texel.* = 0xFF00_0000 | @as(u32, red) << 16;
        if (format == .bc5) {
            const greens = blockAlphas(at + 8);
            for (&channels, greens) |*texel, green| texel.* |= @as(u32, green) << 8;
        }
        return channels;
    }
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

// --- BC7 ---------------------------------------------------------------------

/// What one of BC7's eight modes holds: the subsets its block is cut into,
/// and the bits each field takes - the specification's Table.M. The fields
/// lie in the block in this order, from the bit after the mode up: the
/// partition, the rotation, the index selection, the colours, the alphas,
/// the p-bits, the indices and the second indices. (Since 1.73.)
const Bc7Mode = struct {
    subsets: u5,
    partition: u5,
    rotation: u5,
    selection: u5,
    color: u5,
    alpha: u5,
    /// Whether each endpoint has a p-bit of its own, or the two endpoints
    /// of a subset share one.
    endpoint_pbits: u5,
    shared_pbits: u5,
    indices: u5,
    indices2: u5,
};

const bc7_modes = [8]Bc7Mode{
    .{ .subsets = 3, .partition = 4, .rotation = 0, .selection = 0, .color = 4, .alpha = 0, .endpoint_pbits = 1, .shared_pbits = 0, .indices = 3, .indices2 = 0 },
    .{ .subsets = 2, .partition = 6, .rotation = 0, .selection = 0, .color = 6, .alpha = 0, .endpoint_pbits = 0, .shared_pbits = 1, .indices = 3, .indices2 = 0 },
    .{ .subsets = 3, .partition = 6, .rotation = 0, .selection = 0, .color = 5, .alpha = 0, .endpoint_pbits = 0, .shared_pbits = 0, .indices = 2, .indices2 = 0 },
    .{ .subsets = 2, .partition = 6, .rotation = 0, .selection = 0, .color = 7, .alpha = 0, .endpoint_pbits = 1, .shared_pbits = 0, .indices = 2, .indices2 = 0 },
    .{ .subsets = 1, .partition = 0, .rotation = 2, .selection = 1, .color = 5, .alpha = 6, .endpoint_pbits = 0, .shared_pbits = 0, .indices = 2, .indices2 = 3 },
    .{ .subsets = 1, .partition = 0, .rotation = 2, .selection = 0, .color = 7, .alpha = 8, .endpoint_pbits = 0, .shared_pbits = 0, .indices = 2, .indices2 = 2 },
    .{ .subsets = 1, .partition = 0, .rotation = 0, .selection = 0, .color = 7, .alpha = 7, .endpoint_pbits = 1, .shared_pbits = 0, .indices = 4, .indices2 = 0 },
    .{ .subsets = 2, .partition = 6, .rotation = 0, .selection = 0, .color = 5, .alpha = 5, .endpoint_pbits = 1, .shared_pbits = 0, .indices = 2, .indices2 = 0 },
};

/// How far between the two endpoints an index of 2, 3 or 4 bits stands,
/// out of 64: the specification's interpolation factors. (Since 1.73.)
const bc7_weights2 = [4]u32{ 0, 21, 43, 64 };
const bc7_weights3 = [8]u32{ 0, 9, 18, 27, 37, 46, 55, 64 };
const bc7_weights4 = [16]u32{ 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };

inline fn bc7Weight(bits: u32, index: u32) u32 {
    return switch (bits) {
        2 => bc7_weights2[index & 3],
        3 => bc7_weights3[index & 7],
        else => bc7_weights4[index & 15],
    };
}

/// Between two endpoint channels, `weight` of 64 of the way: the
/// specification's interpolation, which rounds to the nearest.
inline fn bc7Mix(a: u32, b: u32, weight: u32) u32 {
    return (a * (64 - weight) + b * weight + 32) >> 6;
}

/// A block's bits, the lowest first: how BC7 keeps its fields, LSB to MSB
/// in byte order. (Since 1.73.)
const Bc7Bits = struct {
    at: [*]const u8,
    next: u32,

    fn read(bits: *Bc7Bits, count: u32) u32 {
        @setRuntimeSafety(false);
        var made: u32 = 0;
        for (0..count) |k| {
            const bit = bits.next + @as(u32, @intCast(k));
            made |= @as(u32, bits.at[bit >> 3] >> @intCast(bit & 7) & 1) << @intCast(k);
        }
        bits.next += count;
        return made;
    }
};

/// The sixteen texels of a BC7 block at `at`, in rows, each 0xAARRGGBB:
/// 16 bytes read, and nothing past them.
///
/// The block is cut into one, two or three subsets by a pattern the
/// partition number names (`bc7_two`, `bc7_three`); each subset has two
/// endpoints, and each texel an index saying how far between them it
/// stands. A mode says how many bits each of those takes
/// (`bc7_modes`): the endpoints may carry an alpha of their own, a p-bit
/// below the channel's bits, and a second set of indices for the alpha
/// which a rotation then swaps into one of the three colour channels. A
/// low byte of 0 is reserved by the format and reads as transparent
/// black. (Since 1.73.)
fn bc7Block(at: [*]const u8) [16]u32 {
    @setRuntimeSafety(false);
    var made: [16]u32 = @splat(0);
    const low = at[0];
    if (low == 0) return made;
    // The mode is the zeros of the low byte before its first 1.
    const number = @ctz(low);
    const mode = bc7_modes[number];
    var bits = Bc7Bits{ .at = at, .next = @as(u32, number) + 1 };
    const partition = bits.read(mode.partition);
    const rotation = bits.read(mode.rotation);
    const selection = bits.read(mode.selection);

    // Two endpoints for each subset, read a channel at a time: red for
    // both ends of every subset, then green, then blue, then the alphas.
    var ends: [3][2][4]u32 = @splat(@splat(@splat(0)));
    for (0..3) |channel| {
        for (0..mode.subsets) |subset| {
            for (0..2) |end| ends[subset][end][channel] = bits.read(mode.color);
        }
    }
    if (mode.alpha != 0) {
        for (0..mode.subsets) |subset| {
            for (0..2) |end| ends[subset][end][3] = bits.read(mode.alpha);
        }
    }

    // A p-bit stands below the channel's own bits: one for each endpoint,
    // or one shared by both endpoints of a subset - the lower bit the
    // first subset's, as the specification has it.
    var pbits: [3][2]u32 = @splat(@splat(0));
    const has_pbit = mode.shared_pbits != 0 or mode.endpoint_pbits != 0;
    if (mode.shared_pbits != 0) {
        for (0..mode.subsets) |subset| {
            const bit = bits.read(1);
            pbits[subset][0] = bit;
            pbits[subset][1] = bit;
        }
    } else if (mode.endpoint_pbits != 0) {
        for (0..mode.subsets) |subset| {
            for (0..2) |end| pbits[subset][end] = bits.read(1);
        }
    }

    // Each channel to a whole byte: the p-bit under it, then the top bits
    // repeated into what is left. A format with no alpha of its own is
    // opaque.
    const extra: u5 = if (has_pbit) 1 else 0;
    const color_total: u5 = mode.color + extra;
    const alpha_total: u5 = if (mode.alpha == 0) 8 else mode.alpha + extra;
    for (0..mode.subsets) |subset| for (0..2) |end| {
        inline for (0..4) |channel| {
            if (channel == 3 and mode.alpha == 0) {
                ends[subset][end][3] = 255;
            } else {
                const total = if (channel == 3) alpha_total else color_total;
                var value = ends[subset][end][channel];
                if (has_pbit) value = value << 1 | pbits[subset][end];
                value <<= @intCast(8 - total);
                ends[subset][end][channel] = value | value >> total;
            }
        }
    };

    // Which subset each texel is in, and the one index of each subset
    // that has a bit fewer: its endpoints are ordered so that index's top
    // bit is 0.
    var subsets: [16]u32 = @splat(0);
    var anchors: [3]u32 = .{ 0, 0, 0 };
    if (mode.subsets == 2) {
        const picks = bc7_two[partition];
        for (&subsets, &picks) |*one, pick| one.* = pick;
        anchors[1] = bc7_anchor_two[partition];
    } else if (mode.subsets == 3) {
        const picks = bc7_three[partition];
        for (&subsets, &picks) |*one, pick| one.* = pick;
        anchors[1] = bc7_anchor_three_second[partition];
        anchors[2] = bc7_anchor_three_third[partition];
    }

    var primary: [16]u32 = @splat(0);
    for (&primary, 0..) |*index, k| {
        const anchored = k == anchors[subsets[k]];
        index.* = bits.read(@as(u32, mode.indices) - @as(u32, if (anchored) 1 else 0));
    }
    var secondary: [16]u32 = @splat(0);
    if (mode.indices2 != 0) {
        // A mode with a second set of indices has one subset, so texel 0
        // is the only anchor.
        for (&secondary, 0..) |*index, k| index.* = bits.read(@as(u32, mode.indices2) - @as(u32, if (k == 0) 1 else 0));
    }

    // The colour takes the second index where the mode has an index
    // selection bit and it is set; the alpha takes the second set
    // otherwise, where there is one.
    const color_second = mode.selection != 0 and selection == 1;
    const alpha_second = mode.indices2 != 0 and !color_second;
    const color_bits: u32 = if (color_second) mode.indices2 else mode.indices;
    const alpha_bits: u32 = if (alpha_second) mode.indices2 else mode.indices;
    for (&made, 0..) |*texel, k| {
        const subset = subsets[k];
        const color_index = if (color_second) secondary[k] else primary[k];
        const alpha_index = if (alpha_second) secondary[k] else primary[k];
        const color_weight = bc7Weight(color_bits, color_index);
        const alpha_weight = bc7Weight(alpha_bits, alpha_index);
        var channels: [4]u32 = undefined;
        inline for (0..3) |channel| {
            channels[channel] = bc7Mix(ends[subset][0][channel], ends[subset][1][channel], color_weight);
        }
        channels[3] = bc7Mix(ends[subset][0][3], ends[subset][1][3], alpha_weight);
        // The rotation swaps the alpha with red, green or blue.
        if (rotation != 0) {
            const with = rotation - 1;
            const kept = channels[3];
            channels[3] = channels[with];
            channels[with] = kept;
        }
        texel.* = channels[3] << 24 | channels[0] << 16 | channels[1] << 8 | channels[2];
    }
    return made;
}

/// Which subset each of a block's sixteen texels is in, for a block cut
/// into two and into three: the specification's Table.P2 and Table.P3,
/// the partition number picking the row and the texels running across
/// then down. (Since 1.73.)
const bc7_two = [64][16]u8{
    .{ 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1 },
    .{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    .{ 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1 },
    .{ 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 1 },
    .{ 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 1 },
    .{ 0, 0, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1 },
    .{ 0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1 },
    .{ 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 1 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1 },
    .{ 0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1 },
    .{ 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1 },
    .{ 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 1 },
    .{ 0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0 },
    .{ 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0 },
    .{ 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0 },
    .{ 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 1 },
    .{ 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0 },
    .{ 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0 },
    .{ 0, 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0, 0 },
    .{ 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 0 },
    .{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 },
    .{ 0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 0 },
    .{ 0, 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0 },
    .{ 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 },
    .{ 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1 },
    .{ 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0 },
    .{ 0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0 },
    .{ 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0 },
    .{ 0, 1, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0 },
    .{ 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1 },
    .{ 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 1 },
    .{ 0, 1, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 1, 0 },
    .{ 0, 0, 0, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 0, 0, 0 },
    .{ 0, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 0, 0 },
    .{ 0, 0, 1, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 0, 0 },
    .{ 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0 },
    .{ 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1 },
    .{ 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1 },
    .{ 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0 },
    .{ 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0 },
    .{ 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0 },
    .{ 0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1 },
    .{ 0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1 },
    .{ 0, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0 },
    .{ 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0 },
    .{ 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 1 },
    .{ 0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1 },
    .{ 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1 },
    .{ 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1 },
    .{ 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1 },
    .{ 0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 },
    .{ 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0 },
    .{ 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1 },
};
const bc7_three = [64][16]u8{
    .{ 0, 0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 1, 2, 2, 2, 2 },
    .{ 0, 0, 0, 1, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 2, 1 },
    .{ 0, 0, 0, 0, 2, 0, 0, 1, 2, 2, 1, 1, 2, 2, 1, 1 },
    .{ 0, 2, 2, 2, 0, 0, 2, 2, 0, 0, 1, 1, 0, 1, 1, 1 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2 },
    .{ 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 2, 2, 0, 0, 2, 2 },
    .{ 0, 0, 2, 2, 0, 0, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2 },
    .{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2 },
    .{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2 },
    .{ 0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2 },
    .{ 0, 1, 1, 2, 0, 1, 1, 2, 0, 1, 1, 2, 0, 1, 1, 2 },
    .{ 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 2 },
    .{ 0, 0, 1, 1, 0, 1, 1, 2, 1, 1, 2, 2, 1, 2, 2, 2 },
    .{ 0, 0, 1, 1, 2, 0, 0, 1, 2, 2, 0, 0, 2, 2, 2, 0 },
    .{ 0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 2, 1, 1, 2, 2 },
    .{ 0, 1, 1, 1, 0, 0, 1, 1, 2, 0, 0, 1, 2, 2, 0, 0 },
    .{ 0, 0, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2, 2 },
    .{ 0, 0, 2, 2, 0, 0, 2, 2, 0, 0, 2, 2, 1, 1, 1, 1 },
    .{ 0, 1, 1, 1, 0, 1, 1, 1, 0, 2, 2, 2, 0, 2, 2, 2 },
    .{ 0, 0, 0, 1, 0, 0, 0, 1, 2, 2, 2, 1, 2, 2, 2, 1 },
    .{ 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 2, 2, 0, 1, 2, 2 },
    .{ 0, 0, 0, 0, 1, 1, 0, 0, 2, 2, 1, 0, 2, 2, 1, 0 },
    .{ 0, 1, 2, 2, 0, 1, 2, 2, 0, 0, 1, 1, 0, 0, 0, 0 },
    .{ 0, 0, 1, 2, 0, 0, 1, 2, 1, 1, 2, 2, 2, 2, 2, 2 },
    .{ 0, 1, 1, 0, 1, 2, 2, 1, 1, 2, 2, 1, 0, 1, 1, 0 },
    .{ 0, 0, 0, 0, 0, 1, 1, 0, 1, 2, 2, 1, 1, 2, 2, 1 },
    .{ 0, 0, 2, 2, 1, 1, 0, 2, 1, 1, 0, 2, 0, 0, 2, 2 },
    .{ 0, 1, 1, 0, 0, 1, 1, 0, 2, 0, 0, 2, 2, 2, 2, 2 },
    .{ 0, 0, 1, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 0, 1, 1 },
    .{ 0, 0, 0, 0, 2, 0, 0, 0, 2, 2, 1, 1, 2, 2, 2, 1 },
    .{ 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 2, 2, 2 },
    .{ 0, 2, 2, 2, 0, 0, 2, 2, 0, 0, 1, 2, 0, 0, 1, 1 },
    .{ 0, 0, 1, 1, 0, 0, 1, 2, 0, 0, 2, 2, 0, 2, 2, 2 },
    .{ 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0 },
    .{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 0, 0, 0, 0 },
    .{ 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0 },
    .{ 0, 1, 2, 0, 2, 0, 1, 2, 1, 2, 0, 1, 0, 1, 2, 0 },
    .{ 0, 0, 1, 1, 2, 2, 0, 0, 1, 1, 2, 2, 0, 0, 1, 1 },
    .{ 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 0, 0, 0, 0, 1, 1 },
    .{ 0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 2, 1, 2, 1, 2, 1 },
    .{ 0, 0, 2, 2, 1, 1, 2, 2, 0, 0, 2, 2, 1, 1, 2, 2 },
    .{ 0, 0, 2, 2, 0, 0, 1, 1, 0, 0, 2, 2, 0, 0, 1, 1 },
    .{ 0, 2, 2, 0, 1, 2, 2, 1, 0, 2, 2, 0, 1, 2, 2, 1 },
    .{ 0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 0, 1, 0, 1 },
    .{ 0, 0, 0, 0, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1 },
    .{ 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 2, 2 },
    .{ 0, 2, 2, 2, 0, 1, 1, 1, 0, 2, 2, 2, 0, 1, 1, 1 },
    .{ 0, 0, 0, 2, 1, 1, 1, 2, 0, 0, 0, 2, 1, 1, 1, 2 },
    .{ 0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2 },
    .{ 0, 2, 2, 2, 0, 1, 1, 1, 0, 1, 1, 1, 0, 2, 2, 2 },
    .{ 0, 0, 0, 2, 1, 1, 1, 2, 1, 1, 1, 2, 0, 0, 0, 2 },
    .{ 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 2, 2 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 1, 2 },
    .{ 0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 2, 2, 2, 2, 2, 2 },
    .{ 0, 0, 2, 2, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 2, 2 },
    .{ 0, 0, 2, 2, 1, 1, 2, 2, 1, 1, 2, 2, 0, 0, 2, 2 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2 },
    .{ 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1 },
    .{ 0, 2, 2, 2, 1, 2, 2, 2, 0, 2, 2, 2, 1, 2, 2, 2 },
    .{ 0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 },
    .{ 0, 1, 1, 1, 2, 0, 1, 1, 2, 2, 0, 1, 2, 2, 2, 0 },
};
/// Which texel each subset is anchored at - the one index with a bit
/// fewer - for the second subset of a two-subset block, and for the
/// second and third of a three-subset one: the specification's Table.A2,
/// Table.A3a and Table.A3b. The first subset is always anchored at texel
/// 0. (Since 1.73.)
const bc7_anchor_two = [64]u8{
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 2,  8,  2,  2,  8,  8,  15, 2,  8,  2,  2,  8,  8,  2,  2,
    15, 15, 6,  8,  2,  8,  15, 15, 2,  8,  2,  2,  2,  15, 15, 6,
    6,  2,  6,  8,  15, 15, 2,  2,  15, 15, 15, 15, 15, 2,  2,  15,
};
const bc7_anchor_three_second = [64]u8{
    3, 3,  15, 15, 8, 3,  15, 15, 8,  8,  6,  6,  6,  5,  3,  3,
    3, 3,  8,  15, 3, 3,  6,  10, 5,  8,  8,  6,  8,  5,  15, 15,
    8, 15, 3,  5,  6, 10, 8,  15, 15, 3,  15, 5,  15, 15, 15, 15,
    3, 15, 5,  5,  5, 8,  5,  10, 5,  10, 8,  13, 15, 12, 3,  3,
};
const bc7_anchor_three_third = [64]u8{
    15, 8, 8,  3,  15, 15, 3,  8,  15, 15, 15, 15, 15, 15, 15, 8,
    15, 8, 15, 3,  15, 8,  15, 8,  3,  15, 6,  10, 15, 15, 10, 8,
    15, 3, 15, 10, 10, 8,  9,  10, 6,  15, 8,  15, 3,  6,  6,  8,
    15, 3, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 3,  15, 15, 8,
};

// --- BC6H --------------------------------------------------------------------

/// One field of a BC6H block: which of the twelve endpoint components it
/// belongs to, and which of that component's bits it holds. The
/// specification's Table.F writes a field `v[a:b]`, and the bits run from
/// `from` towards `to` - the reverse where `to` is under `from`, which is
/// how the high-precision modes hold the top bits of their first
/// endpoint. The components are r0, g0, b0, r1, g1, b1 and so on, so
/// `which` divided by three is the endpoint and the rest of it the
/// channel. (Since 1.74.)
const Bc6Field = struct { which: u8, to: u8, from: u8 };

/// What one of BC6H's fourteen modes holds: the specification's Table.MF
/// beside the fields of Table.F. A mode with one subset holds two
/// endpoints and no partition; one with two holds four endpoints and a
/// partition of 5 bits. `transformed` says the endpoints past the first
/// are offsets on it, in which case they are held in fewer bits -
/// `deltas`, a count for each channel - than the first's `bits`.
/// (Since 1.74.)
const Bc6Mode = struct {
    transformed: bool,
    subsets: u8,
    bits: u8,
    deltas: [3]u8,
    fields: []const Bc6Field,
};

/// The modes by their number, as the low two bits of a block hold it
/// where they are under 2 and the low five otherwise. The numbers that
/// are not here - 19, 23, 27 and 31 - are reserved by the format, and
/// such a block reads as opaque black.
const bc6_modes = modes: {
    var made: [32]?Bc6Mode = @splat(null);
    const fields = bc6_fields;
    made[0] = .{ .transformed = true, .subsets = 2, .bits = 10, .deltas = .{ 5, 5, 5 }, .fields = fields[0] };
    made[1] = .{ .transformed = true, .subsets = 2, .bits = 7, .deltas = .{ 6, 6, 6 }, .fields = fields[1] };
    made[2] = .{ .transformed = true, .subsets = 2, .bits = 11, .deltas = .{ 5, 4, 4 }, .fields = fields[2] };
    made[3] = .{ .transformed = false, .subsets = 1, .bits = 10, .deltas = .{ 10, 10, 10 }, .fields = fields[3] };
    made[6] = .{ .transformed = true, .subsets = 2, .bits = 11, .deltas = .{ 4, 5, 4 }, .fields = fields[4] };
    made[7] = .{ .transformed = true, .subsets = 1, .bits = 11, .deltas = .{ 9, 9, 9 }, .fields = fields[5] };
    made[10] = .{ .transformed = true, .subsets = 2, .bits = 11, .deltas = .{ 4, 4, 5 }, .fields = fields[6] };
    made[11] = .{ .transformed = true, .subsets = 1, .bits = 12, .deltas = .{ 8, 8, 8 }, .fields = fields[7] };
    made[14] = .{ .transformed = true, .subsets = 2, .bits = 9, .deltas = .{ 5, 5, 5 }, .fields = fields[8] };
    made[15] = .{ .transformed = true, .subsets = 1, .bits = 16, .deltas = .{ 4, 4, 4 }, .fields = fields[9] };
    made[18] = .{ .transformed = true, .subsets = 2, .bits = 8, .deltas = .{ 6, 5, 5 }, .fields = fields[10] };
    made[22] = .{ .transformed = true, .subsets = 2, .bits = 8, .deltas = .{ 5, 6, 5 }, .fields = fields[11] };
    made[26] = .{ .transformed = true, .subsets = 2, .bits = 8, .deltas = .{ 5, 5, 6 }, .fields = fields[12] };
    made[30] = .{ .transformed = false, .subsets = 2, .bits = 6, .deltas = .{ 6, 6, 6 }, .fields = fields[13] };
    break :modes made;
};

/// Where every mode keeps its endpoint components: the specification's
/// Table.F, read from the lowest bit of the block after the mode and
/// going up. The rows are in the order the modes are given there - 0, 1,
/// 2, 3, 6, 7, 10, 11, 14, 15, 18, 22, 26, 30 - and `bc6_modes` picks
/// one by its number.
const bc6_fields = [14][]const Bc6Field{
    // mode 0
    &.{ .{ .which = 7, .to = 4, .from = 4 }, .{ .which = 8, .to = 4, .from = 4 }, .{ .which = 11, .to = 4, .from = 4 }, .{ .which = 0, .to = 9, .from = 0 }, .{ .which = 1, .to = 9, .from = 0 }, .{ .which = 2, .to = 9, .from = 0 }, .{ .which = 3, .to = 4, .from = 0 }, .{ .which = 10, .to = 4, .from = 4 }, .{ .which = 7, .to = 3, .from = 0 }, .{ .which = 4, .to = 4, .from = 0 }, .{ .which = 11, .to = 0, .from = 0 }, .{ .which = 10, .to = 3, .from = 0 }, .{ .which = 5, .to = 4, .from = 0 }, .{ .which = 11, .to = 1, .from = 1 }, .{ .which = 8, .to = 3, .from = 0 }, .{ .which = 6, .to = 4, .from = 0 }, .{ .which = 11, .to = 2, .from = 2 }, .{ .which = 9, .to = 4, .from = 0 }, .{ .which = 11, .to = 3, .from = 3 } },
    // mode 1
    &.{ .{ .which = 7, .to = 5, .from = 5 }, .{ .which = 10, .to = 4, .from = 4 }, .{ .which = 10, .to = 5, .from = 5 }, .{ .which = 0, .to = 6, .from = 0 }, .{ .which = 11, .to = 0, .from = 0 }, .{ .which = 11, .to = 1, .from = 1 }, .{ .which = 8, .to = 4, .from = 4 }, .{ .which = 1, .to = 6, .from = 0 }, .{ .which = 8, .to = 5, .from = 5 }, .{ .which = 11, .to = 2, .from = 2 }, .{ .which = 7, .to = 4, .from = 4 }, .{ .which = 2, .to = 6, .from = 0 }, .{ .which = 11, .to = 3, .from = 3 }, .{ .which = 11, .to = 5, .from = 5 }, .{ .which = 11, .to = 4, .from = 4 }, .{ .which = 3, .to = 5, .from = 0 }, .{ .which = 7, .to = 3, .from = 0 }, .{ .which = 4, .to = 5, .from = 0 }, .{ .which = 10, .to = 3, .from = 0 }, .{ .which = 5, .to = 5, .from = 0 }, .{ .which = 8, .to = 3, .from = 0 }, .{ .which = 6, .to = 5, .from = 0 }, .{ .which = 9, .to = 5, .from = 0 } },
    // mode 2
    &.{ .{ .which = 0, .to = 9, .from = 0 }, .{ .which = 1, .to = 9, .from = 0 }, .{ .which = 2, .to = 9, .from = 0 }, .{ .which = 3, .to = 4, .from = 0 }, .{ .which = 0, .to = 10, .from = 10 }, .{ .which = 7, .to = 3, .from = 0 }, .{ .which = 4, .to = 3, .from = 0 }, .{ .which = 1, .to = 10, .from = 10 }, .{ .which = 11, .to = 0, .from = 0 }, .{ .which = 10, .to = 3, .from = 0 }, .{ .which = 5, .to = 3, .from = 0 }, .{ .which = 2, .to = 10, .from = 10 }, .{ .which = 11, .to = 1, .from = 1 }, .{ .which = 8, .to = 3, .from = 0 }, .{ .which = 6, .to = 4, .from = 0 }, .{ .which = 11, .to = 2, .from = 2 }, .{ .which = 9, .to = 4, .from = 0 }, .{ .which = 11, .to = 3, .from = 3 } },
    // mode 3
    &.{ .{ .which = 0, .to = 9, .from = 0 }, .{ .which = 1, .to = 9, .from = 0 }, .{ .which = 2, .to = 9, .from = 0 }, .{ .which = 3, .to = 9, .from = 0 }, .{ .which = 4, .to = 9, .from = 0 }, .{ .which = 5, .to = 9, .from = 0 } },
    // mode 6
    &.{ .{ .which = 0, .to = 9, .from = 0 }, .{ .which = 1, .to = 9, .from = 0 }, .{ .which = 2, .to = 9, .from = 0 }, .{ .which = 3, .to = 3, .from = 0 }, .{ .which = 0, .to = 10, .from = 10 }, .{ .which = 10, .to = 4, .from = 4 }, .{ .which = 7, .to = 3, .from = 0 }, .{ .which = 4, .to = 4, .from = 0 }, .{ .which = 1, .to = 10, .from = 10 }, .{ .which = 10, .to = 3, .from = 0 }, .{ .which = 5, .to = 3, .from = 0 }, .{ .which = 2, .to = 10, .from = 10 }, .{ .which = 11, .to = 1, .from = 1 }, .{ .which = 8, .to = 3, .from = 0 }, .{ .which = 6, .to = 3, .from = 0 }, .{ .which = 11, .to = 0, .from = 0 }, .{ .which = 11, .to = 2, .from = 2 }, .{ .which = 9, .to = 3, .from = 0 }, .{ .which = 7, .to = 4, .from = 4 }, .{ .which = 11, .to = 3, .from = 3 } },
    // mode 7
    &.{ .{ .which = 0, .to = 9, .from = 0 }, .{ .which = 1, .to = 9, .from = 0 }, .{ .which = 2, .to = 9, .from = 0 }, .{ .which = 3, .to = 8, .from = 0 }, .{ .which = 0, .to = 10, .from = 10 }, .{ .which = 4, .to = 8, .from = 0 }, .{ .which = 1, .to = 10, .from = 10 }, .{ .which = 5, .to = 8, .from = 0 }, .{ .which = 2, .to = 10, .from = 10 } },
    // mode 10
    &.{ .{ .which = 0, .to = 9, .from = 0 }, .{ .which = 1, .to = 9, .from = 0 }, .{ .which = 2, .to = 9, .from = 0 }, .{ .which = 3, .to = 3, .from = 0 }, .{ .which = 0, .to = 10, .from = 10 }, .{ .which = 8, .to = 4, .from = 4 }, .{ .which = 7, .to = 3, .from = 0 }, .{ .which = 4, .to = 3, .from = 0 }, .{ .which = 1, .to = 10, .from = 10 }, .{ .which = 11, .to = 0, .from = 0 }, .{ .which = 10, .to = 3, .from = 0 }, .{ .which = 5, .to = 4, .from = 0 }, .{ .which = 2, .to = 10, .from = 10 }, .{ .which = 8, .to = 3, .from = 0 }, .{ .which = 6, .to = 3, .from = 0 }, .{ .which = 11, .to = 1, .from = 1 }, .{ .which = 11, .to = 2, .from = 2 }, .{ .which = 9, .to = 3, .from = 0 }, .{ .which = 11, .to = 4, .from = 4 }, .{ .which = 11, .to = 3, .from = 3 } },
    // mode 11
    &.{ .{ .which = 0, .to = 9, .from = 0 }, .{ .which = 1, .to = 9, .from = 0 }, .{ .which = 2, .to = 9, .from = 0 }, .{ .which = 3, .to = 7, .from = 0 }, .{ .which = 0, .to = 10, .from = 11 }, .{ .which = 4, .to = 7, .from = 0 }, .{ .which = 1, .to = 10, .from = 11 }, .{ .which = 5, .to = 7, .from = 0 }, .{ .which = 2, .to = 10, .from = 11 } },
    // mode 14
    &.{ .{ .which = 0, .to = 8, .from = 0 }, .{ .which = 8, .to = 4, .from = 4 }, .{ .which = 1, .to = 8, .from = 0 }, .{ .which = 7, .to = 4, .from = 4 }, .{ .which = 2, .to = 8, .from = 0 }, .{ .which = 11, .to = 4, .from = 4 }, .{ .which = 3, .to = 4, .from = 0 }, .{ .which = 10, .to = 4, .from = 4 }, .{ .which = 7, .to = 3, .from = 0 }, .{ .which = 4, .to = 4, .from = 0 }, .{ .which = 11, .to = 0, .from = 0 }, .{ .which = 10, .to = 3, .from = 0 }, .{ .which = 5, .to = 4, .from = 0 }, .{ .which = 11, .to = 1, .from = 1 }, .{ .which = 8, .to = 3, .from = 0 }, .{ .which = 6, .to = 4, .from = 0 }, .{ .which = 11, .to = 2, .from = 2 }, .{ .which = 9, .to = 4, .from = 0 }, .{ .which = 11, .to = 3, .from = 3 } },
    // mode 15
    &.{ .{ .which = 0, .to = 9, .from = 0 }, .{ .which = 1, .to = 9, .from = 0 }, .{ .which = 2, .to = 9, .from = 0 }, .{ .which = 3, .to = 3, .from = 0 }, .{ .which = 0, .to = 10, .from = 15 }, .{ .which = 4, .to = 3, .from = 0 }, .{ .which = 1, .to = 10, .from = 15 }, .{ .which = 5, .to = 3, .from = 0 }, .{ .which = 2, .to = 10, .from = 15 } },
    // mode 18
    &.{ .{ .which = 0, .to = 7, .from = 0 }, .{ .which = 10, .to = 4, .from = 4 }, .{ .which = 8, .to = 4, .from = 4 }, .{ .which = 1, .to = 7, .from = 0 }, .{ .which = 11, .to = 2, .from = 2 }, .{ .which = 7, .to = 4, .from = 4 }, .{ .which = 2, .to = 7, .from = 0 }, .{ .which = 11, .to = 3, .from = 3 }, .{ .which = 11, .to = 4, .from = 4 }, .{ .which = 3, .to = 5, .from = 0 }, .{ .which = 7, .to = 3, .from = 0 }, .{ .which = 4, .to = 4, .from = 0 }, .{ .which = 11, .to = 0, .from = 0 }, .{ .which = 10, .to = 3, .from = 0 }, .{ .which = 5, .to = 4, .from = 0 }, .{ .which = 11, .to = 1, .from = 1 }, .{ .which = 8, .to = 3, .from = 0 }, .{ .which = 6, .to = 5, .from = 0 }, .{ .which = 9, .to = 5, .from = 0 } },
    // mode 22
    &.{ .{ .which = 0, .to = 7, .from = 0 }, .{ .which = 11, .to = 0, .from = 0 }, .{ .which = 8, .to = 4, .from = 4 }, .{ .which = 1, .to = 7, .from = 0 }, .{ .which = 7, .to = 5, .from = 5 }, .{ .which = 7, .to = 4, .from = 4 }, .{ .which = 2, .to = 7, .from = 0 }, .{ .which = 10, .to = 5, .from = 5 }, .{ .which = 11, .to = 4, .from = 4 }, .{ .which = 3, .to = 4, .from = 0 }, .{ .which = 10, .to = 4, .from = 4 }, .{ .which = 7, .to = 3, .from = 0 }, .{ .which = 4, .to = 5, .from = 0 }, .{ .which = 10, .to = 3, .from = 0 }, .{ .which = 5, .to = 4, .from = 0 }, .{ .which = 11, .to = 1, .from = 1 }, .{ .which = 8, .to = 3, .from = 0 }, .{ .which = 6, .to = 4, .from = 0 }, .{ .which = 11, .to = 2, .from = 2 }, .{ .which = 9, .to = 4, .from = 0 }, .{ .which = 11, .to = 3, .from = 3 } },
    // mode 26
    &.{ .{ .which = 0, .to = 7, .from = 0 }, .{ .which = 11, .to = 1, .from = 1 }, .{ .which = 8, .to = 4, .from = 4 }, .{ .which = 1, .to = 7, .from = 0 }, .{ .which = 8, .to = 5, .from = 5 }, .{ .which = 7, .to = 4, .from = 4 }, .{ .which = 2, .to = 7, .from = 0 }, .{ .which = 11, .to = 5, .from = 5 }, .{ .which = 11, .to = 4, .from = 4 }, .{ .which = 3, .to = 4, .from = 0 }, .{ .which = 10, .to = 4, .from = 4 }, .{ .which = 7, .to = 3, .from = 0 }, .{ .which = 4, .to = 4, .from = 0 }, .{ .which = 11, .to = 0, .from = 0 }, .{ .which = 10, .to = 3, .from = 0 }, .{ .which = 5, .to = 5, .from = 0 }, .{ .which = 8, .to = 3, .from = 0 }, .{ .which = 6, .to = 4, .from = 0 }, .{ .which = 11, .to = 2, .from = 2 }, .{ .which = 9, .to = 4, .from = 0 }, .{ .which = 11, .to = 3, .from = 3 } },
    // mode 30
    &.{ .{ .which = 0, .to = 5, .from = 0 }, .{ .which = 10, .to = 4, .from = 4 }, .{ .which = 11, .to = 0, .from = 0 }, .{ .which = 11, .to = 1, .from = 1 }, .{ .which = 8, .to = 4, .from = 4 }, .{ .which = 1, .to = 5, .from = 0 }, .{ .which = 7, .to = 5, .from = 5 }, .{ .which = 8, .to = 5, .from = 5 }, .{ .which = 11, .to = 2, .from = 2 }, .{ .which = 7, .to = 4, .from = 4 }, .{ .which = 2, .to = 5, .from = 0 }, .{ .which = 10, .to = 5, .from = 5 }, .{ .which = 11, .to = 3, .from = 3 }, .{ .which = 11, .to = 5, .from = 5 }, .{ .which = 11, .to = 4, .from = 4 }, .{ .which = 3, .to = 5, .from = 0 }, .{ .which = 7, .to = 3, .from = 0 }, .{ .which = 4, .to = 5, .from = 0 }, .{ .which = 10, .to = 3, .from = 0 }, .{ .which = 5, .to = 5, .from = 0 }, .{ .which = 8, .to = 3, .from = 0 }, .{ .which = 6, .to = 5, .from = 0 }, .{ .which = 9, .to = 5, .from = 0 } },
};

/// `value`, held in `bits` bits, as the number those bits stand for where
/// the top one is its sign.
inline fn bc6Signed(value: i32, bits: u8) i32 {
    const spare: u5 = @intCast(32 - bits);
    return value << spare >> spare;
}

/// An endpoint component unquantized: spread over the 16 bits a half float
/// has, so that the bits are used to the full and a negative range
/// interpolates the way a two's complement value does. The
/// specification's unquantize step, over `bits` of endpoint.
fn bc6Unquantize(comptime signed: bool, value: i32, bits: u8) i32 {
    if (!signed) {
        if (bits >= 15) return value;
        if (value == 0) return 0;
        if (value == (@as(i32, 1) << @intCast(bits)) - 1) return 0xFFFF;
        return ((value << 15) + 0x4000) >> @intCast(bits - 1);
    }
    if (bits >= 16) return value;
    const negative = value < 0;
    const whole = if (negative) -value else value;
    var made: i32 = 0;
    if (whole == 0) {
        made = 0;
    } else if (whole >= (@as(i32, 1) << @intCast(bits - 1)) - 1) {
        made = 0x7FFF;
    } else {
        made = ((whole << 15) + 0x4000) >> @intCast(bits - 1);
    }
    return if (negative) -made else made;
}

/// An interpolated component as the half float it stands for: the
/// specification's final unquantize, which scales the magnitude by 31/64
/// where the format is unsigned and by 31/32 where it is signed, the sign
/// going back on afterwards. What comes out is a legal half float, the
/// largest of them for the largest value.
///
/// The scaling comes first and the sign after it, which is what the
/// hardware references do: a small negative value whose magnitude scales
/// to nothing is 0 rather than the -0 the other order would give.
inline fn bc6Finish(comptime signed: bool, value: i32) u16 {
    if (!signed) return @intCast(value * 31 >> 6);
    const scaled = if (value < 0) -((-value * 31) >> 5) else (value * 31) >> 5;
    if (scaled < 0) return @intCast(-scaled | 0x8000);
    return @intCast(scaled);
}

/// The three channels of each of a BC6H block's sixteen texels, as the
/// half floats they are: 16 bytes read at `at`, and nothing past them.
/// `signed` is the `_sfloat` form of the format, whose values run either
/// way from 0; the `_ufloat` one holds nothing under it.
///
/// The block is cut into one subset or two, as BC7's is, and each subset
/// has two endpoints with an index for every texel between them. One of
/// fourteen modes says how many bits the first endpoint's channels take,
/// how many the others take as offsets on it, and where in the block
/// every one of those sits (`bc6_modes`, `bc6_fields`). The endpoints are
/// then unquantized over the 16 bits of a half float, interpolated as
/// whole numbers, and scaled into the half float the format means. A mode
/// the format reserves reads as black. (Since 1.74.)
pub fn bc6hHalves(comptime signed: bool, at: [*]const u8) [16][3]u16 {
    @setRuntimeSafety(false);
    var made: [16][3]u16 = @splat(@splat(0));
    const low: u32 = at[0] & 0x1F;
    const number = if (low & 3 < 2) low & 3 else low;
    const mode = bc6_modes[number] orelse return made;
    var bits = Bc7Bits{ .at = at, .next = if (number < 2) 2 else 5 };

    // The endpoint components, field by field as Table.F has them: the
    // bits of one component can lie in several places, and the
    // high-precision modes hold some of them in reverse.
    var ends: [4][3]i32 = @splat(@splat(0));
    for (mode.fields) |field| {
        const up = field.to >= field.from;
        const count: u32 = if (up) field.to - field.from + 1 else field.from - field.to + 1;
        const got = bits.read(count);
        const into = &ends[field.which / 3][field.which % 3];
        var sits: i32 = field.from;
        for (0..count) |k| {
            if (got >> @intCast(k) & 1 != 0) into.* |= @as(i32, 1) << @intCast(sits);
            sits += if (up) 1 else -1;
        }
    }

    // The first endpoint is a signed value where the texture is; the
    // others are where it is or where they are offsets on the first,
    // which they then are, wrapped at the bits the first takes.
    const epb = mode.bits;
    const ends_held = mode.subsets * 2;
    const base = ends[0];
    if (signed) {
        for (&ends[0]) |*value| value.* = bc6Signed(value.*, epb);
    }
    const mask = (@as(i32, 1) << @intCast(epb)) - 1;
    for (1..ends_held) |end| {
        for (&ends[end], mode.deltas, 0..) |*value, width, channel| {
            if (signed or mode.transformed) value.* = bc6Signed(value.*, width);
            if (mode.transformed) {
                value.* = (value.* + if (signed) bc6Signed(base[channel], epb) else base[channel]) & mask;
                if (signed) value.* = bc6Signed(value.*, epb);
            }
        }
    }
    var wide: [4][3]i32 = @splat(@splat(0));
    for (0..ends_held) |end| {
        for (&wide[end], ends[end]) |*value, raw| value.* = bc6Unquantize(signed, raw, epb);
    }

    // Which subset each texel is in, and its index between that subset's
    // two endpoints: the first half of BC7's two-subset table, and its
    // anchors.
    const two = mode.subsets == 2;
    var subsets: [16]u32 = @splat(0);
    var anchor: u32 = 0;
    if (two) {
        const partition = bits.read(5);
        const picks = bc7_two[partition];
        for (&subsets, &picks) |*one, pick| one.* = pick;
        anchor = bc7_anchor_two[partition];
    }
    const index_bits: u32 = if (two) 3 else 4;
    for (&made, 0..) |*texel, k| {
        const subset = subsets[k];
        const anchored = k == 0 or (two and k == anchor);
        const index = bits.read(index_bits - @as(u32, if (anchored) 1 else 0));
        const weight: i32 = @intCast(bc7Weight(index_bits, index));
        const first = &wide[subset * 2];
        const second = &wide[subset * 2 + 1];
        for (texel, first, second) |*half, a, b| {
            half.* = bc6Finish(signed, (a * (64 - weight) + b * weight + 32) >> 6);
        }
    }
    return made;
}

/// The sixteen texels of a BC6H block at `at`, in rows, each 0xAARRGGBB:
/// the halves `bc6hHalves` reads, each held between 0 and 1 and rounded
/// to 8 bits the way a float texel is (`floatTexel`), and the alpha
/// whole - the format holds three channels and no fourth. What is above 1
/// reads as 255, which is what a colour of 8 bits a channel has to say
/// about it: `Texture.partsAt` gives a function the halves themselves.
/// (Since 1.74.)
pub fn bc6hBlock(comptime signed: bool, at: [*]const u8) [16]u32 {
    @setRuntimeSafety(false);
    var made: [16]u32 = undefined;
    for (&made, bc6hHalves(signed, at)) |*texel, halves| {
        texel.* = 0xFF00_0000 |
            @as(u32, byteOfFloat(ofHalf(halves[0]))) << 16 |
            @as(u32, byteOfFloat(ofHalf(halves[1]))) << 8 |
            byteOfFloat(ofHalf(halves[2]));
    }
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
        // The word as it lies, and the one byte made a colour: what the
        // smaller texels cost a sample (since 1.48).
        .argb8888 => @as(*const u32, @ptrCast(@alignCast(at))).*,
        .r8 => redOf8(at[0]),
        .rgb565 => widen(@as(*const u16, @ptrCast(@alignCast(at))).*),
        // A depth as a grey, as `Texture.colorAt` reads one: the fast path
        // is built for blocks and never reads a texture of this.
        .d16 => greyOf8(@truncate(@as(*const u16, @ptrCast(@alignCast(at))).* >> 8)),
        // Never read a texel at a time: `sampleBlocked` has the block.
        .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5, .bc6hu, .bc6hs, .bc7 => missing_texel,
        // A float texel read and rounded where it lies (since 1.45): the
        // decoding is the cost of keeping the floats.
        .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => floatTexel(format, at),
        // Channels of its own read and made into a colour (since 1.69):
        // the top 8 bits of each, which is all a tile's colour holds.
        .rg8, .r16, .rg16, .rgba16 => channelColor(format, at),
        // Whole numbers held to the colour they stand for (since 1.70):
        // nothing, or the channel at the full.
        .r8u, .rg8u, .rgba8u, .r8i, .rg8i, .rgba8i, .r16u, .rg16u, .rgba16u, .r16i, .rg16i, .rgba16i, .r32u, .rg32u, .rgba32u, .r32i, .rg32i, .rgba32i => wholeColor(format, at),
    };
}

/// The texel kept at `at`, spread.
inline fn fetchSpread(comptime format: Format, at: [*]const u8) u64 {
    @setRuntimeSafety(false);
    return switch (format) {
        .rgba8888 => @as(*const u64, @ptrCast(@alignCast(at))).*,
        .argb8888, .r8, .rgb565, .d16, .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5, .bc6hu, .bc6hs, .bc7, .rgba16f, .rgba32f, .rg11b10f, .rgb9e5, .r32f => spread(fetch(format, at)),
        .rg8, .r16, .rg16, .rgba16 => spread(fetch(format, at)),
        .r8u, .rg8u, .rgba8u, .r8i, .rg8i, .rgba8i, .r16u, .rg16u, .rgba16u, .r16i, .rg16i, .rgba16i, .r32u, .rg32u, .rgba32u, .r32i, .rg32i, .rgba32i => spread(fetch(format, at)),
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
///
/// Where `Sampler.unnormalized` says so the point is in texels of the
/// first level, which is the only level such a sampler reads, and one
/// sample is taken (since 1.67).
pub fn sampleBy(texture: *const Texture, sampler: *const Sampler, layer: u32, point: Point) u32 {
    return sampledOver(texture, sampler, .{ .layer = layer }, point);
}

/// A cube's colour the way a direction looks, as `sampler` says: `first`
/// is the cube's first face - 0 for a single cube, a multiple of six for
/// one of an array (`cubeNear`) - and `face` the face the direction fell
/// on, with `point` carrying that face's u and v and how fast they change
/// (`cubeHit`).
///
/// **What lies past a face's edge is read from the face beside it**, as a
/// GPU has it and as the fixed form `texture_cube` does since 1.46: a
/// bilinear sample on a seam mixes the texels either side of it, and a
/// comparison on one counts what passed either side. The sampler's `wrap`
/// says nothing of a cube - it has no edge of its own to hold at, to
/// repeat or to border - while its levels, bias, clamp, mipmap mode,
/// anisotropy and comparison say what they say everywhere.
///
/// Until 1.60 such a sample was taken inside the one face, through
/// `sampleBy`, so a seam read the face's own edge texels twice and the
/// sampler's edges stood in for the cube's. (Since 1.60.)
pub fn sampleCubeBy(texture: *const Texture, sampler: *const Sampler, first: u32, face: u32, point: Point) u32 {
    return sampledOver(texture, sampler, .{ .cube = .{ .first = first, .face = face } }, point);
}

/// What both of those do: the level the point falls on, and the levels
/// round it mixed where the sampler asks for it. (Since 1.60.)
fn sampledOver(texture: *const Texture, sampler: *const Sampler, reads: Reads, point: Point) u32 {
    const chosen = chosenLevel(texture, sampler, point);
    const levels = levelsOf(texture, sampler, chosen.level);
    const low = tapped(texture, sampler, reads, levels.low, point, chosen.taps, chosen.filter);
    if (levels.part <= 0) return low;
    return mixColors(low, tapped(texture, sampler, reads, levels.high, point, chosen.taps, chosen.filter), levels.part);
}

/// What a sample settles before it reads anything: the level the point
/// falls on as the sampler holds it, how many samples to take along the
/// longer axis, and which of the sampler's two filters the level asks
/// for. (Since 1.59, where `sampleVolumeBy` came to want the same.)
const Chosen = struct { level: f32, taps: u32, filter: Filter };

fn chosenLevel(texture: *const Texture, sampler: *const Sampler, point: Point) Chosen {
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
    return .{ .level = held(level + sampler.lod_bias, sampler, last), .taps = taps, .filter = filter };
}

/// The levels a sample reads and how much of the second: the nearer one
/// alone where `mipmap` is `nearest` or there is one level, and `part` 0
/// for it. (Since 1.59.)
const Levels = struct { low: u32, high: u32, part: f32 };

fn levelsOf(texture: *const Texture, sampler: *const Sampler, level: f32) Levels {
    if (sampler.mipmap == .nearest or texture.levels == 1) {
        const one: u32 = @intFromFloat(@round(level));
        return .{ .low = one, .high = one, .part = 0 };
    }
    const lower = @floor(level);
    const low: u32 = @intFromFloat(lower);
    const last: f32 = @floatFromInt(texture.levels - 1);
    const high: u32 = @intFromFloat(@min(lower + 1, last));
    const part = level - lower;
    if (low == high or part <= 0) return .{ .low = low, .high = low, .part = 0 };
    return .{ .low = low, .high = high, .part = part };
}

/// A 3D texture's colour at (u, v) of `point` and `r` through it, each 0 to
/// 1, as `sampler` says: its slices are its layers, read as `wrap[2]` says
/// and mixed where the filter is bilinear.
///
/// The level comes first and the slice after it, because **a level has
/// half the slices of the one before it** (`slicesAt`): `r` is taken over
/// the slices that level has, and where two levels are mixed each is read
/// over its own. Until 1.59 it was taken over the whole depth at every
/// level, so a sample of a level past the first read the slices of none of
/// them - the wrong slice where it was there at all, and memory no copy
/// had written where it was not.
pub fn sampleVolumeBy(texture: *const Texture, sampler: *const Sampler, point: Point, r: f32) u32 {
    const chosen = chosenLevel(texture, sampler, point);
    const levels = levelsOf(texture, sampler, chosen.level);
    const low = slicedBy(texture, sampler, levels.low, point, r, chosen);
    if (levels.part <= 0) return low;
    return mixColors(low, slicedBy(texture, sampler, levels.high, point, r, chosen), levels.part);
}

/// One level of a 3D texture at (u, v) of `point` and `r` through it: the
/// slice `r` falls on of the `slicesAt` that level has, or the two it
/// falls between where the filter mixes. (Since 1.59.)
fn slicedBy(texture: *const Texture, sampler: *const Sampler, lod: u32, point: Point, r: f32, chosen: Chosen) u32 {
    const level = @min(lod, texture.levels - 1);
    const slices = texture.slicesAt(level);
    // In slices already, where the sampler's coordinates are not
    // normalized: Vulkan has no 3D texture read that way, so this is the
    // library's own answer rather than a rule of Vulkan's, and it is the
    // one that keeps every axis in the same units (since 1.67).
    const z = if (sampler.unnormalized) sane(r) else sane(r) * @as(f32, @floatFromInt(slices));
    if (chosen.filter == .nearest) {
        const slice = slicedIn(sampler, @intFromFloat(@floor(z)), slices) orelse return sampler.border;
        return tapped(texture, sampler, .{ .layer = slice }, level, point, chosen.taps, chosen.filter);
    }
    const lower = @floor(z - 0.5);
    const first: i32 = @intFromFloat(lower);
    const near = if (slicedIn(sampler, first, slices)) |slice| tapped(texture, sampler, .{ .layer = slice }, level, point, chosen.taps, chosen.filter) else sampler.border;
    const far = if (slicedIn(sampler, first + 1, slices)) |slice| tapped(texture, sampler, .{ .layer = slice }, level, point, chosen.taps, chosen.filter) else sampler.border;
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
fn tapped(texture: *const Texture, sampler: *const Sampler, reads: Reads, lod: u32, point: Point, taps: u32, filter: Filter) u32 {
    const level = @min(lod, texture.levels - 1);
    if (taps <= 1) return sampledAt(texture, sampler, reads, level, point.u, point.v, filter, point.reference);
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
        const color = sampledAt(texture, sampler, reads, level, point.u + du * at, point.v + dv * at, filter, point.reference);
        inline for (&sums, [4]u5{ 0, 8, 16, 24 }) |*sum, shift| sum.* += color >> shift & 0xFF;
    }
    var made: u32 = 0;
    inline for (sums, [4]u5{ 0, 8, 16, 24 }) |sum, shift| made |= ((sum + taps / 2) / taps) << shift;
    return made;
}

/// One sample of a level at (u, v), filtered as `filter` says and compared
/// where the sampler asks for it.
fn sampledAt(texture: *const Texture, sampler: *const Sampler, reads: Reads, lod: u32, u: f32, v: f32, filter: Filter, reference: f32) u32 {
    const across: f32 = @floatFromInt(texture.width(lod));
    const down: f32 = @floatFromInt(texture.height(lod));
    // In texels of this level already, where the sampler says so: the
    // level is the first one, which CreateSampler holds such a sampler to
    // (since 1.67).
    const x = if (sampler.unnormalized) sane(u) else sane(u) * across;
    const y = if (sampler.unnormalized) sane(v) else sane(v) * down;
    if (filter == .nearest) {
        const left: i32 = @intFromFloat(@floor(x));
        const top: i32 = @intFromFloat(@floor(y));
        if (sampler.compare == .none) return texelAt(texture, sampler, reads, lod, left, top);
        const value = valueAt(texture, sampler, reads, lod, left, top);
        return greyOf(if (sampler.compare.passes(value, reference)) 1 else 0);
    }
    const low_x = @floor(x - 0.5);
    const low_y = @floor(y - 0.5);
    const left: i32 = @intFromFloat(low_x);
    const top: i32 = @intFromFloat(low_y);
    const part_x = x - 0.5 - low_x;
    const part_y = y - 0.5 - low_y;
    const corners = [4]u32{
        texelAt(texture, sampler, reads, lod, left, top),
        texelAt(texture, sampler, reads, lod, left + 1, top),
        texelAt(texture, sampler, reads, lod, left, top + 1),
        texelAt(texture, sampler, reads, lod, left + 1, top + 1),
    };
    if (sampler.compare != .none) {
        // A shadow sample mixes what passed, not what was read: Vulkan's
        // percentage-closer filtering. Each corner is read as a value, so
        // a depth texture is compared at all 16 bits of it.
        var passed: f32 = 0;
        const weights = [4]f32{ (1 - part_x) * (1 - part_y), part_x * (1 - part_y), (1 - part_x) * part_y, part_x * part_y };
        const places = [4][2]i32{ .{ left, top }, .{ left + 1, top }, .{ left, top + 1 }, .{ left + 1, top + 1 } };
        inline for (places, weights) |place_at, weight| {
            if (sampler.compare.passes(valueAt(texture, sampler, reads, lod, place_at[0], place_at[1]), reference)) passed += weight;
        }
        return greyOf(passed);
    }
    const upper = mixColors(corners[0], corners[1], part_x);
    const lower = mixColors(corners[2], corners[3], part_x);
    return mixColors(upper, lower, part_y);
}

/// Texel (x, y) of a level of a layer, whole numbers that may lie past the
/// level: where they do, what `Sampler.wrap` says, which may be the border.
/// What a sample reads from: one layer as it lies, or a face of a cube,
/// whose edges read into the faces beside it rather than taking the
/// sampler's own. (Since 1.60.)
const Reads = union(enum) {
    layer: u32,
    cube: struct { first: u32, face: u32 },
};

fn texelAt(texture: *const Texture, sampler: *const Sampler, reads: Reads, lod: u32, x: i32, y: i32) u32 {
    switch (reads) {
        .layer => |layer| {
            const column = wrapped(sampler.wrap[0], x, texture.width(lod)) orelse return sampler.border;
            const row = wrapped(sampler.wrap[1], y, texture.height(lod)) orelse return sampler.border;
            return texture.texelColor(@min(layer, texture.layer_count - 1), lod, column, row);
        },
        // A cube has no edge of its own: past a face's, the face beside
        // it, so a tap on a seam reads over it (`cubePlace`).
        .cube => |one| return texture.cubeTexel(one.first, one.face, lod, x, y),
    }
}

/// What a shadow sample compares with the reference, 0 to 1: the depth of
/// a depth texture, at all 16 bits of it, and the red channel of any
/// other. Past a bordered edge the border's own red channel.
fn valueAt(texture: *const Texture, sampler: *const Sampler, reads: Reads, lod: u32, x: i32, y: i32) f32 {
    switch (reads) {
        .layer => |layer| {
            const border = @as(f32, @floatFromInt(sampler.border >> 16 & 0xFF)) / 255;
            const column = wrapped(sampler.wrap[0], x, texture.width(lod)) orelse return border;
            const row = wrapped(sampler.wrap[1], y, texture.height(lod)) orelse return border;
            return texture.valueOf(@min(layer, texture.layer_count - 1), lod, column, row);
        },
        .cube => |one| return texture.cubeValue(one.first, one.face, lod, x, y),
    }
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
        // Turned round once below 0 - where -1 is texel 0 and -2 texel 1 -
        // and held at the edge either way (since 1.49).
        .mirror_clamp_to_edge => @intCast(std.math.clamp(if (at < 0) -1 - at else at, 0, whole - 1)),
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

/// A one-channel texel as a colour: red, with a green and a blue of 0 and
/// the whole alpha, the way Vulkan reads R8_UNORM (`Format.r8`, since
/// 1.48).
pub inline fn redOf8(value: u8) u32 {
    return 0xFF00_0000 | @as(u32, value) << 16;
}

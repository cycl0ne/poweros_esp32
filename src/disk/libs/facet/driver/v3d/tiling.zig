// SPDX-License-Identifier: MIT
//! How the TMU reads a texture: each level in the layout its size says, the
//! smallest first and the largest last, and the state that tells it where
//! they are (Mesa's v3dv_image.c, v3d_tiling.c and v3dvx_image.c).
//!
//! The TMU works out the layout of a level from its size, and where the
//! smaller levels lie from where level 0 does: none of this can be chosen.
//! A 3D texture's level is its slices one after another, so a level's
//! place counts every slice of each smaller level (since 1.141).
//!   - A level no more than a microtile (64 bytes) in one direction is
//!     `lineartile`: one line of microtiles.
//!   - One no wider than 1 or 2 UIF blocks (2 x 2 microtiles) is `ublinear`:
//!     blocks in rows of that many.
//!   - Anything wider is `uif`: columns of 4 blocks, side by side, padded in
//!     height so that a column does not share the banks of the next.

const std = @import("std");
const texture = @import("sdk").facet.texture;

/// The most levels a texture here has: 8192 across, down to 1.
pub const most_levels = 14;

const microtile_bytes: u32 = 64;
const block_bytes: u32 = 4 * microtile_bytes;
const block_row_bytes: u32 = 4 * block_bytes;
const page_bytes: u32 = 4096;
const banks: u32 = 8;
const page_cache_bytes: u32 = page_bytes * banks;
const page_rows: u32 = page_bytes / block_row_bytes;
const page_cache_rows: u32 = page_cache_bytes / block_row_bytes;
const page_rows_and_a_half: u32 = page_rows * 3 / 2;
const page_cache_rows_less: u32 = page_cache_rows - page_rows_and_a_half;

pub const Kind = enum { lineartile, ublinear_1, ublinear_2, uif, uif_xor };

pub const Level = struct {
    kind: Kind,
    /// From the start of the texture's memory.
    offset: u32,
    width: u32,
    height: u32,
    /// Its height in pixels, padded as the layout has it.
    padded_height: u32,
    /// The rows of blocks it was padded by, if it is `uif`.
    block_pad: u32,
    /// Its slices, one after another: 1 but for a 3D texture's level.
    slices: u32,
    /// The bytes of one slice, from its start to the next one's.
    slice_bytes: u32,
};

pub const Layout = struct {
    /// Bytes a pixel: 1, 2 or 4.
    pixel: u32,
    /// Level 0's slices: a 3D texture's depth, and 1 for any other.
    depth: u32,
    count: u32,
    levels: [most_levels]Level,
    /// All the texture takes: to be bound on `alignment`.
    bytes: u32,
};

/// What a texture's memory has to be aligned to.
pub const alignment = page_bytes;

/// A microtile is 64 bytes whatever the texel: 8 x 8 of one byte, 8 x 4
/// of two, 4 x 4 of four (Mesa's `v3d_utile_width`, `v3d_utile_height`).
fn microtileWidth(pixel: u32) u32 {
    return if (pixel <= 2) 8 else 4;
}

fn microtileHeight(pixel: u32) u32 {
    return if (pixel == 1) 8 else 4;
}

fn minify(size: u32, level: u32) u32 {
    return @max(size >> @intCast(level), 1);
}

fn alignUp(value: u32, to: u32) u32 {
    return (value + to - 1) / to * to;
}

/// The rows of blocks a `uif` level is padded by.
fn blockPad(pixel: u32, height: u32) u32 {
    const rows = height / (2 * microtileHeight(pixel));
    const into_cache = rows % page_cache_rows;
    if (into_cache == 0) return 0;
    if (into_cache < page_rows_and_a_half) return if (rows < page_cache_rows) 0 else page_rows_and_a_half - into_cache;
    if (into_cache > page_cache_rows_less) return page_cache_rows - into_cache;
    return 0;
}

/// The layout of a texture of `count` levels, whose level 0 is `width` by
/// `height`, of `pixel` bytes each, and `depth` slices: a 3D texture's,
/// or 1 for any other, whose layers are each a texture of their own.
///
/// It is Mesa's v3d_setup_slices (src/broadcom/vulkan/v3dv_image.c:
/// 112-282). A 3D texture's level is all its slices (:174-178, :264-265),
/// as the TMU finds it from level 0's place. Until 1.141 each slice was
/// a texture of its own, as a layer is, and the TMU read a level past
/// level 0 a slice or more from where it lay.
///
/// `four` is an image of four samples a pixel, which v3dv lays out as one
/// of twice the width and twice the height, each pixel's samples a 2 x 2
/// quad of it (`sampleTexel`), and its level 0 in UIF however small, the
/// tile buffer storing all four samples only there (v3dv_image.c:136-140,
/// 180-183, `uif_top`; since 1.146). Vulkan gives such an image the one
/// level.
pub fn layoutOf(pixel: u32, width: u32, height: u32, depth: u32, count: u32, four: bool) Layout {
    var layout = Layout{ .pixel = pixel, .depth = depth, .count = count, .levels = undefined, .bytes = 0 };
    const micro_w = microtileWidth(pixel);
    const micro_h = microtileHeight(pixel);
    const block_w = 2 * micro_w;
    const block_h = 2 * micro_h;
    // From level 2 on, sizes count from a power of two.
    const pot_width = 2 * std.math.ceilPowerOfTwoAssert(u32, minify(width, 1));
    const pot_height = 2 * std.math.ceilPowerOfTwoAssert(u32, minify(height, 1));
    // And the slices from level 1 on (v3dv_image.c:132-134, 174-178).
    const pot_depth = 2 * std.math.ceilPowerOfTwoAssert(u32, minify(depth, 1));
    var offset: u32 = 0;
    var level = count;
    while (level > 0) {
        level -= 1;
        const made = &layout.levels[level];
        made.width = minify(width, level);
        made.height = minify(height, level);
        var across = if (level < 2) made.width else minify(pot_width, level);
        var down = if (level < 2) made.height else minify(pot_height, level);
        if (four) {
            across *= 2;
            down *= 2;
        }
        const uif_top = four and level == 0;
        made.block_pad = 0;
        if (!uif_top and (across <= micro_w or down <= micro_h)) {
            made.kind = .lineartile;
            across = alignUp(across, micro_w);
            down = alignUp(down, micro_h);
        } else if (!uif_top and across <= block_w) {
            made.kind = .ublinear_1;
            across = alignUp(across, block_w);
            down = alignUp(down, block_h);
        } else if (!uif_top and across <= 2 * block_w) {
            made.kind = .ublinear_2;
            across = alignUp(across, 2 * block_w);
            down = alignUp(down, block_h);
        } else {
            across = alignUp(across, 4 * block_w);
            down = alignUp(down, block_h);
            made.block_pad = blockPad(pixel, down);
            down += made.block_pad * block_h;
            made.kind = if (down / block_h % (page_cache_bytes / block_row_bytes) == 0) .uif_xor else .uif;
        }
        made.offset = offset;
        made.padded_height = down;
        made.slices = if (level < 1) depth else minify(pot_depth, level);
        made.slice_bytes = across * pixel * down;
        var taken = made.slice_bytes * made.slices;
        // The hardware puts level 1 on a page if it or a smaller one could
        // be uif_xor; the smaller ones, being powers of two, then stay so.
        if (level == 1 and across > 4 * block_w and down > page_cache_rows_less * block_h) {
            taken = alignUp(taken, page_bytes);
        }
        offset += taken;
    }
    // Level 0 on a page: what comes first is what is short of it.
    const start = alignUp(layout.levels[0].offset, page_bytes) - layout.levels[0].offset;
    for (layout.levels[0..count]) |*made| made.offset += start;
    layout.bytes = offset + start;
    return layout;
}

/// Where sample `sample` of pixel (x, y) of an image of four samples lies,
/// as a texel of the layout `layoutOf` gives it with `four`: the samples
/// across its quad and then down, as v3d's compiler fetches one
/// (`v3d_nir_lower_txf_ms_instr`, v3d_nir_lower_txf_ms.c:46-51; since
/// 1.146).
pub fn sampleTexel(x: u32, y: u32, sample: u32) [2]u32 {
    return .{ 2 * x + (sample & 1), 2 * y + (sample >> 1 & 1) };
}

/// A level's height in UIF blocks: what a store or a load into it is told
/// where it is `uif` (v3dv's padded_height_of_output_image_in_uif_blocks,
/// v3dv_image.c:247-248), and 0 for the other tilings, which need none.
pub fn blocksDown(layout: *const Layout, level: u32) u32 {
    const made = &layout.levels[level];
    return switch (made.kind) {
        .uif, .uif_xor => made.padded_height / (2 * microtileHeight(layout.pixel)),
        .lineartile, .ublinear_1, .ublinear_2 => 0,
    };
}

/// Where slice `slice` of level `level` of a 3D texture begins, from where
/// the level does: the slices one after another (v3dv_image.c:384-385,
/// v3dv_layer_offset). 0 for any other texture's level, which has one.
pub fn sliceAt(layout: *const Layout, level: u32, slice: u32) u32 {
    return slice * layout.levels[level].slice_bytes;
}

/// Where texel (x, y) of level `level` lies, from the texture's start: of
/// a 3D texture's level, in its first slice (`sliceAt`).
pub fn texelOffset(layout: *const Layout, level: u32, x: u32, y: u32) u32 {
    const made = &layout.levels[level];
    const pixel = layout.pixel;
    const micro_w = microtileWidth(pixel);
    const micro_h = microtileHeight(pixel);
    const inside = (x & (micro_w - 1)) * pixel + (y & (micro_h - 1)) * micro_w * pixel;
    const offset = switch (made.kind) {
        .lineartile => microtile_bytes * (x / micro_w + y / micro_h) + inside,
        .ublinear_1 => blocks(x, y, micro_w, micro_h, 1) + inside,
        .ublinear_2 => blocks(x, y, micro_w, micro_h, 2) + inside,
        .uif, .uif_xor => uif: {
            const block_x = x / (2 * micro_w);
            var block_y = y / (2 * micro_h);
            if (made.kind == .uif_xor and block_x / 4 & 1 != 0) block_y ^= 0x10;
            const rows = made.padded_height / (2 * micro_h);
            const number = block_x / 4 * ((rows - 1) * 4) + block_x + block_y * 4;
            break :uif number * block_bytes + inBlock(x, y, micro_w, micro_h) + inside;
        },
    };
    return made.offset + offset;
}

/// The offset of a microtile inside its block.
fn inBlock(x: u32, y: u32, micro_w: u32, micro_h: u32) u32 {
    return (if (y & micro_h != 0) @as(u32, 2 * microtile_bytes) else 0) + (if (x & micro_w != 0) microtile_bytes else 0);
}

fn blocks(x: u32, y: u32, micro_w: u32, micro_h: u32, columns: u32) u32 {
    const block_x = x / (2 * micro_w);
    const block_y = y / (2 * micro_h);
    return block_bytes * (block_y * columns + block_x) + inBlock(x, y, micro_w, micro_h);
}

// --- what the TMU is told ----------------------------------------------------

pub const texture_state_bytes = 24;
pub const sampler_state_bytes = 24;
/// Both go in memory on these: the low bits of their addresses in a
/// configuration parameter are other fields.
pub const texture_state_alignment = 16;
pub const sampler_state_alignment = 32;

const TEXTURE_R8: u64 = 0;
const TEXTURE_RGBA8: u64 = 4;
const TEXTURE_RGB565: u64 = 6;
/// D16_UNORM's, as v3dv samples it (v3dvx_formats.c:204;
/// v3d_packet.xml:354).
const TEXTURE_DEPTH_COMP16: u64 = 21;

const SWIZZLE_ZERO: u64 = 0;
const SWIZZLE_ONE: u64 = 1;
const SWIZZLE_RED: u64 = 2;
const SWIZZLE_GREEN: u64 = 3;
const SWIZZLE_BLUE: u64 = 4;
const SWIZZLE_ALPHA: u64 = 5;

/// What a texel holds in memory.
pub const Texels = enum {
    /// Bytes red, green, blue, alpha.
    rgba,
    /// Bytes blue, green, red, alpha.
    bgra,
    /// 16 bits, red at the top, blue at the bottom.
    rgb565,
    /// One byte of red, read as (red, 0, 0, 1) - the swizzles say the
    /// rest (since 1.48).
    r8,
    /// 16 bits of depth, read as (depth, 0, 0, 1): v3dv's DEPTH_COMP16 and
    /// SWIZ_X001 for D16_UNORM (v3dvx_formats.c:204; since 1.142). Where
    /// the program writes a reference, what passed stands in the depth's
    /// place, as the cores give it (since 1.121).
    d16,

    pub fn bytes(texels: Texels) u32 {
        return switch (texels) {
            .rgba, .bgra => 4,
            .rgb565, .d16 => 2,
            .r8 => 1,
        };
    }
};

/// Where each of the four channels a sample gives back comes from, as an
/// image view's swizzle names it: a channel of the colour the format reads
/// as, or a constant (since 1.120).
pub const Pick = enum { red, green, blue, alpha, zero, one };

/// Each channel from itself: a view that swizzles nothing.
pub const own_picks = [4]Pick{ .red, .green, .blue, .alpha };

/// A texture's state, into `into`: levels `base` to `last` of it, at
/// `address` on the V3D, and `depth` layers or slices `stride` bytes apart,
/// each channel from where the view's `picks` say.
pub fn writeTextureState(into: []u8, layout: *const Layout, texels: Texels, picks: [4]Pick, address: u32, base: u32, last: u32, depth: u32, stride: u32) void {
    const level_0 = &layout.levels[0];
    const base_address = address + level_0.offset;
    const strict_uif = level_0.kind == .uif or level_0.kind == .uif_xor;
    const texture_type = switch (texels) {
        .rgba, .bgra => TEXTURE_RGBA8,
        .rgb565 => TEXTURE_RGB565,
        .r8 => TEXTURE_R8,
        .d16 => TEXTURE_DEPTH_COMP16,
    };
    // Which channel of the texel each of the four comes out of: a 565
    // texel has no alpha and an R8 one has red alone, so those read 1 and
    // 0, as Vulkan reads a format that is short of a channel. A depth is
    // red alone too.
    const red: u64 = if (texels == .bgra) SWIZZLE_BLUE else SWIZZLE_RED;
    const green: u64 = if (texels == .r8 or texels == .d16) SWIZZLE_ZERO else SWIZZLE_GREEN;
    const blue: u64 = switch (texels) {
        .bgra => SWIZZLE_RED,
        .r8, .d16 => SWIZZLE_ZERO,
        .rgba, .rgb565 => SWIZZLE_BLUE,
    };
    const alpha: u64 = if (texels == .rgba or texels == .bgra) SWIZZLE_ALPHA else SWIZZLE_ONE;
    // And the view's swizzle over those, as v3dv composes the format's
    // with the view's (`util_format_compose_swizzles`,
    // src/broadcom/vulkan/v3dv_image.c:828-831): a channel the view takes
    // is read from where the format keeps it, and a constant is itself.
    const own = [4]u64{ red, green, blue, alpha };
    var picked: [4]u64 = undefined;
    for (&picked, picks) |*one, pick| one.* = switch (pick) {
        .red => own[0],
        .green => own[1],
        .blue => own[2],
        .alpha => own[3],
        .zero => SWIZZLE_ZERO,
        .one => SWIZZLE_ONE,
    };
    // Bits 0 to 63: the address, the distance between arrays' worth, and
    // the width's first 6. That distance starts at bit 33 on this chip, a
    // V3D 7.1.10; on 7.1.2 it starts at 32 (Mesa's v3d_packet.xml).
    const first: u64 = @as(u64, base_address) | @as(u64, stride / 64) << 33 | @as(u64, level_0.width) << 58;
    // Bits 64 to 127.
    const second: u64 = @as(u64, level_0.width) >> 6 |
        @as(u64, level_0.height) << (72 - 64) |
        @as(u64, depth) << (86 - 64) |
        texture_type << (100 - 64) |
        @as(u64, @intFromBool(strict_uif)) << (107 - 64) |
        picked[0] << (108 - 64) |
        picked[1] << (111 - 64) |
        picked[2] << (114 - 64) |
        picked[3] << (117 - 64) |
        @as(u64, last) << (120 - 64) |
        @as(u64, base) << (124 - 64);
    // Bits 128 to 191: the planes of a video format take the same address.
    const plane: u64 = base_address >> 6;
    const third: u64 = @as(u64, if (strict_uif) level_0.block_pad else 0) |
        @as(u64, @intFromBool(level_0.kind == .uif_xor)) << (132 - 128) |
        @as(u64, @intFromBool(strict_uif)) << (134 - 128) |
        @as(u64, 1) << (136 - 128) |
        @as(u64, 1) << (137 - 128) |
        plane << (138 - 128) |
        plane << (164 - 128);
    std.mem.writeInt(u64, into[0..8], first, .little);
    std.mem.writeInt(u64, into[8..16], second, .little);
    std.mem.writeInt(u64, into[16..24], third, .little);
}

pub const Filter = enum { nearest, bilinear };

/// What the TMU reads past a texture's edge: `Wrap Mode` in Mesa's
/// v3d_packet.xml:79-85, numbered as the state holds it, and the five
/// Vulkan has (v3dvx_device.c:36-42).
pub const Wrap = enum(u64) {
    repeat = 0,
    clamp = 1,
    mirror = 2,
    border = 3,
    /// Turned round once below 0 and then held at the edge: Vulkan's
    /// MIRROR_CLAMP_TO_EDGE.
    mirror_once = 4,
};

/// What a border reads: `Border Color Mode`, v3d_packet.xml:72-77. Its
/// fourth, `Follows` (7), takes a colour from the state's last four words,
/// which only VK_EXT_custom_border_color asks for (v3dvx_device.c:225-228);
/// facet has Vulkan 1.0's three borders and no other
/// (`_sampler.borderOf`), so the words stay 0.
pub const Border = enum(u64) {
    transparent_black = 0,
    opaque_black = 1,
    opaque_white = 2,
};

/// How a shadow sample compares: `Compare Function`, v3d_packet.xml:3-12,
/// in Vulkan's order (v3dvx_device.c:44-54).
pub const Compare = enum(u64) {
    never = 0,
    less = 1,
    equal = 2,
    less_or_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_or_equal = 6,
    always = 7,
};

/// A sampler as the TMU's state holds it: each field v3dv's
/// `pack_sampler_state` fills (src/broadcom/vulkan/v3dvx_device.c:203-271),
/// at the place v3d_packet.xml:1712-1737 gives it. The defaults are the
/// state a fixed form samples through: its filter both ways, its wrap on
/// every axis, the nearest level, and every level the texture has.
pub const SamplerState = struct {
    /// Where a texel covers more than a pixel, and where it covers less.
    mag: Filter = .bilinear,
    min: Filter = .bilinear,
    /// The nearer level alone, rather than the two a point falls between
    /// mixed.
    mip_nearest: bool = true,
    /// Across, down and through a 3D texture: `Wrap S`, `T` and `R`.
    wrap: [3]Wrap = @splat(.repeat),
    border: Border = .transparent_black,
    /// Added to the level, in levels: `Fixed Bias`, s8.8.
    bias: f32 = 0,
    /// The levels a sample is held to, 0 to 15: `Min` and `Max
    /// Level-of-Detail`, u4.8. 15 is past any texture's last level.
    min_lod: f32 = 0,
    max_lod: f32 = 15,
    /// `Maximum Anisotropy` - 0 for 2 samples, 1 for 4, 2 for 8, 3 for
    /// 16 - with `Anisotropy Enable`; null for one sample.
    anisotropy: ?u2 = null,
    /// What a shadow sample does with the reference. The TMU compares only
    /// where the program writes one to TMUDREF (Mesa's v3d_tex.c:155-157),
    /// so for any other sample this says nothing; v3dv writes `never`
    /// where the sampler has no comparison (v3dvx_device.c:262-264).
    compare: Compare = .never,
};

/// A sampler's state, into `into`: v3dv's `pack_sampler_state`
/// (v3dvx_device.c:230-270), field for field. The two that v3dv sets to 0
/// whatever it is given are 0 here too: `Wrap I Border` ("Also hardcoded on
/// v3d", :254) and `sRGB Disable` ("Not even set by v3d", :261).
pub fn writeSamplerState(into: []u8, state: SamplerState) void {
    const words: u64 = @as(u64, @intFromBool(state.mag == .nearest)) |
        @as(u64, @intFromBool(state.min == .nearest)) << 1 |
        @as(u64, @intFromBool(state.mip_nearest)) << 2 |
        @as(u64, @intFromBool(state.anisotropy != null)) << 3 |
        @intFromEnum(state.compare) << 4 |
        lodBits(state.min_lod) << 8 |
        lodBits(state.max_lod) << 20 |
        biasBits(state.bias) << 32 |
        @intFromEnum(state.wrap[0]) << 48 |
        @intFromEnum(state.wrap[1]) << 51 |
        @intFromEnum(state.wrap[2]) << 54 |
        @intFromEnum(state.border) << 58 |
        @as(u64, state.anisotropy orelse 0) << 61;
    @memset(into[0..sampler_state_bytes], 0);
    std.mem.writeInt(u64, into[0..8], words, .little);
}

/// A level as the state holds it, u4.8: held to 0 to 15 as v3dv holds it
/// (`MIN2(MAX2(0, lod), 15)`, v3dvx_device.c:259-260), to the nearest
/// 256th. Mesa's packing goes through `util_bitpack_ufixed`
/// (gen_pack_header.py:323), whose source is outside the parts of Mesa
/// read for this port; the nearest is what is taken here. A NaN is 0.
fn lodBits(lod: f32) u64 {
    const held = if (std.math.isNan(lod)) 0 else std.math.clamp(lod, 0, 15);
    return @intFromFloat(@round(held * 256));
}

/// The bias as the state holds it, s8.8. v3dv packs Vulkan's `mipLodBias`
/// as it is (v3dvx_device.c:258), which Vulkan holds to
/// `max_sampler_lod_bias`; facet's CreateSampler does not, so this holds
/// it to what the field can say rather than let a wild bias run into the
/// wrap fields. A NaN is 0.
fn biasBits(bias: f32) u64 {
    const held = if (std.math.isNan(bias)) 0 else std.math.clamp(bias, -128, 32767.0 / 256.0);
    const fixed: i16 = @intFromFloat(@round(held * 256));
    return @as(u16, @bitCast(fixed));
}

/// What a sampler comes to on the TMU: its state, and whether the
/// coordinates are in texels, which goes in configuration parameter 1
/// rather than in the state (`parameter1`).
pub const Sampled = struct {
    state: SamplerState,
    unnormalized: bool = false,
};

/// `sampler` as the TMU samples through it: v3dv's `pack_sampler_state`
/// (v3dvx_device.c:203-271) from facet's own sampler rather than from a
/// VkSamplerCreateInfo, and v3dv's unnormalized bit
/// (v3dv_uniforms.c:213-218). Null where it asks for what no program here
/// can carry.
///
/// That is a comparison where the program writes no reference. The TMU
/// compares only where the program writes it to TMUDREF (Mesa's
/// v3d_tex.c:155-157), which the shadow form's does since 1.142 (`dref`)
/// and compile.zig's do not yet. A comparing sampler would be read for its
/// colour there, while the cores compare it with 0 (`ir.zig`). Vulkan has
/// a comparing sampler read only by a Dref sample, so neither answer is
/// wrong, but the two would differ quietly; the draw paints
/// `shader.missing` instead. Item 58 of docs/facet-vulkan10.md is the
/// Dref sample of a generated program.
///
/// The compare function is Vulkan's, NEVER where the sampler compares
/// nothing, as v3dv packs it (v3dvx_device.c:262-264).
///
/// Two places differ from v3dv by what facet keeps rather than by what
/// the TMU is told:
/// - Anisotropy. A facet sampler keeps the samples it takes
///   (`texture.Sampler.anisotropy`, 1 for one) and not Vulkan's
///   `anisotropyEnable` beside them. v3dv turns anisotropy on wherever it
///   is enabled, so an enabled sampler of `maxAnisotropy` 1 takes 2
///   samples there and 1 here, which is what Vulkan says 1 is.
/// - The border, a colour here (`texture.Sampler.border`) rather than
///   Vulkan's enum: it is one of the three CreateSampler makes from
///   Vulkan's six (`_sampler.borderOf`), and those are the TMU's three.
pub fn samplerOf(sampler: *const texture.Sampler, dref: bool) ?Sampled {
    if (sampler.compare != .none and !dref) return null;
    var wrap: [3]Wrap = undefined;
    for (&wrap, sampler.wrap) |*into, each| into.* = switch (each) {
        .repeat => .repeat,
        .mirrored_repeat => .mirror,
        .clamp_to_edge => .clamp,
        .clamp_to_border => .border,
        .mirror_clamp_to_edge => .mirror_once,
    };
    return .{
        .state = .{
            .mag = filterOf(sampler.mag_filter),
            .min = filterOf(sampler.min_filter),
            .mip_nearest = sampler.mipmap == .nearest,
            .wrap = wrap,
            .border = switch (sampler.border) {
                0x0000_0000 => .transparent_black,
                0xFF00_0000 => .opaque_black,
                0xFFFF_FFFF => .opaque_white,
                else => return null,
            },
            .bias = sampler.lod_bias,
            .min_lod = sampler.min_lod,
            .max_lod = sampler.max_lod,
            .anisotropy = anisotropyOf(sampler.anisotropy),
            .compare = switch (sampler.compare) {
                .none, .never => .never,
                .less => .less,
                .equal => .equal,
                .less_or_equal => .less_or_equal,
                .greater => .greater,
                .not_equal => .not_equal,
                .greater_or_equal => .greater_or_equal,
                .always => .always,
            },
        },
        .unnormalized = sampler.unnormalized,
    };
}

fn filterOf(filter: texture.Filter) Filter {
    return switch (filter) {
        .nearest => .nearest,
        .bilinear => .bilinear,
    };
}

/// v3dv's `Maximum Anisotropy` for the samples a sampler takes
/// (v3dvx_device.c:231-239): 16 past 8, 8 past 4, 4 past 2, and 2 for
/// anything else above one.
fn anisotropyOf(taps: f32) ?u2 {
    if (!(taps > 1)) return null;
    if (taps > 8) return 3;
    if (taps > 4) return 2;
    if (taps > 2) return 1;
    return 0;
}

/// Configuration parameter 0: the state's address, and the two words of two
/// half-floats each that come back.
pub fn parameter0(state: u32) u32 {
    return state | 0b11;
}

/// Configuration parameter 1: the sampler's address, and whether the
/// coordinates are in texels (`Unnormalized coordinates`, bit 1 of TMU
/// Config Parameter 1, v3d_packet.xml:1542-1547), which v3dv sets from the
/// sampler as it writes the uniform (v3dv_uniforms.c:213-218). The
/// per-pixel mask is the program's, ORed in where its sample skips the
/// helper pixels (`compile.per_pixel_mask`; since 1.167).
pub fn parameter1(sampler: u32, unnormalized: bool) u32 {
    return sampler | @as(u32, @intFromBool(unnormalized)) << 1;
}

test "the levels are in Mesa's layouts, smallest first" {
    const layout = layoutOf(4, 64, 64, 1, 7, false);
    try std.testing.expectEqual(Kind.lineartile, layout.levels[6].kind);
    try std.testing.expectEqual(Kind.lineartile, layout.levels[4].kind);
    try std.testing.expectEqual(Kind.ublinear_1, layout.levels[3].kind);
    try std.testing.expectEqual(Kind.ublinear_2, layout.levels[2].kind);
    try std.testing.expectEqual(Kind.uif, layout.levels[1].kind);
    try std.testing.expectEqual(Kind.uif, layout.levels[0].kind);
    try std.testing.expectEqual(@as(u32, 0), layout.levels[0].offset % alignment);
    for (1..7) |level| try std.testing.expect(layout.levels[level].offset < layout.levels[level - 1].offset);
    try std.testing.expect(layout.bytes >= 64 * 64 * 4 + layout.levels[0].offset);
}

test "a 3D texture's level is its slices, as v3d_setup_slices lays them out" {
    // Four slices of 16 x 16 and two levels: level 1 is two slices of
    // 8 x 8, one after the other just before level 0, and level 0 four.
    const layout = layoutOf(4, 16, 16, 4, 2, false);
    try std.testing.expectEqual(@as(u32, 4), layout.levels[0].slices);
    try std.testing.expectEqual(@as(u32, 2), layout.levels[1].slices);
    try std.testing.expectEqual(@as(u32, 8 * 8 * 4), layout.levels[1].slice_bytes);
    try std.testing.expectEqual(@as(u32, 16 * 16 * 4), layout.levels[0].slice_bytes);
    try std.testing.expectEqual(layout.levels[0].offset, layout.levels[1].offset + 2 * layout.levels[1].slice_bytes);
    try std.testing.expectEqual(@as(u32, 0), layout.levels[0].offset % alignment);
    try std.testing.expectEqual(layout.levels[0].offset + 4 * layout.levels[0].slice_bytes, layout.bytes);
    try std.testing.expectEqual(@as(u32, 256), sliceAt(&layout, 1, 1));
    // From level 1 on the slices count from a power of two, as the
    // sizes do: six slices are three at level 1 to Vulkan, and four here
    // (v3dv_image.c:132-134).
    const six = layoutOf(4, 16, 16, 6, 3, false);
    try std.testing.expectEqual(@as(u32, 6), six.levels[0].slices);
    try std.testing.expectEqual(@as(u32, 4), six.levels[1].slices);
    try std.testing.expectEqual(@as(u32, 2), six.levels[2].slices);
    // A texture that is not 3D has one slice a level, and lies as before.
    const flat = layoutOf(4, 16, 16, 1, 2, false);
    try std.testing.expectEqual(@as(u32, 1), flat.levels[1].slices);
    try std.testing.expectEqual(flat.levels[0].offset, flat.levels[1].offset + flat.levels[1].slice_bytes);
}

test "a level's texels each have a place of their own" {
    // Sizes in every layout, for each size of texel - one byte as well
    // since 1.48, whose microtile is 8 x 8 rather than 8 x 4 or 4 x 4.
    const sizes = [_][2]u32{ .{ 4, 4 }, .{ 8, 8 }, .{ 16, 16 }, .{ 32, 32 }, .{ 64, 64 }, .{ 256, 64 }, .{ 64, 256 }, .{ 128, 128 } };
    var seen: [256 * 256 * 4]bool = undefined;
    for ([_]u32{ 1, 2, 4 }) |pixel| for (sizes) |size| {
        const layout = layoutOf(pixel, size[0], size[1], 1, 1, false);
        @memset(&seen, false);
        for (0..size[1]) |y| for (0..size[0]) |x| {
            const at = texelOffset(&layout, 0, @intCast(x), @intCast(y));
            try std.testing.expect(at + pixel <= layout.bytes);
            try std.testing.expectEqual(@as(u32, 0), at % pixel);
            try std.testing.expect(!seen[at]);
            seen[at] = true;
        };
    };
}

test "the UIF layout is v3d_tiling.c's" {
    const layout = layoutOf(4, 64, 64, 1, 1, false);
    // A block is 8 x 8 at 4 bytes a texel; the next microtile right is 64
    // bytes on, the next down 128.
    try std.testing.expectEqual(@as(u32, 4), texelOffset(&layout, 0, 1, 0));
    try std.testing.expectEqual(@as(u32, 16), texelOffset(&layout, 0, 0, 1));
    try std.testing.expectEqual(@as(u32, 64), texelOffset(&layout, 0, 4, 0));
    try std.testing.expectEqual(@as(u32, 128), texelOffset(&layout, 0, 0, 4));
    try std.testing.expectEqual(@as(u32, 256), texelOffset(&layout, 0, 8, 0));
}

test "one byte a texel: Mesa's 8 x 8 microtile, and the TMU's R8 with the swizzles of a channel it has not" {
    // A microtile is 64 bytes whatever the texel, so one of bytes is
    // 8 x 8: the next byte right is 1 on, the next row 8, the next
    // microtile right 64 and the one below 128 (two microtiles of a
    // block, 64 each).
    const layout = layoutOf(1, 64, 64, 1, 1, false);
    try std.testing.expectEqual(@as(u32, 1), texelOffset(&layout, 0, 1, 0));
    try std.testing.expectEqual(@as(u32, 8), texelOffset(&layout, 0, 0, 1));
    try std.testing.expectEqual(@as(u32, 64), texelOffset(&layout, 0, 8, 0));
    try std.testing.expectEqual(@as(u32, 128), texelOffset(&layout, 0, 0, 8));
    // A level of 64 x 64 bytes takes a quarter of what one of words takes.
    const words = layoutOf(4, 64, 64, 1, 1, false);
    try std.testing.expectEqual(words.bytes - words.levels[0].offset, 4 * (layout.bytes - layout.levels[0].offset));

    var state: [texture_state_bytes]u8 = undefined;
    writeTextureState(&state, &layout, .r8, own_picks, 0x20_0000, 0, 0, 1, 0);
    const second = std.mem.readInt(u64, state[8..16], .little);
    try std.testing.expectEqual(TEXTURE_R8, second >> (100 - 64) & 0x7F);
    // Red from the texel, a green and a blue of 0 and a whole alpha: what
    // Vulkan reads of a one-channel format.
    try std.testing.expectEqual(SWIZZLE_RED, second >> (108 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ZERO, second >> (111 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ZERO, second >> (114 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ONE, second >> (117 - 64) & 7);
}

test "a view's swizzle over the format's own: a channel the view takes read from where the format keeps it, a constant as itself" {
    // B8G8R8A8 viewed as its alpha, 0, 1 and its red: the alpha where it
    // is, and the red from the TMU's blue, which is where the format
    // keeps it (since 1.120).
    var state: [texture_state_bytes]u8 = undefined;
    writeTextureState(&state, &layoutOf(4, 64, 64, 1, 1, false), .bgra, .{ .alpha, .zero, .one, .red }, 0x10_0000, 0, 0, 1, 0);
    var second = std.mem.readInt(u64, state[8..16], .little);
    try std.testing.expectEqual(SWIZZLE_ALPHA, second >> (108 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ZERO, second >> (111 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ONE, second >> (114 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_BLUE, second >> (117 - 64) & 7);
    // R8 viewed as its alpha, its green and its red twice: the alpha and
    // the green it has not got read 1 and 0, as Vulkan reads them.
    writeTextureState(&state, &layoutOf(1, 64, 64, 1, 1, false), .r8, .{ .alpha, .green, .red, .red }, 0x20_0000, 0, 0, 1, 0);
    second = std.mem.readInt(u64, state[8..16], .little);
    try std.testing.expectEqual(SWIZZLE_ONE, second >> (108 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ZERO, second >> (111 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_RED, second >> (114 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_RED, second >> (117 - 64) & 7);
}

test "the states have their fields where the packet file has them" {
    const layout = layoutOf(4, 64, 32, 1, 1, false);
    var state: [texture_state_bytes]u8 = undefined;
    writeTextureState(&state, &layout, .bgra, own_picks, 0x10_0000, 0, 0, 1, 0);
    const first = std.mem.readInt(u64, state[0..8], .little);
    const second = std.mem.readInt(u64, state[8..16], .little);
    try std.testing.expectEqual(@as(u64, 0x10_0000), first & 0xFFFF_FFFF);
    const width = (first >> 58 | second << 6) & 0x3FFF;
    try std.testing.expectEqual(@as(u64, 64), width);
    try std.testing.expectEqual(@as(u64, 32), second >> (72 - 64) & 0x3FFF);
    try std.testing.expectEqual(@as(u64, 1), second >> (86 - 64) & 0x3FFF);
    try std.testing.expectEqual(TEXTURE_RGBA8, second >> (100 - 64) & 0x7F);
    try std.testing.expectEqual(SWIZZLE_BLUE, second >> (108 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_GREEN, second >> (111 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_RED, second >> (114 - 64) & 7);
    try std.testing.expectEqual(SWIZZLE_ALPHA, second >> (117 - 64) & 7);
    var sampler: [sampler_state_bytes]u8 = undefined;
    writeSamplerState(&sampler, .{ .mag = .nearest, .min = .nearest, .wrap = @splat(.clamp) });
    const bits = std.mem.readInt(u64, sampler[0..8], .little);
    try std.testing.expectEqual(@as(u64, 7), bits & 7);
    try std.testing.expectEqual(@as(u64, 1), bits >> 48 & 7);
    try std.testing.expectEqual(@as(u64, 15 << 8), bits >> 20 & 0xFFF);
}

/// The first word of the state `state` packs to.
fn samplerWord(state: SamplerState) u64 {
    var into: [sampler_state_bytes]u8 = undefined;
    writeSamplerState(&into, state);
    for (into[8..]) |byte| std.debug.assert(byte == 0);
    return std.mem.readInt(u64, into[0..8], .little);
}

test "a fixed form's sampler state is the words it always had" {
    // What `writeSamplerState` wrote for every sampler until 1.140: the
    // filter both ways, the nearest level, every level, one wrap.
    for ([_]Filter{ .nearest, .bilinear }) |filter| for ([_]Wrap{ .repeat, .clamp }) |wrap| {
        const nearest: u64 = @intFromBool(filter == .nearest);
        const before: u64 = nearest | nearest << 1 | 1 << 2 | (15 << 8) << 20 |
            @intFromEnum(wrap) << 48 | @intFromEnum(wrap) << 51 | @intFromEnum(wrap) << 54;
        try std.testing.expectEqual(before, samplerWord(.{ .mag = filter, .min = filter, .wrap = @splat(wrap) }));
    };
}

test "every field of v3dv's pack_sampler_state lands where v3d_packet.xml has it" {
    const sampler = texture.Sampler{
        .mag_filter = .bilinear,
        .min_filter = .nearest,
        .mipmap = .linear,
        .wrap = .{ .mirrored_repeat, .clamp_to_border, .mirror_clamp_to_edge },
        .border = 0xFFFF_FFFF,
        .lod_bias = -1.5,
        .min_lod = 2.25,
        .max_lod = texture.lod_unclamped,
        .anisotropy = 6,
    };
    const made = samplerOf(&sampler, false).?;
    try std.testing.expect(!made.unnormalized);
    const word = samplerWord(made.state);
    try std.testing.expectEqual(@as(u64, 0), word & 1); // Mag filter Nearest
    try std.testing.expectEqual(@as(u64, 1), word >> 1 & 1); // Min filter Nearest
    try std.testing.expectEqual(@as(u64, 0), word >> 2 & 1); // Mip filter Nearest
    try std.testing.expectEqual(@as(u64, 1), word >> 3 & 1); // Anisotropy Enable
    try std.testing.expectEqual(@as(u64, 0), word >> 4 & 7); // Depth Compare Function, NEVER
    try std.testing.expectEqual(@as(u64, 0), word >> 7 & 1); // sRGB Disable
    try std.testing.expectEqual(@as(u64, 576), word >> 8 & 0xFFF); // Min Level-of-Detail, 2.25 in u4.8
    try std.testing.expectEqual(@as(u64, 15 << 8), word >> 20 & 0xFFF); // Max Level-of-Detail, held to 15
    try std.testing.expectEqual(@as(u64, 0xFE80), word >> 32 & 0xFFFF); // Fixed Bias, -1.5 in s8.8
    try std.testing.expectEqual(@as(u64, 2), word >> 48 & 7); // Wrap S, MIRROR
    try std.testing.expectEqual(@as(u64, 3), word >> 51 & 7); // Wrap T, BORDER
    try std.testing.expectEqual(@as(u64, 4), word >> 54 & 7); // Wrap R, MIRROR_ONCE
    try std.testing.expectEqual(@as(u64, 0), word >> 57 & 1); // Wrap I Border
    try std.testing.expectEqual(@as(u64, 2), word >> 58 & 7); // Border Color Mode, 1111
    try std.testing.expectEqual(@as(u64, 2), word >> 61 & 3); // Maximum Anisotropy, 8 for 6
}

test "anisotropy, the borders and the unnormalized bit as v3dv has them" {
    // v3dvx_device.c:231-239: 16 past 8, 8 past 4, 4 past 2, 2 below.
    const asked = [_]f32{ 1, 1.5, 2, 2.5, 4, 4.5, 8, 9, 16 };
    const codes = [_]?u2{ null, 0, 0, 1, 1, 2, 2, 3, 3 };
    for (asked, codes) |taps, code| {
        const made = samplerOf(&.{ .anisotropy = taps }, false).?;
        try std.testing.expectEqual(code, made.state.anisotropy);
        const word = samplerWord(made.state);
        try std.testing.expectEqual(@as(u64, @intFromBool(code != null)), word >> 3 & 1);
        try std.testing.expectEqual(@as(u64, code orelse 0), word >> 61 & 3);
    }
    // The three borders CreateSampler makes, the TMU's 0000, 0001, 1111.
    for ([_]u32{ 0, 0xFF00_0000, 0xFFFF_FFFF }, [_]u64{ 0, 1, 2 }) |border, mode| {
        const made = samplerOf(&.{ .wrap = @splat(.clamp_to_border), .border = border }, false).?;
        try std.testing.expectEqual(mode, samplerWord(made.state) >> 58 & 7);
    }
    try std.testing.expectEqual(@as(?Sampled, null), samplerOf(&.{ .wrap = @splat(.clamp_to_border), .border = 0x8040_2010 }, false));
    // In texels: bit 1 of parameter 1, beside the address (v3dv_uniforms.c:213-218).
    const table = samplerOf(&.{ .mag_filter = .nearest, .min_filter = .nearest, .max_lod = 0, .wrap = @splat(.clamp_to_edge), .unnormalized = true }, false).?;
    try std.testing.expect(table.unnormalized);
    try std.testing.expectEqual(@as(u64, 0), samplerWord(table.state) >> 20 & 0xFFF);
    try std.testing.expectEqual(@as(u32, 0x1000_0042), parameter1(0x1000_0040, true));
    try std.testing.expectEqual(@as(u32, 0x1000_0040), parameter1(0x1000_0040, false));
}

test "a comparing sampler is taken only where the program writes the reference, and a wild bias or a NaN stays in its field" {
    try std.testing.expectEqual(@as(?Sampled, null), samplerOf(&.{ .compare = .less }, false));
    try std.testing.expectEqual(@as(?Sampled, null), samplerOf(&.{ .compare = .never }, false));
    // Bits 4-6, Vulkan's function as v3dv packs it (v3dvx_device.c:262-264).
    try std.testing.expectEqual(@as(u64, 1), samplerWord(samplerOf(&.{ .compare = .less }, true).?.state) >> 4 & 7);
    try std.testing.expectEqual(@as(u64, 6), samplerWord(samplerOf(&.{ .compare = .greater_or_equal }, true).?.state) >> 4 & 7);
    try std.testing.expectEqual(@as(u64, 0), samplerWord(samplerOf(&.{}, true).?.state) >> 4 & 7);
    const wild = samplerWord(.{ .bias = 1e9, .min_lod = std.math.nan(f32), .max_lod = -3 });
    try std.testing.expectEqual(@as(u64, 0x7FFF), wild >> 32 & 0xFFFF);
    try std.testing.expectEqual(@as(u64, 0), wild >> 8 & 0xFFF);
    try std.testing.expectEqual(@as(u64, 0), wild >> 20 & 0xFFF);
    try std.testing.expectEqual(@as(u64, 0), wild >> 48 & 0x3FF_FFFF); // the wraps, the border and anisotropy untouched
    try std.testing.expectEqual(@as(u64, 0x8000), samplerWord(.{ .bias = -1e9 }) >> 32 & 0xFFFF);
    try std.testing.expectEqual(@as(u64, 0), samplerWord(.{ .bias = std.math.nan(f32) }) >> 32 & 0xFFFF);
}

test "an image of four samples is twice as wide and twice as high, level 0 in UIF however small, and a sample's texel is its place in the quad" {
    // Two by two RGBA8: four by four at four samples, which at one sample
    // would be lineartile (no more than a microtile across); here UIF,
    // aligned to a column of four blocks across and a block down
    // (v3dv_image.c:136-140, 180-183, 206-211).
    try std.testing.expectEqual(Kind.lineartile, layoutOf(4, 4, 4, 1, 1, false).levels[0].kind);
    const small = layoutOf(4, 2, 2, 1, 1, true);
    try std.testing.expectEqual(Kind.uif, small.levels[0].kind);
    try std.testing.expectEqual(@as(u32, 2), small.levels[0].width);
    try std.testing.expectEqual(@as(u32, 2), small.levels[0].height);
    try std.testing.expectEqual(@as(u32, 8), small.levels[0].padded_height);
    try std.testing.expectEqual(@as(u32, 32 * 4 * 8), small.bytes);
    try std.testing.expectEqual(@as(u32, 1), blocksDown(&small, 0));

    // 64 x 64 RGBA8 is the UIF level 128 x 128 is at one sample.
    const big = layoutOf(4, 64, 64, 1, 1, true);
    const twice = layoutOf(4, 128, 128, 1, 1, false);
    try std.testing.expectEqual(twice.levels[0].kind, big.levels[0].kind);
    try std.testing.expectEqual(twice.levels[0].padded_height, big.levels[0].padded_height);
    try std.testing.expectEqual(twice.bytes, big.bytes);
    try std.testing.expectEqual(@as(u32, 128 * 4 * 128), big.bytes);

    // R5G6B5, 30 x 20: 60 x 40, a microtile 8 x 4 at two bytes, so 64
    // across and 40 down, five rows of blocks and no padding.
    const narrow = layoutOf(2, 30, 20, 1, 1, true);
    try std.testing.expectEqual(Kind.uif, narrow.levels[0].kind);
    try std.testing.expectEqual(@as(u32, 40), narrow.levels[0].padded_height);
    try std.testing.expectEqual(@as(u32, 64 * 2 * 40), narrow.bytes);

    // The samples across the quad and then down, as v3d's compiler
    // fetches sample s (v3d_nir_lower_txf_ms.c:46-51).
    const quads = [_][2]u32{ .{ 6, 10 }, .{ 7, 10 }, .{ 6, 11 }, .{ 7, 11 } };
    for (quads, 0..) |want, sample| try std.testing.expectEqual(want, sampleTexel(3, 5, @intCast(sample)));
    // Every sample of every pixel its own four bytes, inside the level.
    var seen = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer seen.deinit();
    for (0..20) |y| for (0..30) |x| for (0..4) |sample| {
        const at = sampleTexel(@intCast(x), @intCast(y), @intCast(sample));
        const offset = texelOffset(&narrow, 0, at[0], at[1]);
        try std.testing.expect(offset + 2 <= narrow.bytes);
        try std.testing.expect(!(try seen.getOrPut(offset)).found_existing);
    };
}

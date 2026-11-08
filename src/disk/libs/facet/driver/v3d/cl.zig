// SPDX-License-Identifier: MIT
//! The control lists' packets, as many of them as are used here: a byte for
//! the packet and its fields little-endian after it, by Mesa's
//! src/broadcom/cle/v3d_packet.xml for version 7.1.

/// Where packets are written, and what the V3D calls that place.
pub const List = struct {
    at: [*]u8,
    address: u32,
    used: u32 = 0,

    pub fn here(list: *const List) u32 {
        return list.address + list.used;
    }

    pub fn byte(list: *List, value: u8) void {
        list.at[list.used] = value;
        list.used += 1;
    }

    pub fn half(list: *List, value: u16) void {
        list.byte(@truncate(value));
        list.byte(@truncate(value >> 8));
    }

    pub fn word(list: *List, value: u32) void {
        list.half(@truncate(value));
        list.half(@truncate(value >> 16));
    }

    pub fn double(list: *List, value: u64) void {
        list.word(@truncate(value));
        list.word(@truncate(value >> 32));
    }
};

// --- packets of no fields ---------------------------------------------------

pub const FLUSH: u8 = 4;
pub const START_TILE_BINNING: u8 = 6;
pub const END_OF_RENDERING: u8 = 13;
pub const RETURN_FROM_SUB_LIST: u8 = 18;
pub const FLUSH_VCD_CACHE: u8 = 19;
pub const CLEAR_RENDER_TARGETS: u8 = 25;
pub const END_OF_LOADS: u8 = 26;
pub const END_OF_TILE_MARKER: u8 = 27;
pub const TILE_COORDINATES_IMPLICIT: u8 = 125;

// --- rendering --------------------------------------------------------------

const TILE_RENDERING_MODE_CFG: u8 = 121;

pub const OUTPUT_RGBA8: u64 = 27;
pub const OUTPUT_BGR565: u64 = 7;
/// How a depth or a stencil plane lies in memory, for a store or a load of
/// the tiles' own (since 1.47).
pub const OUTPUT_D16: u64 = 42;
pub const OUTPUT_S8: u64 = 44;
pub const STORE_NONE: u64 = 8;
pub const STORE_RENDER_TARGET_0: u64 = 0;
/// The tiles' depth and their stencil, which are stored and loaded as the
/// render target is.
pub const STORE_Z: u64 = 9;
pub const STORE_STENCIL: u64 = 10;
pub const LIST_TRIANGLES: u8 = 2;
/// The first block of each tile's list and the next ones, as 128 and 64
/// bytes: what the binner is told and the renderer too.
pub const TILE_INITIAL_BLOCK_ENUM: u32 = 1;
pub const TILE_OVERFLOW_BLOCK_ENUM: u32 = 0;

pub fn log2Tile(pixels: u32) u32 {
    return switch (pixels) {
        8 => 0,
        16 => 1,
        32 => 2,
        else => 3,
    };
}

/// The common part: first of the rendering mode's packets. A depth buffer
/// of 16 bits, in the tiles alone, or none. The coarse early test stays off:
/// each pixel is still tested before its program runs.
pub fn renderingCommon(list: *List, width: u32, height: u32, tile: u32, depth: bool) void {
    const log2 = @as(u64, log2Tile(tile));
    const no_depth_buffer: u64 = @as(u64, @intFromBool(!depth)) << 44;
    const depth_16: u64 = 2 << 47;
    list.byte(TILE_RENDERING_MODE_CFG);
    list.double(@as(u64, width) << 8 | @as(u64, height) << 24 | no_depth_buffer | 1 << 46 | depth_16 | log2 << 52 | log2 << 55);
}

/// Render target 0, at 32 bits a pixel and 8 bits of normalized channel,
/// and the colour it clears to.
pub fn renderTarget0(list: *List, tile: u32, clear: u32) void {
    const stride: u64 = tile / 2;
    const type_8: u64 = 8;
    list.byte(TILE_RENDERING_MODE_CFG);
    list.double(2 | (stride - 1) << 18 | type_8 << 27 | @as(u64, clear) << 32);
}

/// The last of the rendering mode's packets: depth and stencil's clear.
pub fn zsClear(list: *List, depth: f32, stencil: u32) void {
    const bits: u32 = @bitCast(depth);
    list.byte(TILE_RENDERING_MODE_CFG);
    list.double(1 | @as(u64, stencil) << 8 | @as(u64, bits) << 16);
}

pub fn tileListInitialBlock(list: *List) void {
    list.byte(126);
    list.byte(1 << 2 | TILE_INITIAL_BLOCK_ENUM);
}

pub fn tileListBase(list: *List, address: u32) void {
    list.byte(123);
    list.word(address);
}

pub fn supertileCfg(list: *List, w: u32, h: u32, frame_w: u32, frame_h: u32, tiles_x: u32, tiles_y: u32) void {
    list.byte(122);
    list.double(@as(u64, w - 1) | @as(u64, h - 1) << 8 | @as(u64, frame_w) << 16 | @as(u64, frame_h) << 24 |
        @as(u64, tiles_x) << 32 | @as(u64, tiles_y) << 44);
}

pub fn tileCoordinates(list: *List, column: u32, row: u32) void {
    list.byte(124);
    list.byte(@truncate(column));
    list.byte(@truncate(column >> 8 | row << 4));
    list.byte(@truncate(row >> 4));
}

pub fn supertileCoordinates(list: *List, column: u32, row: u32) void {
    list.byte(23);
    list.byte(@truncate(column));
    list.byte(@truncate(row));
}

/// How the image a store or a load reaches lies: rows of pixels, or a
/// level of a texture in the tiling its size gives it (`tiling.Kind`),
/// as v3dv stores into a slice of an image (v3dvx_cmd_buffer.c:396-406;
/// v3d_packet.xml:108-115). The tilings since 1.142.
pub const MEMORY_RASTER: u64 = 0;
pub const MEMORY_LINEARTILE: u64 = 1;
pub const MEMORY_UBLINEAR_1: u64 = 2;
pub const MEMORY_UBLINEAR_2: u64 = 3;
pub const MEMORY_UIF: u64 = 4;
pub const MEMORY_UIF_XOR: u64 = 5;

/// A store to an image, or to none at all. `stride` is "Height in UB or
/// Stride": the bytes of a row in rows, a UIF level's height in UIF
/// blocks, and nothing for the other tilings.
pub fn store(list: *List, buffer: u64, format: u64, swap_rb: bool, address: u32, stride: u32, memory: u64) void {
    list.byte(29);
    list.double(buffer | memory << 4 | format << 12 | @as(u64, @intFromBool(swap_rb)) << 20 | @as(u64, stride) << 28);
    list.word(address);
}

/// A buffer of the tiles loaded from an image, as `store` reaches one:
/// the render target, or the depth or the stencil.
pub fn load(list: *List, buffer: u64, format: u64, swap_rb: bool, address: u32, stride: u32, memory: u64) void {
    list.byte(30);
    list.double(buffer | memory << 4 | format << 12 | @as(u64, @intFromBool(swap_rb)) << 20 | @as(u64, stride) << 28);
    list.word(address);
}

pub fn genericTileList(list: *List, start: u32, end: u32) void {
    list.byte(20);
    list.word(start);
    list.word(end);
}

pub fn primListFormat(list: *List, kind: u8) void {
    list.byte(56);
    list.byte(kind);
}

pub fn setInstanceId(list: *List, id: u32) void {
    list.byte(54);
    list.word(id);
}

pub fn branchToImplicitTileList(list: *List) void {
    list.byte(21);
    list.byte(0);
}

// --- binning ----------------------------------------------------------------

pub fn binningMode(list: *List, width: u32, height: u32, tile: u32) void {
    const log2 = @as(u64, log2Tile(tile));
    list.byte(120);
    list.double(@as(u64, TILE_INITIAL_BLOCK_ENUM) << 2 | @as(u64, TILE_OVERFLOW_BLOCK_ENUM) << 4 |
        log2 << 8 | log2 << 11 | @as(u64, width - 1) << 32 | @as(u64, height - 1) << 48);
}

/// Where the hardware counts the samples that passed the tests and the
/// fragment program kept: a word of its own, which it adds to as the tiles
/// are drawn. Zero stops the counting, so that what another job left is not
/// gone on with (since 1.47).
pub fn occlusionQuery(list: *List, address: u32) void {
    list.byte(92);
    list.word(address);
}

/// No occlusion query: what another job left is not to go on counting.
pub fn occlusionQueryOff(list: *List) void {
    occlusionQuery(list, 0);
}

pub fn clipWindow(list: *List, left: u32, bottom: u32, width: u32, height: u32) void {
    list.byte(107);
    list.double(@as(u64, left) | @as(u64, bottom) << 16 | @as(u64, width) << 32 | @as(u64, height) << 48);
}

pub const COMPARE_ALWAYS: u32 = 7;
const Z_CLIP_NONE: u32 = 0;
const Z_CLIP_ZERO_TO_ONE: u32 = 2;

pub const Cfg = struct {
    /// The faces drawn: forward is the way `clockwise` says.
    forward: bool = true,
    reverse: bool = true,
    clockwise: bool = false,
    /// As facet.CompareOp numbers them, from never to always.
    compare: u32 = COMPARE_ALWAYS,
    depth_write: bool = false,
    stencil: bool = false,
    blend: bool = false,
    /// Whether a triangle moves its depth by what `depthOffset` said
    /// (since 1.47).
    biased: bool = false,
    /// Whether a pixel is drawn only where the depth already in the tile
    /// lies between what `depthBounds` said.
    bounded: bool = false,
    /// Whether what lies past the near plane is drawn all the same, its
    /// depth held inside the range `clipperZLimits` gave: clamping is also
    /// not clipping, so the clip to the z planes goes off with it, as
    /// Vulkan has a depth clamp.
    clamped: bool = false,
};

pub fn cfgBits(list: *List, cfg: Cfg) void {
    const value: u32 = @as(u32, @intFromBool(cfg.forward)) |
        @as(u32, @intFromBool(cfg.reverse)) << 1 |
        @as(u32, @intFromBool(cfg.clockwise)) << 2 |
        @as(u32, @intFromBool(cfg.biased)) << 3 |
        @as(u32, @intFromBool(cfg.bounded)) << 5 |
        @as(u32, @intFromBool(cfg.clamped)) << 10 |
        cfg.compare << 12 |
        @as(u32, @intFromBool(cfg.depth_write)) << 15 |
        @as(u32, @intFromBool(cfg.stencil)) << 18 |
        @as(u32, @intFromBool(cfg.blend)) << 19 |
        (if (cfg.clamped) Z_CLIP_NONE else Z_CLIP_ZERO_TO_ONE) << 22;
    list.byte(96);
    list.byte(@truncate(value));
    list.byte(@truncate(value >> 8));
    list.byte(@truncate(value >> 16));
}

/// What a triangle adds to its depth where `Cfg.biased` says: `units` of
/// the depth buffer's smallest difference and `factor` of the triangle's
/// steepest slope, as Vulkan's constant factor and slope factor, each held
/// inside `limit` where that is not 0. The two are `f187`, the top 16 bits
/// of a float; the limit is a float. (Since 1.47.)
pub fn depthOffset(list: *List, factor: f32, units: f32, limit: f32) void {
    list.byte(106);
    list.word(f187(factor) | f187(units) << 16);
    list.word(@bitCast(limit));
}

/// A float's top 16 bits: one of eight bits of exponent and seven of
/// mantissa, which is how the hardware takes a small number (Mesa's
/// `f187`).
fn f187(value: f32) u32 {
    return @as(u32, @bitCast(value)) >> 16;
}

/// The depth a pixel's own must lie between to be drawn, where
/// `Cfg.bounded` says. (Since 1.47.)
pub fn depthBounds(list: *List, least: f32, most: f32) void {
    list.byte(93);
    list.word(@bitCast(least));
    list.word(@bitCast(most));
}

/// How render target 0 is written: factors and modes as facet.library
/// numbers them, which is as the hardware does.
pub const Mixing = struct {
    src_color: u32 = 1,
    dst_color: u32 = 0,
    color_mode: u32 = 0,
    src_alpha: u32 = 1,
    dst_alpha: u32 = 0,
    alpha_mode: u32 = 0,
    /// Red, green, blue and alpha, 0 to 1.
    constants: [4]f32 = .{ 0, 0, 0, 0 },
    /// Red in bit 0: the channels written.
    channels: u32 = 0xF,
};

/// Render target 0 blended as `mixing` says.
pub fn blend(list: *List, mixing: *const Mixing) void {
    list.byte(83);
    list.byte(1);
    list.byte(84);
    const color = mixing.dst_color << 4 | mixing.src_color;
    const alpha = mixing.dst_alpha << 4 | mixing.src_alpha;
    list.word(1 << 24 | color << 16 | mixing.color_mode << 12 | alpha << 4 | mixing.alpha_mode);
    list.byte(86);
    list.word(half(mixing.constants[0]) | half(mixing.constants[1]) << 16);
    list.word(half(mixing.constants[2]) | half(mixing.constants[3]) << 16);
}

fn half(value: f32) u32 {
    return @as(u16, @bitCast(@as(f16, @floatCast(value))));
}

/// The channels of render target 0 written, red in bit 0, and all of the
/// others: a bit here says not to.
pub fn colorWriteMasks(list: *List, channels: u32) void {
    list.byte(87);
    list.word(~channels & 0xF);
}

/// A face's stencil test, the operations and compare as the hardware numbers
/// them.
pub const StencilFace = struct {
    fail: u32,
    pass: u32,
    depth_fail: u32,
    compare: u32,
    compare_mask: u8,
    write_mask: u8,
    reference: u8,
};

/// What the front faces, or the back ones, are tested with.
pub fn stencilCfg(list: *List, face: *const StencilFace, front: bool) void {
    list.byte(80);
    list.word(@as(u32, face.reference) |
        @as(u32, face.compare_mask) << 8 |
        face.compare << 16 |
        face.fail << 19 |
        face.depth_fail << 22 |
        face.pass << 25 |
        @as(u32, @intFromBool(front)) << 28 |
        @as(u32, @intFromBool(!front)) << 29);
    list.byte(face.write_mask);
}

/// One sample's worth of coverage, in all 4 of its bits.
pub fn sampleState(list: *List) void {
    const one_as_f187: u32 = 0x3F80;
    list.byte(91);
    list.word(0xF | one_as_f187 << 16);
}

pub const ZERO_ALL_CENTROID_FLAGS: u8 = 88;
pub const ZERO_ALL_FLAT_SHADE_FLAGS: u8 = 97;
pub const ZERO_ALL_NON_PERSPECTIVE_FLAGS: u8 = 99;

pub fn pointSize(list: *List, size: f32) void {
    list.byte(104);
    list.word(@bitCast(size));
}

pub fn lineWidth(list: *List, width: f32) void {
    list.byte(105);
    list.word(@bitCast(width));
}

/// Half the viewport, in 1/64 of a pixel.
pub fn clipperXy(list: *List, half_width: f32, half_height: f32) void {
    list.byte(110);
    list.word(@bitCast(half_width));
    list.word(@bitCast(half_height));
}

pub fn clipperZ(list: *List, scale: f32, offset: f32) void {
    list.byte(111);
    list.word(@bitCast(scale));
    list.word(@bitCast(offset));
}

pub fn clipperZLimits(list: *List, least: f32, most: f32) void {
    list.byte(109);
    list.word(@bitCast(least));
    list.word(@bitCast(most));
}

/// Where the viewport's middle is: 14 bits and 8 of fraction, which cannot
/// be below 0, and a coarse part of 64 pixels that can.
pub fn viewportOffset(list: *List, x: f32, y: f32) void {
    list.byte(108);
    list.word(viewportPart(x));
    list.word(viewportPart(y));
}

fn viewportPart(at: f32) u32 {
    var fine = at;
    var coarse: i32 = 0;
    if (fine < 0) {
        const blocks: i32 = @intFromFloat(@ceil(-fine / 64));
        fine += 64 * @as(f32, @floatFromInt(blocks));
        coarse = -blocks;
    }
    const fine_bits: u32 = @intFromFloat(fine * 256);
    const coarse_bits: u32 = @bitCast(coarse);
    return fine_bits & 0x3F_FFFF | coarse_bits << 22;
}

pub fn vcmCacheSize(list: *List, binning: u32, rendering: u32) void {
    list.byte(71);
    list.byte(@truncate(binning | rendering << 4));
}

/// A record of 32-byte alignment and the attribute records after it.
pub fn glShaderState(list: *List, record: u32, attributes: u32) void {
    list.byte(64);
    list.word(record | attributes);
}

pub const PRIM_TRIANGLES: u8 = 4;
const INDEX_BUFFER_SETUP: u8 = 44;

/// Where the indices of a draw are, in 32 bits each.
pub fn indexBufferSetup(list: *List, address: u32, bytes: u32) void {
    list.byte(INDEX_BUFFER_SETUP);
    list.word(address);
    list.word(bytes);
}

/// `count` triangles' corners from the first index of the index buffer.
pub fn indexedPrimList(list: *List, mode: u8, count: u32) void {
    const index_32: u8 = 2 << 6;
    list.byte(32);
    list.byte(mode | index_32);
    list.word(count);
    list.word(0);
}

/// On to the list at `address`.
pub fn branch(list: *List, address: u32) void {
    list.byte(16);
    list.word(address);
}

pub fn vertexArrayPrims(list: *List, mode: u8, count: u32, first: u32) void {
    list.byte(36);
    list.byte(mode);
    list.word(count);
    list.word(first);
}

// --- the shader state in memory ---------------------------------------------

/// The record of V3D 7.1.10 (the BCM2712's D0 stepping), which has draw
/// index and base vertex and so its fields where others have them not:
/// each program threadable, input and output sharing their place in the
/// VPM (as Mesa does, for all versions), clipping on.
pub const shader_record_bytes = 32;

pub const Programs = struct {
    fragment: u32,
    fragment_uniforms: u32,
    vertex: u32,
    vertex_uniforms: u32,
    coordinate: u32,
    coordinate_uniforms: u32,
    varyings: u32,
    /// What the fragment program says of itself, as v3dv's
    /// pack_shader_state_record has it from the compiler's prog data
    /// (v3dvx_pipeline.c:461-487, 554-562). The defaults are what the
    /// programs written by hand need (qpu.zig).
    fragment_threads: u8 = 4,
    /// It reads W at the pixel's centre other than for a varying.
    center_w: bool = false,
    /// Its first thread switch, and not its last, is where it waits on
    /// the scoreboard.
    lock_scoreboard_on_first_thrsw: bool = false,
    /// It writes Z, and early Z is to be off for it: what a program that
    /// drops pixels says (v3dvx_pipeline.c:454-459). Since 1.139.
    writes_z: bool = false,
    disable_ez: bool = false,
};

/// Values a program writes: its segment's size in sectors of 8.
const coordinate_values: u32 = 6;

pub fn shaderRecord(list: *List, programs: Programs) void {
    const clipping: u32 = 1 << 1;
    const writes_z: u32 = @as(u32, @intFromBool(programs.writes_z)) << 12;
    const disable_ez: u32 = @as(u32, @intFromBool(programs.disable_ez)) << 13;
    const center_w: u32 = @as(u32, @intFromBool(programs.center_w)) << 15;
    const scoreboard_on_first: u32 = @as(u32, @intFromBool(programs.lock_scoreboard_on_first_thrsw)) << 20;
    const no_implicit_varyings: u32 = 1 << 21;
    list.word(clipping | writes_z | disable_ez | center_w | scoreboard_on_first | no_implicit_varyings | programs.varyings << 24);
    // Size in sectors, the input's 0 for sharing the output's, and 1 less
    // than the 1 required in play.
    const coordinate_sectors = (coordinate_values + 7) / 8;
    const vertex_sectors = (4 + programs.varyings + 7) / 8;
    list.word(coordinate_sectors | vertex_sectors << 16);
    const threadable: u32 = 1 << 0;
    const final_section: u32 = 1 << 1;
    // A fragment program never starts in its last section: see qpu.zig,
    // and Mesa's single_seg, which is !last_thrsw (vir.c:1041), where a
    // fragment program always has one (vir_emit_last_thrsw). It is
    // threadable four ways only where it was compiled for four threads.
    const four_ways: u32 = @intFromBool(programs.fragment_threads == 4);
    list.word(programs.fragment | four_ways * threadable);
    list.word(programs.fragment_uniforms);
    list.word(programs.vertex | threadable | final_section);
    list.word(programs.vertex_uniforms);
    list.word(programs.coordinate | threadable | final_section);
    list.word(programs.coordinate_uniforms);
}

/// An attribute record: `values` of 32 bits each, copied as they are, of
/// which the programs read the first `by_coordinate` and `by_vertex`.
pub fn attribute(list: *List, address: u32, values: u32, by_coordinate: u32, by_vertex: u32, stride: u32) void {
    const type_int: u32 = 6 << 2;
    const read_as_int: u32 = 1 << 7;
    list.word(address);
    list.word((values & 3) | type_int | read_as_int | by_coordinate << 8 | by_vertex << 12);
    list.word(stride);
    list.word(0xFF_FFFF);
}

const std = @import("std");

test "the packets have Mesa's lengths and its fields" {
    var memory: [64]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x1000 };

    renderingCommon(&list, 1280, 720, 64, false);
    try std.testing.expectEqual(@as(u32, 9), list.used);
    // Image size at 8 and 24, early-Z off at 46, log2 of the tile at 52, 55.
    try std.testing.expectEqual(@as(u8, 121), memory[0]);
    const common = std.mem.readInt(u64, memory[1..9], .little);
    try std.testing.expectEqual(@as(u64, 1280), common >> 8 & 0xFFFF);
    try std.testing.expectEqual(@as(u64, 720), common >> 24 & 0xFFFF);
    try std.testing.expectEqual(@as(u64, 1), common >> 46 & 1);
    try std.testing.expectEqual(@as(u64, 3), common >> 52 & 7);
    try std.testing.expectEqual(@as(u64, 3), common >> 55 & 7);

    list.used = 0;
    store(&list, STORE_RENDER_TARGET_0, OUTPUT_RGBA8, true, 0x12345000, 5120, MEMORY_RASTER);
    try std.testing.expectEqual(@as(u32, 13), list.used);
    const fields = std.mem.readInt(u64, memory[1..9], .little);
    try std.testing.expectEqual(OUTPUT_RGBA8, fields >> 12 & 0x3F);
    try std.testing.expectEqual(@as(u64, 1), fields >> 20 & 1);
    try std.testing.expectEqual(@as(u64, 5120), fields >> 28 & 0xFFFFF);
    try std.testing.expectEqual(MEMORY_RASTER, fields >> 4 & 7);
    try std.testing.expectEqual(@as(u32, 0x12345000), std.mem.readInt(u32, memory[9..13], .little));

    // A depth into a UIF level, as v3dv stores into a slice of its image
    // (v3dvx_cmd_buffer.c:396-406): the tiling at bit 4, the height in
    // UIF blocks where a raster store has its stride.
    list.used = 0;
    store(&list, STORE_Z, OUTPUT_D16, false, 0x2000_0000, 12, MEMORY_UIF_XOR);
    const tiled = std.mem.readInt(u64, memory[1..9], .little);
    try std.testing.expectEqual(STORE_Z, tiled & 0xF);
    try std.testing.expectEqual(MEMORY_UIF_XOR, tiled >> 4 & 7);
    try std.testing.expectEqual(OUTPUT_D16, tiled >> 12 & 0x3F);
    try std.testing.expectEqual(@as(u64, 12), tiled >> 28 & 0xFFFFF);

    list.used = 0;
    tileCoordinates(&list, 0x123, 0x456);
    try std.testing.expectEqual(@as(u32, 4), list.used);
    try std.testing.expectEqual(@as(u32, 0x456123), std.mem.readInt(u32, memory[0..4], .little) >> 8);
}

test "the shader record and an attribute are the size the hardware reads" {
    var memory: [64]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x2000 };
    shaderRecord(&list, .{
        .fragment = 0x100,
        .fragment_uniforms = 0x200,
        .vertex = 0x300,
        .vertex_uniforms = 0x400,
        .coordinate = 0x500,
        .coordinate_uniforms = 0x600,
        .varyings = 2,
    });
    try std.testing.expectEqual(@as(u32, shader_record_bytes), list.used);
    try std.testing.expectEqual(@as(u32, 0x101), std.mem.readInt(u32, memory[8..12], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, memory[0..4], .little) >> 24);
    list.used = 0;
    attribute(&list, 0x700, 4, 2, 4, 32);
    try std.testing.expectEqual(@as(u32, 16), list.used);
    // Vec size 4 as 0, the int type, read as int, 2 and 4 values read.
    try std.testing.expectEqual(@as(u32, 0b0100_0010_1001_1000), std.mem.readInt(u32, memory[4..8], .little));
}

test "a program compiled through Mesa's back end says its threads, its W and its scoreboard" {
    var memory: [64]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x2000 };
    const programs: Programs = .{
        .fragment = 0x100,
        .fragment_uniforms = 0x200,
        .vertex = 0x300,
        .vertex_uniforms = 0x400,
        .coordinate = 0x500,
        .coordinate_uniforms = 0x600,
        .varyings = 3,
    };
    shaderRecord(&list, programs);
    // As the programs written by hand have it: clipping, no implicit
    // varyings, and nothing else of the fragment program's.
    try std.testing.expectEqual(@as(u32, 1 << 1 | 1 << 21 | 3 << 24), std.mem.readInt(u32, memory[0..4], .little));

    var mesa = programs;
    mesa.fragment_threads = 2;
    mesa.center_w = true;
    mesa.lock_scoreboard_on_first_thrsw = true;
    list.used = 0;
    shaderRecord(&list, mesa);
    // The Draw Index record's bits 15 and 20 (v3d_packet.xml, "GL Shader
    // State Record Draw Index", min_ver 71), and two threads, so not
    // four-way threadable.
    try std.testing.expectEqual(@as(u32, 1 << 1 | 1 << 15 | 1 << 20 | 1 << 21 | 3 << 24), std.mem.readInt(u32, memory[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x100), std.mem.readInt(u32, memory[8..12], .little));

    // A program that drops pixels: "Fragment shader does Z writes" at 12
    // and "Turn off early-z test" at 13.
    var drops = programs;
    drops.writes_z = true;
    drops.disable_ez = true;
    list.used = 0;
    shaderRecord(&list, drops);
    try std.testing.expectEqual(@as(u32, 1 << 1 | 1 << 12 | 1 << 13 | 1 << 21 | 3 << 24), std.mem.readInt(u32, memory[0..4], .little));
}

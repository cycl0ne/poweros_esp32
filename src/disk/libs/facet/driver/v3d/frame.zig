// SPDX-License-Identifier: MIT
//! A frame's two lists: the binner's, which says what is drawn, and the
//! renderer's, which clears each tile or loads it, draws what was binned
//! for it and stores it in rows of pixels (v3dx_rcl.c and v3dx_emit.c in
//! Mesa).

const cl = @import("cl.zig");
const List = cl.List;

/// A frame of one sample's tiles: 64 x 64 at 32 bits a pixel, 16 KiB of
/// the colour buffer, what `chooseTile` gives for facet's one render
/// target. The device reports it as its tile (driver.zig).
pub const tile_pixels: u32 = 64;

/// The tile buffer's memory at 7.1: the colour's, the depth's, and the
/// depth's smaller buffer beside it (v3d_util.c:100-102).
const tlb_color_bytes: u32 = 16 * 1024;
const tlb_depth_bytes: u32 = 16 * 1024;
const tlb_aux_depth_bytes: u32 = 8 * 1024;

/// Whether a tile of `pixels` fits the tile buffer, at `color_bytes` and
/// `depth_bytes` a pixel: with the depth in its smaller buffer, which lends
/// the depth's main buffer to the colour, or else each in its own
/// (`tile_size_valid`, v3d_util.c:104-117).
fn tileFits(pixels: u32, color_bytes: u32, depth_bytes: u32) bool {
    if (pixels * depth_bytes <= tlb_aux_depth_bytes and pixels * color_bytes <= tlb_color_bytes + tlb_depth_bytes) return true;
    return pixels * depth_bytes <= tlb_depth_bytes and pixels * color_bytes <= tlb_color_bytes;
}

/// The largest tile a frame's samples fit in, at `color_bytes` a pixel
/// over all its render targets, 4 for each 32 bits of internal colour as
/// v3dv sums them (v3dv_pass.c:371): `v3d_choose_tile_size`'s 7.1 branch
/// (v3d_util.c:119-182), from 64 x 64 down. Four samples hold four times
/// the colour and the depth. Double buffering, which facet does not use,
/// is left out.
pub fn chooseTile(color_bytes: u32, four: bool) cl.Tile {
    const sizes = [_][2]u32{ .{ 64, 64 }, .{ 64, 32 }, .{ 32, 32 }, .{ 32, 16 }, .{ 16, 16 }, .{ 16, 8 }, .{ 8, 8 } };
    const samples: u32 = if (four) 4 else 1;
    for (sizes) |size| {
        if (tileFits(size[0] * size[1], color_bytes * samples, 4 * samples)) return .{ .width = size[0], .height = size[1] };
    }
    return .{ .width = 8, .height = 8 };
}

comptime {
    const one = chooseTile(4, false);
    if (one.width != tile_pixels or one.height != tile_pixels) @compileError("a frame of one sample's tile is not tile_pixels");
}
/// How many supertiles a frame may have, and not this many in a row.
const most_supertiles: u32 = 256;

/// Batches of 16 vertices the VCM caches: what Mesa's sum comes to for any
/// program here, each a small part of half the VPM.
const vcm_batches: u32 = 4;

/// Where one tile's list lies: what `writeTileList` wrote, for the frame's
/// list to branch each tile to.
pub const TileList = struct {
    start: u32,
    end: u32,
};

/// A rectangle of pixels.
pub const Area = struct {
    left: u32,
    top: u32,
    right: u32,
    bottom: u32,
};

/// A plane of the tiles kept in an image's rows: the depth or the stencil,
/// loaded as a tile starts and stored as it ends
/// (`Capabilities.stored_depth`, `stored_stencil`, since 1.47).
/// The hardware stores a plane as its own pixels one after another, so the
/// image's format holds that plane alone - `d16_unorm` or `s8_uint` - and a
/// format that holds both is refused on this device.
pub const Kept = struct {
    /// Which buffer of the tiles: `cl.STORE_Z` or `cl.STORE_STENCIL`.
    buffer: u64,
    /// How the image holds it: `cl.OUTPUT_D16` or `cl.OUTPUT_S8`.
    format: u64,
    image: u32,
    /// Its rows' bytes, or for a UIF level its height in UIF blocks.
    stride: u32,
    /// How it lies: rows, or a texture's level in its tiling, which a
    /// depth image sampled as well is (`cl.MEMORY_RASTER` and the rest,
    /// since 1.142).
    memory: u64 = cl.MEMORY_RASTER,
    load: bool = false,
    store: bool = false,
};

pub const Frame = struct {
    width: u32,
    height: u32,
    image: u32,
    /// Its rows' bytes, or for a UIF level its height in UIF blocks.
    stride: u32,
    /// How the image lies: rows, or the level of four samples a device
    /// keeps them together in (`cl.MEMORY_UIF`, `_image.Image.quads`,
    /// since 1.147).
    memory: u64 = cl.MEMORY_RASTER,
    /// How the image holds a pixel.
    format: u64 = cl.OUTPUT_RGBA8,
    /// The image is blue first, not red.
    swap_rb: bool,
    /// As it lies in the tile buffer: red in the low byte.
    clear: u32,
    /// The binner's lists, or memory the renderer will not read.
    tile_lists: u32,
    /// Whether the binner ran, so that a tile has a list to draw.
    binned: bool,
    /// The tiles start with what the image holds, not the colour cleared.
    load: bool = false,
    /// With `load` and an `area`: the area is cleared, so a tile the area
    /// covers whole is not loaded after all - every pixel of it is either
    /// the colour cleared or something drawn over it, and reading the image
    /// for it is work thrown away. Only the tiles at the area's edge, which
    /// must keep the pixels outside it, are loaded.
    clear_inside: bool = false,
    /// There is a depth buffer, cleared to this; it stays in the tiles.
    depth: bool = false,
    clear_depth: f32 = 1.0,
    /// And a stencil, the same.
    stencil: bool = false,
    clear_stencil: u32 = 0,
    /// The depth or the stencil kept in memory, or null for a pass whose
    /// own live in the tiles alone.
    kept: ?Kept = null,
    /// The tiles rendered: any others of the image stay as they are. Null
    /// for all.
    area: ?Area = null,
    /// The tiles hold four samples a pixel: each draw then writes its
    /// sample mask, and takes its coverage at four places
    /// (`writeDrawState`), and every load and store moves all four
    /// samples of the colour and of what is kept (`writeTileList`).
    four: bool = false,
    /// The tile's size, `chooseTile`'s for the frame's colour and samples.
    tile: cl.Tile = .{ .width = tile_pixels, .height = tile_pixels },
    /// In a frame of four, the rows the colour's samples are averaged into
    /// as each tile ends, or null where it has no resolve attachment or
    /// one the tiles cannot write (`tilesInArea`; since 1.148,
    /// docs/facet-vulkan10.md item 61, step V5).
    resolve: ?Resolve = null,
    /// The frame has a colour: render target 0 is `image`. Without one
    /// (a subpass of no colour attachment, since 1.150) its one render
    /// target is the unused one v3dv configures (`cl.unusedRenderTarget`),
    /// and a tile loads, stores and clears no colour; `image`, `stride`,
    /// `format`, `clear`, `load`, `clear_inside` and `resolve` say
    /// nothing.
    color: bool = true,

    pub fn tilesX(frame: *const Frame) u32 {
        return (frame.width + frame.tile.width - 1) / frame.tile.width;
    }

    pub fn tilesY(frame: *const Frame) u32 {
        return (frame.height + frame.tile.height - 1) / frame.tile.height;
    }
};

/// Where a frame of four resolves its colour: rows of one sample a pixel,
/// of the colour's format, as Vulkan has a resolve attachment
/// (VUID-VkSubpassDescription-pResolveAttachments-00850).
pub const Resolve = struct {
    image: u32,
    /// Its rows' bytes.
    stride: u32,
};

/// The supertiles a frame is rendered by: each `width` by `height` tiles,
/// `across` by `down` of them over the frame, no more than the 256 the
/// hardware's frame holds, grown a tile at a time across and down in turn
/// until they fit, as v3dv grows its own (`job_compute_frame_tiling`,
/// v3dv_cmd_buffer.c:421-446, which has the same bound).
pub const Supertiles = struct { width: u32, height: u32, across: u32, down: u32 };

pub fn supertilesOf(frame: *const Frame) Supertiles {
    const tiles_x = frame.tilesX();
    const tiles_y = frame.tilesY();
    var at = Supertiles{ .width = 1, .height = 1, .across = tiles_x, .down = tiles_y };
    while (at.across >= most_supertiles or at.down >= most_supertiles or at.across * at.down > most_supertiles) {
        if (at.width < at.height) at.width += 1 else at.height += 1;
        at.across = (tiles_x + at.width - 1) / at.width;
        at.down = (tiles_y + at.height - 1) / at.height;
    }
    return at;
}

/// Whether every tile the renderer renders lies inside the frame's area,
/// or over the frame's edge: v3dv's render area "tile aligned"
/// (`v3dv_subpass_area_is_tile_aligned`, v3dv_pass.c:663-683, its
/// framebuffer padded at the edge, v3dv_device.c:3178). Aligned to the
/// supertile rather than the tile: the renderer renders every supertile
/// the area touches, whole (`writeRender`, as v3dv's
/// `cmd_buffer_emit_render_pass_rcl` does, v3dvx_cmd_buffer.c:771-795),
/// and a tile's store writes all its pixels. Where it is so, the tiles
/// can resolve the colour into its resolve attachment (since 1.148), and
/// store a kept depth or stencil they did not load (since 1.151): where
/// it is not, a tile sticking out of the area would write what Vulkan has
/// the pass leave alone. A frame of all of its tiles always is.
pub fn tilesInArea(frame: *const Frame) bool {
    const area = frame.area orelse return true;
    const at = supertilesOf(frame);
    const across = at.width * frame.tile.width;
    const down = at.height * frame.tile.height;
    return area.left % across == 0 and area.top % down == 0 and
        ((area.right - area.left) % across == 0 or area.right >= frame.width) and
        ((area.bottom - area.top) % down == 0 or area.bottom >= frame.height);
}

/// What a draw of a frame is drawn with.
pub const DrawState = struct {
    /// The pixels it may touch.
    clip: Area,
    cfg: cl.Cfg = .{},
    mixing: cl.Mixing = .{},
    /// The front's and the back's test, with `cfg.stencil`.
    stencil: [2]cl.StencilFace = undefined,
    /// What a triangle adds to its depth, with `cfg.biased`: the constant
    /// in the depth buffer's smallest differences, the slope of the
    /// triangle's steepest, and the clamp both are held inside (since
    /// 1.47).
    bias_constant: f32 = 0,
    bias_slope: f32 = 0,
    bias_clamp: f32 = 0,
    /// The depth a pixel's own must lie between, with `cfg.bounded`.
    bounds: [2]f32 = .{ 0, 1 },
    /// The viewport, as Vulkan gives it.
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
    /// The samples the draw may write, in a frame of four: Vulkan's sample
    /// mask where the pipeline has four, as v3dv's
    /// `pipeline_set_sample_mask` keeps it (v3dv_pipeline.c:2903-2913).
    sample_mask: u4 = 0xF,
};

/// The start of the binner's list for a frame: what stays the same for all
/// its draws.
pub fn beginBin(list: *List, frame: *const Frame) void {
    cl.binningMode(list, frame.width, frame.height, frame.tile);
    list.byte(cl.FLUSH_VCD_CACHE);
    cl.occlusionQueryOff(list);
    list.byte(cl.START_TILE_BINNING);
    cl.colorWriteMasks(list, 0xF);
    cl.sampleState(list, 0xF);
    list.byte(cl.ZERO_ALL_FLAT_SHADE_FLAGS);
    list.byte(cl.ZERO_ALL_NON_PERSPECTIVE_FLAGS);
    list.byte(cl.ZERO_ALL_CENTROID_FLAGS);
    cl.pointSize(list, 1.0);
    cl.lineWidth(list, 1.0);
    cl.vcmCacheSize(list, vcm_batches, vcm_batches);
}

/// What the draws after it are drawn with. In a frame of four samples the
/// coverage is taken at four places, as v3dv sets "Rasterizer Oversample
/// Mode" for a pipeline of four (v3dvx_pipeline.c:193-196; facet's lines
/// are triangles, so the line rasterization that rules it out never
/// applies), and every draw writes its sample mask, as v3dv writes it with
/// each pipeline (v3dv_cmd_buffer.c:3017-3018; v3dvx_cmd_buffer.c:1615-1618).
/// A frame of one sample keeps `beginBin`'s mask of four bits.
pub fn writeDrawState(list: *List, frame: *const Frame, state: *const DrawState) void {
    const clip = state.clip;
    cl.clipWindow(list, clip.left, clip.top, clip.right - clip.left, clip.bottom - clip.top);
    var cfg = state.cfg;
    cfg.oversample = frame.four;
    cl.cfgBits(list, cfg);
    if (frame.four) cl.sampleState(list, state.sample_mask);
    if (state.cfg.biased) cl.depthOffset(list, state.bias_slope, state.bias_constant, state.bias_clamp);
    if (state.cfg.bounded) cl.depthBounds(list, state.bounds[0], state.bounds[1]);
    if (state.cfg.blend) cl.blend(list, &state.mixing);
    if (state.cfg.stencil) {
        cl.stencilCfg(list, &state.stencil[0], true);
        cl.stencilCfg(list, &state.stencil[1], false);
    }
    cl.colorWriteMasks(list, state.mixing.channels);
    cl.clipperXy(list, state.width * 32.0, state.height * 32.0);
    cl.clipperZ(list, state.max_depth - state.min_depth, state.min_depth);
    cl.clipperZLimits(list, @min(state.min_depth, state.max_depth), @max(state.min_depth, state.max_depth));
    cl.viewportOffset(list, state.x + state.width * 0.5, state.y + state.height * 0.5);
}

/// The end of the binner's list.
pub fn endBin(list: *List) void {
    list.byte(cl.FLUSH);
}

/// The binner's list for a frame of one draw over all of it: `count`
/// vertices as triangles with the shader state at `record`.
pub fn writeBin(list: *List, frame: *const Frame, record: u32, attributes: u32, count: u32) void {
    beginBin(list, frame);
    writeDrawState(list, frame, &.{
        .clip = .{ .left = 0, .top = 0, .right = frame.width, .bottom = frame.height },
        .x = 0,
        .y = 0,
        .width = @floatFromInt(frame.width),
        .height = @floatFromInt(frame.height),
    });
    cl.glShaderState(list, record, attributes);
    cl.vertexArrayPrims(list, cl.PRIM_TRIANGLES, count, 0);
    endBin(list);
}

/// What each tile does, in its own list: `render` branches to it for every
/// tile. `load` is whether this list's tiles read the image first, which is
/// `frame.load` unless the frame wants a second list for the tiles its
/// cleared area covers whole. In a frame of four samples each load and
/// store moves all of them, as v3dv's do for an image of more than one
/// (v3dvx_cmd_buffer.c:206-209, 408-413), the images being of four too.
/// Where it resolves, the colour's average is stored into the resolve
/// attachment first, as v3dv stores a resolve before the colour it is of,
/// neither asking for a clear (v3dvx_cmd_buffer.c:640-686).
pub fn writeTileList(list: *List, frame: *const Frame, load: bool) void {
    const samples: cl.Decimate = if (frame.four) .all_samples else .sample_0;
    list.byte(cl.TILE_COORDINATES_IMPLICIT);
    if (load and frame.color) cl.load(list, cl.STORE_RENDER_TARGET_0, frame.format, frame.swap_rb, frame.image, frame.stride, frame.memory, samples);
    // The depth or the stencil read in after the colour, as Mesa orders
    // them, whether or not this list's tiles read the colour.
    if (frame.kept) |kept| if (kept.load) cl.load(list, kept.buffer, kept.format, false, kept.image, kept.stride, kept.memory, samples);
    list.byte(cl.END_OF_LOADS);
    // The binner starts each tile's list assuming triangles.
    cl.primListFormat(list, cl.LIST_TRIANGLES);
    if (frame.binned) {
        cl.setInstanceId(list, 0);
        cl.branchToImplicitTileList(list);
    }
    // And written out before it: the hardware clears the tiles' depth and
    // stencil between tiles by itself, so neither store asks for a clear.
    const stores_kept = if (frame.kept) |kept| kept.store else false;
    if (stores_kept) {
        const kept = frame.kept.?;
        cl.store(list, kept.buffer, kept.format, false, kept.image, kept.stride, kept.memory, samples);
    }
    if (frame.color) {
        if (frame.resolve) |into| cl.store(list, cl.STORE_RENDER_TARGET_0, frame.format, frame.swap_rb, into.image, into.stride, cl.MEMORY_RASTER, .four);
        cl.store(list, cl.STORE_RENDER_TARGET_0, frame.format, frame.swap_rb, frame.image, frame.stride, frame.memory, samples);
        list.byte(cl.CLEAR_RENDER_TARGETS);
    } else if (!stores_kept) {
        // A tile of no colour that keeps nothing still ends in a store,
        // of nothing, and clears no render target: the depth and stencil
        // clear between tiles by themselves (v3dvx_cmd_buffer.c:680-685,
        // 544-551, 687-699).
        cl.store(list, cl.STORE_NONE, frame.format, false, 0, 0, cl.MEMORY_RASTER, .sample_0);
    }
    list.byte(cl.END_OF_TILE_MARKER);
    list.byte(cl.RETURN_FROM_SUB_LIST);
}

/// The frame's list. `tiles` is `writeTileList`'s. `inside`, for a frame
/// that clears inside an area, is a second one written without the load:
/// the supertiles the area covers whole are pointed at that instead, which
/// is what `clear_inside` is for. The renderer is told which list to branch
/// to as it goes, so a row of supertiles costs at most two of those packets.
pub fn writeRender(list: *List, frame: *const Frame, tiles: TileList, inside: ?TileList) void {
    const tiles_x = frame.tilesX();
    const tiles_y = frame.tilesY();
    cl.renderingCommon(list, frame.width, frame.height, frame.tile, frame.depth or frame.stencil, frame.four);
    if (frame.color) cl.renderTarget0(list, frame.tile.width, frame.clear) else cl.unusedRenderTarget(list);
    cl.zsClear(list, frame.clear_depth, frame.clear_stencil);
    cl.tileListInitialBlock(list);
    cl.tileListBase(list, frame.tile_lists);

    const supertiles = supertilesOf(frame);
    const supertile_w = supertiles.width;
    const supertile_h = supertiles.height;
    const frame_w = supertiles.across;
    const frame_h = supertiles.down;
    cl.supertileCfg(list, supertile_w, supertile_h, frame_w, frame_h, tiles_x, tiles_y);

    // Clearing happens at a tile's end, so the first tile's own is done
    // first; the second time round is the GFXH-1742 workaround, the race
    // of the tile buffer's type changing under the QPUs.
    var round: u32 = 0;
    while (round < 2) : (round += 1) {
        cl.tileCoordinates(list, 0, 0);
        list.byte(cl.END_OF_LOADS);
        cl.store(list, cl.STORE_NONE, frame.format, false, 0, 0, cl.MEMORY_RASTER, .sample_0);
        if (round == 0) list.byte(cl.CLEAR_RENDER_TARGETS);
        list.byte(cl.END_OF_TILE_MARKER);
    }
    list.byte(cl.FLUSH_VCD_CACHE);
    cl.genericTileList(list, tiles.start, tiles.end);
    const area = frame.area orelse Area{ .left = 0, .top = 0, .right = frame.width, .bottom = frame.height };
    const across = supertile_w * frame.tile.width;
    const down = supertile_h * frame.tile.height;
    // Which of the two lists the renderer is on: `tiles`, the one the frame
    // asked for, until a supertile wholly inside the area wants the other.
    var pointed = false;
    var row = area.top / down;
    while (row < frame_h and row * down < area.bottom) : (row += 1) {
        const rows_within = row * down >= area.top and (row + 1) * down <= area.bottom;
        var column = area.left / across;
        while (column < frame_w and column * across < area.right) : (column += 1) {
            const within = inside != null and rows_within and
                column * across >= area.left and (column + 1) * across <= area.right;
            if (within != pointed) {
                const which = if (within) inside.? else tiles;
                cl.genericTileList(list, which.start, which.end);
                pointed = within;
            }
            cl.supertileCoordinates(list, column, row);
        }
    }
    list.byte(cl.END_OF_RENDERING);
}

const std = @import("std");

test "the tile is v3d_choose_tile_size's at 7.1, at one sample and at four" {
    const Case = struct { bytes: u32, four: bool, width: u32, height: u32 };
    // Each worked through tile_size_valid (v3d_util.c:104-117) by hand: an
    // RGBA8 target is 4 bytes, RGBA16F 8, RGBA32F 16, and 64 is eight
    // targets of 128 bits, "the most expensive configuration" the 8 KiB
    // depth buffer is there for (v3d_util.c:150-152).
    const cases = [_]Case{
        .{ .bytes = 4, .four = false, .width = 64, .height = 64 },
        .{ .bytes = 4, .four = true, .width = 32, .height = 32 },
        .{ .bytes = 8, .four = false, .width = 64, .height = 32 },
        .{ .bytes = 8, .four = true, .width = 32, .height = 16 },
        .{ .bytes = 16, .four = false, .width = 64, .height = 32 },
        .{ .bytes = 16, .four = true, .width = 32, .height = 16 },
        .{ .bytes = 64, .four = true, .width = 16, .height = 8 },
        // No colour: the depth alone, four times over.
        .{ .bytes = 0, .four = true, .width = 32, .height = 32 },
    };
    for (cases) |case| {
        const tile = chooseTile(case.bytes, case.four);
        try std.testing.expectEqual(case.width, tile.width);
        try std.testing.expectEqual(case.height, tile.height);
        const samples: u32 = if (case.four) 4 else 1;
        try std.testing.expect(tileFits(tile.width * tile.height, case.bytes * samples, 4 * samples));
    }
}

test "a frame of four takes its tile, its multisample bit, and a mask and oversampling for each draw" {
    var memory: [256]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x1000 };
    var frame = Frame{ .width = 100, .height = 40, .image = 0x10_0000, .stride = 400, .swap_rb = false, .clear = 0, .tile_lists = 0x20_0000, .binned = false };
    try std.testing.expectEqual(@as(u32, 2), frame.tilesX());
    try std.testing.expectEqual(@as(u32, 1), frame.tilesY());
    frame.four = true;
    frame.tile = chooseTile(8, true);
    try std.testing.expectEqual(@as(u32, 4), frame.tilesX());
    try std.testing.expectEqual(@as(u32, 3), frame.tilesY());

    beginBin(&list, &frame);
    const bin = std.mem.readInt(u64, memory[1..9], .little);
    try std.testing.expectEqual(@as(u64, 2), bin >> 8 & 7);
    try std.testing.expectEqual(@as(u64, 1), bin >> 11 & 7);

    const state = DrawState{ .clip = .{ .left = 0, .top = 0, .right = 100, .bottom = 40 }, .x = 0, .y = 0, .width = 100, .height = 40, .sample_mask = 0x6 };
    list.used = 0;
    writeDrawState(&list, &frame, &state);
    // The clip window's 9 bytes, then CFG_BITS with oversampling, then
    // SAMPLE_STATE with the draw's mask.
    try std.testing.expectEqual(@as(u8, 96), memory[9]);
    try std.testing.expectEqual(@as(u24, 1 << 6), std.mem.readInt(u24, memory[10..13], .little) & 1 << 6);
    try std.testing.expectEqual(@as(u8, 91), memory[13]);
    try std.testing.expectEqual(@as(u32, 0x3F80_0006), std.mem.readInt(u32, memory[14..18], .little));
    const four_bytes = list.used;

    // At one sample neither: CFG_BITS without oversampling, and the
    // clipper next, as before.
    frame.four = false;
    list.used = 0;
    writeDrawState(&list, &frame, &state);
    try std.testing.expectEqual(@as(u24, 0), std.mem.readInt(u24, memory[10..13], .little) & 1 << 6);
    try std.testing.expect(memory[13] != 91);
    try std.testing.expectEqual(four_bytes - 5, list.used);

    // The renderer's common packet: the multisample bit and the tile's
    // log2 sizes, and the render target's stride from its width.
    frame.four = true;
    list.used = 0;
    writeRender(&list, &frame, .{ .start = 0x3000, .end = 0x3040 }, null);
    const common = std.mem.readInt(u64, memory[1..9], .little);
    try std.testing.expectEqual(@as(u64, 1), common >> 42 & 1);
    try std.testing.expectEqual(@as(u64, 2), common >> 52 & 7);
    try std.testing.expectEqual(@as(u64, 1), common >> 55 & 7);
    try std.testing.expectEqual(@as(u8, 121), memory[9]);
    const target = std.mem.readInt(u64, memory[10..18], .little);
    try std.testing.expectEqual(@as(u64, 15), target >> 18 & 0x7F);
}

test "a frame of four samples loads and stores all of them, the colour where its level lies and the depth where it is kept" {
    var memory: [128]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x1000 };
    var frame = Frame{
        .width = 64,
        .height = 64,
        .image = 0x10_0000,
        .stride = 7,
        .memory = cl.MEMORY_UIF_XOR,
        .swap_rb = true,
        .clear = 0,
        .tile_lists = 0x20_0000,
        .binned = false,
        .load = true,
        .four = true,
        .tile = chooseTile(4, true),
        .kept = .{ .buffer = cl.STORE_Z, .format = cl.OUTPUT_D16, .image = 0x30_0000, .stride = 3, .memory = cl.MEMORY_UIF, .load = true, .store = true },
    };
    const Seen = struct { code: u8, fields: u64, address: u32 };
    const seen = struct {
        fn at(bytes: []const u8, place: usize) Seen {
            return .{ .code = bytes[place], .fields = std.mem.readInt(u64, bytes[place + 1 ..][0..8], .little), .address = std.mem.readInt(u32, bytes[place + 9 ..][0..4], .little) };
        }
    }.at;
    for ([_]bool{ true, false }) |four| {
        frame.four = four;
        list.used = 0;
        writeTileList(&list, &frame, true);
        const decimate: u64 = if (four) 3 else 0;
        try std.testing.expectEqual(cl.TILE_COORDINATES_IMPLICIT, memory[0]);
        // The colour's load, then the depth's; END_OF_LOADS; the list's
        // format; the depth's store, then the colour's.
        const color_load = seen(&memory, 1);
        const depth_load = seen(&memory, 14);
        try std.testing.expectEqual(cl.END_OF_LOADS, memory[27]);
        const depth_store = seen(&memory, 30);
        const color_store = seen(&memory, 43);
        try std.testing.expectEqual(@as(u8, 30), color_load.code);
        try std.testing.expectEqual(@as(u8, 30), depth_load.code);
        try std.testing.expectEqual(@as(u8, 29), depth_store.code);
        try std.testing.expectEqual(@as(u8, 29), color_store.code);
        for ([_]Seen{ color_load, color_store }) |color| {
            try std.testing.expectEqual(cl.STORE_RENDER_TARGET_0, color.fields & 0xF);
            try std.testing.expectEqual(cl.MEMORY_UIF_XOR, color.fields >> 4 & 7);
            try std.testing.expectEqual(decimate, color.fields >> 10 & 3);
            try std.testing.expectEqual(@as(u64, 1), color.fields >> 20 & 1);
            try std.testing.expectEqual(@as(u64, 7), color.fields >> 28 & 0xFFFFF);
            try std.testing.expectEqual(@as(u32, 0x10_0000), color.address);
        }
        for ([_]Seen{ depth_load, depth_store }) |depth| {
            try std.testing.expectEqual(cl.STORE_Z, depth.fields & 0xF);
            try std.testing.expectEqual(cl.MEMORY_UIF, depth.fields >> 4 & 7);
            try std.testing.expectEqual(decimate, depth.fields >> 10 & 3);
            try std.testing.expectEqual(@as(u64, 3), depth.fields >> 28 & 0xFFFFF);
            try std.testing.expectEqual(@as(u32, 0x30_0000), depth.address);
        }
    }
    // A frame in rows, as every frame was before: raster, the first sample.
    frame = .{ .width = 64, .height = 64, .image = 0x10_0000, .stride = 256, .swap_rb = false, .clear = 0, .tile_lists = 0x20_0000, .binned = false, .load = true };
    list.used = 0;
    writeTileList(&list, &frame, true);
    const rows = seen(&memory, 1);
    try std.testing.expectEqual(cl.MEMORY_RASTER, rows.fields >> 4 & 7);
    try std.testing.expectEqual(@as(u64, 0), rows.fields >> 10 & 3);
    try std.testing.expectEqual(@as(u64, 256), rows.fields >> 28 & 0xFFFFF);
}

test "a frame of no colour configures the unused render target, and its tiles move and clear no colour" {
    var memory: [512]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x1000 };
    var frame = Frame{
        .width = 64,
        .height = 64,
        .image = 0,
        .stride = 0,
        .swap_rb = false,
        .clear = 0,
        .tile_lists = 0x20_0000,
        .binned = false,
        .color = false,
        .depth = true,
        .tile = chooseTile(0, false),
        .kept = .{ .buffer = cl.STORE_Z, .format = cl.OUTPUT_D16, .image = 0x30_0000, .stride = 128, .load = true, .store = true },
    };
    // The depth kept: its load, END_OF_LOADS, the list's format and its
    // store, and then the tile's end. No colour asked for, even with
    // `load`, and no CLEAR_RENDER_TARGETS.
    writeTileList(&list, &frame, true);
    try std.testing.expectEqual(cl.TILE_COORDINATES_IMPLICIT, memory[0]);
    try std.testing.expectEqual(@as(u8, 30), memory[1]);
    try std.testing.expectEqual(cl.STORE_Z, std.mem.readInt(u64, memory[2..10], .little) & 0xF);
    try std.testing.expectEqual(cl.END_OF_LOADS, memory[14]);
    try std.testing.expectEqual(@as(u8, 29), memory[17]);
    try std.testing.expectEqual(cl.STORE_Z, std.mem.readInt(u64, memory[18..26], .little) & 0xF);
    try std.testing.expectEqual(cl.END_OF_TILE_MARKER, memory[30]);
    try std.testing.expectEqual(cl.RETURN_FROM_SUB_LIST, memory[31]);
    try std.testing.expectEqual(@as(usize, 32), list.used);
    // Nothing kept: the one store is of nothing (v3dvx_cmd_buffer.c:680-685).
    frame.kept = null;
    list.used = 0;
    writeTileList(&list, &frame, false);
    try std.testing.expectEqual(cl.END_OF_LOADS, memory[1]);
    try std.testing.expectEqual(@as(u8, 29), memory[4]);
    try std.testing.expectEqual(cl.STORE_NONE, std.mem.readInt(u64, memory[5..13], .little) & 0xF);
    try std.testing.expectEqual(cl.END_OF_TILE_MARKER, memory[17]);
    try std.testing.expectEqual(@as(usize, 19), list.used);
    // The rendering mode: the common packet, then the unused render
    // target, sub-id 2 and every other field 0, then the depth's clear.
    list.used = 0;
    writeRender(&list, &frame, .{ .start = 0x2000, .end = 0x2020 }, null);
    try std.testing.expectEqual(cl.TILE_RENDERING_MODE_CFG, memory[9]);
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, memory[10..18], .little));
    try std.testing.expectEqual(cl.TILE_RENDERING_MODE_CFG, memory[18]);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, memory[19..27], .little) & 7);
    // With a colour, render target 0 as before.
    frame.color = true;
    frame.image = 0x10_0000;
    frame.stride = 256;
    list.used = 0;
    writeRender(&list, &frame, .{ .start = 0x2000, .end = 0x2020 }, null);
    try std.testing.expect(std.mem.readInt(u64, memory[10..18], .little) != 2);
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, memory[10..18], .little) & 7);
}

test "a frame of four that resolves stores the average into the resolve's rows before the colour, and only over supertiles inside its area" {
    var memory: [128]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x1000 };
    var frame = Frame{
        .width = 100,
        .height = 70,
        .image = 0x10_0000,
        .stride = 7,
        .memory = cl.MEMORY_UIF_XOR,
        .swap_rb = true,
        .clear = 0,
        .tile_lists = 0x20_0000,
        .binned = false,
        .four = true,
        .tile = chooseTile(4, true),
        .kept = .{ .buffer = cl.STORE_Z, .format = cl.OUTPUT_D16, .image = 0x30_0000, .stride = 3, .memory = cl.MEMORY_UIF, .load = false, .store = true },
        .resolve = .{ .image = 0x40_0000, .stride = 400 },
    };
    writeTileList(&list, &frame, false);
    const Seen = struct { code: u8, fields: u64, address: u32 };
    const seen = struct {
        fn at(bytes: []const u8, place: usize) Seen {
            return .{ .code = bytes[place], .fields = std.mem.readInt(u64, bytes[place + 1 ..][0..8], .little), .address = std.mem.readInt(u32, bytes[place + 9 ..][0..4], .little) };
        }
    }.at;
    // No load: END_OF_LOADS at once, the list's format, then the depth's
    // store, the resolve's, the colour's.
    try std.testing.expectEqual(cl.END_OF_LOADS, memory[1]);
    const depth_store = seen(&memory, 4);
    const resolve_store = seen(&memory, 17);
    const color_store = seen(&memory, 30);
    for ([_]Seen{ depth_store, resolve_store, color_store }) |store| try std.testing.expectEqual(@as(u8, 29), store.code);
    try std.testing.expectEqual(cl.STORE_Z, depth_store.fields & 0xF);
    // The average of the four, into rows, red and blue swapped as the
    // colour's are, at the resolve's own stride.
    try std.testing.expectEqual(cl.STORE_RENDER_TARGET_0, resolve_store.fields & 0xF);
    try std.testing.expectEqual(cl.MEMORY_RASTER, resolve_store.fields >> 4 & 7);
    try std.testing.expectEqual(@as(u64, 1), resolve_store.fields >> 10 & 3);
    try std.testing.expectEqual(@as(u64, 1), resolve_store.fields >> 20 & 1);
    try std.testing.expectEqual(@as(u64, 400), resolve_store.fields >> 28 & 0xFFFFF);
    try std.testing.expectEqual(@as(u32, 0x40_0000), resolve_store.address);
    // The colour all four, where its level lies.
    try std.testing.expectEqual(cl.STORE_RENDER_TARGET_0, color_store.fields & 0xF);
    try std.testing.expectEqual(@as(u64, 3), color_store.fields >> 10 & 3);
    try std.testing.expectEqual(@as(u32, 0x10_0000), color_store.address);
    try std.testing.expectEqual(cl.CLEAR_RENDER_TARGETS, memory[43]);

    // 100 by 70 in tiles of 32 is 4 by 3 of them, a supertile each.
    try std.testing.expectEqual(Supertiles{ .width = 1, .height = 1, .across = 4, .down = 3 }, supertilesOf(&frame));
    try std.testing.expect(tilesInArea(&frame));
    const Case = struct { area: Area, aligned: bool };
    for ([_]Case{
        .{ .area = .{ .left = 32, .top = 32, .right = 96, .bottom = 64 }, .aligned = true },
        // To the frame's edge, which the tiles pass.
        .{ .area = .{ .left = 32, .top = 0, .right = 100, .bottom = 70 }, .aligned = true },
        .{ .area = .{ .left = 16, .top = 0, .right = 100, .bottom = 70 }, .aligned = false },
        .{ .area = .{ .left = 0, .top = 0, .right = 48, .bottom = 32 }, .aligned = false },
        .{ .area = .{ .left = 0, .top = 0, .right = 32, .bottom = 40 }, .aligned = false },
    }) |case| {
        frame.area = case.area;
        try std.testing.expectEqual(case.aligned, tilesInArea(&frame));
    }
    // 2560 by 1440, 80 by 45 tiles: grown to supertiles of 4 by 4, 20 by
    // 12 of them, so a tile's alignment is no longer enough.
    frame.width = 2560;
    frame.height = 1440;
    try std.testing.expectEqual(Supertiles{ .width = 4, .height = 4, .across = 20, .down = 12 }, supertilesOf(&frame));
    frame.area = .{ .left = 128, .top = 128, .right = 256, .bottom = 256 };
    try std.testing.expect(tilesInArea(&frame));
    frame.area = .{ .left = 32, .top = 32, .right = 64, .bottom = 64 };
    try std.testing.expect(!tilesInArea(&frame));
}

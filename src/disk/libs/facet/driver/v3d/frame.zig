// SPDX-License-Identifier: MIT
//! A frame's two lists: the binner's, which says what is drawn, and the
//! renderer's, which clears each tile or loads it, draws what was binned
//! for it and stores it in rows of pixels (v3dx_rcl.c and v3dx_emit.c in
//! Mesa).

const cl = @import("cl.zig");
const List = cl.List;

/// A frame of one sample's tiles: 64 x 64 at 32 bits a pixel, 16 KiB of
/// the colour buffer, what `chooseTile` gives for one render target of
/// normalized bytes. The device reports it as its tile (driver.zig).
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

/// The planes of the tiles kept in an image's rows: the depth, the
/// stencil, or since 1.224 both of D24_UNORM_S8_UINT, loaded as a tile
/// starts and stored as it ends (`Capabilities.stored_depth`,
/// `stored_stencil`, since 1.47). The hardware stores a plane of 16 bits
/// or of 8 as its own pixels one after another, so such an image's format
/// holds that plane alone - `d16_unorm` or `s8_uint` - and
/// `d16_unorm_s8_uint` keeps neither here; a depth of 24 bits lies in a
/// word with its stencil, either stored alone or both together, as v3dv
/// stores a D24S8 (v3dvx_cmd_buffer.c:213-223, 557-599).
pub const Kept = struct {
    /// Which buffer of the tiles is stored, or where nothing is, loaded:
    /// `cl.STORE_Z`, `cl.STORE_STENCIL`, or both, `cl.STORE_ZSTENCIL`.
    buffer: u64,
    /// The buffer loaded where it is not `buffer`: a pass that loads one
    /// plane of a D24S8 and stores the other or both, v3dv picking the
    /// load's planes and the store's apart (v3dvx_cmd_buffer.c:331-334,
    /// 594-599; since 1.224). Null for `buffer`.
    loaded: ?u64 = null,
    /// How the image holds it: `cl.OUTPUT_D16`, `cl.OUTPUT_S8`, or
    /// `cl.OUTPUT_D24S8` for either plane of a depth of 24 bits.
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

/// A render target of a frame that has an image: where the image lies,
/// how it holds a pixel, how the tile buffer holds it, and whether a tile
/// starts with what the image holds (since 1.232 one of each render
/// target; the frame's own fields before).
pub const Color = struct {
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
    swap_rb: bool = false,
    /// The render target in the tile buffer: its bits a pixel, its type
    /// and clamp, and the colour it clears to as the buffer holds it, red
    /// lowest (`cl.clearColor`). Normalized bytes at 32 bits a pixel by
    /// default, which every colour was drawn at until 1.228.
    target: cl.RenderTarget = .{},
    /// The tiles start with what the image holds, not the colour cleared,
    /// as v3dv loads each attachment that needs it
    /// (`cmd_buffer_render_pass_emit_loads`, v3dvx_cmd_buffer.c:236-282).
    load: bool = false,
    /// With `load` and the frame's `area`: the area is cleared, so a tile
    /// the area covers whole does not load this target after all - every
    /// pixel of it is either the colour cleared or something drawn over
    /// it, and reading the image for it is work thrown away. Only the
    /// tiles at the area's edge, which must keep the pixels outside it,
    /// load it.
    clear_inside: bool = false,
    /// In a frame of four, the rows its samples are averaged into as each
    /// tile ends, or null where it has no resolve attachment or one the
    /// tiles cannot write (`tilesInArea`; since 1.148,
    /// docs/facet-vulkan10.md item 61, step V5).
    resolve: ?Resolve = null,
};

pub const Frame = struct {
    width: u32,
    height: u32,
    /// Render target `i`'s image, for each `i` below `targets`: null for
    /// an unused colour attachment, whose target is configured unused
    /// (`cl.unusedRenderTarget`) and moves no colour.
    colors: [cl.most_render_targets]?Color = @splat(null),
    /// The render targets configured: a subpass's colour attachments, the
    /// unused among them, as v3dv configures MAX2(color_count, 1)
    /// (v3dvx_cmd_buffer.c:975, 1077-1086). A frame of no colour - a
    /// subpass of no colour attachment, or of unused ones alone, since
    /// 1.150 - has its one, unused, and a tile loads, stores and clears no
    /// colour. Since 1.232: render target 0 alone before.
    targets: u32 = 1,
    /// The binner's lists, or memory the renderer will not read.
    tile_lists: u32,
    /// Whether the binner ran, so that a tile has a list to draw.
    binned: bool,
    /// There is a depth buffer, cleared to this; it stays in the tiles.
    depth: bool = false,
    /// Of 24 bits, not 16: the attachment's format is X8_D24_UNORM_PACK32
    /// or D24_UNORM_S8_UINT (`cl.renderingCommon`, since 1.224).
    depth24: bool = false,
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

    /// The render targets `colors` has, used or not.
    pub fn configured(frame: *const Frame) []const ?Color {
        std.debug.assert(frame.targets <= cl.most_render_targets);
        return frame.colors[0..@max(frame.targets, 1)];
    }

    /// Whether any render target has an image (`Frame.color` until 1.232).
    pub fn hasColor(frame: *const Frame) bool {
        for (frame.configured()) |each| if (each != null) return true;
        return false;
    }

    /// Whether some target clears inside the area (`Color.clear_inside`),
    /// so that the frame wants the second list of `writeRender`, for the
    /// tiles the area covers whole.
    pub fn clearsInside(frame: *const Frame) bool {
        for (frame.configured()) |each| if (each) |color| if (color.clear_inside) return true;
        return false;
    }

    /// The bytes a pixel of every render target takes in the tile buffer,
    /// what `chooseTile` is given: 4 for each 32 bits of each target with
    /// an image, as v3dv sums `total_color_bpp` over a subpass's colour
    /// attachments, the unused left out (v3dv_pass.c:353-371).
    pub fn colorBytes(frame: *const Frame) u32 {
        var bytes: u32 = 0;
        for (frame.configured()) |each| if (each) |color| {
            bytes += 4 * color.target.bpp.words();
        };
        return bytes;
    }

    pub fn tilesX(frame: *const Frame) u32 {
        return (frame.width + frame.tile.width - 1) / frame.tile.width;
    }

    pub fn tilesY(frame: *const Frame) u32 {
        return (frame.height + frame.tile.height - 1) / frame.tile.height;
    }
};

/// Where a frame of four resolves its colour: an image of one sample a
/// pixel, of the colour's format, as Vulkan has a resolve attachment
/// (VUID-VkSubpassDescription-pResolveAttachments-00850), in rows or,
/// sampled as well, in a texture's level (since 1.210).
pub const Resolve = struct {
    image: u32,
    /// Its rows' bytes, or for a UIF level its height in UIF blocks.
    stride: u32,
    /// How it lies: rows, or a texture's level in its tiling, as v3dv
    /// stores a resolve into its image's slice
    /// (v3dvx_cmd_buffer.c:398-406).
    memory: u64 = cl.MEMORY_RASTER,
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
    /// How each render target is written, by its number: blended where
    /// its mixing is `enabled` and `cfg.blend` is set, and its channels
    /// (since 1.233; render target 0's alone before).
    mixings: [cl.most_render_targets]cl.Mixing = @splat(.{}),
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
    /// The fragment program's varyings that are flat and those without
    /// perspective, a bit each (`compile.Code.flat_shade_flags`; since
    /// 1.190).
    flat_shade_flags: u32 = 0,
    noperspective_flags: u32 = 0,
};

/// What is kept free in a part of the binner's list: a draw's packets,
/// then the branch out (`_play.roomOnList`; here since 1.190).
pub const packets_bytes: u32 = 192;

/// The start of the binner's list for a frame: what stays the same for all
/// its draws.
pub fn beginBin(list: *List, frame: *const Frame) void {
    cl.binningMode(list, frame.width, frame.height, frame.tile);
    list.byte(cl.FLUSH_VCD_CACHE);
    cl.occlusionQueryOff(list);
    list.byte(cl.START_TILE_BINNING);
    cl.colorWriteMasks(list, 0);
    cl.sampleState(list, 0xF);
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
/// A frame of one sample keeps `beginBin`'s mask of four bits. The flat
/// and non-perspective flags are the fragment program's, written with
/// each draw as v3dv writes them with each pipeline
/// (cmd_buffer_emit_varyings_state, v3dvx_cmd_buffer.c:1791-1831; since
/// 1.190, `beginBin`'s zeroes before).
pub fn writeDrawState(list: *List, frame: *const Frame, state: *const DrawState) void {
    const clip = state.clip;
    cl.clipWindow(list, clip.left, clip.top, clip.right - clip.left, clip.bottom - clip.top);
    var cfg = state.cfg;
    cfg.oversample = frame.four;
    cl.cfgBits(list, cfg);
    if (frame.four) cl.sampleState(list, state.sample_mask);
    if (state.cfg.biased) cl.depthOffset(list, state.bias_slope, state.bias_constant, state.bias_clamp);
    if (state.cfg.bounded) cl.depthBounds(list, state.bounds[0], state.bounds[1]);
    if (state.cfg.blend) cl.blend(list, state.mixings[0..frame.configured().len]);
    if (state.cfg.stencil) {
        cl.stencilCfg(list, &state.stencil[0], true);
        cl.stencilCfg(list, &state.stencil[1], false);
    }
    cl.colorWriteMasks(list, unwrittenOf(frame, &state.mixings));
    cl.clipperXy(list, state.width * 32.0, state.height * 32.0);
    cl.clipperZ(list, state.max_depth - state.min_depth, state.min_depth);
    cl.clipperZLimits(list, @min(state.min_depth, state.max_depth), @max(state.min_depth, state.max_depth));
    cl.viewportOffset(list, state.x + state.width * 0.5, state.y + state.height * 0.5);
    cl.varyingFlags(list, cl.FLAT_SHADE_FLAGS, cl.ZERO_ALL_FLAT_SHADE_FLAGS, state.flat_shade_flags);
    cl.varyingFlags(list, cl.NON_PERSPECTIVE_FLAGS, cl.ZERO_ALL_NON_PERSPECTIVE_FLAGS, state.noperspective_flags);
}

/// The channels a draw leaves alone, four bits a render target
/// (`cl.colorWriteMasks`): of each with an image those its mixing does not
/// write, and of one without none, as v3dv leaves an undefined
/// attachment's bits 0 (v3dvx_pipeline.c:101-106).
pub fn unwrittenOf(frame: *const Frame, mixings: []const cl.Mixing) u32 {
    var unwritten: u32 = 0;
    for (frame.configured(), mixings[0..frame.configured().len], 0..) |each, mixing, rt| if (each != null) {
        unwritten |= (~mixing.channels & 0xF) << @intCast(4 * rt);
    };
    return unwritten;
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
/// tile. `inside` is for the second list a frame that clears inside its
/// area wants, of the tiles the cleared area covers whole: a target that
/// `clear_inside` is not loaded there. Each target is loaded in its
/// number's order, then the depth or the stencil, and the depth or the
/// stencil is stored first, then each target, as v3dv orders them
/// (`cmd_buffer_render_pass_emit_loads`, v3dvx_cmd_buffer.c:236-340;
/// `_stores`, :480-686; since 1.232, render target 0 alone before). In a
/// frame of four samples each load and store moves all of them, as v3dv's
/// do for an image of more than one (v3dvx_cmd_buffer.c:206-209, 408-413),
/// the images being of four too. Where a target resolves, its average is
/// stored into the resolve attachment first, as v3dv stores a resolve
/// before the colour it is of, neither asking for a clear
/// (v3dvx_cmd_buffer.c:640-686).
pub fn writeTileList(list: *List, frame: *const Frame, inside: bool) void {
    const samples: cl.Decimate = if (frame.four) .all_samples else .sample_0;
    list.byte(cl.TILE_COORDINATES_IMPLICIT);
    for (frame.configured(), 0..) |each, number| if (each) |color| {
        if (color.load and !(inside and color.clear_inside)) cl.load(list, cl.renderTargetBuffer(@intCast(number)), color.format, color.swap_rb, color.image, color.stride, color.memory, samples);
    };
    // The depth or the stencil read in after the colours, as Mesa orders
    // them, whether or not this list's tiles read a colour.
    if (frame.kept) |kept| if (kept.load) cl.load(list, kept.loaded orelse kept.buffer, kept.format, false, kept.image, kept.stride, kept.memory, samples);
    list.byte(cl.END_OF_LOADS);
    // The binner starts each tile's list assuming triangles.
    cl.primListFormat(list, cl.LIST_TRIANGLES);
    if (frame.binned) {
        cl.setInstanceId(list, 0);
        cl.branchToImplicitTileList(list);
    }
    // And written out before them: the hardware clears the tiles' depth
    // and stencil between tiles by itself, so neither store asks for a
    // clear.
    const stores_kept = if (frame.kept) |kept| kept.store else false;
    if (stores_kept) {
        const kept = frame.kept.?;
        cl.store(list, kept.buffer, kept.format, false, kept.image, kept.stride, kept.memory, samples);
    }
    for (frame.configured(), 0..) |each, number| if (each) |color| {
        const buffer = cl.renderTargetBuffer(@intCast(number));
        if (color.resolve) |into| cl.store(list, buffer, color.format, color.swap_rb, into.image, into.stride, into.memory, .four);
        cl.store(list, buffer, color.format, color.swap_rb, color.image, color.stride, color.memory, samples);
    };
    // One clear of every render target after their stores, as v3dv's 7.1
    // clears them all at once (`use_global_rt_clear`,
    // v3dvx_cmd_buffer.c:687-699).
    if (frame.hasColor()) {
        list.byte(cl.CLEAR_RENDER_TARGETS);
    } else if (!stores_kept) {
        // A tile of no colour that keeps nothing still ends in a store,
        // of nothing, and clears no render target: the depth and stencil
        // clear between tiles by themselves (v3dvx_cmd_buffer.c:680-685,
        // 544-551, 687-699).
        cl.store(list, cl.STORE_NONE, cl.OUTPUT_RGBA8, false, 0, 0, cl.MEMORY_RASTER, .sample_0);
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
    const configured = frame.configured();
    cl.renderingCommon(list, frame.width, frame.height, frame.tile, frame.depth or frame.stencil, frame.depth24, frame.four, @intCast(configured.len));
    // Each render target in its number's order, one after another in the
    // tile buffer, an unused one taking no room
    // (v3dvx_cmd_buffer.c:1077-1197; since 1.232).
    var base: u32 = 0;
    for (configured, 0..) |each, number| {
        if (each) |color| {
            base = cl.renderTarget(list, frame.tile, @intCast(number), base, color.target);
        } else cl.unusedRenderTarget(list, @intCast(number));
    }
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
        cl.store(list, cl.STORE_NONE, cl.OUTPUT_RGBA8, false, 0, 0, cl.MEMORY_RASTER, .sample_0);
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
    var frame = Frame{ .width = 100, .height = 40, .colors = .{ .{ .image = 0x10_0000, .stride = 400 }, null, null, null }, .tile_lists = 0x20_0000, .binned = false };
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

test "a draw's state writes its program's flat and non-perspective flags, or zeroes them, and at its most fits what a part of the list keeps" {
    var memory: [256]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x1000 };
    var frame = Frame{ .width = 100, .height = 40, .colors = .{ .{ .image = 0x10_0000, .stride = 400 }, null, null, null }, .tile_lists = 0x20_0000, .binned = false };
    const plain = DrawState{ .clip = .{ .left = 0, .top = 0, .right = 100, .bottom = 40 }, .x = 0, .y = 0, .width = 100, .height = 40 };
    writeDrawState(&list, &frame, &plain);
    // ZERO_ALL of each last, as v3dv writes them for a program of none
    // (since 1.190).
    try std.testing.expectEqual(cl.ZERO_ALL_FLAT_SHADE_FLAGS, memory[list.used - 2]);
    try std.testing.expectEqual(cl.ZERO_ALL_NON_PERSPECTIVE_FLAGS, memory[list.used - 1]);
    const plain_bytes = list.used;
    var flagged = plain;
    flagged.flat_shade_flags = 0x30;
    flagged.noperspective_flags = 0xC0;
    list.used = 0;
    writeDrawState(&list, &frame, &flagged);
    try std.testing.expectEqual(plain_bytes + 8, list.used);
    try std.testing.expectEqual(cl.FLAT_SHADE_FLAGS, memory[list.used - 10]);
    try std.testing.expectEqual(@as(u32, 0x30 << 8 | 1 << 6), std.mem.readInt(u32, memory[list.used - 9 ..][0..4], .little));
    try std.testing.expectEqual(cl.NON_PERSPECTIVE_FLAGS, memory[list.used - 5]);
    try std.testing.expectEqual(@as(u32, 0xC0 << 8 | 1 << 6), std.mem.readInt(u32, memory[list.used - 4 ..][0..4], .little));

    // Every packet a draw's state can have, the occlusion query's that
    // `_play.countSamples` may write after the room was asked for, and
    // the branch to the next part: inside what `roomOnList` keeps. Four
    // render targets, each blended: a BLEND_CFG of each (since 1.233).
    frame.four = true;
    frame.targets = 4;
    for (frame.colors[1..]) |*each| each.* = frame.colors[0];
    frame.tile = chooseTile(frame.colorBytes(), true);
    var most = flagged;
    most.cfg = .{ .biased = true, .bounded = true, .blend = true, .stencil = true, .clamped = true, .depth_write = true };
    most.mixings = @splat(.{ .enabled = true });
    const face = cl.StencilFace{ .fail = 1, .pass = 2, .depth_fail = 1, .compare = cl.COMPARE_ALWAYS, .compare_mask = 0xFF, .write_mask = 0xFF, .reference = 1 };
    most.stencil = .{ face, face };
    list.used = 0;
    writeDrawState(&list, &frame, &most);
    cl.occlusionQuery(&list, 0x4000);
    cl.branch(&list, 0x5000);
    try std.testing.expect(list.used <= packets_bytes);
}

test "a frame of four samples loads and stores all of them, the colour where its level lies and the depth where it is kept" {
    var memory: [128]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x1000 };
    var frame = Frame{
        .width = 64,
        .height = 64,
        .colors = .{ .{ .image = 0x10_0000, .stride = 7, .memory = cl.MEMORY_UIF_XOR, .swap_rb = true, .load = true }, null, null, null },
        .tile_lists = 0x20_0000,
        .binned = false,
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
        writeTileList(&list, &frame, false);
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
    frame = .{ .width = 64, .height = 64, .colors = .{ .{ .image = 0x10_0000, .stride = 256, .load = true }, null, null, null }, .tile_lists = 0x20_0000, .binned = false };
    list.used = 0;
    writeTileList(&list, &frame, false);
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
        .tile_lists = 0x20_0000,
        .binned = false,
        .depth = true,
        .tile = chooseTile(0, false),
        .kept = .{ .buffer = cl.STORE_Z, .format = cl.OUTPUT_D16, .image = 0x30_0000, .stride = 128, .load = true, .store = true },
    };
    // The depth kept: its load, END_OF_LOADS, the list's format and its
    // store, and then the tile's end. No colour, and no
    // CLEAR_RENDER_TARGETS.
    writeTileList(&list, &frame, false);
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
    frame.colors[0] = .{ .image = 0x10_0000, .stride = 256 };
    list.used = 0;
    writeRender(&list, &frame, .{ .start = 0x2000, .end = 0x2020 }, null);
    try std.testing.expect(std.mem.readInt(u64, memory[10..18], .little) != 2);
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, memory[10..18], .little) & 7);
}

test "a frame of D24_UNORM_S8_UINT loads the plane its ops load and stores both in one store, as D24S8, its tiles' depth of 24 bits (since 1.224)" {
    var memory: [512]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x1000 };
    var frame = Frame{
        .width = 64,
        .height = 64,
        .tile_lists = 0x20_0000,
        .binned = false,
        .depth = true,
        .depth24 = true,
        .stencil = true,
        .tile = chooseTile(0, false),
        .kept = .{ .buffer = cl.STORE_ZSTENCIL, .loaded = cl.STORE_Z, .format = cl.OUTPUT_D24S8, .image = 0x30_0000, .stride = 256, .load = true, .store = true },
    };
    // The depth alone loaded, then both stored, each as D24S8, as v3dv
    // picks the load's buffer and the store's apart (v3dvx_cmd_buffer.c:
    // 331-334, 594-599).
    writeTileList(&list, &frame, false);
    try std.testing.expectEqual(@as(u8, 30), memory[1]);
    const load = std.mem.readInt(u64, memory[2..10], .little);
    try std.testing.expectEqual(cl.STORE_Z, load & 0xF);
    try std.testing.expectEqual(cl.OUTPUT_D24S8, load >> 12 & 0x3F);
    try std.testing.expectEqual(cl.END_OF_LOADS, memory[14]);
    try std.testing.expectEqual(@as(u8, 29), memory[17]);
    const store = std.mem.readInt(u64, memory[18..26], .little);
    try std.testing.expectEqual(cl.STORE_ZSTENCIL, store & 0xF);
    try std.testing.expectEqual(cl.OUTPUT_D24S8, store >> 12 & 0x3F);
    try std.testing.expectEqual(@as(u32, 0x30_0000), std.mem.readInt(u32, memory[26..30], .little));
    // With no plane of its own to load, it loads what it stores.
    frame.kept.?.loaded = null;
    list.used = 0;
    writeTileList(&list, &frame, false);
    try std.testing.expectEqual(cl.STORE_ZSTENCIL, std.mem.readInt(u64, memory[2..10], .little) & 0xF);
    // The rendering mode: the tiles' depth of 24 bits, and of 16 for a
    // frame of D16.
    list.used = 0;
    writeRender(&list, &frame, .{ .start = 0x2000, .end = 0x2020 }, null);
    try std.testing.expectEqual(cl.TILE_RENDERING_MODE_CFG, memory[0]);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, memory[1..9], .little) >> 47 & 0xF);
    frame.depth24 = false;
    list.used = 0;
    writeRender(&list, &frame, .{ .start = 0x2000, .end = 0x2020 }, null);
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, memory[1..9], .little) >> 47 & 0xF);
}

test "a frame of four that resolves stores the average into the resolve's rows, or a sampled one's level in its tiling, before the colour, and only over supertiles inside its area" {
    var memory: [128]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x1000 };
    var frame = Frame{
        .width = 100,
        .height = 70,
        .colors = .{ .{ .image = 0x10_0000, .stride = 7, .memory = cl.MEMORY_UIF_XOR, .swap_rb = true, .resolve = .{ .image = 0x40_0000, .stride = 400 } }, null, null, null },
        .tile_lists = 0x20_0000,
        .binned = false,
        .four = true,
        .tile = chooseTile(4, true),
        .kept = .{ .buffer = cl.STORE_Z, .format = cl.OUTPUT_D16, .image = 0x30_0000, .stride = 3, .memory = cl.MEMORY_UIF, .load = false, .store = true },
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

    // Into a resolve attachment sampled as well, which lies as a texture
    // does (since 1.210): the store names its level's tiling and its
    // height in UIF blocks, as v3dv stores a resolve into its image's
    // slice (v3dvx_cmd_buffer.c:398-411).
    var into_level = frame;
    into_level.colors[0].?.resolve = .{ .image = 0x50_0000, .stride = 23, .memory = cl.MEMORY_UIF_XOR };
    var level_memory: [128]u8 = undefined;
    var level_list = List{ .at = &level_memory, .address = 0x1000 };
    writeTileList(&level_list, &into_level, false);
    const level_store = seen(&level_memory, 17);
    try std.testing.expectEqual(cl.STORE_RENDER_TARGET_0, level_store.fields & 0xF);
    try std.testing.expectEqual(cl.MEMORY_UIF_XOR, level_store.fields >> 4 & 7);
    try std.testing.expectEqual(@as(u64, 1), level_store.fields >> 10 & 3);
    try std.testing.expectEqual(@as(u64, 23), level_store.fields >> 28 & 0xFFFFF);
    try std.testing.expectEqual(@as(u32, 0x50_0000), level_store.address);

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

test "a frame of several render targets configures each by its number, one after another in the tile buffer and an unused one in none, loads each in order and stores each after the depth (since 1.232)" {
    // RGBA8 loaded, an unused attachment, RGBA16F loaded at the area's
    // edge alone, RGBA32F cleared: 4 + 8 + 16 bytes a pixel, a tile of 32
    // by 32 (`tile_size_valid` by hand: 1024 x 28 fits the 32 KiB the
    // depth's 8 KiB buffer lends the colour; 2048 x 28 does not).
    const halves = cl.RenderTarget{ .bpp = .@"64", .type_clamp = cl.typeClamp(.float16, false, false), .clear = .{ 0x1111_2222, 0x3333_4444, 0, 0 } };
    const floats = cl.RenderTarget{ .bpp = .@"128", .type_clamp = cl.typeClamp(.float32, false, false), .clear = .{ 0xA1A2_A3A4, 0xB1B2_B3B4, 0xC1C2_C3C4, 0xD1D2_D3D4 } };
    var frame = Frame{
        .width = 64,
        .height = 64,
        .colors = .{
            .{ .image = 0x10_0000, .stride = 256, .load = true, .target = .{ .clear = .{ 0x8040_20FF, 0, 0, 0 } } },
            null,
            .{ .image = 0x40_0000, .stride = 512, .format = cl.OUTPUT_RGBA16F, .target = halves, .load = true, .clear_inside = true },
            .{ .image = 0x50_0000, .stride = 1024, .format = cl.OUTPUT_RGBA32F, .swap_rb = true, .target = floats },
        },
        .targets = 4,
        .tile_lists = 0x20_0000,
        .binned = false,
        .depth = true,
        .kept = .{ .buffer = cl.STORE_Z, .format = cl.OUTPUT_D16, .image = 0x30_0000, .stride = 128, .load = true, .store = true },
    };
    try std.testing.expectEqual(@as(u32, 28), frame.colorBytes());
    frame.tile = chooseTile(frame.colorBytes(), false);
    try std.testing.expectEqual(cl.Tile{ .width = 32, .height = 32 }, frame.tile);
    try std.testing.expect(frame.hasColor());
    try std.testing.expect(frame.clearsInside());
    try std.testing.expectEqual(@as(usize, 4), frame.configured().len);

    var memory: [1024]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x1000 };
    const double = struct {
        fn at(bytes: []const u8, place: usize) u64 {
            return std.mem.readInt(u64, bytes[place..][0..8], .little);
        }
    }.at;
    // The common packet counts four, at 4 and one less; then each target's
    // packets in its number's order, every one naming it at 3.
    writeRender(&list, &frame, .{ .start = 0x2000, .end = 0x2020 }, null);
    try std.testing.expectEqual(@as(u64, 3), double(&memory, 1) >> 4 & 0xF);
    const Packet = struct { sub_id: u64, number: u64 };
    const expected = [_]Packet{
        .{ .sub_id = 2, .number = 0 },
        .{ .sub_id = 2, .number = 1 },
        .{ .sub_id = 2, .number = 2 },
        .{ .sub_id = 3, .number = 2 },
        .{ .sub_id = 2, .number = 3 },
        .{ .sub_id = 3, .number = 3 },
        .{ .sub_id = 4, .number = 3 },
        // Depth and stencil's clear, the last.
        .{ .sub_id = 1, .number = 0 },
    };
    for (expected, 0..) |packet, k| {
        try std.testing.expectEqual(cl.TILE_RENDERING_MODE_CFG, memory[9 + 9 * k]);
        const fields = double(&memory, 10 + 9 * k);
        try std.testing.expectEqual(packet.sub_id, fields & 7);
        if (packet.sub_id != 1) try std.testing.expectEqual(packet.number, fields >> 3 & 7);
    }
    // Render target 0 at 0, of a stride of 16 (32 pixels of one word, two
    // rows in 128 bits); the unused one a stride of 1, which packs to 0,
    // and nothing else; render target 2 at 32 rows of 16, 64 units of 512
    // bits, its stride 32; render target 3 past its 32 rows of 32, at 192,
    // its stride 64. What they take ends at 448 units, 28 KiB: 28 bytes of
    // each of the tile's 1024 pixels, as v3dv adds tile_height * stride / 8
    // after each (v3dvx_cmd_buffer.c:1159-1166).
    const first = double(&memory, 10);
    try std.testing.expectEqual(@as(u64, 0), first >> 7 & 0x7FF);
    try std.testing.expectEqual(@as(u64, 15), first >> 18 & 0x7F);
    try std.testing.expectEqual(@as(u64, 0x8040_20FF), first >> 32);
    try std.testing.expectEqual(@as(u64, 2 | 1 << 3), double(&memory, 19));
    const third = double(&memory, 28);
    try std.testing.expectEqual(@as(u64, 64), third >> 7 & 0x7FF);
    try std.testing.expectEqual(@as(u64, 31), third >> 18 & 0x7F);
    try std.testing.expectEqual(@as(u64, 1), third >> 25 & 3);
    try std.testing.expectEqual(@as(u64, 0x1111_2222), third >> 32);
    try std.testing.expectEqual(@as(u64, 0x3333_4444), double(&memory, 37) >> 24 & 0xFFFF_FFFF);
    const fourth = double(&memory, 46);
    try std.testing.expectEqual(@as(u64, 192), fourth >> 7 & 0x7FF);
    try std.testing.expectEqual(@as(u64, 63), fourth >> 18 & 0x7F);
    try std.testing.expectEqual(@as(u64, 2), fourth >> 25 & 3);
    try std.testing.expectEqual(@as(u64, 0xD1D2_D3D4_C1C2_C3), double(&memory, 64) >> 8);
    var base: u32 = 0;
    for (frame.configured(), 0..) |each, number| if (each) |color| {
        var scratch: [32]u8 = undefined;
        var into = List{ .at = &scratch, .address = 0 };
        base = cl.renderTarget(&into, frame.tile, @intCast(number), base, color.target);
    };
    try std.testing.expectEqual(@as(u32, 448), base);
    try std.testing.expectEqual(frame.colorBytes() * frame.tile.width * frame.tile.height, base * 64);

    // Each tile: render target 0's load, then 2's, then the depth's;
    // END_OF_LOADS and the list's format; the depth's store, then 0's,
    // 2's and 3's, each from its own buffer into its own image; one clear
    // of them all.
    list.used = 0;
    writeTileList(&list, &frame, false);
    const Move = struct { code: u8, buffer: u64, format: u64, swap_rb: u64, image: u32 };
    const move = struct {
        fn at(bytes: []const u8, place: usize) Move {
            const fields = std.mem.readInt(u64, bytes[place + 1 ..][0..8], .little);
            return .{ .code = bytes[place], .buffer = fields & 0xF, .format = fields >> 12 & 0x3F, .swap_rb = fields >> 20 & 1, .image = std.mem.readInt(u32, bytes[place + 9 ..][0..4], .little) };
        }
    }.at;
    try std.testing.expectEqual(Move{ .code = 30, .buffer = 0, .format = cl.OUTPUT_RGBA8, .swap_rb = 0, .image = 0x10_0000 }, move(&memory, 1));
    try std.testing.expectEqual(Move{ .code = 30, .buffer = 2, .format = cl.OUTPUT_RGBA16F, .swap_rb = 0, .image = 0x40_0000 }, move(&memory, 14));
    try std.testing.expectEqual(Move{ .code = 30, .buffer = cl.STORE_Z, .format = cl.OUTPUT_D16, .swap_rb = 0, .image = 0x30_0000 }, move(&memory, 27));
    try std.testing.expectEqual(cl.END_OF_LOADS, memory[40]);
    try std.testing.expectEqual(Move{ .code = 29, .buffer = cl.STORE_Z, .format = cl.OUTPUT_D16, .swap_rb = 0, .image = 0x30_0000 }, move(&memory, 43));
    try std.testing.expectEqual(Move{ .code = 29, .buffer = 0, .format = cl.OUTPUT_RGBA8, .swap_rb = 0, .image = 0x10_0000 }, move(&memory, 56));
    try std.testing.expectEqual(Move{ .code = 29, .buffer = 2, .format = cl.OUTPUT_RGBA16F, .swap_rb = 0, .image = 0x40_0000 }, move(&memory, 69));
    try std.testing.expectEqual(Move{ .code = 29, .buffer = 3, .format = cl.OUTPUT_RGBA32F, .swap_rb = 1, .image = 0x50_0000 }, move(&memory, 82));
    try std.testing.expectEqual(cl.CLEAR_RENDER_TARGETS, memory[95]);
    try std.testing.expectEqual(cl.END_OF_TILE_MARKER, memory[96]);
    try std.testing.expectEqual(@as(usize, 98), list.used);
    // Inside the cleared area: render target 2 is not loaded, 0 still is.
    list.used = 0;
    writeTileList(&list, &frame, true);
    try std.testing.expectEqual(@as(u64, 0), move(&memory, 1).buffer);
    try std.testing.expectEqual(cl.STORE_Z, move(&memory, 14).buffer);
    try std.testing.expectEqual(cl.END_OF_LOADS, memory[27]);
    // Without a target that clears inside, no second list is wanted.
    frame.colors[2].?.clear_inside = false;
    try std.testing.expect(!frame.clearsInside());

    // At four samples, a target that resolves stores its average first,
    // from its own buffer: render target 3's into its resolve.
    frame.four = true;
    frame.tile = chooseTile(frame.colorBytes(), true);
    frame.colors[3].?.resolve = .{ .image = 0x60_0000, .stride = 1024 };
    list.used = 0;
    writeTileList(&list, &frame, false);
    const resolve = move(&memory, 82);
    try std.testing.expectEqual(Move{ .code = 29, .buffer = 3, .format = cl.OUTPUT_RGBA32F, .swap_rb = 1, .image = 0x60_0000 }, resolve);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, memory[83..91], .little) >> 10 & 3);
    try std.testing.expectEqual(Move{ .code = 29, .buffer = 3, .format = cl.OUTPUT_RGBA32F, .swap_rb = 1, .image = 0x50_0000 }, move(&memory, 95));
    try std.testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, memory[96..104], .little) >> 10 & 3);
    try std.testing.expectEqual(cl.CLEAR_RENDER_TARGETS, memory[108]);
}

test "a frame of no colour, or of unused attachments alone, configures one unused render target, and of several the last unused ones too, as v3dv's color_count (since 1.232)" {
    var memory: [512]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x1000 };
    // Two unused attachments: two targets, both unused, no colour.
    var frame = Frame{ .width = 64, .height = 64, .targets = 2, .tile_lists = 0x20_0000, .binned = false, .tile = chooseTile(0, false) };
    try std.testing.expect(!frame.hasColor());
    try std.testing.expectEqual(@as(u32, 0), frame.colorBytes());
    writeRender(&list, &frame, .{ .start = 0x2000, .end = 0x2020 }, null);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, memory[1..9], .little) >> 4 & 0xF);
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, memory[10..18], .little));
    try std.testing.expectEqual(@as(u64, 2 | 1 << 3), std.mem.readInt(u64, memory[19..27], .little));
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, memory[28..36], .little) & 7);
    // None at all: the one, unused (v3dvx_cmd_buffer.c:1189-1197).
    frame.targets = 0;
    try std.testing.expectEqual(@as(usize, 1), frame.configured().len);
    list.used = 0;
    writeRender(&list, &frame, .{ .start = 0x2000, .end = 0x2020 }, null);
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, memory[1..9], .little) >> 4 & 0xF);
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, memory[10..18], .little));
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, memory[19..27], .little) & 7);
    // A colour at 1 alone behind an unused 0: it is the first in the
    // tile buffer, at 0, and loads and stores from buffer 1.
    frame.targets = 2;
    frame.colors[1] = .{ .image = 0x10_0000, .stride = 256, .load = true };
    frame.tile = chooseTile(frame.colorBytes(), false);
    list.used = 0;
    writeRender(&list, &frame, .{ .start = 0x2000, .end = 0x2020 }, null);
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, memory[10..18], .little));
    const one = std.mem.readInt(u64, memory[19..27], .little);
    try std.testing.expectEqual(@as(u64, 1), one >> 3 & 7);
    try std.testing.expectEqual(@as(u64, 0), one >> 7 & 0x7FF);
    try std.testing.expectEqual(@as(u64, 31), one >> 18 & 0x7F);
    list.used = 0;
    writeTileList(&list, &frame, false);
    try std.testing.expectEqual(@as(u8, 30), memory[1]);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, memory[2..10], .little) & 0xF);
    try std.testing.expectEqual(cl.END_OF_LOADS, memory[14]);
    try std.testing.expectEqual(@as(u8, 29), memory[17]);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, memory[18..26], .little) & 0xF);
    try std.testing.expectEqual(cl.CLEAR_RENDER_TARGETS, memory[30]);
}

test "a draw blends each render target its mixing enables, by a BLEND_CFG naming it, and writes the channels of each, a target without an image left at 0, as v3dv's masks (since 1.233)" {
    var memory: [256]u8 = undefined;
    var list = List{ .at = &memory, .address = 0x1000 };
    const color = Color{ .image = 0x10_0000, .stride = 256 };
    const frame = Frame{ .width = 64, .height = 64, .colors = .{ color, null, color, color }, .targets = 4, .tile_lists = 0x20_0000, .binned = false };
    var state = DrawState{ .clip = .{ .left = 0, .top = 0, .right = 64, .bottom = 64 }, .x = 0, .y = 0, .width = 64, .height = 64, .cfg = .{ .blend = true } };
    // Render target 0 additive, 2 not blended and writing red alone, 3
    // blended by the source's alpha with constants of its own, which are
    // not the first's.
    state.mixings[0] = .{ .enabled = true, .dst_color = 1, .dst_alpha = 1, .constants = .{ 0.5, 0, 0, 1 } };
    // Render target 1, without an image, writes no channel, as
    // `_play.mixingsOf` gives it: its bits stay 0 all the same.
    state.mixings[1] = .{ .channels = 0 };
    state.mixings[2] = .{ .channels = 0x1 };
    state.mixings[3] = .{ .enabled = true, .src_color = 6, .dst_color = 7, .channels = 0xC, .constants = .{ 1, 1, 1, 1 } };
    writeDrawState(&list, &frame, &state);
    var at: usize = 0;
    while (memory[at] != 83) at += 1;
    // BLEND_ENABLES: 0 and 3.
    try std.testing.expectEqual(@as(u8, 0b1001), memory[at + 1]);
    try std.testing.expectEqual(@as(u8, 84), memory[at + 2]);
    try std.testing.expectEqual(@as(u32, 1 << 24 | 0x11 << 16 | 0x11 << 4), std.mem.readInt(u32, memory[at + 3 ..][0..4], .little));
    try std.testing.expectEqual(@as(u8, 84), memory[at + 7]);
    try std.testing.expectEqual(@as(u32, 1 << 27 | 0x76 << 16 | 0x01 << 4), std.mem.readInt(u32, memory[at + 8 ..][0..4], .little));
    // The one constant colour: the first blended target's.
    try std.testing.expectEqual(@as(u8, 86), memory[at + 12]);
    try std.testing.expectEqual(@as(u32, 0x3800), std.mem.readInt(u32, memory[at + 13 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x3C00 << 16), std.mem.readInt(u32, memory[at + 17 ..][0..4], .little));
    // COLOR_WRITE_MASKS: 0 all, 1 without an image 0, 2 red alone, 3 blue
    // and alpha.
    while (memory[at] != 87) at += 1;
    try std.testing.expectEqual(@as(u32, 0x3 << 12 | 0xE << 8), std.mem.readInt(u32, memory[at + 1 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x3 << 12 | 0xE << 8), unwrittenOf(&frame, &state.mixings));
    // Render target 0 alone, as every frame was: its own four bits.
    const one = Frame{ .width = 64, .height = 64, .colors = .{ color, null, null, null }, .tile_lists = 0x20_0000, .binned = false };
    try std.testing.expectEqual(@as(u32, 0), unwrittenOf(&one, &state.mixings));
    try std.testing.expectEqual(@as(u32, 0xE), unwrittenOf(&one, &.{ .{ .channels = 1 }, .{}, .{}, .{} }));
}

// SPDX-License-Identifier: MIT
//! A frame's two lists: the binner's, which says what is drawn, and the
//! renderer's, which clears each tile or loads it, draws what was binned
//! for it and stores it in rows of pixels (v3dx_rcl.c and v3dx_emit.c in
//! Mesa).

const cl = @import("cl.zig");
const List = cl.List;

/// Tiles this size hold 32 bits a pixel: 16 KiB of the colour buffer.
pub const tile_pixels: u32 = 64;
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
    stride: u32,
    load: bool = false,
    store: bool = false,
};

pub const Frame = struct {
    width: u32,
    height: u32,
    image: u32,
    stride: u32,
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

    pub fn tilesX(frame: *const Frame) u32 {
        return (frame.width + tile_pixels - 1) / tile_pixels;
    }

    pub fn tilesY(frame: *const Frame) u32 {
        return (frame.height + tile_pixels - 1) / tile_pixels;
    }
};

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
};

/// The start of the binner's list for a frame: what stays the same for all
/// its draws.
pub fn beginBin(list: *List, frame: *const Frame) void {
    cl.binningMode(list, frame.width, frame.height, tile_pixels);
    list.byte(cl.FLUSH_VCD_CACHE);
    cl.occlusionQueryOff(list);
    list.byte(cl.START_TILE_BINNING);
    cl.colorWriteMasks(list, 0xF);
    cl.sampleState(list);
    list.byte(cl.ZERO_ALL_FLAT_SHADE_FLAGS);
    list.byte(cl.ZERO_ALL_NON_PERSPECTIVE_FLAGS);
    list.byte(cl.ZERO_ALL_CENTROID_FLAGS);
    cl.pointSize(list, 1.0);
    cl.lineWidth(list, 1.0);
    cl.vcmCacheSize(list, vcm_batches, vcm_batches);
}

/// What the draws after it are drawn with.
pub fn writeDrawState(list: *List, state: *const DrawState) void {
    const clip = state.clip;
    cl.clipWindow(list, clip.left, clip.top, clip.right - clip.left, clip.bottom - clip.top);
    cl.cfgBits(list, state.cfg);
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
    writeDrawState(list, &.{
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
/// cleared area covers whole.
pub fn writeTileList(list: *List, frame: *const Frame, load: bool) void {
    list.byte(cl.TILE_COORDINATES_IMPLICIT);
    if (load) cl.load(list, cl.STORE_RENDER_TARGET_0, frame.format, frame.swap_rb, frame.image, frame.stride);
    // The depth or the stencil read in after the colour, as Mesa orders
    // them, whether or not this list's tiles read the colour.
    if (frame.kept) |kept| if (kept.load) cl.load(list, kept.buffer, kept.format, false, kept.image, kept.stride);
    list.byte(cl.END_OF_LOADS);
    // The binner starts each tile's list assuming triangles.
    cl.primListFormat(list, cl.LIST_TRIANGLES);
    if (frame.binned) {
        cl.setInstanceId(list, 0);
        cl.branchToImplicitTileList(list);
    }
    // And written out before it: the hardware clears the tiles' depth and
    // stencil between tiles by itself, so neither store asks for a clear.
    if (frame.kept) |kept| if (kept.store) cl.store(list, kept.buffer, kept.format, false, kept.image, kept.stride);
    cl.store(list, cl.STORE_RENDER_TARGET_0, frame.format, frame.swap_rb, frame.image, frame.stride);
    list.byte(cl.CLEAR_RENDER_TARGETS);
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
    cl.renderingCommon(list, frame.width, frame.height, tile_pixels, frame.depth or frame.stencil);
    cl.renderTarget0(list, tile_pixels, frame.clear);
    cl.zsClear(list, frame.clear_depth, frame.clear_stencil);
    cl.tileListInitialBlock(list);
    cl.tileListBase(list, frame.tile_lists);

    var supertile_w: u32 = 1;
    var supertile_h: u32 = 1;
    var frame_w = tiles_x;
    var frame_h = tiles_y;
    while (frame_w >= most_supertiles or frame_h >= most_supertiles or frame_w * frame_h > most_supertiles) {
        if (supertile_w < supertile_h) supertile_w += 1 else supertile_h += 1;
        frame_w = (tiles_x + supertile_w - 1) / supertile_w;
        frame_h = (tiles_y + supertile_h - 1) / supertile_h;
    }
    cl.supertileCfg(list, supertile_w, supertile_h, frame_w, frame_h, tiles_x, tiles_y);

    // Clearing happens at a tile's end, so the first tile's own is done
    // first; the second time round is the GFXH-1742 workaround, the race
    // of the tile buffer's type changing under the QPUs.
    var round: u32 = 0;
    while (round < 2) : (round += 1) {
        cl.tileCoordinates(list, 0, 0);
        list.byte(cl.END_OF_LOADS);
        cl.store(list, cl.STORE_NONE, frame.format, false, 0, 0);
        if (round == 0) list.byte(cl.CLEAR_RENDER_TARGETS);
        list.byte(cl.END_OF_TILE_MARKER);
    }
    list.byte(cl.FLUSH_VCD_CACHE);
    cl.genericTileList(list, tiles.start, tiles.end);
    const area = frame.area orelse Area{ .left = 0, .top = 0, .right = frame.width, .bottom = frame.height };
    const across = supertile_w * tile_pixels;
    const down = supertile_h * tile_pixels;
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

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

/// A rectangle of pixels.
pub const Area = struct {
    left: u32,
    top: u32,
    right: u32,
    bottom: u32,
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
    /// There is a depth buffer, cleared to this; it stays in the tiles.
    depth: bool = false,
    clear_depth: f32 = 1.0,
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
    cl.colorWriteMasks(list);
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
    if (state.cfg.blend) cl.blendAlpha(list);
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
/// tile.
pub fn writeTileList(list: *List, frame: *const Frame) void {
    list.byte(cl.TILE_COORDINATES_IMPLICIT);
    if (frame.load) cl.load(list, frame.format, frame.swap_rb, frame.image, frame.stride);
    list.byte(cl.END_OF_LOADS);
    // The binner starts each tile's list assuming triangles.
    cl.primListFormat(list, cl.LIST_TRIANGLES);
    if (frame.binned) {
        cl.setInstanceId(list, 0);
        cl.branchToImplicitTileList(list);
    }
    cl.store(list, cl.STORE_RENDER_TARGET_0, frame.format, frame.swap_rb, frame.image, frame.stride);
    list.byte(cl.CLEAR_RENDER_TARGETS);
    list.byte(cl.END_OF_TILE_MARKER);
    list.byte(cl.RETURN_FROM_SUB_LIST);
}

/// The frame's list: `tile_start` to `tile_end` is `writeTileList`'s.
pub fn writeRender(list: *List, frame: *const Frame, tile_start: u32, tile_end: u32) void {
    const tiles_x = frame.tilesX();
    const tiles_y = frame.tilesY();
    cl.renderingCommon(list, frame.width, frame.height, tile_pixels, frame.depth);
    cl.renderTarget0(list, tile_pixels, frame.clear);
    cl.zsClear(list, frame.clear_depth);
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
    cl.genericTileList(list, tile_start, tile_end);
    const area = frame.area orelse Area{ .left = 0, .top = 0, .right = frame.width, .bottom = frame.height };
    const across = supertile_w * tile_pixels;
    const down = supertile_h * tile_pixels;
    var row = area.top / down;
    while (row < frame_h and row * down < area.bottom) : (row += 1) {
        var column = area.left / across;
        while (column < frame_w and column * across < area.right) : (column += 1) {
            cl.supertileCoordinates(list, column, row);
        }
    }
    list.byte(cl.END_OF_RENDERING);
}

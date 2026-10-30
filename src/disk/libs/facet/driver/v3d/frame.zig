// SPDX-License-Identifier: MIT
//! A frame's render control list: its tiles cleared, what was binned for
//! them drawn, and each stored in rows of pixels (v3dx_rcl.c in Mesa).

const cl = @import("cl.zig");
const List = cl.List;

/// Tiles this size hold 32 bits a pixel: 16 KiB of the colour buffer.
pub const tile_pixels: u32 = 64;
/// How many supertiles a frame may have, and not this many in a row.
const most_supertiles: u32 = 256;

/// Batches of 16 vertices the VCM caches, for 1 sector out of half the VPM:
/// what Mesa's sum comes to for these programs.
const vcm_batches: u32 = 4;

pub const Frame = struct {
    width: u32,
    height: u32,
    image: u32,
    stride: u32,
    /// The image is blue first, not red.
    swap_rb: bool,
    /// As it lies in the tile buffer: red in the low byte.
    clear: u32,
    /// The binner's lists, or memory the renderer will not read.
    tile_lists: u32,
    /// Whether the binner ran, so that a tile has a list to draw.
    binned: bool,

    pub fn tilesX(frame: *const Frame) u32 {
        return (frame.width + tile_pixels - 1) / tile_pixels;
    }

    pub fn tilesY(frame: *const Frame) u32 {
        return (frame.height + tile_pixels - 1) / tile_pixels;
    }
};

/// The binner's list for a frame: its fixed state, then `count` vertices as
/// triangles with the shader state at `record`.
pub fn writeBin(list: *List, frame: *const Frame, record: u32, attributes: u32, count: u32) void {
    cl.binningMode(list, frame.width, frame.height, tile_pixels);
    list.byte(cl.FLUSH_VCD_CACHE);
    cl.occlusionQueryOff(list);
    list.byte(cl.START_TILE_BINNING);

    cl.clipWindow(list, 0, 0, frame.width, frame.height);
    cl.cfgBits(list);
    cl.colorWriteMasks(list);
    cl.sampleState(list);
    list.byte(cl.ZERO_ALL_FLAT_SHADE_FLAGS);
    list.byte(cl.ZERO_ALL_NON_PERSPECTIVE_FLAGS);
    list.byte(cl.ZERO_ALL_CENTROID_FLAGS);
    cl.pointSize(list, 1.0);
    cl.lineWidth(list, 1.0);
    const half_width: f32 = @floatFromInt(frame.width);
    const half_height: f32 = @floatFromInt(frame.height);
    cl.clipperXy(list, half_width * 32.0, half_height * 32.0);
    cl.clipperZ(list, 0.5, 0.5);
    cl.clipperZLimits(list, 0.0, 1.0);
    cl.viewportOffset(list, frame.width / 2, frame.height / 2);
    cl.vcmCacheSize(list, vcm_batches, vcm_batches);
    cl.glShaderState(list, record, attributes);
    cl.vertexArrayPrims(list, cl.PRIM_TRIANGLES, count, 0);
    list.byte(cl.FLUSH);
}

/// What each tile does, in its own list: `render` branches to it for every
/// tile.
pub fn writeTileList(list: *List, frame: *const Frame) void {
    list.byte(cl.TILE_COORDINATES_IMPLICIT);
    list.byte(cl.END_OF_LOADS);
    // The binner starts each tile's list assuming triangles.
    cl.primListFormat(list, cl.LIST_TRIANGLES);
    if (frame.binned) {
        cl.setInstanceId(list, 0);
        cl.branchToImplicitTileList(list);
    }
    cl.store(list, cl.STORE_RENDER_TARGET_0, frame.swap_rb, frame.image, frame.stride);
    list.byte(cl.CLEAR_RENDER_TARGETS);
    list.byte(cl.END_OF_TILE_MARKER);
    list.byte(cl.RETURN_FROM_SUB_LIST);
}

/// The frame's list: `tile_start` to `tile_end` is `writeTileList`'s.
pub fn writeRender(list: *List, frame: *const Frame, tile_start: u32, tile_end: u32) void {
    const tiles_x = frame.tilesX();
    const tiles_y = frame.tilesY();
    cl.renderingCommon(list, frame.width, frame.height, tile_pixels);
    cl.renderTarget0(list, tile_pixels, frame.clear);
    cl.zsClear(list, 1.0);
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
        cl.store(list, cl.STORE_NONE, false, 0, 0);
        if (round == 0) list.byte(cl.CLEAR_RENDER_TARGETS);
        list.byte(cl.END_OF_TILE_MARKER);
    }
    list.byte(cl.FLUSH_VCD_CACHE);
    cl.genericTileList(list, tile_start, tile_end);
    var row: u32 = 0;
    while (row < frame_h) : (row += 1) {
        var column: u32 = 0;
        while (column < frame_w) : (column += 1) {
            cl.supertileCoordinates(list, column, row);
        }
    }
    list.byte(cl.END_OF_RENDERING);
}

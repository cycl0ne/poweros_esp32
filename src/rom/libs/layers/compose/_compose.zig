// SPDX-License-Identifier: MPL-2.0
//! A composed LayerInfo: every layer draws into a buffer of its own, and
//! what of each can be seen is copied on to the display.
//!
//! Sharing the display's buffer is right where memory is slow, as on the
//! ESP32s: every pixel is written once, where the display reads it. The
//! 64-bit machines are the other way round. Their memory reads back fast,
//! a buffer the display scans out of is better written than read, and
//! what a window loses to being covered costs its program a redraw. So a
//! composed layer has all of itself, always:
//!
//! - **Drawing** goes into the layer's own buffer, every part of it,
//!   covered or not. Its RastPort has one list of targets - the buffer,
//!   cut only by the program's own clip and an update's damage - which
//!   nothing done to the other layers changes.
//! - **What was drawn** is handed on through the buffer's `watch` hook
//!   rather than to the board, and the part of it that can be seen is
//!   copied on to the display there and then, in the task that drew it.
//!   Drawing between `BeginDraw` and `EndDraw` is handed on at the end,
//!   so a window is never copied half drawn.
//! - **What covers what** is worked out as ever (`retile`), and decides
//!   only which layer each pixel of the display is copied from. A layer
//!   uncovered, moved or brought forward is copied, not drawn again: no
//!   damage, no keeping, nothing carried across the display.
//!
//! A caller's picture shown over part of a layer (`ShowLayerPicture`) is
//! copied from where it is in place of that part of the buffer, whenever
//! the layer is: a swapchain's image shown in a window, without a copy
//! into the window first.
//!
//! The buffer is attached to the display's board (rtg's AttachBitMap), so
//! the board's engine draws in it as it draws on the display; its memory
//! is this library's, from exec, and none of the board's own. A super
//! layer's buffer is its bitmap, attached the same way, and its scroll is
//! only where the copying reads from.
//!
//! It is built only where it is of use, on the 64-bit machines: on the
//! others `on` is false at compile time and none of it is in the image.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const layers = sdk.layers;
const rtg = sdk.rtg;
const utility = sdk.utility;
const Rect = graphics.Rect;

const info_mod = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = info_mod.LayerInfo;
const Layer = info_mod.Layer;
const Buffer = info_mod.Buffer;
const LayersBase = @import("../layers.zig").LayersBase;
const super = @import("../super/_super.zig");

/// Whether this build composes at all. The 32-bit machines are the
/// ESP32s, where the display's memory is what everything waits on and a
/// copy of every pixel drawn would be one more trip through it.
pub const built = @sizeOf(usize) == 8;

/// Whether a LayerInfo's layers are composed.
///
/// INPUTS:
/// - `info` - the LayerInfo.
pub inline fn on(info: *const LayerInfo) bool {
    return built and info.compose;
}

/// What a row of a buffer is rounded to, and where its pixels start: a
/// cache line, as graphics.library's own bitmaps have it, so no two rows
/// share one and cores drawing different rows do not contend for it.
const line = 64;

/// The board a LayerInfo's display is a buffer of, or null when it is
/// plain memory, which cannot be composed.
///
/// INPUTS:
/// - `info` - the LayerInfo.
pub fn boardOf(info: *const LayerInfo) ?*rtg.RtgBoard {
    const display = info.bitmap orelse return null;
    return @ptrCast(@alignCast(display.board orelse return null));
}

/// A buffer `width` by `height` in the display's format, attached to the
/// display's board. Null without memory.
///
/// INPUTS:
/// - `lb` - the library: exec for the memory, rtg for the handle.
/// - `info` - the display it is for.
/// - `width` - how wide.
/// - `height` - how tall.
/// - `clear` - whether it starts as zeros; otherwise it holds whatever the
///   memory held, for a caller that is about to paint all of it.
pub fn make(lb: *LayersBase, info: *LayerInfo, width: u32, height: u32, clear: bool) ?Buffer {
    const sys = lb.sys_base;
    const board = boardOf(info) orelse return null;
    const format = info.surface.format;
    const row = rtg.bitmaps.formatRowBytes(format, width);
    if (row == 0 or height == 0) return null;
    const pitch = (row + line - 1) & ~@as(u32, line - 1);
    const pixels_bytes = @as(usize, pitch) * height;
    const bytes = pixels_bytes + line;
    const memory = sys.AllocMem(bytes, if (clear) exec.MEMF_CLEAR else exec.MEMF_ANY) orelse return null;
    // The layer's, not the task's that happened to make or size it.
    _ = sys.SetMemOwner(memory, null);
    const start = (@intFromPtr(memory) + line - 1) & ~@as(usize, line - 1);
    const described = rtg.RtgBitMap{
        .pixels = @ptrFromInt(start),
        .width = width,
        .height = height,
        .pitch = pitch,
        .size_bytes = pixels_bytes,
        .format = format,
    };
    const bitmap = lb.rtg_base.AttachBitMap(board, &described) orelse {
        sys.FreeMem(memory, bytes);
        return null;
    };
    _ = sys.SetMemOwner(bitmap, null);
    return .{ .bitmap = bitmap, .memory = memory, .bytes = bytes };
}

/// Give a buffer back: the handle to rtg, the memory to exec.
///
/// INPUTS:
/// - `lb` - the library.
/// - `buffer` - what `make` or `take` made.
pub fn free(lb: *LayersBase, buffer: Buffer) void {
    buffer.bitmap.watch = null;
    lb.rtg_base.FreeBitMap(buffer.bitmap);
    if (buffer.memory) |memory| lb.sys_base.FreeMem(memory, buffer.bytes);
}

/// A buffer becomes the one a layer draws into, and what is drawn in it
/// is told to this library from then on.
fn adopt(layer: *Layer, buffer: Buffer) void {
    layer.own = buffer;
    layer.watch = .{ .entry = &watched, .data = layer };
    buffer.bitmap.watch = &layer.watch;
}

/// The buffer a new layer of a composed LayerInfo draws into, made before
/// the layer is on the list. False without memory.
///
/// A super layer's is its bitmap. Any other's is a buffer its size; one
/// that asked for no backfill starts as what the display shows where it
/// lies, as it would drawn straight on to the display, and as nothing
/// where it hangs off the display.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer, with its bounds, flags, backfill and bitmap.
pub fn take(lb: *LayersBase, layer: *Layer) bool {
    const info = layer.info;
    if (layer.super) |bm| {
        const board = boardOf(info) orelse return false;
        const described = rtg.RtgBitMap{
            .pixels = bm.pixels,
            .width = bm.width,
            .height = bm.height,
            .pitch = bm.pitch,
            .size_bytes = bm.size_bytes,
            .format = bm.format,
        };
        const bitmap = lb.rtg_base.AttachBitMap(board, &described) orelse return false;
        _ = lb.sys_base.SetMemOwner(bitmap, null);
        adopt(layer, .{ .bitmap = bitmap });
        return true;
    }
    const plain = layer.backfill == layers.LAYERS_NOBACKFILL;
    const buffer = make(lb, info, @intCast(layer.bounds.width()), @intCast(layer.bounds.height()), plain) orelse return false;
    if (plain) {
        const seen = Rect.intersect(layer.bounds, info.bounds);
        if (!seen.isEmpty()) _ = lb.graphics_base.BltBitMap(
            info.surface,
            seen.min_x,
            seen.min_y,
            @ptrCast(buffer.bitmap),
            seen.min_x - layer.bounds.min_x,
            seen.min_y - layer.bounds.min_y,
            seen.width(),
            seen.height(),
        );
    }
    adopt(layer, buffer);
    return true;
}

/// A layer's buffer given back, as the layer goes.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer, off the list.
pub fn drop(lb: *LayersBase, layer: *Layer) void {
    layer.picture = null;
    const buffer = layer.own orelse return;
    layer.own = null;
    free(lb, buffer);
}

/// `picture` shown over `area` of a layer, in the layer's coordinates and
/// cut to the picture's size, and what of it can be seen copied on to the
/// display. False, and nothing shown, for a picture not in the display's
/// pixels or an area it does not reach. The caller holds the layer.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer, composed and not a super one.
/// - `picture` - the picture, the caller's.
/// - `area` - where in the layer.
pub fn showPicture(lb: *LayersBase, layer: *Layer, picture: *const rtg.Surface, area: Rect) bool {
    if (picture.format != layer.info.surface.format) return false;
    const reach = Rect{
        .min_x = area.min_x,
        .min_y = area.min_y,
        .max_x = @min(area.max_x, area.min_x + @as(i32, @intCast(picture.width))),
        .max_y = @min(area.max_y, area.min_y + @as(i32, @intCast(picture.height))),
    };
    if (reach.isEmpty()) return false;
    layer.picture = picture;
    layer.picture_area = reach;
    const ox, const oy = super.origin(layer);
    showLayer(lb, layer, .{ .min_x = reach.min_x + ox, .min_y = reach.min_y + oy, .max_x = reach.max_x + ox, .max_y = reach.max_y + oy });
    return true;
}

/// The picture a layer shows put into its buffer, where it stays, and no
/// longer shown in place of it: the display shows the same as before.
/// The caller holds the layer.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
pub fn keepPicture(lb: *LayersBase, layer: *Layer) void {
    const picture = layer.picture orelse return;
    layer.picture = null;
    const own = layer.own orelse return;
    const area = Rect.intersect(layer.picture_area, .{ .max_x = @intCast(own.bitmap.width), .max_y = @intCast(own.bitmap.height) });
    if (area.isEmpty()) return;
    const from_x = area.min_x - layer.picture_area.min_x;
    const from_y = area.min_y - layer.picture_area.min_y;
    _ = lb.graphics_base.BltBitMap(picture, from_x, from_y, @ptrCast(own.bitmap), area.min_x, area.min_y, area.width(), area.height());
}

/// A layer that changes size takes `fresh`, a buffer of the new size,
/// with as much of the old one copied into it as fits at its top left.
/// The old one is given back. The caller holds every layer and makes the
/// targets again: they still name the old buffer.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
/// - `fresh` - its new buffer, from `make`.
pub fn replace(lb: *LayersBase, layer: *Layer, fresh: Buffer) void {
    const old = layer.own orelse {
        adopt(layer, fresh);
        return;
    };
    const width = @min(old.bitmap.width, fresh.bitmap.width);
    const height = @min(old.bitmap.height, fresh.bitmap.height);
    const copy = rtg.RtgCopy{ .width = @intCast(width), .height = @intCast(height) };
    if (lb.rtg_base.CopyRect(old.bitmap, fresh.bitmap, &copy) != rtg.errors.RTGERR_OK) {
        _ = lb.graphics_base.BltBitMap(@ptrCast(old.bitmap), 0, 0, @ptrCast(fresh.bitmap), 0, 0, @intCast(width), @intCast(height));
    }
    free(lb, old);
    adopt(layer, fresh);
}

/// What the hook of a layer's buffer is told: a rectangle of it was
/// drawn. What of it can be seen is copied on to the display.
fn watched(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const layer: *Layer = @ptrCast(@alignCast(hook.data orelse return 0));
    const written: *const rtg.RtgRect = @ptrCast(@alignCast(message orelse return 0));
    const lb: *LayersBase = @ptrCast(@alignCast(layer.info.lb));
    const ox, const oy = super.origin(layer);
    showLayer(lb, layer, .{
        .min_x = written.x + ox,
        .min_y = written.y + oy,
        .max_x = written.x + written.width + ox,
        .max_y = written.y + written.height + oy,
    });
    return 0;
}

/// How many pieces of a layer's visible region are read without asking
/// exec for room: a window under one or two others is a handful.
const pieces_at_hand = 16;

/// What of one layer can be seen inside `area`, copied from its buffer on
/// to the display.
///
/// It is called from whichever task drew, holding that layer, so it
/// touches only what the layer's lock keeps still - its place and what it
/// can see - and no pool of the LayerInfo's, which the other layers' tasks
/// share. A piece is copied through the LayerInfo's own RastPort on the
/// display and handed on from there, by the engine where the board has
/// one.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
/// - `area` - where, in the display's coordinates.
pub fn showLayer(lb: *LayersBase, layer: *Layer, area: Rect) void {
    const gb = lb.graphics_base;
    const own = layer.own orelse return;
    const dest = layer.info.display_rp orelse return;
    const cut = Rect.intersect(area, layer.bounds);
    if (cut.isEmpty()) return;
    const ox, const oy = super.origin(layer);

    var at_hand: [pieces_at_hand]Rect = undefined;
    const n = gb.RegionRectangles(layer.visible, &at_hand, pieces_at_hand);
    if (n == 0) return;
    var pieces: []const Rect = at_hand[0..@min(n, pieces_at_hand)];
    var room: ?*anyopaque = null;
    defer if (room) |memory| lb.sys_base.FreeVec(memory);
    if (n > pieces_at_hand) {
        room = lb.sys_base.AllocVec(n * @sizeOf(Rect), exec.MEMF_ANY);
        if (room) |memory| {
            const all: [*]Rect = @ptrCast(@alignCast(memory));
            _ = gb.RegionRectangles(layer.visible, all, n);
            pieces = all[0..n];
        }
    }
    const over = if (layer.picture) |_| Rect{
        .min_x = layer.picture_area.min_x + ox,
        .min_y = layer.picture_area.min_y + oy,
        .max_x = layer.picture_area.max_x + ox,
        .max_y = layer.picture_area.max_y + oy,
    } else Rect{};
    for (pieces) |r| {
        const piece = Rect.intersect(r, cut);
        if (piece.isEmpty()) continue;
        const shown = Rect.intersect(piece, over);
        if (shown.isEmpty()) {
            gb.BltBitMapRastPort(@ptrCast(own.bitmap), piece.min_x - ox, piece.min_y - oy, dest, piece.min_x, piece.min_y, piece.width(), piece.height());
            continue;
        }
        gb.BltBitMapRastPort(layer.picture.?, shown.min_x - over.min_x, shown.min_y - over.min_y, dest, shown.min_x, shown.min_y, shown.width(), shown.height());
        // The rest of the piece, around the picture: above, below, and
        // to either side of it.
        const around = [4]Rect{
            .{ .min_x = piece.min_x, .min_y = piece.min_y, .max_x = piece.max_x, .max_y = shown.min_y },
            .{ .min_x = piece.min_x, .min_y = shown.max_y, .max_x = piece.max_x, .max_y = piece.max_y },
            .{ .min_x = piece.min_x, .min_y = shown.min_y, .max_x = shown.min_x, .max_y = shown.max_y },
            .{ .min_x = shown.max_x, .min_y = shown.min_y, .max_x = piece.max_x, .max_y = shown.max_y },
        };
        for (around) |rest| {
            if (rest.isEmpty()) continue;
            gb.BltBitMapRastPort(@ptrCast(own.bitmap), rest.min_x - ox, rest.min_y - oy, dest, rest.min_x, rest.min_y, rest.width(), rest.height());
        }
    }
}

/// Everything inside `area` copied on to the display again, each pixel
/// from the layer that can be seen there. What no layer covers is left as
/// it is.
///
/// The caller holds every layer, so no layer is drawn meanwhile, and the
/// whole of it is handed on to the board at once.
///
/// INPUTS:
/// - `lb` - the library.
/// - `info` - the display.
/// - `area` - where, in the display's coordinates.
pub fn show(lb: *LayersBase, info: *LayerInfo, area: Rect) void {
    if (!on(info)) return;
    const cut = Rect.intersect(area, info.bounds);
    if (cut.isEmpty()) return;
    const gb = lb.graphics_base;
    const dest = info.display_rp orelse return;
    gb.BeginDraw(dest);
    defer gb.EndDraw(dest);
    var it = info.layers.iterator();
    while (it.next()) |node| {
        const layer: *Layer = @fieldParentPtr("node", node);
        showLayer(lb, layer, cut);
    }
}

/// `show` for every rectangle of a region, handed on to the board at
/// once. Without the memory to read the region, its bounding rectangle
/// is shown: more is copied, never less.
///
/// INPUTS:
/// - `lb` - the library.
/// - `info` - the display.
/// - `region` - where, in the display's coordinates.
pub fn showRegion(lb: *LayersBase, info: *LayerInfo, region: *graphics.Region) void {
    if (!on(info)) return;
    const gb = lb.graphics_base;
    const sys = lb.sys_base;
    const dest = info.display_rp orelse return;
    const n = gb.RegionRectangles(region, null, 0);
    if (n == 0) return;
    gb.BeginDraw(dest);
    defer gb.EndDraw(dest);
    const bytes = n * @sizeOf(Rect);
    const memory = sys.AllocPooled(info.pool, bytes) orelse {
        show(lb, info, info.bounds);
        return;
    };
    defer sys.FreePooled(info.pool, memory, bytes);
    const rects: [*]Rect = @ptrCast(@alignCast(memory));
    _ = gb.RegionRectangles(region, rects, n);
    for (rects[0..n]) |r| show(lb, info, r);
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// The composing is tested with the calls in layers.zig, where a board and
// a display can be made.

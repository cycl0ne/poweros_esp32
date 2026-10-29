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
//! A layer that is nothing but its backfill - a screen's ground, which a
//! buffer would cost the size of the display - can have none
//! (`LATAG_NoBuffer`). Where it is seen it is painted on to the display by
//! its backfill whenever it is shown, as a layer with a buffer is copied,
//! and darkened after where shadows fall on it: fresh, then darkened, so
//! a shadow is never laid twice. Its RastPort draws nowhere.
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
const TagItem = utility.TagItem;

const info_mod = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = info_mod.LayerInfo;
const Layer = info_mod.Layer;
const Buffer = info_mod.Buffer;
const LayersBase = @import("../layers.zig").LayersBase;
const super = @import("../super/_super.zig");
const backfill = @import("../backfill/_backfill.zig");
const effects = @import("_effects.zig");

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

/// What a new layer of a composed LayerInfo that has no buffer
/// (`LATAG_NoBuffer`) paints through, made before the layer is on the
/// list: a handle on the display's memory, attached to its board so the
/// engine paints there, and whose hand-on is nobody's - what is painted
/// is handed on with the rest of what is shown. False without memory.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer: simple, with a backfill.
pub fn takeBare(lb: *LayersBase, layer: *Layer) bool {
    const info = layer.info;
    const board = boardOf(info) orelse return false;
    const display = info.bitmap orelse return false;
    const described = rtg.RtgBitMap{
        .pixels = display.pixels,
        .width = display.width,
        .height = display.height,
        .pitch = display.pitch,
        .size_bytes = display.size_bytes,
        .format = display.format,
    };
    const bitmap = lb.rtg_base.AttachBitMap(board, &described) orelse return false;
    _ = lb.sys_base.SetMemOwner(bitmap, null);
    layer.watch = .{ .entry = &unwatched, .data = layer };
    bitmap.watch = &layer.watch;
    layer.through = bitmap;
    return true;
}

/// Whether a layer has no buffer of its own and is only what its backfill
/// paints.
///
/// INPUTS:
/// - `layer` - the layer.
pub inline fn bare(layer: *const Layer) bool {
    return built and layer.through != null;
}

/// A layer's buffer given back, as the layer goes.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer, off the list.
pub fn drop(lb: *LayersBase, layer: *Layer) void {
    layer.picture = null;
    if (layer.through) |bitmap| {
        layer.through = null;
        free(lb, .{ .bitmap = bitmap });
    }
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

/// A layer that changes size takes the memory of `fresh`, a buffer of the
/// new size, with as much of the old picture copied into it as fits at its
/// top left. The old memory is given back, and so is `fresh`'s handle: the
/// layer keeps the handle it had, with the new memory and shape in it. So
/// whatever names the buffer goes on naming it - above all a batch open on
/// it (`BeginDraw`), which goes on in the new memory: all of it is then
/// left for the batch's end to show, and the result is true; the caller
/// leaves the rest of the move to it too (`Layer.unshown`). The caller
/// holds every layer and makes the targets again, for their rectangles.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
/// - `fresh` - its new buffer, from `make`.
///
/// RESULT:
/// True when a batch is open on the buffer and the layer is to be shown
/// at its end, not by the caller.
///
/// NOTES:
/// The batch's fields are graphics.library's, changed under its batches'
/// lock; here they are written under every layer's, which is as good for
/// a buffer only its own layer draws in: nothing draws in it meanwhile.
pub fn replace(lb: *LayersBase, layer: *Layer, fresh: Buffer) bool {
    const old = layer.own orelse {
        adopt(layer, fresh);
        return false;
    };
    const width = @min(old.bitmap.width, fresh.bitmap.width);
    const height = @min(old.bitmap.height, fresh.bitmap.height);
    const copy = rtg.RtgCopy{ .width = @intCast(width), .height = @intCast(height) };
    if (lb.rtg_base.CopyRect(old.bitmap, fresh.bitmap, &copy) != rtg.errors.RTGERR_OK) {
        _ = lb.graphics_base.BltBitMap(@ptrCast(old.bitmap), 0, 0, @ptrCast(fresh.bitmap), 0, 0, @intCast(width), @intCast(height));
    }
    // The memory changes hands, each handle taking the other's: the
    // layer's handle the new memory, `fresh`'s the old to be given back.
    const kept = old.bitmap;
    const spare = fresh.bitmap;
    const shape = .{ kept.pixels, kept.width, kept.height, kept.pitch, kept.size_bytes };
    kept.pixels = spare.pixels;
    kept.width = spare.width;
    kept.height = spare.height;
    kept.pitch = spare.pitch;
    kept.size_bytes = spare.size_bytes;
    spare.pixels, spare.width, spare.height, spare.pitch, spare.size_bytes = shape;
    free(lb, .{ .bitmap = spare, .memory = old.memory, .bytes = old.bytes });
    layer.own = .{ .bitmap = kept, .memory = fresh.memory, .bytes = fresh.bytes };
    if (kept.held == 0) return false;
    kept.dirty_left = 0;
    kept.dirty_top = 0;
    kept.dirty_right = kept.width;
    kept.dirty_end = kept.height;
    return true;
}

/// Every move left to a batch's end (`replace`) whose batch has ended
/// shown, all of it: for a batch that ended without the layers held,
/// whose end showed the layer alone. The caller holds every layer.
pub fn showUnshown(lb: *LayersBase, info: *LayerInfo) void {
    if (!on(info)) return;
    var it = info.layers.iterator();
    while (it.next()) |node| {
        const layer: *Layer = @fieldParentPtr("node", node);
        if (layer.unshown.isEmpty()) continue;
        if (layer.own) |own| if (own.bitmap.held != 0) continue;
        const area = layer.unshown;
        layer.unshown = .{};
        show(lb, info, area);
    }
}

/// Whether this task holds every layer of `info` (`LockLayers`).
fn holdsAll(lb: *LayersBase, info: *const LayerInfo) bool {
    const me = lb.sys_base.FindTask(null) orelse return false;
    return info.locked_all != 0 and info.lock.owner == me;
}

/// What the hook of a layer's buffer is told: a rectangle of it was
/// drawn. What of it can be seen is copied on to the display.
fn watched(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const layer: *Layer = @ptrCast(@alignCast(hook.data orelse return 0));
    const written: *const rtg.RtgRect = @ptrCast(@alignCast(message orelse return 0));
    const lb: *LayersBase = @ptrCast(@alignCast(layer.info.lb));
    const ox, const oy = super.origin(layer);
    const area = Rect{
        .min_x = written.x + ox,
        .min_y = written.y + oy,
        .max_x = written.x + written.width + ox,
        .max_y = written.y + written.height + oy,
    };
    // A move left to a batch's end is shown whole - where the layer was,
    // and its shadow - by `showUnshown` as the layers are let go of. When
    // the task ending the batch holds them, that is in a moment, and what
    // was drawn goes with it rather than being copied twice; otherwise the
    // layer is shown now, and the rest whenever they are next let go of.
    if (!layer.unshown.isEmpty() and holdsAll(lb, layer.info)) {
        layer.unshown = layer.unshown.unionWith(area);
        return 0;
    }
    showLayer(lb, layer, area);
    return 0;
}

/// What the display's handle a bare layer paints through is told: nothing
/// to do. Whoever is showing it hands what it painted on.
fn unwatched(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    _ = object;
    _ = message;
    return 0;
}

/// How many pieces of a layer's visible region are read without asking
/// exec for room: a window under one or two others is a handful.
const pieces_at_hand = 16;

/// How a piece of a layer reaches the display's buffer: copied, or laid
/// over what is there at the layer's opacity. Either way it is handed on
/// to the board by the caller, through a `Gather`.
const How = enum { copied, laid };

/// What has been copied on to the display and not yet handed on to the
/// board. Each handing on is a command to the board - on virtio a trip
/// out of the machine - so the pieces of a drawing go as one box around
/// them while that box is mostly what was copied, and a new box is begun
/// where it would be mostly what was not. Handing on pixels that did not
/// change is only a little more to send: they are what the display holds.
const Gather = struct {
    box: Rect = .{},
    /// How many of the box's pixels were copied.
    copied: u64 = 0,

    fn add(g: *Gather, lb: *LayersBase, info: *const LayerInfo, piece: Rect) void {
        const size = pixels(piece);
        if (!g.box.isEmpty()) {
            const joined = Rect.unionWith(g.box, piece);
            if (pixels(joined) <= 2 * (g.copied + size)) {
                g.box = joined;
                g.copied += size;
                return;
            }
            g.handOn(lb, info);
        }
        g.box = piece;
        g.copied = size;
    }

    fn handOn(g: *Gather, lb: *LayersBase, info: *const LayerInfo) void {
        if (g.box.isEmpty()) return;
        const box = g.box;
        g.* = .{};
        const display = info.bitmap orelse return;
        _ = lb.rtg_base.RefreshRect(display, &.{ .x = box.min_x, .y = box.min_y, .width = box.width(), .height = box.height() });
    }

    fn pixels(r: Rect) u64 {
        return @as(u64, @intCast(r.width())) * @as(u64, @intCast(r.height()));
    }
};

/// A rectangle of `from` - `x`, `y` its corner there - on to `piece` of
/// the display, `how` says how. `bitmap` is `from` as a board's buffer,
/// or null for a picture in memory of the caller's.
fn put(lb: *LayersBase, layer: *const Layer, from: *const rtg.Surface, bitmap: ?*rtg.RtgBitMap, x: i32, y: i32, piece: Rect, how: How) void {
    const gb = lb.graphics_base;
    const rb = lb.rtg_base;
    const display = layer.info.bitmap orelse return;
    const rect = rtg.RtgRect{ .x = piece.min_x, .y = piece.min_y, .width = piece.width(), .height = piece.height() };
    if (how == .laid) {
        const pixels = rtg.RtgPixels{
            .pixels = from.pixels,
            .pitch = from.pitch,
            .format = from.format,
            .flags = rtg.RTGPIXF_OPAQUE,
            .x = x,
            .y = y,
        };
        // A board that cannot lay it over has it copied: seen whole a
        // moment early, rather than not at all.
        if (rb.BlendPixels(display, &rect, &pixels, layer.opacity) == rtg.errors.RTGERR_OK) return;
    }
    // The engine reads only a source's surface, so a picture in plain
    // memory is described to it as a bitmap, as graphics.library does.
    var described = rtg.RtgBitMap{
        .pixels = from.pixels,
        .width = from.width,
        .height = from.height,
        .pitch = from.pitch,
        .size_bytes = from.size_bytes,
        .format = from.format,
        .flags = from.flags,
    };
    const copy = rtg.RtgCopy{ .src_x = x, .src_y = y, .width = piece.width(), .height = piece.height(), .dest_x = piece.min_x, .dest_y = piece.min_y };
    if (rb.CopyRect(bitmap orelse &described, display, &copy) == rtg.errors.RTGERR_OK) return;
    _ = gb.BltBitMap(from, x, y, @ptrCast(display), piece.min_x, piece.min_y, piece.width(), piece.height());
}

/// Where the picture a layer shows lies on the display, or nothing.
fn pictureOn(layer: *const Layer) Rect {
    if (layer.picture == null) return .{};
    const ox, const oy = super.origin(layer);
    return .{
        .min_x = layer.picture_area.min_x + ox,
        .min_y = layer.picture_area.min_y + oy,
        .max_x = layer.picture_area.max_x + ox,
        .max_y = layer.picture_area.max_y + oy,
    };
}

/// A piece of a layer, in the display's coordinates and inside what it
/// can see, on to the display: from its buffer, and from the picture it
/// shows where the piece is under that.
fn putLayer(lb: *LayersBase, layer: *const Layer, piece: Rect, how: How) void {
    const own = layer.own orelse return;
    const ox, const oy = super.origin(layer);
    const buffer: *const rtg.Surface = @ptrCast(own.bitmap);
    const over = pictureOn(layer);
    const shown = Rect.intersect(piece, over);
    if (shown.isEmpty()) {
        put(lb, layer, buffer, own.bitmap, piece.min_x - ox, piece.min_y - oy, piece, how);
        return;
    }
    put(lb, layer, layer.picture.?, null, shown.min_x - over.min_x, shown.min_y - over.min_y, shown, how);
    // The rest of the piece, around the picture: above, below, and to
    // either side of it.
    const around = [4]Rect{
        .{ .min_x = piece.min_x, .min_y = piece.min_y, .max_x = piece.max_x, .max_y = shown.min_y },
        .{ .min_x = piece.min_x, .min_y = shown.max_y, .max_x = piece.max_x, .max_y = piece.max_y },
        .{ .min_x = piece.min_x, .min_y = shown.min_y, .max_x = shown.min_x, .max_y = shown.max_y },
        .{ .min_x = shown.max_x, .min_y = shown.min_y, .max_x = piece.max_x, .max_y = shown.max_y },
    };
    for (around) |rest| {
        if (!rest.isEmpty()) put(lb, layer, buffer, own.bitmap, rest.min_x - ox, rest.min_y - oy, rest, how);
    }
}

/// The pieces of one layer copied from its buffer on to the display
/// together: one job of the board's engine for all of them (rtg's
/// `CopyRects`) rather than one a piece, each of which wakes every core
/// and waits for them. A piece the layer's picture shows over comes from
/// two places and goes by itself, as before.
///
/// With a `Gather`, each piece is then darkened where the shadows of the
/// layers in front fall on it - before it is handed on, so it is never
/// seen without them - and gathered to be handed on. The pieces do not
/// overlap, so copying them all before darkening any is the same
/// picture. Without one the caller does both.
const Batch = struct {
    copies: [rtg.RTG_MAX_COPIES]rtg.RtgCopy = undefined,
    pieces: [rtg.RTG_MAX_COPIES]Rect = undefined,
    count: u32 = 0,
    gather: ?*Gather = null,

    fn add(b: *Batch, lb: *LayersBase, layer: *const Layer, piece: Rect) void {
        if (!Rect.intersect(piece, pictureOn(layer)).isEmpty()) {
            b.flush(lb, layer);
            putLayer(lb, layer, piece, .copied);
            b.finish(lb, layer, piece);
            return;
        }
        if (b.count == b.copies.len) b.flush(lb, layer);
        const ox, const oy = super.origin(layer);
        b.copies[b.count] = .{
            .src_x = piece.min_x - ox,
            .src_y = piece.min_y - oy,
            .width = piece.width(),
            .height = piece.height(),
            .dest_x = piece.min_x,
            .dest_y = piece.min_y,
        };
        b.pieces[b.count] = piece;
        b.count += 1;
    }

    /// What is collected copied on to the display. A board that does not
    /// take the copies together has them each the way `putLayer` copies
    /// one - again, where it took some of them before it stopped.
    fn flush(b: *Batch, lb: *LayersBase, layer: *const Layer) void {
        if (b.count == 0) return;
        const pieces = b.pieces[0..b.count];
        b.count = 0;
        const own = layer.own orelse return;
        const display = layer.info.bitmap orelse return;
        if (lb.rtg_base.CopyRects(own.bitmap, display, &b.copies, @intCast(pieces.len)) != rtg.errors.RTGERR_OK) {
            for (pieces) |piece| putLayer(lb, layer, piece, .copied);
        }
        for (pieces) |piece| b.finish(lb, layer, piece);
    }

    fn finish(b: *Batch, lb: *LayersBase, layer: *const Layer, piece: Rect) void {
        land(lb, layer, piece, b.gather orelse return);
    }
};

/// A piece just put on the display from `layer`, darkened where the
/// shadows of the layers in front fall on it - before it is handed on, so
/// it is never seen without them - and gathered to be handed on.
fn land(lb: *LayersBase, layer: *const Layer, piece: Rect, gather: *Gather) void {
    if (layer.info.shaded and effects.shadedFront(layer, piece)) effects.darkenFront(lb, layer, piece);
    gather.add(lb, layer.info, piece);
}

/// A piece of a bare layer, in the display's coordinates and inside what
/// it can see, painted on to the display by the layer's backfill: through
/// its own RastPort, narrowed to the piece for the call. The caller holds
/// every layer, so nothing else draws through that RastPort meanwhile.
fn paintBare(lb: *LayersBase, layer: *Layer, piece: Rect) void {
    const through = layer.through orelse return;
    const gb = lb.graphics_base;
    const ox, const oy = super.origin(layer);
    var target = graphics.ClipTarget{
        .rect = .{ .min_x = piece.min_x - ox, .min_y = piece.min_y - oy, .max_x = piece.max_x - ox, .max_y = piece.max_y - oy },
        .surface = @ptrCast(through),
        .bitmap = through,
        .dx = ox,
        .dy = oy,
    };
    gb.SetRPAttrs(layer.rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipTargets, .data = @intFromPtr(&target) }, .{} });
    backfill.fill(lb, layer, target.rect);
    gb.SetRPAttrs(layer.rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipTargets, .data = @intFromPtr(layer.targets) }, .{} });
}

/// The pieces of a layer's visible region, `at_hand` or from exec, for
/// `each` to be called with every one of them inside `cut`.
fn eachPiece(lb: *LayersBase, layer: *const Layer, cut: Rect, context: anytype, comptime each: fn (@TypeOf(context), Rect) void) void {
    const gb = lb.graphics_base;
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
    for (pieces) |r| {
        const piece = Rect.intersect(r, cut);
        if (!piece.isEmpty()) each(context, piece);
    }
}

/// What of one layer can be seen inside `area`, copied from its buffer on
/// to the display.
///
/// It is called from whichever task drew, holding that layer, so it
/// touches only what the layer's lock keeps still - its place and what it
/// can see, and every other layer's, which change only while all are
/// held - and no pool of the LayerInfo's, which the other layers' tasks
/// share; nor the LayerInfo's RastPort, whose batch is not for two tasks
/// at once. Each piece is copied on to the display's buffer, by the
/// engine where the board has one, darkened where a shadow falls on it,
/// and the pieces are handed on to the board together after.
///
/// What is seen through, or under something seen through, waits: laying
/// it over what is behind it is for `show`, which copies that first.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer.
/// - `area` - where, in the display's coordinates.
pub fn showLayer(lb: *LayersBase, layer: *Layer, area: Rect) void {
    var gather = Gather{};
    copyLayer(lb, layer, area, &gather);
    gather.handOn(lb, layer.info);
}

/// `showLayer`, its pieces gathered for the caller to hand on. A bare
/// layer's are painted rather than copied.
fn copyLayer(lb: *LayersBase, layer: *Layer, area: Rect, gather: *Gather) void {
    if (layer.own == null and !bare(layer)) return;
    if (layer.opacity != 255) return;
    const cut = Rect.intersect(area, layer.bounds);
    if (cut.isEmpty()) return;
    const Each = struct {
        lb: *LayersBase,
        layer: *Layer,
        batch: *Batch,

        fn piece(each: @This(), r: Rect) void {
            if (!each.layer.info.veiled) return each.put(r);
            var parts: [effects.most_unveiled]Rect = undefined;
            const n = effects.unveiled(each.layer, r, &parts);
            for (parts[0..n]) |part| each.put(part);
        }

        fn put(each: @This(), r: Rect) void {
            if (!bare(each.layer)) return each.batch.add(each.lb, each.layer, r);
            paintBare(each.lb, each.layer, r);
            land(each.lb, each.layer, r, each.batch.gather.?);
        }
    };
    var batch = Batch{ .gather = gather };
    eachPiece(lb, layer, cut, Each{ .lb = lb, .layer = layer, .batch = &batch }, Each.piece);
    batch.flush(lb, layer);
}

/// Everything inside `area` copied on to the display again, each pixel
/// from the layer that can be seen there - painted, from a bare one. What
/// no layer covers is left as it is.
///
/// The caller holds every layer, so no layer is drawn meanwhile, and the
/// whole of it is handed on to the board at once. With shadows, or a
/// layer seen through, it is done in order, back to front: each layer's
/// shadow laid over what is behind it, then the layer copied over that -
/// or laid over it, seen through.
///
/// INPUTS:
/// - `lb` - the library.
/// - `info` - the display.
/// - `area` - where, in the display's coordinates.
pub fn show(lb: *LayersBase, info: *LayerInfo, area: Rect) void {
    var gather = Gather{};
    showInto(lb, info, area, &gather);
    gather.handOn(lb, info);
}

/// `show`, what it copies gathered for the caller to hand on.
fn showInto(lb: *LayersBase, info: *LayerInfo, area: Rect, gather: *Gather) void {
    if (!on(info)) return;
    const cut = Rect.intersect(area, info.bounds);
    if (cut.isEmpty()) return;
    if (!info.veiled and !info.shaded) {
        var it = info.layers.iterator();
        while (it.next()) |node| {
            const layer: *Layer = @fieldParentPtr("node", node);
            copyLayer(lb, layer, cut, gather);
        }
        return;
    }
    const Each = struct {
        lb: *LayersBase,
        layer: *Layer,
        batch: *Batch,

        fn piece(each: @This(), r: Rect) void {
            if (bare(each.layer)) return paintBare(each.lb, each.layer, r);
            if (each.layer.opacity != 255) return putLayer(each.lb, each.layer, r, .laid);
            each.batch.add(each.lb, each.layer, r);
        }
    };
    var at = info.layers.last();
    while (at) |node| {
        const layer: *Layer = @fieldParentPtr("node", node);
        at = if (node.pred.?.pred == null) null else node.pred;
        effects.darken(lb, layer, cut);
        if (layer.own != null or bare(layer)) {
            // Each layer's copied before the next one's shadow falls on it.
            var batch = Batch{};
            eachPiece(lb, layer, cut, Each{ .lb = lb, .layer = layer, .batch = &batch }, Each.piece);
            batch.flush(lb, layer);
        }
    }
    gather.add(lb, info, cut);
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
    const n = gb.RegionRectangles(region, null, 0);
    if (n == 0) return;
    const bytes = n * @sizeOf(Rect);
    const memory = sys.AllocPooled(info.pool, bytes) orelse {
        show(lb, info, info.bounds);
        return;
    };
    defer sys.FreePooled(info.pool, memory, bytes);
    const rects: [*]Rect = @ptrCast(@alignCast(memory));
    _ = gb.RegionRectangles(region, rects, n);
    var gather = Gather{};
    for (rects[0..n]) |r| showInto(lb, info, r, &gather);
    gather.handOn(lb, info);
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// The composing is tested with the calls in layers.zig, where a board and
// a display can be made.

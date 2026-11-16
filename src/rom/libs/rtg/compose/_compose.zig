// SPDX-License-Identifier: MPL-2.0
//! The picture of a board, as the library composes it.
//!
//! A display reaches its pixels one of two ways. It reads the shown
//! buffers itself (**direct**): its driver says how many bands it reads
//! so. Or it has a picture of its own - a controller's memory behind a
//! bus, an emulator's copy - and its driver fills in `update`: "this
//! rectangle of the display changed". The library composes that picture.
//! It keeps what goes into it - the board's bands, the overlay and the
//! pointer, each with its place - and hands the driver the pixels of any
//! rectangle as they are to be seen (`lines`, which is ComposeLines): each
//! line from the band that covers it, the overlay over that, the pointer
//! over both. So a board whose driver wrote none of them has bands, an
//! overlay and a pointer.
//!
//! Everything that goes into the picture changes under the board's
//! **compose lock**, and the driver's `update` runs inside it: what was
//! written into a shown buffer (`handOn`), a pointer or an overlay set,
//! shown or moved, and a show. A move is the rectangle the image left and
//! the one it came to, handed to `update`: it costs the image's size, not
//! the picture's.
//!
//! A board that has both ways is shown **direct while plain**: for as
//! long as nothing lies over the picture - no more bands than the display
//! reads itself, no overlay, no pointer of the library's. When that
//! changes the board is shown again the other way (`settle`), and back
//! when it is plain again.
//!
//! A pointer or an overlay the board lays itself - a cursor plane, a
//! stream's own copy (`RtgPointerOps`, `RtgOverlayOps`) - is not the
//! library's to lay: its calls go to the driver, under the same lock.
//!
//! A display that is flipped between frames (`flip`) is composed the
//! same, into the frame it is not reading: what changes is noted, and a
//! task of the board's makes the next picture of it (`_flip.zig`).
//!
//! Locks: the board's lock is taken before its compose lock, and on a
//! flipped board the flip lock between the two. A show holds them all.
//! A pointer or an overlay set or shown may change how the board is
//! shown, and takes them too; a move takes the compose lock alone, and
//! so does a hand-on, which on a flipped board takes none but the damage
//! lock.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const err = rtg.errors;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const shows = @import("../display/_display.zig");
const flips = @import("_flip.zig");

/// What the library keeps for a board's picture, beside the bands
/// (`Private.bands`), the pointer and the overlay (`RtgBoard`).
pub const State = struct {
    /// The compose lock.
    lock: exec.SignalSemaphore = .{},
    /// How many bands the display reads itself, as its driver said.
    direct_bands: u32 = 0,
    /// Whether the display reads the shown buffers itself now. Clear: it
    /// shows its own picture, which the library composes.
    direct: bool = true,
    /// The picture's size, and the bytes a pixel of it takes, in the mode
    /// the bands are shown in - 0 bytes where a pixel is not whole bytes,
    /// which the library does not compose.
    width: u32 = 0,
    height: u32 = 0,
    bytes: u32 = 0,
    format: rtg.PixelFormat = .rgb565,
    /// The frames of a board that is flipped, and what changed since a
    /// picture was last made in one (`_flip.zig`).
    flip: flips.State = .{},
};

/// A board's compose state.
///
/// INPUTS:
/// - `board` - the board.
pub fn stateOf(board: *rtg.RtgBoard) *State {
    return &boards.privateOf(board).compose;
}

/// Takes a board's compose lock.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board.
pub fn obtain(rb: *RtgBase, board: *rtg.RtgBoard) void {
    rb.sys_base.ObtainSemaphore(&stateOf(board).lock);
}

/// Gives a board's compose lock back.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, its compose lock taken by `obtain`.
pub fn release(rb: *RtgBase, board: *rtg.RtgBoard) void {
    rb.sys_base.ReleaseSemaphore(&stateOf(board).lock);
}

/// Takes the locks a show is made under, and a change that may show the
/// board another way: the flip lock of a flipped board, then the compose
/// lock.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock is held.
pub fn obtainWhole(rb: *RtgBase, board: *rtg.RtgBoard) void {
    flips.obtain(rb, board);
    obtain(rb, board);
}

/// Gives the two back: the compose lock first, so that a pointer moves
/// while the frame of a flip made under them is waited for.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, its locks taken by `obtainWhole`.
pub fn releaseWhole(rb: *RtgBase, board: *rtg.RtgBoard) void {
    release(rb, board);
    flips.release(rb, board);
}

/// Whether the library composes a picture for the board: its display has
/// one of its own, or is flipped between frames.
///
/// INPUTS:
/// - `board` - the board.
pub fn composes(board: *const rtg.RtgBoard) bool {
    const ops = board.ops orelse return false;
    return ops.update != null or ops.flip != null;
}

/// Whether the board's pointer is the library's to lay.
///
/// INPUTS:
/// - `board` - the board.
pub fn laysPointer(board: *const rtg.RtgBoard) bool {
    return composes(board) and board.ops.?.pointer == null;
}

/// Whether the board's overlay is the library's to lay.
///
/// INPUTS:
/// - `board` - the board.
pub fn laysOverlay(board: *const rtg.RtgBoard) bool {
    return composes(board) and board.ops.?.overlay == null;
}

/// Whether the display shows the library's picture now: something is
/// shown, and not direct.
///
/// INPUTS:
/// - `board` - the board; its compose lock is held.
pub fn composing(board: *rtg.RtgBoard) bool {
    const private = boards.privateOf(board);
    return composes(board) and private.band_count != 0 and !private.compose.direct;
}

/// Whether bands can be read by the display itself as things stand:
/// always on a board the library composes nothing for; else no more of
/// them than the display reads, and nothing of the library's over them.
///
/// INPUTS:
/// - `board` - the board; its compose lock is held.
/// - `bands` - the bands, checked for the board's mode.
pub fn plain(board: *rtg.RtgBoard, bands: []const rtg.RtgBand) bool {
    if (!composes(board)) return true;
    if (flips.flipped(board)) return readsBuffer(board, bands);
    const reads = stateOf(board).direct_bands;
    if (bands.len > reads) return false;
    // A display that reads one band reads one whole buffer.
    if (reads == 1 and bands.len == 1 and (bands[0].flags != 0 or bands[0].origin != 0)) return false;
    if (laysOverlay(board) and board.overlay != null) return false;
    if (laysPointer(board) and board.pointer != null and board.info.flags & rtg.boards.RTGBF_POINTER != 0) return false;
    return true;
}

/// Whether a flipped board's display is to read a buffer in place of a
/// frame, as things stand: on a board that says it can
/// (`RTGBF_DIRECT_FLIP`), one whole buffer shown in place of another
/// that nothing was written in while it was shown - or in place of
/// itself while the display reads it so - with nothing of the library's
/// over the picture. That is a program that draws a picture in one
/// buffer while it shows another and then shows that one. A screen drawn
/// in while it is shown is shown frames.
///
/// INPUTS:
/// - `board` - a flipped board; its compose lock is held, and the bands
///   it shows are still in place.
/// - `bands` - the bands it is to show.
fn readsBuffer(board: *rtg.RtgBoard, bands: []const rtg.RtgBand) bool {
    if (board.info.flags & rtg.boards.RTGBF_DIRECT_FLIP == 0) return false;
    const private = boards.privateOf(board);
    const state = &private.compose;
    if (state.flip.written) return false;
    if (bands.len != 1 or private.band_count != 1) return false;
    const new = bands[0];
    const old = private.bands[0];
    if (new.flags != 0 or new.origin != 0 or old.flags != 0 or old.origin != 0) return false;
    if (laysOverlay(board) and board.overlay != null) return false;
    if (laysPointer(board) and board.pointer != null and board.info.flags & rtg.boards.RTGBF_POINTER != 0) return false;
    if (new.bitmap == old.bitmap and !state.direct) return false;
    return true;
}

/// Whether the library composes pixels of that format: whole bytes each.
///
/// INPUTS:
/// - `rb` - the library.
/// - `format` - the pixel format.
pub fn takes(rb: *RtgBase, format: rtg.PixelFormat) bool {
    const bits = rb.iface().RtgFormatBits(@intFromEnum(format));
    return bits != 0 and bits % 8 == 0;
}

/// What a board's picture was made of, kept across a show that may be
/// refused (`place`, `putBack`).
pub const Kept = struct {
    bands: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined,
    count: u32 = 0,
    direct: bool = true,
    width: u32 = 0,
    height: u32 = 0,
    bytes: u32 = 0,
    format: rtg.PixelFormat = .rgb565,
};

/// The bands a picture is to be made of put in place, for a show about to
/// be asked of the driver: what `lines` reads from now on.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock and its compose lock are held.
/// - `mode` - the mode the bands are shown in.
/// - `bands` - the bands.
/// - `direct` - whether the display is to read them itself.
///
/// RESULT:
/// What was in place before, for `putBack`.
pub fn place(rb: *RtgBase, board: *rtg.RtgBoard, mode: *const rtg.RtgMode, bands: []const rtg.RtgBand, direct: bool) Kept {
    const private = boards.privateOf(board);
    const state = &private.compose;
    var kept = Kept{ .count = private.band_count, .direct = state.direct, .width = state.width, .height = state.height, .bytes = state.bytes, .format = state.format };
    for (private.bands[0..private.band_count], 0..) |band, i| kept.bands[i] = band;
    // On a flipped board what is written meanwhile is turned into the
    // display's rectangles through the bands, with no lock but this.
    flips.holdBands(rb, board);
    for (bands, 0..) |band, i| private.bands[i] = band;
    private.band_count = @intCast(bands.len);
    flips.letBands(rb, board);
    state.direct = direct;
    state.width = mode.width;
    state.height = mode.height;
    state.bytes = if (takes(rb, mode.format)) rb.iface().RtgFormatBits(@intFromEnum(mode.format)) / 8 else 0;
    state.format = mode.format;
    return kept;
}

/// What was in place before a show that was refused, in place again.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock and its compose lock are held.
/// - `kept` - what `place` answered.
pub fn putBack(rb: *RtgBase, board: *rtg.RtgBoard, kept: *const Kept) void {
    const private = boards.privateOf(board);
    const state = &private.compose;
    flips.holdBands(rb, board);
    for (kept.bands[0..kept.count], 0..) |band, i| private.bands[i] = band;
    private.band_count = kept.count;
    flips.letBands(rb, board);
    state.direct = kept.direct;
    state.width = kept.width;
    state.height = kept.height;
    state.bytes = kept.bytes;
    state.format = kept.format;
}

/// The board shows nothing from now on: no band is in place.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock and its compose lock are held.
pub fn empty(rb: *RtgBase, board: *rtg.RtgBoard) void {
    flips.holdBands(rb, board);
    boards.privateOf(board).band_count = 0;
    flips.letBands(rb, board);
}

// --- the picture's pixels ----------------------------------------------------

/// The band display line `y` is in: the last that starts at or above it.
fn bandAt(bands: []const rtg.RtgBand, y: u32) ?*const rtg.RtgBand {
    var i = bands.len;
    while (i > 0) {
        i -= 1;
        if (bands[i].line <= y) return &bands[i];
    }
    return null;
}

/// The pixels of a rectangle of the board's picture as they are to be
/// seen: each line from the band that covers it - black where none does -
/// then the overlay and the pointer over them, where they are the
/// library's to lay.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its compose lock is held.
/// - `area` - the rectangle, in the picture's own coordinates.
/// - `into` - where the pixels go: the rectangle's first row first.
/// - `pitch` - bytes from one row of `into` to the next.
///
/// RESULT:
/// RTGERR_OK; RTGERR_BAD_ARG for a rectangle that is empty or not wholly
/// inside the picture; RTGERR_BAD_FORMAT in a mode whose pixels are not
/// whole bytes, and on a board in no mode.
pub fn lines(rb: *RtgBase, board: *rtg.RtgBoard, area: *const rtg.RtgRect, into: [*]u8, pitch: u32) i32 {
    const sys = rb.sys_base;
    const private = boards.privateOf(board);
    const state = &private.compose;
    if (state.bytes == 0) return err.RTGERR_BAD_FORMAT;
    if (area.width <= 0 or area.height <= 0 or area.x < 0 or area.y < 0) return err.RTGERR_BAD_ARG;
    if (@as(i64, area.x) + area.width > state.width or @as(i64, area.y) + area.height > state.height) return err.RTGERR_BAD_ARG;
    const left: u32 = @intCast(area.x);
    const top: u32 = @intCast(area.y);
    const row_bytes: u32 = @as(u32, @intCast(area.width)) * state.bytes;
    const rows: u32 = @intCast(area.height);
    const bands = private.bands[0..private.band_count];

    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        const out = into + @as(usize, row) * pitch;
        const y = top + row;
        const band = bandAt(bands, y) orelse {
            @memset(out[0..row_bytes], 0);
            continue;
        };
        const source_row: u32 = if (band.flags & rtg.RTGBANDF_REPEAT != 0) 0 else y - band.origin;
        const bitmap = band.bitmap;
        const from = bitmap.pixels.? + @as(usize, source_row) * bitmap.pitch + @as(usize, left) * state.bytes;
        sys.CopyMem(from, out, row_bytes);
    }

    if (laysOverlay(board)) lay(state, board.overlay, board.overlay_x, board.overlay_y, area, into, pitch);
    if (laysPointer(board) and board.info.flags & rtg.boards.RTGBF_POINTER != 0) {
        lay(state, board.pointer, board.pointer_x, board.pointer_y, area, into, pitch);
    }
    return err.RTGERR_OK;
}

/// One image laid over the pixels of a rectangle: a masked copy of the
/// part of it that is inside.
fn lay(state: *const State, given: ?*const rtg.RtgPointerImage, x: i32, y: i32, area: *const rtg.RtgRect, into: [*]u8, pitch: u32) void {
    const image = given orelse return;
    const where = cutTo(imageRect(image, x, y), area) orelse return;
    // An image made for another format than the picture's is in none the
    // picture can take: it comes back with the next set.
    if (image.format != state.format) return;
    const bytes = state.bytes;
    const image_left: i64 = @as(i64, x) - image.hot_x;
    const image_top: i64 = @as(i64, y) - image.hot_y;
    var row: i32 = 0;
    while (row < where.height) : (row += 1) {
        const image_y: u32 = @intCast(@as(i64, where.y) + row - image_top);
        const out = into + @as(usize, @intCast(where.y + row - area.y)) * pitch + @as(usize, @intCast(where.x - area.x)) * bytes;
        const mask = image.mask + @as(usize, image_y) * image.mask_pitch;
        const pixels = image.pixels + @as(usize, image_y) * image.pitch;
        var column: i32 = 0;
        while (column < where.width) : (column += 1) {
            const image_x: u32 = @intCast(@as(i64, where.x) + column - image_left);
            if (mask[image_x / 8] & (@as(u8, 0x80) >> @intCast(image_x % 8)) == 0) continue;
            const from = pixels + @as(usize, image_x) * bytes;
            const to = out + @as(usize, @intCast(column)) * bytes;
            var i: u32 = 0;
            while (i < bytes) : (i += 1) to[i] = from[i];
        }
    }
}

// --- rectangles of the display -------------------------------------------------

/// A rectangle as wide numbers, so a place a caller put anywhere cannot
/// wrap.
const Wide = struct { left: i64, top: i64, right: i64, bottom: i64 };

/// The rectangle an image covers with its point at (x, y).
fn imageRect(image: *const rtg.RtgPointerImage, x: i32, y: i32) Wide {
    const left = @as(i64, x) - image.hot_x;
    const top = @as(i64, y) - image.hot_y;
    return .{ .left = left, .top = top, .right = left + image.width, .bottom = top + image.height };
}

/// The part of a rectangle inside another, or null when none of it is.
fn cutTo(wide: Wide, area: *const rtg.RtgRect) ?rtg.RtgRect {
    const left = @max(wide.left, area.x);
    const top = @max(wide.top, area.y);
    const right = @min(wide.right, @as(i64, area.x) + area.width);
    const bottom = @min(wide.bottom, @as(i64, area.y) + area.height);
    if (left >= right or top >= bottom) return null;
    return .{ .x = @intCast(left), .y = @intCast(top), .width = @intCast(right - left), .height = @intCast(bottom - top) };
}

/// The part of the picture an image covers with its point at (x, y), or
/// null: no image, or none of it on the picture.
fn onPicture(state: *const State, given: ?*const rtg.RtgPointerImage, x: i32, y: i32) ?rtg.RtgRect {
    const image = given orelse return null;
    return cutTo(imageRect(image, x, y), &.{ .width = @intCast(state.width), .height = @intCast(state.height) });
}

/// Where the library's pointer is seen on the picture, or null: not the
/// library's, not shown, no image, or off the picture.
fn pointerRect(board: *rtg.RtgBoard) ?rtg.RtgRect {
    if (!laysPointer(board)) return null;
    if (board.info.flags & rtg.boards.RTGBF_POINTER == 0) return null;
    return onPicture(stateOf(board), board.pointer, board.pointer_x, board.pointer_y);
}

/// Where the library's overlay is seen on the picture, or null.
fn overlayRect(board: *rtg.RtgBoard) ?rtg.RtgRect {
    if (!laysOverlay(board)) return null;
    return onPicture(stateOf(board), board.overlay, board.overlay_x, board.overlay_y);
}

/// The rectangles of the picture one change touched: where each image was
/// and where it is. Two that overlap or touch are one, so a short move is
/// one rectangle to deliver and a long one two.
const Changed = struct {
    rects: [4]rtg.RtgRect = undefined,
    count: u32 = 0,

    fn add(changed: *Changed, given: ?rtg.RtgRect) void {
        var grown = given orelse return;
        var i: u32 = 0;
        while (i < changed.count) {
            const other = changed.rects[i];
            const apart = grown.x > other.x + other.width or other.x > grown.x + grown.width or
                grown.y > other.y + other.height or other.y > grown.y + grown.height;
            if (apart) {
                i += 1;
                continue;
            }
            const left = @min(grown.x, other.x);
            const top = @min(grown.y, other.y);
            const right = @max(grown.x + grown.width, other.x + other.width);
            const bottom = @max(grown.y + grown.height, other.y + other.height);
            grown = .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
            changed.count -= 1;
            changed.rects[i] = changed.rects[changed.count];
            i = 0;
        }
        changed.rects[changed.count] = grown;
        changed.count += 1;
    }
};

/// The rectangles a change touched delivered, where the display shows
/// the library's picture: handed to the driver's `update`, or on a
/// flipped board noted for the next picture.
fn deliver(rb: *RtgBase, board: *rtg.RtgBoard, changed: *const Changed) void {
    if (!composing(board)) return;
    if (flips.flipped(board)) return flips.note(rb, board, changed.rects[0..changed.count]);
    const update = board.ops.?.update.?;
    for (changed.rects[0..changed.count]) |*rect| _ = update(board, rect);
}

/// After a change to what lies over the picture: the board shown the
/// other way where it is plain no longer, or plain again; else the
/// rectangles the change touched delivered.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock, its flip lock where it is flipped
///   and its compose lock are held.
/// - `changed` - where the images were and are.
///
/// RESULT:
/// RTGERR_OK, or what the driver answered a show of its own picture
/// with: the display then reads what it read, and the change is the
/// caller's to take back.
fn settle(rb: *RtgBase, board: *rtg.RtgBoard, changed: *const Changed) i32 {
    const private = boards.privateOf(board);
    const state = &private.compose;
    if (private.band_count == 0) return err.RTGERR_OK;
    const direct = plain(board, private.bands[0..private.band_count]);
    if (direct != state.direct) {
        if (!direct and state.bytes == 0) return err.RTGERR_BAD_FORMAT;
        state.direct = direct;
        const code = shows.otherWay(rb, board);
        if (code == err.RTGERR_OK) return code;
        state.direct = !direct;
        // A display that would not go back to reading the buffers itself
        // shows the library's picture still, without the image.
        if (!direct) return code;
    }
    deliver(rb, board, changed);
    return err.RTGERR_OK;
}

// --- what was written, handed on ---------------------------------------------------

/// A rectangle of a buffer that was written, handed on to its board: to
/// the driver's `refresh`, and where the display shows the library's
/// picture, the lines of the bands that show the buffer to its `update`.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the buffer's board.
/// - `bitmap` - the buffer.
/// - `cut` - the rectangle, cut down to the buffer.
///
/// RESULT:
/// RTGERR_OK, RTGERR_NOT_SUPPORTED for a board that needs no telling, or
/// what the driver answered.
pub fn handOn(rb: *RtgBase, board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, cut: *const rtg.RtgRect) i32 {
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    // A flipped board's display reads none of its buffers: what was
    // written is noted, with no lock a picture being made holds.
    if (ops.flip != null) return flips.written(rb, board, bitmap, cut);
    const update = ops.update orelse {
        const refresh = ops.refresh orelse return err.RTGERR_NOT_SUPPORTED;
        return refresh(board, bitmap, cut);
    };
    obtain(rb, board);
    defer release(rb, board);
    var code: i32 = err.RTGERR_OK;
    if (ops.refresh) |refresh| code = refresh(board, bitmap, cut);
    if (!composing(board)) return code;

    const private = boards.privateOf(board);
    const state = &private.compose;
    const shown = private.bands[0..private.band_count];
    const top: u32 = @intCast(cut.y);
    const rows_end: u32 = top + @as(u32, @intCast(cut.height));
    // No further right than the picture: a buffer is the mode's width.
    const right: u32 = @min(@as(u32, @intCast(cut.x + cut.width)), state.width);
    if (@as(u32, @intCast(cut.x)) >= right) return code;
    for (shown, 0..) |band, i| {
        if (band.bitmap != bitmap) continue;
        const band_end = if (i + 1 < shown.len) shown[i + 1].line else state.height;
        // The display lines that show the rows written.
        var first: u32 = band.line;
        var end: u32 = band_end;
        if (band.flags & rtg.RTGBANDF_REPEAT != 0) {
            if (top != 0) continue;
        } else {
            first = @max(band.line, top +| band.origin);
            end = @min(band_end, rows_end +| band.origin);
        }
        if (first >= end) continue;
        const answer = update(board, &.{ .x = cut.x, .y = @intCast(first), .width = @intCast(right - @as(u32, @intCast(cut.x))), .height = @intCast(end - first) });
        if (code == err.RTGERR_OK) code = answer;
    }
    return code;
}

// --- the pointer and the overlay ---------------------------------------------------

/// The locks a pointer's or an overlay's change is made under: the
/// compose lock - and, where the library lays the image (`own`), the
/// board's lock and a flipped board's flip lock before it, as the board
/// may then be shown another way.
fn hold(rb: *RtgBase, board: *rtg.RtgBoard, own: bool) void {
    if (!own) return obtain(rb, board);
    boards.obtain(rb, board);
    obtainWhole(rb, board);
}

fn letGo(rb: *RtgBase, board: *rtg.RtgBoard, own: bool) void {
    if (!own) return release(rb, board);
    releaseWhole(rb, board);
    boards.release(rb, board);
}

/// A board's pointer given an image, or none: handed to the board's own
/// pointer where it has one, else laid by the library from now on.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, one with RTGBC_POINTER.
/// - `made` - the image, converted; null for none.
///
/// RESULT:
/// RTGERR_OK, and the image before is freed; or what the driver
/// answered, and the board keeps the image it had.
pub fn setPointer(rb: *RtgBase, board: *rtg.RtgBoard, made: ?*rtg.RtgPointerImage) i32 {
    const sys = rb.sys_base;
    const own = laysPointer(board);
    hold(rb, board, own);
    defer letGo(rb, board, own);

    const old = board.pointer;
    if (own) {
        var changed = Changed{};
        changed.add(pointerRect(board));
        board.pointer = made;
        changed.add(pointerRect(board));
        const code = settle(rb, board, &changed);
        if (code != err.RTGERR_OK) {
            board.pointer = old;
            return code;
        }
    } else {
        const group = board.ops.?.pointer.?;
        const code = group.set(board, made);
        if (code != err.RTGERR_OK) return code;
        board.pointer = made;
        if (made) |now| group.move(board, board.pointer_x - @as(i32, @intCast(now.hot_x)), board.pointer_y - @as(i32, @intCast(now.hot_y)));
    }
    // Nothing reads the old one any more: the driver's set has returned,
    // and the library's picture is made of the new.
    if (old) |gone| sys.FreeVec(gone);
    return err.RTGERR_OK;
}

/// A board's pointer shown or hidden.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, one with RTGBC_POINTER.
/// - `show` - whether it is to be seen.
///
/// RESULT:
/// RTGERR_OK, or what the driver answered: the pointer is then as it
/// was.
pub fn showPointer(rb: *RtgBase, board: *rtg.RtgBoard, show: bool) i32 {
    const own = laysPointer(board);
    hold(rb, board, own);
    defer letGo(rb, board, own);

    const flag: u32 = rtg.boards.RTGBF_POINTER;
    if ((board.info.flags & flag != 0) == show) return err.RTGERR_OK;
    if (own) {
        var changed = Changed{};
        changed.add(pointerRect(board));
        board.info.flags ^= flag;
        changed.add(pointerRect(board));
        const code = settle(rb, board, &changed);
        if (code != err.RTGERR_OK) board.info.flags ^= flag;
        return code;
    }
    const code = board.ops.?.pointer.?.show(board, show);
    if (code == err.RTGERR_OK) board.info.flags ^= flag;
    return code;
}

/// The pointer's point put at (x, y), and an overlay that follows it
/// with it.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board.
/// - `x`, `y` - where the point goes.
pub fn movePointer(rb: *RtgBase, board: *rtg.RtgBoard, x: i32, y: i32) void {
    obtain(rb, board);
    defer release(rb, board);
    if (board.pointer_x == x and board.pointer_y == y) return;
    const ops = board.ops orelse {
        board.pointer_x = x;
        board.pointer_y = y;
        return;
    };
    const follows = board.overlay_follows != 0;
    var changed = Changed{};
    changed.add(pointerRect(board));
    if (follows) changed.add(overlayRect(board));
    board.pointer_x = x;
    board.pointer_y = y;
    if (follows) {
        board.overlay_x = x;
        board.overlay_y = y;
        if (board.overlay) |overlay| if (ops.overlay) |group| {
            group.move(board, x - @as(i32, @intCast(overlay.hot_x)), y - @as(i32, @intCast(overlay.hot_y)));
        };
        changed.add(overlayRect(board));
    }
    if (board.pointer) |image| if (ops.pointer) |group| {
        group.move(board, x - @as(i32, @intCast(image.hot_x)), y - @as(i32, @intCast(image.hot_y)));
    };
    changed.add(pointerRect(board));
    deliver(rb, board, &changed);
}

/// A board's overlay given an image, or none, its point put at the
/// pointer's, which it follows from now on.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, one with RTGBC_OVERLAY.
/// - `made` - the image, converted; null for none.
///
/// RESULT:
/// RTGERR_OK, and the image before is freed; or what the driver
/// answered, and the board keeps the overlay it had.
pub fn setOverlay(rb: *RtgBase, board: *rtg.RtgBoard, made: ?*rtg.RtgPointerImage) i32 {
    const sys = rb.sys_base;
    const own = laysOverlay(board);
    hold(rb, board, own);
    defer letGo(rb, board, own);

    const old = board.overlay;
    if (own) {
        const was_x = board.overlay_x;
        const was_y = board.overlay_y;
        const was_following = board.overlay_follows;
        var changed = Changed{};
        changed.add(overlayRect(board));
        board.overlay_x = board.pointer_x;
        board.overlay_y = board.pointer_y;
        board.overlay_follows = 1;
        board.overlay = made;
        changed.add(overlayRect(board));
        const code = settle(rb, board, &changed);
        if (code != err.RTGERR_OK) {
            board.overlay = old;
            board.overlay_x = was_x;
            board.overlay_y = was_y;
            board.overlay_follows = was_following;
            return code;
        }
    } else {
        const group = board.ops.?.overlay.?;
        // Placed before it is shown: the driver lays it where it belongs
        // from its first frame.
        board.overlay_x = board.pointer_x;
        board.overlay_y = board.pointer_y;
        board.overlay_follows = 1;
        if (made) |now| group.move(board, board.overlay_x - @as(i32, @intCast(now.hot_x)), board.overlay_y - @as(i32, @intCast(now.hot_y)));
        const code = group.set(board, made);
        if (code != err.RTGERR_OK) return code;
        board.overlay = made;
    }
    if (old) |gone| sys.FreeVec(gone);
    return err.RTGERR_OK;
}

/// The overlay's point put at (x, y), where it stays rather than with
/// the pointer.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board.
/// - `x`, `y` - where the point goes.
pub fn moveOverlay(rb: *RtgBase, board: *rtg.RtgBoard, x: i32, y: i32) void {
    obtain(rb, board);
    defer release(rb, board);
    const was_following = board.overlay_follows != 0;
    board.overlay_follows = 0;
    if (!was_following and board.overlay_x == x and board.overlay_y == y) return;
    var changed = Changed{};
    changed.add(overlayRect(board));
    board.overlay_x = x;
    board.overlay_y = y;
    const image = board.overlay orelse return;
    const ops = board.ops orelse return;
    if (ops.overlay) |group| group.move(board, x - @as(i32, @intCast(image.hot_x)), y - @as(i32, @intCast(image.hot_y)));
    changed.add(overlayRect(board));
    deliver(rb, board, &changed);
}

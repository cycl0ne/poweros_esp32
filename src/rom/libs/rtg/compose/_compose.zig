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
//! A band's buffer need not be the picture's size on such a board. One
//! of another width is scaled as it is composed, by the ratio of the two
//! widths, both ways the same (`_scale.zig`); a line whose row the buffer
//! has not got is black.
//!
//! **Mirrored.** The picture can be mirrored about either axis
//! (`mirror`): by the board's own hardware for the axes its driver said
//! it turns, else by the library as it composes - top to bottom is the
//! rows fetched last first, left to right each row turned round after
//! the images are laid in it. Whoever draws and whoever moves the
//! pointer works in the picture's own coordinates; what the driver is
//! told and what it fetches is in the display's, as the glass has them
//! (`onGlass`). A picture the library mirrors is never read direct.
//!
//! **Dark.** A board that is blank or asleep (`darken`) shows black for
//! as long: the library composes black, and delivers nothing of what is
//! drawn or moved meanwhile - all of which is kept, and is on the glass
//! with the first picture after. A board the library composes nothing
//! for is shown nothing instead, its bands kept by the library. A dark
//! board is never read direct either.
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
//! reads itself, none of another size than the picture's, no overlay, no
//! pointer of the library's, no mirror of the library's - and the board
//! is not dark. When that
//! changes the board is shown again the other way (`settle`), and back
//! when it is plain again.
//!
//! A pointer or an overlay the board lays itself - a cursor plane, a
//! stream's own copy (`RtgPointerOps`, `RtgOverlayOps`) - is not the
//! library's to lay: its calls go to the driver, under the same lock.
//! But for as long as the library mirrors the picture: a plane lies over
//! the picture as it is, not as it is turned, so the board's own is
//! taken off and the library lays the image into the picture it mirrors,
//! and hands it back to the plane when the picture is unturned again
//! (`planes`).
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
const scaling = @import("_scale.zig");

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
    /// The picture mirrored by the library as it composes it, about each
    /// axis: what the board's own hardware does not turn.
    mirror_x: bool = false,
    mirror_y: bool = false,
    /// The axes the board's own hardware turns (`RTGBC_MIRROR_X`,
    /// `RTGBC_MIRROR_Y`), as its driver said, and which of them it has
    /// turned now.
    turns: u32 = 0,
    turned_x: bool = false,
    turned_y: bool = false,
    /// The board is blank or asleep: the library composes black, or -
    /// where it composes nothing - has the driver show nothing.
    dark: bool = false,
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

/// Whether the library mirrors the board's picture itself, about either
/// axis.
fn mirrors(board: *rtg.RtgBoard) bool {
    const state = stateOf(board);
    return state.mirror_x or state.mirror_y;
}

/// Whether the board's pointer is the library's to lay: on a board
/// whose picture it composes, where the board lays none itself, and for
/// as long as the library mirrors the picture.
///
/// INPUTS:
/// - `board` - the board; its compose lock is held, or the answer is
///   asked again once it is.
pub fn laysPointer(board: *rtg.RtgBoard) bool {
    return composes(board) and (board.ops.?.pointer == null or mirrors(board));
}

/// Whether the board's overlay is the library's to lay, as its pointer.
///
/// INPUTS:
/// - `board` - the board; its compose lock is held, or the answer is
///   asked again once it is.
pub fn laysOverlay(board: *rtg.RtgBoard) bool {
    return composes(board) and (board.ops.?.overlay == null or mirrors(board));
}

/// The board's own pointer and overlay - a cursor plane, a plane for a
/// dragged icon - taken off, or given what the board has again: for a
/// picture the library begins to mirror, and one it mirrors no more.
///
/// INPUTS:
/// - `board` - the board; its compose lock is held.
/// - `on` - whether the planes show the images again.
fn planes(board: *rtg.RtgBoard, on: bool) void {
    const ops = board.ops orelse return;
    const shown = board.info.flags & rtg.boards.RTGBF_POINTER != 0;
    if (ops.pointer) |group| {
        if (on) {
            _ = group.set(board, board.pointer);
            if (board.pointer) |image| group.move(board, board.pointer_x - @as(i32, @intCast(image.hot_x)), board.pointer_y - @as(i32, @intCast(image.hot_y)));
            if (shown) _ = group.show(board, true);
        } else {
            if (shown) _ = group.show(board, false);
            // The image may be changed and freed while the library lays
            // it: the plane keeps none.
            _ = group.set(board, null);
        }
    }
    if (ops.overlay) |group| {
        if (on) {
            if (board.overlay) |image| {
                group.move(board, board.overlay_x - @as(i32, @intCast(image.hot_x)), board.overlay_y - @as(i32, @intCast(image.hot_y)));
                _ = group.set(board, image);
            }
        } else if (board.overlay != null) {
            _ = group.set(board, null);
        }
    }
}

/// Whether the display shows the library's picture now, and is to be
/// delivered what changes of it: something is shown, not direct, and the
/// board is not dark.
///
/// INPUTS:
/// - `board` - the board; its compose lock is held.
pub fn composing(board: *rtg.RtgBoard) bool {
    const private = boards.privateOf(board);
    return composes(board) and private.band_count != 0 and !private.compose.direct and !private.compose.dark;
}

/// Whether a band's buffer is the size of a mode's picture: its width,
/// its rows as far apart, and - unless the band repeats one row - its
/// height. A display reads such a buffer as it is; one of another size
/// is scaled, by the library as it composes or by planes that scale.
///
/// INPUTS:
/// - `mode` - the mode the band is shown in.
/// - `band` - the band.
pub fn sized(mode: *const rtg.RtgMode, band: *const rtg.RtgBand) bool {
    const bitmap = band.bitmap;
    if (bitmap.width != mode.width or bitmap.pitch != mode.pitch) return false;
    return band.flags & rtg.RTGBANDF_REPEAT != 0 or bitmap.height == mode.height;
}

/// Whether the display reads every one of the bands as it is: each the
/// mode's size, or the board's planes scale.
fn readable(board: *const rtg.RtgBoard, mode: *const rtg.RtgMode, bands: []const rtg.RtgBand) bool {
    if (board.info.flags & rtg.boards.RTGBF_SCALES != 0) return true;
    for (bands) |*band| {
        if (!sized(mode, band)) return false;
    }
    return true;
}

/// Whether bands can be read by the display itself as things stand:
/// always on a board the library composes nothing for; else no more of
/// them than the display reads, none the library would scale, and
/// nothing of the library's over them.
///
/// INPUTS:
/// - `board` - the board; its compose lock is held.
/// - `mode` - the mode the bands are shown in.
/// - `bands` - the bands, checked for that mode.
pub fn plain(board: *rtg.RtgBoard, mode: *const rtg.RtgMode, bands: []const rtg.RtgBand) bool {
    if (!composes(board)) return true;
    const state = stateOf(board);
    // A picture the library mirrors or keeps black is its own.
    if (state.mirror_x or state.mirror_y or state.dark) return false;
    if (!readable(board, mode, bands)) return false;
    if (flips.flipped(board)) return readsBuffer(board, bands) or readsBands(board, bands);
    const reads = state.direct_bands;
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

/// Whether a flipped board's display is to read several bands itself,
/// as things stand: on a board that says it reads more than one
/// (`RtgBoardSpec.direct_bands`), two bands or more and no more than it
/// reads, none written in since they were shown, with nothing of the
/// library's over the picture. That is a screen pulled down over
/// another, neither drawn in while it moves. A band written in while the
/// display reads it has the pictures made in frames again.
///
/// INPUTS:
/// - `board` - a flipped board; its compose lock is held.
/// - `bands` - the bands it is to show.
fn readsBands(board: *rtg.RtgBoard, bands: []const rtg.RtgBand) bool {
    const state = stateOf(board);
    if (state.direct_bands < 2 or bands.len < 2 or bands.len > state.direct_bands) return false;
    if (state.flip.written) return false;
    if (laysOverlay(board) and board.overlay != null) return false;
    if (laysPointer(board) and board.pointer != null and board.info.flags & rtg.boards.RTGBF_POINTER != 0) return false;
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

/// Where a rectangle goes: its rows from the first, each a stride on -
/// back, for a picture fetched last row first.
const Target = struct {
    first: [*]u8,
    stride: isize,

    fn row(target: Target, index: u32) [*]u8 {
        const from: isize = @bitCast(@intFromPtr(target.first));
        return @ptrFromInt(@as(usize, @bitCast(from + target.stride * @as(isize, @intCast(index)))));
    }
};

/// The pixels of a rectangle of the board's display as they are to be
/// seen: each line from the band that covers it - scaled where the
/// band's buffer is not the picture's width, black where no band covers
/// it or the buffer has no row for it - then the overlay and the pointer
/// over them, where they are the library's to lay; all of it mirrored
/// where the library mirrors the picture, and black on a board that is
/// dark.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its compose lock is held.
/// - `area` - the rectangle, in the display's coordinates: the picture's
///   own, mirrored where the library mirrors.
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
    const columns: u32 = @intCast(area.width);
    const row_bytes: u32 = columns * state.bytes;
    const rows: u32 = @intCast(area.height);
    if (state.dark) {
        var row: u32 = 0;
        while (row < rows) : (row += 1) @memset((into + @as(usize, row) * pitch)[0..row_bytes], 0);
        return err.RTGERR_OK;
    }
    // The rectangle of the picture the display's shows: itself, or its
    // mirror image - and its rows the other way round where the picture
    // is mirrored top to bottom.
    const of_picture = onGlass(state, area.*);
    const left: u32 = @intCast(of_picture.x);
    const top: u32 = @intCast(of_picture.y);
    const target: Target = if (state.mirror_y)
        .{ .first = into + @as(usize, rows - 1) * pitch, .stride = -@as(isize, @intCast(pitch)) }
    else
        .{ .first = into, .stride = @intCast(pitch) };
    const bands = private.bands[0..private.band_count];

    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        const out = target.row(row);
        const y = top + row;
        const band = bandAt(bands, y) orelse {
            @memset(out[0..row_bytes], 0);
            continue;
        };
        const line: u32 = if (band.flags & rtg.RTGBANDF_REPEAT != 0) 0 else y - band.origin;
        const bitmap = band.bitmap;
        if (bitmap.width != state.width) {
            // A buffer of another width: scaled, both ways the same.
            scaling.row(bitmap, state.width, state.bytes, line, left, columns, out);
            continue;
        }
        // A buffer shorter than its band has no row for the lines past
        // its last.
        if (line >= bitmap.height) {
            @memset(out[0..row_bytes], 0);
            continue;
        }
        const from = bitmap.pixels.? + @as(usize, line) * bitmap.pitch + @as(usize, left) * state.bytes;
        sys.CopyMem(from, out, row_bytes);
    }

    if (laysOverlay(board)) lay(state, board.overlay, board.overlay_x, board.overlay_y, &of_picture, target);
    if (laysPointer(board) and board.info.flags & rtg.boards.RTGBF_POINTER != 0) {
        lay(state, board.pointer, board.pointer_x, board.pointer_y, &of_picture, target);
    }
    // Left to right: each row turned round, with what was laid in it.
    if (state.mirror_x) {
        row = 0;
        while (row < rows) : (row += 1) turnRound(into + @as(usize, row) * pitch, columns, state.bytes);
    }
    return err.RTGERR_OK;
}

/// A row of pixels turned round where it lies: the first the last.
fn turnRound(row: [*]u8, count: u32, bytes: u32) void {
    var near: u32 = 0;
    var far: u32 = count;
    while (near + 1 < far) : (near += 1) {
        far -= 1;
        const a = row + @as(usize, near) * bytes;
        const b = row + @as(usize, far) * bytes;
        var i: u32 = 0;
        while (i < bytes) : (i += 1) {
            const kept = a[i];
            a[i] = b[i];
            b[i] = kept;
        }
    }
}

/// A rectangle of the picture as the display has it, and one of the
/// display as the picture has it - the same turn: mirrored about each
/// axis the library mirrors.
///
/// INPUTS:
/// - `state` - the board's compose state, in the mode the picture is
///   shown in.
/// - `rect` - the rectangle, inside the picture.
pub fn onGlass(state: *const State, rect: rtg.RtgRect) rtg.RtgRect {
    var turned = rect;
    if (state.mirror_x) turned.x = @as(i32, @intCast(state.width)) - rect.x - rect.width;
    if (state.mirror_y) turned.y = @as(i32, @intCast(state.height)) - rect.y - rect.height;
    return turned;
}

/// One image laid over the pixels of a rectangle: a masked copy of the
/// part of it that is inside.
fn lay(state: *const State, given: ?*const rtg.RtgPointerImage, x: i32, y: i32, area: *const rtg.RtgRect, target: Target) void {
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
        const out = target.row(@intCast(where.y + row - area.y)) + @as(usize, @intCast(where.x - area.x)) * bytes;
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
    const state = stateOf(board);
    // As the display has them.
    var rects: [4]rtg.RtgRect = undefined;
    for (changed.rects[0..changed.count], 0..) |rect, i| rects[i] = onGlass(state, rect);
    if (flips.flipped(board)) return flips.note(rb, board, rects[0..changed.count]);
    const update = board.ops.?.update.?;
    for (rects[0..changed.count]) |*rect| _ = update(board, rect);
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
    const record = private.mode orelse return err.RTGERR_OK;
    const direct = plain(board, &record.mode, private.bands[0..private.band_count]);
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

/// The whole picture put on the glass again, after a change to how all
/// of it is made - mirrored, dark or not: the board shown the other way
/// where it is plain no longer, or plain again; else the whole display
/// delivered - by `update`, or on a flipped board noted for the next
/// picture. A board the library composes nothing for has its driver
/// asked for what it shows again.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock, its flip lock where it is flipped
///   and its compose lock are held, and its compose state already says
///   the change.
///
/// RESULT:
/// RTGERR_OK - also where nothing is shown - or what the driver
/// answered: the display then shows what it showed.
fn repaint(rb: *RtgBase, board: *rtg.RtgBoard) i32 {
    const private = boards.privateOf(board);
    const state = &private.compose;
    if (private.band_count == 0) return err.RTGERR_OK;
    const record = private.mode orelse return err.RTGERR_OK;
    if (!composes(board)) return shows.otherWay(rb, board);
    const direct = plain(board, &record.mode, private.bands[0..private.band_count]);
    if (direct != state.direct) {
        if (!direct and state.bytes == 0) return err.RTGERR_BAD_FORMAT;
        state.direct = direct;
        const code = shows.otherWay(rb, board);
        if (code != err.RTGERR_OK) state.direct = !direct;
        return code;
    }
    if (direct) return err.RTGERR_OK;
    const whole = rtg.RtgRect{ .width = @intCast(state.width), .height = @intCast(state.height) };
    if (flips.flipped(board)) {
        flips.note(rb, board, &.{whole});
        return err.RTGERR_OK;
    }
    return board.ops.?.update.?(board, &whole);
}

/// A board made dark, or its picture brought back: the library's blank,
/// for a board that is blank or asleep. Dark, the library composes black
/// and delivers nothing of what is drawn or moved; a board it composes
/// nothing for is shown nothing by its driver, the bands kept here. What
/// was shown or drawn meanwhile is on the glass when it is lit again.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock, its flip lock where it is flipped
///   and its compose lock are held.
/// - `dark` - whether it is to be dark.
///
/// RESULT:
/// RTGERR_OK, or what the driver answered: the board is then as it was.
pub fn darken(rb: *RtgBase, board: *rtg.RtgBoard, dark: bool) i32 {
    const state = stateOf(board);
    if (state.dark == dark) return err.RTGERR_OK;
    state.dark = dark;
    const code = repaint(rb, board);
    if (code != err.RTGERR_OK) state.dark = !dark;
    return code;
}

/// A board's picture mirrored about each axis, or not: by the board's
/// own hardware for the axes its driver said it turns, by the library as
/// it composes for the others, and what is shown put on the glass again.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; none of its locks is held.
/// - `x`, `y` - whether the picture is to be mirrored left to right, and
///   top to bottom.
///
/// RESULT:
/// RTGERR_OK; RTGERR_NOT_SUPPORTED for an axis the board cannot mirror;
/// or what the driver answered. On anything but RTGERR_OK the picture is
/// turned as it was.
pub fn mirror(rb: *RtgBase, board: *rtg.RtgBoard, x: bool, y: bool) i32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    obtainWhole(rb, board);
    defer releaseWhole(rb, board);
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const caps = board.info.caps;
    if (x and caps & rtg.boards.RTGBC_MIRROR_X == 0) return err.RTGERR_NOT_SUPPORTED;
    if (y and caps & rtg.boards.RTGBC_MIRROR_Y == 0) return err.RTGERR_NOT_SUPPORTED;
    const state = stateOf(board);
    const was_turned_x = state.turned_x;
    const was_turned_y = state.turned_y;
    const was_mirror_x = state.mirror_x;
    const was_mirror_y = state.mirror_y;
    // The hardware's axes are the hardware's; the library turns the rest.
    const turn_x = x and state.turns & rtg.boards.RTGBC_MIRROR_X != 0;
    const turn_y = y and state.turns & rtg.boards.RTGBC_MIRROR_Y != 0;
    const hardware = turn_x != state.turned_x or turn_y != state.turned_y;
    const own_x = x and !turn_x;
    const own_y = y and !turn_y;
    if (!hardware and own_x == state.mirror_x and own_y == state.mirror_y) return err.RTGERR_OK;
    if (hardware) {
        const code = ops.mirror.?(board, turn_x, turn_y);
        if (code != err.RTGERR_OK) return code;
    }
    // A plane of the board's own lies over the picture unturned: the
    // library lays its image for as long as it mirrors the picture.
    const begins = (own_x or own_y) and !(was_mirror_x or was_mirror_y);
    const ends = !(own_x or own_y) and (was_mirror_x or was_mirror_y);
    if (begins) planes(board, false);
    state.turned_x = turn_x;
    state.turned_y = turn_y;
    state.mirror_x = own_x;
    state.mirror_y = own_y;
    const code = repaint(rb, board);
    if (code != err.RTGERR_OK) {
        if (hardware) _ = ops.mirror.?(board, was_turned_x, was_turned_y);
        state.turned_x = was_turned_x;
        state.turned_y = was_turned_y;
        state.mirror_x = was_mirror_x;
        state.mirror_y = was_mirror_y;
        if (begins) planes(board, true);
        return code;
    }
    if (ends) planes(board, true);
    board.info.mirror_x = @intFromBool(x);
    board.info.mirror_y = @intFromBool(y);
    boards.changed(rb, board);
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
        if (ops.refresh == null and !writesBack(board)) return err.RTGERR_NOT_SUPPORTED;
        return refreshed(rb, board, bitmap, cut);
    };
    obtain(rb, board);
    defer release(rb, board);
    var code = refreshed(rb, board, bitmap, cut);
    if (!composing(board)) return code;

    const private = boards.privateOf(board);
    const state = &private.compose;
    const shown = private.bands[0..private.band_count];
    for (shown, 0..) |*band, i| {
        if (band.bitmap != bitmap) continue;
        const band_end = if (i + 1 < shown.len) shown[i + 1].line else state.height;
        const seen = shownOf(state, band, band_end, cut) orelse continue;
        const answer = update(board, &onGlass(state, seen));
        if (code == err.RTGERR_OK) code = answer;
    }
    return code;
}

/// Whether the library writes what is handed on out of the caches for the
/// board's display, which reads past them (`RTGRF_WRITE_BACK`).
fn writesBack(board: *const rtg.RtgBoard) bool {
    return board.region.flags & rtg.boards.RTGRF_WRITE_BACK != 0;
}

/// A rectangle of a buffer the board's display reads, written by the CPU,
/// handed to the board: written out of the caches first where its region
/// says the library does that, then the driver's `refresh` where it has
/// one. The driver's answer, RTGERR_OK where it has none.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board.
/// - `bitmap` - one of its buffers, with pixels.
/// - `cut` - the rectangle, cut to the buffer and not empty.
pub fn refreshed(rb: *RtgBase, board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, cut: *const rtg.RtgRect) i32 {
    if (writesBack(board)) writeBack(rb, bitmap, cut);
    const refresh = board.ops.?.refresh orelse return err.RTGERR_OK;
    return refresh(board, bitmap, cut);
}

/// A rectangle's pixels written out of the caches: at least half a row
/// wide as its rows, in one stretch; narrower a row at a time, its own
/// bytes alone, so the side of a window's frame does not write back the
/// rows it runs down.
fn writeBack(rb: *RtgBase, bitmap: *const rtg.RtgBitMap, cut: *const rtg.RtgRect) void {
    const sys = rb.sys_base;
    const pixels = bitmap.pixels orelse return;
    if (cut.width <= 0 or cut.height <= 0) return;
    const format = @intFromEnum(bitmap.format);
    const wide = rb.iface().RtgRowBytes(format, @intCast(cut.width));
    const left = rb.iface().RtgRowBytes(format, @intCast(cut.x));
    const rows: u32 = @intCast(cut.height);
    const first = @intFromPtr(pixels) + @as(usize, @intCast(cut.y)) * bitmap.pitch;
    if (wide * 2 >= bitmap.pitch) {
        var bytes: u32 = rows * bitmap.pitch;
        _ = sys.CachePreDMA(@ptrFromInt(first), &bytes, 0);
        return;
    }
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var bytes: u32 = wide;
        _ = sys.CachePreDMA(@ptrFromInt(first + @as(usize, row) * bitmap.pitch + left), &bytes, 0);
    }
}

/// The rectangle of the picture that shows a rectangle of a band's
/// buffer, or null where the band shows none of it: the lines of the
/// band whose rows were written - all of a band that repeats its
/// buffer's first row, where that row is among them - and the columns
/// written, no further right than the picture. A band that is scaled
/// shows them scaled, with a pixel more each side where neighbours are
/// mixed.
///
/// INPUTS:
/// - `state` - the board's compose state, in the mode the bands are
///   shown in.
/// - `band` - a band whose buffer the rectangle is of.
/// - `band_end` - the display line the band ends before.
/// - `cut` - the rectangle written, cut down to the buffer.
pub fn shownOf(state: *const State, band: *const rtg.RtgBand, band_end: u32, cut: *const rtg.RtgRect) ?rtg.RtgRect {
    const bitmap = band.bitmap;
    const scale = scaling.Scale{ .from = bitmap.width, .to = state.width };
    const scaled = bitmap.width != state.width;
    const top: u32 = @intCast(cut.y);
    const rows_end: u32 = top + @as(u32, @intCast(cut.height));
    var left: u32 = @intCast(cut.x);
    var right: u32 = left + @as(u32, @intCast(cut.width));
    if (scaled) {
        const across = scale.span(left, right);
        left = across.first;
        right = across.end;
    }
    right = @min(right, state.width);
    // The display lines that show the rows written.
    var first: u32 = band.line;
    var end: u32 = band_end;
    if (band.flags & rtg.RTGBANDF_REPEAT != 0) {
        if (top != 0) return null;
    } else {
        var from = top;
        var to = rows_end;
        if (scaled) {
            const down = scale.span(top, rows_end);
            from = down.first;
            to = down.end;
        }
        first = @max(band.line, from +| band.origin);
        end = @min(band_end, to +| band.origin);
    }
    if (left >= right or first >= end) return null;
    return .{ .x = @intCast(left), .y = @intCast(first), .width = @intCast(right - left), .height = @intCast(end - first) };
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

/// The locks of a change to an image taken, and whether the library
/// lays that image: asked again with the locks held, since a picture
/// mirrored meanwhile changes who lays.
fn holdFor(rb: *RtgBase, board: *rtg.RtgBoard, lays: *const fn (*rtg.RtgBoard) bool) bool {
    while (true) {
        const own = lays(board);
        hold(rb, board, own);
        if (lays(board) == own) return own;
        letGo(rb, board, own);
    }
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
    const own = holdFor(rb, board, &laysPointer);
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
    const own = holdFor(rb, board, &laysPointer);
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
        if (!laysOverlay(board)) {
            if (board.overlay) |overlay| if (ops.overlay) |group| {
                group.move(board, x - @as(i32, @intCast(overlay.hot_x)), y - @as(i32, @intCast(overlay.hot_y)));
            };
        }
        changed.add(overlayRect(board));
    }
    if (!laysPointer(board)) {
        if (board.pointer) |image| if (ops.pointer) |group| {
            group.move(board, x - @as(i32, @intCast(image.hot_x)), y - @as(i32, @intCast(image.hot_y)));
        };
    }
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
    const own = holdFor(rb, board, &laysOverlay);
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
    if (!laysOverlay(board)) {
        if (ops.overlay) |group| group.move(board, x - @as(i32, @intCast(image.hot_x)), y - @as(i32, @intCast(image.hot_y)));
    }
    changed.add(overlayRect(board));
    deliver(rb, board, &changed);
}

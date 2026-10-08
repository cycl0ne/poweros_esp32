// SPDX-License-Identifier: MPL-2.0
//! The emulator's virtual display as a display board.
//!
//! A module of its own, on the same footing as the panel driver: it opens
//! rtg.library at cold start and hands in a driver called "qemu". It
//! registers only when the virtual display is actually there, so on real
//! hardware nothing of it exists but the tag.
//!
//! What it drives is a frame of memory and a doorbell. The device owns the
//! pixels - they are its own VRAM, not the machine's - and a register says
//! "this rectangle changed, put it on the window". There is no stream to
//! keep fed, no DMA, no blanking and no timing: the picture is whatever is
//! in VRAM the last time the doorbell was rung. That is why this driver is
//! a tenth the size of the panel's, and why nothing here is a simplified
//! version of that one - the two have almost nothing in common below the
//! board interface, which is the point of having the interface.
//!
//! The pointer is laid over the picture in a frame of its own. The
//! doorbell copies at the window's next refresh, not when it is rung, so
//! the pointer cannot be put into the shown buffer, rung and taken out
//! again. While a pointer is shown the window is fed from a composed frame
//! in the VRAM past the board's buffers instead: the shown buffer's rows
//! copied in as they are refreshed, and the pointer laid over them. A move
//! puts back the pointer's old rectangle from the shown buffer and lays it
//! at the new one, so it costs the pointer's size and not the picture's.
//! With no pointer shown the window reads the shown buffer itself, as it
//! always did, and nothing is copied. The overlay - a dragged icon - is
//! laid the same way, under the pointer.
//!
//! Several buffers shown at once, in bands of lines - a screen pulled down
//! over the one behind - are composed the same way: each row of the
//! composed frame copied from the band that covers it, the buffer's row
//! that far below the band's origin, and the pointer over them.
//!
//! It exists so that the layers above it can be looked at before anything
//! is flashed. A board here means rtg.library lists a display,
//! graphics.library finds a View, and what is drawn can be seen - in the
//! emulator's window, or captured from its monitor without one.
//!
//! The module keeps nothing of its own: a ROM image is read only, so the
//! driver node and everything that changes are allocated at init and found
//! again through the node.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;

const qemu_rgb = sdk.hardware.qemu_rgb;
const tags = rtg.tags;
const timer = sdk.devices.timer;

const MODULE_NAME = "rtg-qemu";
const DRIVER_NAME = "qemu";
const VERSION = 1;
const REVISION = 2;
const BUILD_DATE = "08.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const bytes_per_pixel = 2;

/// The driver node is a field of this, so anything holding the node is
/// holding all of it.
const State = struct {
    driver: rtg.RtgDriver = .{},
    sys: *ExecBase,
    rtg_base: *RtgBase,
    /// The board while one exists. There is one virtual display, so there
    /// is at most one.
    board: ?*rtg.RtgBoard = null,
};

/// Everything one board of this driver has. The library allocates it
/// beside the handle.
const Screen = struct {
    sys: *ExecBase,
    /// What the device is asked to show: RTGA_Width and RTGA_Height, the
    /// screen of the board the image was built for, so a board here is
    /// the same shape as the real one and what is seen in the window is
    /// what the glass would show.
    width: u32 = 0,
    height: u32 = 0,
    mode: rtg.RtgMode = .{},
    /// What ShowBitMap was last given, and where it is shown from.
    showing: ?*rtg.RtgBitMap = null,
    /// How many times the picture has been handed to the window. There is
    /// no blanking to count, so this is the only number worth having.
    updates: u32 = 0,
    /// timer.device, opened the first time a frame is waited for: the
    /// request each wait copies.
    timer_io: timer.TimeRequest = .{},
    timer_open: bool = false,
    /// The frame the window is fed from while a pointer is shown, past
    /// the board's buffers in VRAM; null when there was no room, and the
    /// board then has no pointer.
    composed: ?[*]u8 = null,
    /// The pointer: its image (the library's), where the image's top left
    /// is, and whether it is shown.
    pointer: ?*const rtg.RtgPointerImage = null,
    pointer_left: i32 = 0,
    pointer_top: i32 = 0,
    pointer_shown: bool = false,
    /// The overlay (a dragged icon): its image, laid under the pointer
    /// whenever there is one, and where its top left is.
    overlay: ?*const rtg.RtgPointerImage = null,
    overlay_left: i32 = 0,
    overlay_top: i32 = 0,
    /// The bands shown, from the top: one, the shown buffer at its own
    /// origin, unless a screen is pulled down. With more than one the
    /// window is fed from the composed frame, each row from its band.
    bands: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined,
    band_count: u32 = 0,
};

/// A frame of the panel the window stands in for, at 60 a second.
const frame_us = 16_667;

/// Wait as long as `frames` frames of a 60 Hz panel take. The window has
/// no blanking of its own, so this is what makes a program that paces
/// itself by the display - a flip, WaitVBlank - run here at the speed it
/// runs on the glass, and give the CPU away while it waits as it would
/// there. Nothing is waited for when timer.device cannot be had.
fn pace(screen: *Screen, frames: u32) void {
    const sys = screen.sys;
    if (!screen.timer_open) {
        screen.timer_io = .{};
        screen.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
        if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &screen.timer_io.node, 0) != 0) return;
        screen.timer_open = true;
    }
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return;
    defer sys.FreeSignal(bit);
    // The waiting task's own port: any task may be the one showing.
    var port: exec.MsgPort = .{ .sig_bit = @intCast(bit), .sig_task = sys.FindTask(null) };
    port.msg_list.init(.message);
    var io = screen.timer_io;
    io.node.message.reply_port = &port;
    io.node.command = timer.TR_ADDREQUEST;
    io.time = timer.TimeVal.fromMicros(@as(u64, frame_us) * frames);
    _ = sys.DoIO(&io.node);
}

fn stateOf(driver: *rtg.RtgDriver) *State {
    return @fieldParentPtr("driver", driver);
}

fn screenOf(board: *rtg.RtgBoard) *Screen {
    return @ptrCast(@alignCast(board.instance.?));
}

/// Hand the window everything in the shown buffer.
///
/// INPUTS:
/// - `screen` - the board's own state, whose `updates` this counts.
///
/// BEHAVIOR:
/// The device copies from the address it is given at its own pace, so a
/// caller never waits. The whole frame goes every time: the device takes a
/// rectangle, but the window is small enough that working out the union of
/// what changed would cost more than sending it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. Four register writes and nothing else.
/// - Locks: none needed.
/// - Process: a Task will do.
fn present(screen: *Screen) void {
    const shown = screen.showing orelse return;
    const from = if (composing(screen)) screen.composed.? else shown.pixels.?;
    qemu_rgb.update(@intFromPtr(from), @intCast(screen.width), @intCast(screen.height));
    screen.updates +%= 1;
}

// --- the pointer, in the composed frame -----------------------------------

/// Whether the window is fed from the composed frame: a pointer with an
/// image is shown over a picture, there is an overlay, or the picture is
/// several in bands.
fn composing(screen: *Screen) bool {
    if (screen.composed == null or screen.showing == null) return false;
    return screen.band_count > 1 or (screen.pointer_shown and screen.pointer != null) or screen.overlay != null;
}

/// Where display row `y` comes from: its band's buffer, that buffer's row
/// `y - origin`.
fn sourceRow(screen: *Screen, y: u32) ?[*]u8 {
    var i = screen.band_count;
    while (i > 0) {
        i -= 1;
        const band = screen.bands[i];
        if (y < band.line) continue;
        const pitch = screen.width * bytes_per_pixel;
        return band.bitmap.pixels.? + band.rowAt(y) * pitch;
    }
    return null;
}

/// Display rows `top` to `end`, each from its band, into the composed
/// frame.
fn copyRows(screen: *Screen, top: u32, end: u32) void {
    const composed = screen.composed orelse return;
    const pitch = screen.width * bytes_per_pixel;
    var y = top;
    while (y < end) : (y += 1) {
        const from = sourceRow(screen, y) orelse continue;
        screen.sys.CopyMem(from, composed + y * pitch, pitch);
    }
}

/// The part of the image's rectangle at (left, top) that is on the
/// picture, as columns and rows; null when none of it is.
const Clip = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

fn clipOf(screen: *Screen, image: *const rtg.RtgPointerImage, left: i32, top: i32) ?Clip {
    const x0 = @max(left, 0);
    const y0 = @max(top, 0);
    const x1 = @min(left + @as(i32, @intCast(image.width)), @as(i32, @intCast(screen.width)));
    const y1 = @min(top + @as(i32, @intCast(image.height)), @as(i32, @intCast(screen.height)));
    if (x0 >= x1 or y0 >= y1) return null;
    return .{ .x0 = @intCast(x0), .y0 = @intCast(y0), .x1 = @intCast(x1), .y1 = @intCast(y1) };
}

/// The picture back where both images are: their rectangles copied from
/// the shown buffer.
fn restore(screen: *Screen) void {
    // Where they are, read once: the input task may move them while this
    // runs.
    restoreImage(screen, screen.overlay, screen.overlay_left, screen.overlay_top);
    restoreImage(screen, screen.pointer, screen.pointer_left, screen.pointer_top);
}

fn restoreImage(screen: *Screen, given: ?*const rtg.RtgPointerImage, left: i32, top: i32) void {
    const image = given orelse return;
    const clip = clipOf(screen, image, left, top) orelse return;
    const composed = screen.composed orelse return;
    const pitch = screen.width * bytes_per_pixel;
    var y = clip.y0;
    while (y < clip.y1) : (y += 1) {
        const from = sourceRow(screen, y) orelse continue;
        const at = clip.x0 * bytes_per_pixel;
        screen.sys.CopyMem(from + at, composed + y * pitch + at, (clip.x1 - clip.x0) * bytes_per_pixel);
    }
}

/// The images laid over the composed frame: the overlay, then the pointer
/// over it when it is shown.
fn lay(screen: *Screen) void {
    layImage(screen, screen.overlay, screen.overlay_left, screen.overlay_top);
    if (screen.pointer_shown) layImage(screen, screen.pointer, screen.pointer_left, screen.pointer_top);
}

/// One image laid over the composed frame: a masked copy, cut to the
/// picture.
fn layImage(screen: *Screen, given: ?*const rtg.RtgPointerImage, left: i32, top: i32) void {
    const image = given orelse return;
    const clip = clipOf(screen, image, left, top) orelse return;
    const composed = screen.composed orelse return;
    if (image.format != .rgb565) return;
    const pitch = screen.width * bytes_per_pixel;
    var y = clip.y0;
    while (y < clip.y1) : (y += 1) {
        const image_y: u32 = @intCast(@as(i32, @intCast(y)) - top);
        const from: [*]const u16 = @ptrCast(@alignCast(image.pixels + image_y * image.pitch));
        const into: [*]u16 = @ptrCast(@alignCast(composed + y * pitch));
        var x = clip.x0;
        while (x < clip.x1) : (x += 1) {
            const image_x: u32 = @intCast(@as(i32, @intCast(x)) - left);
            if (image.opaqueAt(image_x, image_y)) into[x] = from[image_x];
        }
    }
}

/// The whole picture into the composed frame, with the images over it:
/// when composing starts, and when another buffer is shown.
fn rebuild(screen: *Screen) void {
    if (!composing(screen)) return;
    copyRows(screen, 0, screen.height);
    lay(screen);
}

/// A change to either image: both rectangles put back, the change made,
/// both laid again - they may overlap, and the one under must not be
/// left with a hole the other's restore cut. The frame is rebuilt when
/// composing starts or stops with it.
fn change(screen: *Screen, comptime apply: fn (*Screen, anytype) void, arg: anytype) void {
    const was = composing(screen);
    if (was) restore(screen);
    apply(screen, arg);
    if (!was) {
        rebuild(screen);
    } else if (composing(screen)) {
        lay(screen);
    }
    present(screen);
}

fn setPointer(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    const screen = screenOf(board);
    if (image) |one| {
        if (one.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    }
    change(screen, struct {
        fn apply(on: *Screen, given: anytype) void {
            on.pointer = given;
        }
    }.apply, image);
    return err.RTGERR_OK;
}

fn movePointer(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const screen = screenOf(board);
    if (!composing(screen)) {
        screen.pointer_left = left;
        screen.pointer_top = top;
        return;
    }
    change(screen, struct {
        fn apply(on: *Screen, place: anytype) void {
            on.pointer_left = place[0];
            on.pointer_top = place[1];
        }
    }.apply, .{ left, top });
}

fn showPointer(board: *rtg.RtgBoard, show: bool) callconv(.c) i32 {
    const screen = screenOf(board);
    screen.pointer_shown = show;
    rebuild(screen);
    present(screen);
    return err.RTGERR_OK;
}

fn setOverlay(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    const screen = screenOf(board);
    if (image) |one| {
        if (one.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    }
    change(screen, struct {
        fn apply(on: *Screen, given: anytype) void {
            on.overlay = given;
        }
    }.apply, image);
    return err.RTGERR_OK;
}

fn moveOverlay(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const screen = screenOf(board);
    if (!composing(screen)) {
        screen.overlay_left = left;
        screen.overlay_top = top;
        return;
    }
    change(screen, struct {
        fn apply(on: *Screen, place: anytype) void {
            on.overlay_left = place[0];
            on.overlay_top = place[1];
        }
    }.apply, .{ left, top });
}

fn createBoard(made_by: *rtg.RtgDriver, board: *rtg.RtgBoard, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    if (state.board != null) return err.RTGERR_IN_USE;

    const screen = screenOf(board);
    screen.* = .{
        .sys = state.sys,
        .width = @truncate(state.rtg_base.GetRtgTagData(tags.RTGA_Width, 0, tag_list)),
        .height = @truncate(state.rtg_base.GetRtgTagData(tags.RTGA_Height, 0, tag_list)),
    };
    // The device takes each side as 16 bits.
    if (screen.width == 0 or screen.height == 0) return err.RTGERR_BAD_ARG;
    if (screen.width > 0xFFFF or screen.height > 0xFFFF) return err.RTGERR_BAD_ARG;

    // One mode. A virtual display is not a monitor either: it is the shape
    // the emulator was built for.
    screen.mode = .{
        .node = .{ .name = "window", .pri = 0 },
        .id = 1,
        .width = screen.width,
        .height = screen.height,
        .format = .rgb565,
        .pitch = screen.width * bytes_per_pixel,
        .flags = rtg.boards.RTGMF_DEFAULT,
    };
    state.sys.AddTail(&board.modes, &screen.mode.node);

    // The device's own VRAM is the board's display memory, so a buffer cut
    // out of it is already where the device reads from and a refresh is a
    // doorbell rather than a copy. It is not cached: these are device
    // bytes, and nothing has to be written back before they are read. As
    // many pictures as the board asks for and the VRAM holds are as many
    // buffers as can be shown in turn, each by naming its address.
    const frame = screen.width * screen.height * bytes_per_pixel;
    const room = qemu_rgb.vramSize() / frame;
    if (room == 0) return err.RTGERR_BAD_ARG;
    const asked: u32 = @truncate(state.rtg_base.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list));
    const frames = @min(@max(asked, 1), room);
    // A frame more, if there is one, to compose the pointer in.
    if (frames < room) screen.composed = @ptrFromInt(qemu_rgb.vram + frames * frame);
    board.region = .{
        .base = @ptrFromInt(qemu_rgb.vram),
        .size = frames * frame,
        .alignment = bytes_per_pixel,
        .flags = rtg.boards.RTGRF_DISPLAYABLE,
    };
    board.ops = if (screen.composed != null) &pointer_ops else &ops;
    board.info.buffers = frames;
    state.board = board;
    return err.RTGERR_OK;
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    const screen = screenOf(board);
    if (screen.timer_open) screen.sys.CloseDevice(&screen.timer_io.node);
    screen.timer_open = false;
    if (board.driver) |driver| stateOf(driver).board = null;
}

/// One mode, so this only ever sizes the window to it.
fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode) callconv(.c) i32 {
    const screen = screenOf(board);
    if (mode.width != screen.width or mode.height != screen.height) return err.RTGERR_BAD_MODE;
    if (!qemu_rgb.init(@intCast(screen.width), @intCast(screen.height))) {
        // A stock Espressif QEMU stops its window at 800 pixels.
        exec.kprintf(screen.sys, "%s: the window will not take %dx%d; build QEMU with scripts/build-qemu.sh\n", .{ MODULE_NAME, screen.width, screen.height });
        return err.RTGERR_BAD_MODE;
    }
    board.info.width = screen.width;
    board.info.height = screen.height;
    board.info.format = .rgb565;
    board.info.pitch = screen.width * bytes_per_pixel;
    return err.RTGERR_OK;
}

/// Show a buffer, which here means: remember it and ring the doorbell with
/// its address. The window takes the whole picture from there at its next
/// refresh, so it never shows half of one and half of another.
///
/// The device reads packed rows out of its VRAM or internal memory, so a
/// buffer has to be one cut from the region, the mode's size and pitch.
fn showBitMap(board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) callconv(.c) i32 {
    // No panning in the device.
    if (x != 0 or y != 0) return err.RTGERR_BAD_ARG;
    const screen = screenOf(board);
    if (bitmap) |bm| {
        if (bm.pixels == null) return err.RTGERR_BAD_ARG;
        if (bm.width != screen.width or bm.height != screen.height) return err.RTGERR_NOT_DISPLAYABLE;
        if (bm.pitch != screen.width * bytes_per_pixel) return err.RTGERR_NOT_DISPLAYABLE;
    }
    // A flip from one picture to another takes a frame, as on the glass.
    // The first picture shown is not waited for: it comes up at cold
    // start.
    const flip = screen.showing != null and bitmap != null and (screen.showing != bitmap or screen.band_count > 1);
    screen.showing = bitmap;
    screen.band_count = 0;
    if (bitmap) |bm| {
        screen.bands[0] = .{ .bitmap = bm };
        screen.band_count = 1;
    }
    rebuild(screen);
    if (bitmap != null) present(screen);
    if (flip) pace(screen, 1);
    return err.RTGERR_OK;
}

/// Rows were written by the CPU. They are already in the device's memory,
/// so this is the doorbell and nothing more.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    // With the composed frame the rows go into it first - those of them
    // the bands show - and the pointer back over them where they cross it.
    if (composing(screen)) {
        var shown = false;
        for (screen.bands[0..screen.band_count], 0..) |band, i| {
            if (band.bitmap != bitmap) continue;
            const band_end = if (i + 1 < screen.band_count) screen.bands[i + 1].line else screen.height;
            const first = if (rows == 0) 0 else y;
            const last = if (rows == 0) bitmap.height else y +| rows;
            const lines = band.linesOf(first, last, band_end);
            if (lines.first >= lines.end) continue;
            copyRows(screen, lines.first, lines.end);
            shown = true;
        }
        if (!shown) return err.RTGERR_OK;
        lay(screen);
        present(screen);
        return err.RTGERR_OK;
    }
    // Refreshing a buffer that is not the one being shown is not an error
    // - it is a program drawing ahead into another buffer - but there is
    // nothing to hand to the window.
    if (screen.showing != bitmap) return err.RTGERR_OK;
    present(screen);
    return err.RTGERR_OK;
}

/// Several buffers at once, in bands: kept, composed, handed to the window,
/// and a frame waited out, as a flip is.
fn showBands(board: *rtg.RtgBoard, bands: [*]const rtg.RtgBand, count: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    for (bands[0..count]) |band| {
        const bm = band.bitmap;
        if (bm.pixels == null or bm.pitch != screen.width * bytes_per_pixel) return err.RTGERR_NOT_DISPLAYABLE;
    }
    const was_shown = screen.showing != null;
    @memcpy(screen.bands[0..count], bands[0..count]);
    screen.band_count = count;
    screen.showing = bands[count - 1].bitmap;
    rebuild(screen);
    present(screen);
    if (was_shown) pace(screen, 1);
    return err.RTGERR_OK;
}

/// The window has no blanking of its own: the frames of a 60 Hz panel are
/// waited out instead, so a program pacing itself by them runs as it would
/// on the glass. Nothing is ever torn: the device copies whole pictures.
fn waitVBlank(board: *rtg.RtgBoard, frames: u32) callconv(.c) i32 {
    pace(screenOf(board), if (frames == 0) 1 else frames);
    return err.RTGERR_OK;
}

fn stats(board: *rtg.RtgBoard, into: *rtg.RtgBoardStats) callconv(.c) void {
    const screen = screenOf(board);
    into.frames = screen.updates;
}

const ops = rtg.boards.RtgBoardOps{
    .destroy = &destroy,
    .set_mode = &setMode,
    .show_bitmap = &showBitMap,
    .wait_vblank = &waitVBlank,
    .refresh = &refresh,
    .stats = &stats,
};

/// The same with the pointer and with bands, for a board with a frame to
/// compose them in.
const pointer_ops = rtg.boards.RtgBoardOps{
    .destroy = &destroy,
    .set_mode = &setMode,
    .show_bitmap = &showBitMap,
    .wait_vblank = &waitVBlank,
    .refresh = &refresh,
    .stats = &stats,
    .set_pointer = &setPointer,
    .move_pointer = &movePointer,
    .show_pointer = &showPointer,
    .show_bands = &showBands,
    .set_overlay = &setOverlay,
    .move_overlay = &moveOverlay,
};

const driver_ops = rtg.boards.RtgDriverOps{ .create_board = &createBoard };

/// Whether the board has the emulator's display: its part in the board's
/// system tag list.
fn boardHasIt(sys: *ExecBase) bool {
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const st = sdk.expansion.systemtags;
    return eb.FindBoardPart(null, st.PARTKIND_PANEL, st.CHIP_QEMU_DISPLAY) != null;
}

/// Cold start at 23: after rtg.library (24), which it joins. Nothing is
/// registered on a board without the emulator's display.
fn init(seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*anyopaque {
    _ = seg_list;
    if (!boardHasIt(sys)) return @ptrCast(sys);

    const library = sys.OpenLibrary(rtg.RTGNAME, VERSION) orelse return @ptrCast(sys);
    const rb: *RtgBase = @ptrCast(library);

    const memory = sys.AllocVec(@sizeOf(State), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    };
    const state: *State = @ptrCast(@alignCast(memory));
    state.* = .{ .sys = sys, .rtg_base = rb };
    state.driver = .{
        .node = .{ .name = DRIVER_NAME, .pri = 0 },
        .version = VERSION,
        .revision = REVISION,
        .id_string = VERSION_STRING[1..],
        .type = rtg.boards.RTGDT_BOARD,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Screen),
    };
    if (!rb.AddRtgDriver(&state.driver)) {
        sys.FreeVec(memory);
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    }
    // The library stays open and the state stays allocated: the driver is
    // on the list for good, and the list is how anything finds it again.
    return @ptrCast(sys);
}

/// No library and no vectors: the tag's init is the whole of it.
export const rtg_qemu_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rtg_qemu_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 23,
    .type = .rtg_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};

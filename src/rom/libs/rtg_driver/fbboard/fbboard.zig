// SPDX-License-Identifier: MPL-2.0
//! A display that reads its picture out of the machine's RAM by itself,
//! as a display board: QEMU virt's ramfb (`ramfb.zig`) and the JH7110's
//! display controller behind its HDMI port (`jh7110.zig`).
//!
//! A module of its own, on the same footing as the other drivers: it
//! opens rtg.library at cold start and hands in a driver called "fb",
//! when the board lists a panel of a chip it drives.
//!
//! What it drives is an address. The display reads a whole picture from
//! RAM every frame, wherever it is told the picture is: there is no stream
//! to keep fed and no doorbell to ring, so showing a buffer is naming its
//! address, and what the CPU writes into the buffer shown is on the glass
//! by the next frame - once it is out of the CPU's caches, on a machine
//! whose display does not see them (`RTGRF_CPU_CACHED`: a refresh writes
//! the rows back, with exec's CacheClearE).
//!
//! The buffers are one block of RAM below 4 GiB, taken when the board is
//! made: as many pictures as the board asks for, and one more. The library
//! cuts the buffers from it.
//!
//! The pointer is laid over the picture in that last frame, as the qemu
//! board does it: while a pointer or the overlay is shown, or the picture
//! is several in bands, the display reads the composed frame instead - the
//! shown buffer's rows copied in as they are refreshed, and the images
//! laid over them. A move puts back the pointer's old rectangle from the
//! shown buffer and lays it at the new one, so it costs the pointer's size
//! and not the picture's. With nothing over the picture the display reads
//! the shown buffer itself, and nothing is copied.
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
const st = sdk.expansion.systemtags;

const ramfb = @import("ramfb.zig");
const jh7110 = @import("jh7110.zig");
const tags = rtg.tags;
const timer = sdk.devices.timer;

const MODULE_NAME = "rtg-fb";
const DRIVER_NAME = "fb";
const VERSION = 1;
const REVISION = 0;
const BUILD_DATE = "17.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The chips this drives, as the board's panel part names them.
const chips = [_]u32{ st.CHIP_QEMU_RAMFB, st.CHIP_JH7110_DC8200 };

/// What every row and every buffer starts on: whole cache lines, so a
/// refresh writes back exactly the rows it names, and as wide as any
/// display here fetches in one go.
const row_alignment = 128;
/// Where the block of buffers starts.
const page = 4096;

/// The driver node is a field of this, so anything holding the node is
/// holding all of it.
const State = struct {
    driver: rtg.RtgDriver = .{},
    sys: *ExecBase,
    rtg_base: *RtgBase,
    /// The board while one exists. There is one display, so there is at
    /// most one.
    board: ?*rtg.RtgBoard = null,
};

/// Which display, and what it was found to be.
const Scanout = union(enum) {
    ramfb: ramfb.Ramfb,
    jh7110,
};

/// Everything one board of this driver has. The library allocates it
/// beside the handle.
const Screen = struct {
    sys: *ExecBase,
    scanout: Scanout,
    /// The picture: RTGA_Width by RTGA_Height in RTGA_PixelFormat, rows
    /// `pitch` bytes apart, `bytes` a pixel.
    width: u32 = 0,
    height: u32 = 0,
    format: rtg.PixelFormat = .bgra32,
    bytes: u32 = 4,
    pitch: u32 = 0,
    mode: rtg.RtgMode = .{},
    /// The block the buffers are cut from, as AllocMem gave it.
    memory: ?*anyopaque = null,
    memory_size: usize = 0,
    /// Whether what the CPU writes has to be written back out of its
    /// caches before the display sees it.
    cached: bool = false,
    /// Where the display reads from; 0 before it has been told.
    scanning: usize = 0,
    /// What ShowBitMap was last given.
    showing: ?*rtg.RtgBitMap = null,
    /// How many times the display has been handed a picture.
    updates: u32 = 0,
    /// timer.device, opened the first time a frame is waited for: the
    /// request each wait copies.
    timer_io: timer.TimeRequest = .{},
    timer_open: bool = false,
    /// The frame the pointer is composed in, the block's last.
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
    /// origin, unless a screen is pulled down.
    bands: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined,
    band_count: u32 = 0,
};

/// A frame at 60 a second.
const frame_us = 16_667;

/// Wait as long as `frames` frames take. Nothing here says when one
/// begins, so this is what makes a program that paces itself by the
/// display - a flip, WaitVBlank - run at the speed it would on a display
/// that does, and give the CPU away while it waits.
fn pace(screen: *Screen, frames: u32) void {
    sleep(screen, @as(u64, frame_us) * frames);
}

/// Wait `micros` on timer.device, the CPU given away meanwhile. Nothing
/// is waited for when timer.device cannot be had.
fn sleep(screen: *Screen, micros: u64) void {
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
    io.time = timer.TimeVal.fromMicros(micros);
    _ = sys.DoIO(&io.node);
}

fn stateOf(driver: *rtg.RtgDriver) *State {
    return @fieldParentPtr("driver", driver);
}

fn screenOf(board: *rtg.RtgBoard) *Screen {
    return @ptrCast(@alignCast(board.instance.?));
}

// --- the display -------------------------------------------------------------

/// `length` bytes at `from`, which the CPU has written, where the display
/// reads them.
fn handOn(screen: *Screen, from: [*]u8, length: usize) void {
    if (!screen.cached or length == 0) return;
    screen.sys.CacheClearE(from, @intCast(length), exec.CACRF_ClearD);
}

/// The display told to read from `address` from its next frame on.
fn scanFrom(screen: *Screen, address: usize) void {
    if (address == screen.scanning) return;
    const shown = switch (screen.scanout) {
        .ramfb => |device| ramfb.show(device, address, screen.width, screen.height, screen.pitch, switch (screen.format) {
            .rgb565 => .rgb565,
            else => .bgra32,
        }),
        .jh7110 => done: {
            jh7110.show(address);
            break :done true;
        },
    };
    if (shown) screen.scanning = address;
}

/// The display reading what is to be seen: the composed frame while
/// anything is laid over the picture, else the shown buffer.
fn present(screen: *Screen) void {
    const shown = screen.showing orelse return;
    const from = if (composing(screen)) screen.composed.? else shown.pixels.?;
    scanFrom(screen, @intFromPtr(from));
    screen.updates +%= 1;
}

// --- the pointer, in the composed frame -----------------------------------

/// Whether the display reads the composed frame: a pointer with an image
/// is shown over a picture, there is an overlay, or the picture is several
/// in bands.
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
        return band.bitmap.pixels.? + band.rowAt(y) * screen.pitch;
    }
    return null;
}

/// Display rows `top` to `end`, each from its band, into the composed
/// frame.
fn copyRows(screen: *Screen, top: u32, end: u32) void {
    const composed = screen.composed orelse return;
    const pitch = screen.pitch;
    var y = top;
    while (y < end) : (y += 1) {
        const from = sourceRow(screen, y) orelse continue;
        screen.sys.CopyMem(from, composed + y * pitch, pitch);
    }
    if (top < end) handOn(screen, composed + top * pitch, (end - top) * pitch);
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
    restoreImage(screen, screen.overlay, screen.overlay_left, screen.overlay_top);
    restoreImage(screen, screen.pointer, screen.pointer_left, screen.pointer_top);
}

fn restoreImage(screen: *Screen, given: ?*const rtg.RtgPointerImage, left: i32, top: i32) void {
    const image = given orelse return;
    const clip = clipOf(screen, image, left, top) orelse return;
    const composed = screen.composed orelse return;
    const at = clip.x0 * screen.bytes;
    const length = (clip.x1 - clip.x0) * screen.bytes;
    var y = clip.y0;
    while (y < clip.y1) : (y += 1) {
        const from = sourceRow(screen, y) orelse continue;
        const into = composed + y * screen.pitch + at;
        screen.sys.CopyMem(from + at, into, length);
        handOn(screen, into, length);
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
    if (image.format != screen.format) return;
    var y = clip.y0;
    while (y < clip.y1) : (y += 1) {
        const image_y: u32 = @intCast(@as(i32, @intCast(y)) - top);
        const row = image.pixels + image_y * image.pitch;
        const into = composed + y * screen.pitch;
        var x = clip.x0;
        while (x < clip.x1) : (x += 1) {
            const image_x: u32 = @intCast(@as(i32, @intCast(x)) - left);
            if (!image.opaqueAt(image_x, image_y)) continue;
            switch (screen.bytes) {
                2 => @as([*]u16, @ptrCast(@alignCast(into)))[x] = @as([*]const u16, @ptrCast(@alignCast(row)))[image_x],
                else => @as([*]u32, @ptrCast(@alignCast(into)))[x] = @as([*]const u32, @ptrCast(@alignCast(row)))[image_x],
            }
        }
        handOn(screen, into + clip.x0 * screen.bytes, (clip.x1 - clip.x0) * screen.bytes);
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
        if (one.format != screen.format) return err.RTGERR_BAD_FORMAT;
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
        if (one.format != screen.format) return err.RTGERR_BAD_FORMAT;
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

// --- the board -------------------------------------------------------------------

/// The display the part describes, if it is there.
fn findScanout(chip: u32, address: usize) ?Scanout {
    return switch (chip) {
        st.CHIP_QEMU_RAMFB => .{ .ramfb = ramfb.find(address) orelse return null },
        // Its registers do not answer while its domain is off, so nothing
        // is asked of it before the mode is set.
        st.CHIP_JH7110_DC8200 => .jh7110,
        else => null,
    };
}

fn createBoard(made_by: *rtg.RtgDriver, board: *rtg.RtgBoard, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    if (state.board != null) return err.RTGERR_IN_USE;
    const rb = state.rtg_base;
    const sys = state.sys;

    const chip: u32 = @truncate(rb.GetRtgTagData(st.PART_Chip, st.CHIP_NONE, tag_list));
    const scanout = findScanout(chip, rb.GetRtgTagData(st.PART_Address, 0, tag_list)) orelse return err.RTGERR_NO_DISPLAY;
    const format: rtg.PixelFormat = @enumFromInt(@as(u8, @truncate(rb.GetRtgTagData(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32), tag_list))));
    const bytes: u32 = switch (format) {
        .bgra32 => 4,
        .rgb565 => 2,
        else => return err.RTGERR_BAD_FORMAT,
    };
    const screen = screenOf(board);
    screen.* = .{
        .sys = sys,
        .scanout = scanout,
        .width = @truncate(rb.GetRtgTagData(tags.RTGA_Width, 0, tag_list)),
        .height = @truncate(rb.GetRtgTagData(tags.RTGA_Height, 0, tag_list)),
        .format = format,
        .bytes = bytes,
    };
    if (screen.width == 0 or screen.height == 0) return err.RTGERR_BAD_ARG;
    if (screen.width > 0x3FFF or screen.height > 0x3FFF) return err.RTGERR_BAD_ARG;
    screen.pitch = std.mem.alignForward(u32, screen.width * bytes, row_alignment);
    // The JH7110's one mode, and a display that does not see the caches.
    if (scanout == .jh7110) {
        if (screen.width != jh7110.width or screen.height != jh7110.height) return err.RTGERR_BAD_ARG;
        if (format != .bgra32) return err.RTGERR_BAD_FORMAT;
        screen.cached = true;
    }

    // One mode: the picture the board was built for.
    screen.mode = .{
        .node = .{ .name = "native", .pri = 0 },
        .id = 1,
        .width = screen.width,
        .height = screen.height,
        .format = format,
        .pitch = screen.pitch,
        .flags = rtg.boards.RTGMF_DEFAULT,
    };
    if (scanout == .jh7110) {
        screen.mode.pixel_clock_hz = jh7110.pixel_clock_hz;
        screen.mode.refresh_mhz = jh7110.refresh_mhz;
    }
    sys.AddTail(&board.modes, &screen.mode.node);

    // As many pictures as the board asks for, and one to compose in, in
    // memory every DMA engine reaches. Not cleared: each is cleared before
    // it is first shown.
    const frame: usize = @as(usize, screen.pitch) * screen.height;
    const frames: u32 = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list))), 1);
    screen.memory_size = (frames + 1) * frame + page;
    screen.memory = sys.AllocMem(screen.memory_size, exec.MEMF_DMA) orelse {
        screen.memory_size = 0;
        return err.RTGERR_NO_MEMORY;
    };
    const base = std.mem.alignForward(usize, @intFromPtr(screen.memory.?), page);
    screen.composed = @ptrFromInt(base + frames * frame);
    board.region = .{
        .base = @ptrFromInt(base),
        .size = frames * frame,
        .alignment = row_alignment,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | if (screen.cached) rtg.boards.RTGRF_CPU_CACHED else 0,
    };
    board.ops = &ops;
    board.info.buffers = frames;
    board.info.pixel_clock_hz = screen.mode.pixel_clock_hz;
    board.info.refresh_mhz = screen.mode.refresh_mhz;
    state.board = board;
    return err.RTGERR_OK;
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    const screen = screenOf(board);
    if (screen.timer_open) screen.sys.CloseDevice(&screen.timer_io.node);
    screen.timer_open = false;
    if (screen.memory) |memory| screen.sys.FreeMem(memory, screen.memory_size);
    screen.memory = null;
    if (board.driver) |driver| stateOf(driver).board = null;
}

/// One mode, so this checks it is that one - and brings the display up
/// the first time, black: the block's first frame, which the library has
/// not handed out yet.
fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode) callconv(.c) i32 {
    const screen = screenOf(board);
    if (mode.width != screen.width or mode.height != screen.height or mode.format != screen.format) return err.RTGERR_BAD_MODE;
    if (screen.scanning == 0) {
        const first = board.region.base.?;
        const bytes = @as(usize, screen.pitch) * screen.height;
        @memset(first[0..bytes], 0);
        handOn(screen, first, bytes);
        if (!begin(screen, @intFromPtr(first))) return err.RTGERR_NO_DISPLAY;
    }
    board.info.width = screen.width;
    board.info.height = screen.height;
    board.info.format = screen.format;
    board.info.pitch = screen.pitch;
    return err.RTGERR_OK;
}

/// What `jh7110.start` waits with.
const Waiter = struct {
    screen: *Screen,

    pub fn wait(waiter: Waiter, micros: u32) void {
        sleep(waiter.screen, micros);
    }
};

/// The display started, reading the picture at `address`. False, and
/// said on the raw port, when it did not come up.
fn begin(screen: *Screen, address: usize) bool {
    switch (screen.scanout) {
        .ramfb => scanFrom(screen, address),
        .jh7110 => {
            const failure = jh7110.start(address, screen.pitch, Waiter{ .screen = screen });
            switch (failure) {
                .none => screen.scanning = address,
                .power => exec.kprintf(screen.sys, "%s: the display's power domain did not come on\n", .{MODULE_NAME}),
                .pll => exec.kprintf(screen.sys, "%s: the HDMI transmitter's PLL did not lock\n", .{MODULE_NAME}),
            }
            if (failure == .none and !jh7110.monitor()) {
                exec.kprintf(screen.sys, "%s: no monitor on the HDMI port\n", .{MODULE_NAME});
            }
        },
    }
    return screen.scanning == address;
}

/// Show a buffer: the display told where it is, from its next frame. Null
/// shows black: the composed frame, cleared, which nothing else uses
/// while no picture is shown.
fn showBitMap(board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) callconv(.c) i32 {
    // No panning.
    if (x != 0 or y != 0) return err.RTGERR_BAD_ARG;
    const screen = screenOf(board);
    if (bitmap) |bm| {
        if (bm.pixels == null) return err.RTGERR_BAD_ARG;
        if (bm.width != screen.width or bm.height != screen.height) return err.RTGERR_NOT_DISPLAYABLE;
        if (bm.pitch != screen.pitch or bm.format != screen.format) return err.RTGERR_NOT_DISPLAYABLE;
    }
    // A flip from one picture to another takes a frame. The first picture
    // shown is not waited for: it comes up at cold start.
    const flip = screen.showing != null and bitmap != null and (screen.showing != bitmap or screen.band_count > 1);
    screen.showing = bitmap;
    screen.band_count = 0;
    if (bitmap) |bm| {
        screen.bands[0] = .{ .bitmap = bm };
        screen.band_count = 1;
        rebuild(screen);
        present(screen);
    } else if (screen.composed) |black| {
        const bytes = @as(usize, screen.pitch) * screen.height;
        @memset(black[0..bytes], 0);
        handOn(screen, black, bytes);
        scanFrom(screen, @intFromPtr(black));
    }
    if (flip) pace(screen, 1);
    return err.RTGERR_OK;
}

/// Rows were written by the CPU: out of its caches, and into the composed
/// frame while the display reads that - those of them the bands show, and
/// the pointer back over them where they cross it.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    const first = if (rows == 0) 0 else @min(y, bitmap.height);
    const last = if (rows == 0) bitmap.height else @min(y +| rows, bitmap.height);
    // Any buffer, shown or not: one drawn ahead is shown by naming it.
    handOn(screen, bitmap.pixels.? + first * bitmap.pitch, (last - first) * bitmap.pitch);
    if (!composing(screen)) return err.RTGERR_OK;
    var shown = false;
    for (screen.bands[0..screen.band_count], 0..) |band, i| {
        if (band.bitmap != bitmap) continue;
        const band_end = if (i + 1 < screen.band_count) screen.bands[i + 1].line else screen.height;
        const lines = band.linesOf(first, last, band_end);
        if (lines.first >= lines.end) continue;
        copyRows(screen, lines.first, lines.end);
        shown = true;
    }
    if (shown) lay(screen);
    return err.RTGERR_OK;
}

/// Several buffers at once, in bands: composed, shown, and a frame waited
/// out, as a flip is.
fn showBands(board: *rtg.RtgBoard, bands: [*]const rtg.RtgBand, count: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    for (bands[0..count]) |band| {
        const bm = band.bitmap;
        if (bm.pixels == null or bm.pitch != screen.pitch or bm.format != screen.format) return err.RTGERR_NOT_DISPLAYABLE;
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

/// Frames waited out by the clock: nothing here says when one begins.
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
    .set_pointer = &setPointer,
    .move_pointer = &movePointer,
    .show_pointer = &showPointer,
    .show_bands = &showBands,
    .set_overlay = &setOverlay,
    .move_overlay = &moveOverlay,
};

const driver_ops = rtg.boards.RtgDriverOps{ .create_board = &createBoard };

/// Whether the board lists a panel of a chip this drives.
fn boardHasOne(sys: *ExecBase) bool {
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    for (chips) |chip| {
        if (eb.FindBoardPart(null, st.PARTKIND_PANEL, chip) != null) return true;
    }
    return false;
}

/// Cold start at 23: after rtg.library (24), which it joins. Nothing is
/// registered on a board without such a panel.
fn init(seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*anyopaque {
    _ = seg_list;
    if (!boardHasOne(sys)) return @ptrCast(sys);

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
export const rtg_fb_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rtg_fb_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 23,
    .type = .rtg_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};

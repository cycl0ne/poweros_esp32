// SPDX-License-Identifier: MPL-2.0
//! The BCM2711's video scaler behind its first HDMI port, in the mode the
//! VideoCore's firmware lit, as a display board - the scaler's display
//! list in `hvs.zig`, the link's sound in `sound.zig`: a display that
//! reads its picture out of the machine's RAM by itself.
//!
//! A module of its own, on the same footing as the other drivers: a
//! description of a driver called "bcm2711" behind a ROM tag, which
//! rtg.library puts on its list. It takes the panel part that is the
//! scaler (CHIP_BCM2711_HVS) and makes a board of it.
//!
//! **The firmware keeps the mode.** It read the monitor's EDID, lit a
//! mode on the port and shows its own framebuffer through the scaler. The
//! board has that one mode, the size the part names; the port, its pixel
//! valve and its controller stay the firmware's. What the driver changes
//! is the scaler's display list: a list of its own on the channel that
//! feeds the port, which reads the driver's planes in place of the
//! firmware's one.
//!
//! **Flipped.** The scaler reads RAM past the caches, so it is never
//! shown a buffer drawn in: rtg.library makes each picture in the one of
//! two frames the display is not reading, writes it out of the caches
//! (`RTGRF_WRITE_BACK`), and has this driver point the picture's plane at
//! it (`flipOp`). The scaler takes the address as it starts its next
//! frame; the driver waits until its channel has started one since, and
//! says the frame is taken (`RTGFLIP_TAKEN`). A program that shows one
//! whole buffer after another has its buffers read as they are
//! (`RTGBF_DIRECT_FLIP`), and nothing is copied.
//!
//! **The pointer and the overlay** are each a plane of the scaler's own,
//! laid over the picture: the image copied into a buffer of the driver's
//! as ARGB, its mask the alpha, and a move is the plane written again at
//! its new place. Two buffers each take turns, so the one the scaler
//! reads is never the one written.
//!
//! **The firmware may take the channel back**, writing a list of its own
//! as it sets the mode again - a monitor plugged in. The library looks at
//! the board every thirty frames (`look_frames`), and the look (`detect`)
//! gives the channel the driver's list again where the firmware's picture
//! is still the board's size; where it is not, the firmware's picture is
//! left on the glass, and that is said once. The connector is the
//! firmware's: a monitor is taken to be there, and its EDID is not read.
//!
//! **The sound** the link carries is the controller's to send, which the
//! driver sets up when the sound's driver asks (`audio`, `sound.zig`).
//!
//! The buffers are the machine's first GiB, which the scaler reaches
//! (MEMF_DMA), taken by the library as each is allocated
//! (RTGRF_SYSTEM_MEMORY, RTGRF_DMA_MEMORY). The driver's own are the two
//! planes' images.
//!
//! Pixel valve 2 raises an interrupt at each frame (the part's PART_Irq):
//! its server says the frame to the library (`FrameDone`), which a flip
//! and WaitVBlank wait for.
//!
//! The module keeps nothing of its own: a ROM image is read only, so what
//! changes is the library's to allocate - a `Screen` beside the board -
//! and found again through what an op is handed.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;
const st = sdk.expansion.systemtags;
const tags = rtg.tags;
const HdmiPort = sdk.hardware.bcm2711.HdmiPort;

const hvs = @import("hvs.zig");
const sound = @import("sound.zig");

const MODULE_NAME = "rtg-bcm2711";
const DRIVER_NAME = "bcm2711";
const VERSION = 1;
const REVISION = 0;
const BUILD_DATE = "17.11.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// What every row and every buffer starts on: whole cache lines, so
/// what is written back is exactly the rows handed on.
const row_alignment = 128;
/// Where the planes' images start.
const page = 4096;
/// The bytes of one of the cursor plane's two images.
const cursor_bytes = hvs.cursor_side * hvs.cursor_side * 4;
/// The bytes of one of the overlay plane's two images: rtg's largest
/// image.
const overlay_bytes = hvs.overlay_side * hvs.overlay_side * 4;
/// How many frames go by between two looks at the channel: half a second
/// of them at sixty a second.
const look_frames = 30;
/// How many frames a flip is waited for at the most: the one it was made
/// in, and two more, past which the scaler is taken not to be running.
const flip_frames = 3;
/// How long the scaler is given to read the firmware's list again before
/// the planes' images go: two frames at 24 a second, the slowest a
/// monitor is sent.
const give_back_us = 100_000;

/// Everything the board of this driver has. The library allocates it
/// beside the handle.
const Screen = struct {
    sys: *ExecBase,
    /// rtg.library, as the driver calls it.
    rtg_base: *RtgBase,
    /// The scaler as the firmware left it for the port, and the port's
    /// other blocks, as the board's list names them.
    hvs: hvs.Hvs,
    port: HdmiPort,
    /// The picture: the firmware's mode, rows `pitch` bytes apart, four
    /// bytes a pixel.
    width: u32,
    height: u32,
    pitch: u32 = 0,
    /// The board, and how many pictures it may have at once.
    board: *rtg.RtgBoard,
    buffers: u32 = 1,
    /// What a row of a buffer is rounded up to: the board's display
    /// memory's alignment, which the library rounds a mode's rows by.
    alignment: u32 = row_alignment,
    /// Held while the channel's list is written by a task: a flip, a
    /// look that gives the channel the driver's list again.
    port_lock: exec.SignalSemaphore = .{},
    /// Where the scaler reads from; 0 while its channel does not read the
    /// driver's list.
    scanning: usize = 0,
    /// Whether the firmware was found to have the channel in a mode that
    /// is not the board's, said once.
    lost: bool = false,
    /// How many times the display has been handed a picture.
    updates: u32 = 0,
    /// The sound the link was told to carry: null for none.
    audio: ?rtg.RtgAudio = null,
    /// The overlay's plane's two image buffers, as AllocMem gave them and
    /// where they start; which of them is the plane's, the size of the
    /// image in it, whether it is shown, and where its top left is.
    overlay_memory: ?*anyopaque = null,
    overlay_images: ?[*]u8 = null,
    overlay_turn: u1 = 0,
    overlay_width: u32 = 0,
    overlay_height: u32 = 0,
    overlay_shown: bool = false,
    overlay_left: i32 = 0,
    overlay_top: i32 = 0,
    /// The cursor plane's two image buffers, as AllocMem gave them and
    /// where they start; which of them is the plane's, whether it is the
    /// small size, and its image's hot spot.
    cursor_memory: ?*anyopaque = null,
    cursor: ?[*]u8 = null,
    cursor_turn: u1 = 0,
    cursor_small: bool = false,
    cursor_hot_x: u32 = 0,
    cursor_hot_y: u32 = 0,
    /// The pointer: its image (the library's), where the image's top left
    /// is, and whether it is shown.
    pointer: ?*const rtg.RtgPointerImage = null,
    pointer_left: i32 = 0,
    pointer_top: i32 = 0,
    pointer_shown: bool = false,
    /// The pixel valve's frame interrupt: its number (0 for none), its
    /// server and whether that is on.
    frame_irq: u32 = 0,
    frame_int: exec.Interrupt = .{},
    frame_hooked: bool = false,
};

/// The library as a program calls it, for a call that is not a driver's
/// own.
fn programs(rb: *RtgDriverBase) *RtgBase {
    return @ptrCast(rb);
}

fn screenOf(board: *rtg.RtgBoard) *Screen {
    return @ptrCast(@alignCast(board.instance.?));
}

/// The library as a driver calls it, from a board's screen.
fn drivers(screen: *const Screen) *RtgDriverBase {
    return @ptrCast(screen.rtg_base);
}

/// The pixel valve's interrupt: the frame said to the library, which
/// counts it and wakes whoever waits for one.
fn frameServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const screen: *Screen = @ptrCast(@alignCast(data.?));
    if (hvs.takeInterrupts(&screen.hvs) == 0) return 0;
    // Every `look_frames` of them, the library looks at the board.
    drivers(screen).FrameDone(screen.board);
    return 1;
}

/// The frame interrupt's server on, once the channel reads the driver's
/// list.
fn hookFrames(screen: *Screen) void {
    if (screen.frame_hooked or screen.frame_irq == 0) return;
    screen.frame_int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = screen,
        .code = &frameServer,
    };
    screen.sys.AddIntServer(screen.frame_irq, &screen.frame_int);
    screen.frame_hooked = true;
}

/// The frame interrupt's server off again.
fn unhookFrames(screen: *Screen) void {
    if (!screen.frame_hooked) return;
    screen.sys.RemIntServer(screen.frame_irq, &screen.frame_int);
    screen.frame_hooked = false;
}

// --- the display -------------------------------------------------------------

/// The channel reading the driver's list, the picture at `address` in it
/// and the cursor and the overlay as the board has them, and the frame
/// interrupt hooked. Made holding `port_lock`.
fn startHvs(screen: *Screen, address: usize) void {
    hvs.start(&screen.hvs, address, screen.pitch);
    screen.scanning = address;
    cursorPlane(screen);
    overlayPlane(screen);
    hookFrames(screen);
}

/// The channel looked at: where the firmware has written a list of its
/// own - set the mode again, as a monitor was plugged in - the driver's
/// is made again, its picture the one shown and the cursor and the
/// overlay as they are, where the firmware's picture is still the
/// board's size; where it is not, the firmware's is left, and said once.
/// Made holding `port_lock`.
fn keepHvs(screen: *Screen) void {
    if (screen.scanning == 0 or hvs.ours(&screen.hvs)) return;
    const sys = screen.sys;
    const again = hvs.find(screen.hvs.base, screen.hvs.channel, screen.hvs.pixel_valve, screen.width, screen.height) orelse {
        if (!screen.lost) exec.kprintf(sys, "%s: the firmware set the HDMI port to a mode that is not %ux%u, so its picture is seen\n", .{ MODULE_NAME, screen.width, screen.height });
        screen.lost = true;
        return;
    };
    screen.hvs = again;
    screen.lost = false;
    startHvs(screen, screen.scanning);
    exec.kprintf(sys, "%s: the firmware set the HDMI port's mode again, and the display is the driver's again\n", .{MODULE_NAME});
}

// --- the pointer and the overlay, each a plane of the scaler's ---------------

/// `rows` by `columns` of an image into a plane's buffer whose rows are
/// `side` pixels apart. The library's image is ARGB already, clear where
/// its mask leaves a pixel out (`RtgPointerImage`): its rows are copied.
fn imageInto(buffer: [*]u8, side: u32, one: *const rtg.RtgPointerImage, rows: u32, columns: u32) void {
    const row_bytes = columns * 4;
    var y: u32 = 0;
    while (y < rows) : (y += 1) @memcpy(buffer[y * side * 4 ..][0..row_bytes], one.pixels[y * one.pitch ..][0..row_bytes]);
}

fn cursorBuffer(screen: *Screen, turn: u1) [*]u8 {
    return screen.cursor.? + @as(usize, turn) * cursor_bytes;
}

/// Where the pointer's hot spot is: where the image's top left puts it,
/// kept on the picture.
fn hotSpot(screen: *const Screen) struct { x: u32, y: u32 } {
    const x = @as(i64, screen.pointer_left) + screen.cursor_hot_x;
    const y = @as(i64, screen.pointer_top) + screen.cursor_hot_y;
    return .{
        .x = @intCast(@max(@min(x, @as(i64, screen.width) - 1), 0)),
        .y = @intCast(@max(@min(y, @as(i64, screen.height) - 1), 0)),
    };
}

/// The cursor's plane told its buffer, size and hot spot, the hot spot's
/// place, and whether it is seen: only with an image.
fn cursorPlane(screen: *Screen) void {
    if (screen.cursor == null) return;
    const spot = hotSpot(screen);
    hvs.cursor(
        &screen.hvs,
        @intFromPtr(cursorBuffer(screen, screen.cursor_turn)),
        screen.cursor_small,
        screen.cursor_hot_x,
        screen.cursor_hot_y,
        spot.x,
        spot.y,
        screen.pointer_shown and screen.pointer != null,
    );
}

/// A new image into the buffer the cursor's plane is not reading, and
/// the plane turned to it.
fn cursorImage(screen: *Screen, image: ?*const rtg.RtgPointerImage) void {
    screen.pointer = image;
    const one = image orelse return cursorPlane(screen);
    if (screen.cursor == null) return;
    const small = one.width <= hvs.cursor_side / 2 and one.height <= hvs.cursor_side / 2;
    const side: u32 = if (small) hvs.cursor_side / 2 else hvs.cursor_side;
    const turn = screen.cursor_turn +% 1;
    const buffer = cursorBuffer(screen, turn);
    @memset(buffer[0 .. side * side * 4], 0);
    imageInto(buffer, side, one, @min(one.height, side), @min(one.width, side));
    screen.cursor_hot_x = @min(one.hot_x, side - 1);
    screen.cursor_hot_y = @min(one.hot_y, side - 1);
    screen.sys.CacheClearE(buffer, side * side * 4, exec.CACRF_ClearD);
    screen.cursor_turn = turn;
    screen.cursor_small = small;
    cursorPlane(screen);
}

fn setPointer(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    const screen = screenOf(board);
    if (image) |one| {
        if (one.format != .bgra32) return err.RTGERR_BAD_FORMAT;
    }
    cursorImage(screen, image);
    return err.RTGERR_OK;
}

fn movePointer(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const screen = screenOf(board);
    screen.pointer_left = left;
    screen.pointer_top = top;
    cursorPlane(screen);
}

fn showPointer(board: *rtg.RtgBoard, show: bool) callconv(.c) i32 {
    const screen = screenOf(board);
    screen.pointer_shown = show;
    cursorPlane(screen);
    return err.RTGERR_OK;
}

comptime {
    std.debug.assert(hvs.overlay_side == rtg.boards.RTG_OVERLAY_MAX);
}

fn overlayBuffer(screen: *Screen, turn: u1) [*]u8 {
    return screen.overlay_images.? + @as(usize, turn) * overlay_bytes;
}

/// The plane told its buffer, the image's size and place, and whether it
/// is seen.
fn overlayPlane(screen: *Screen) void {
    if (screen.overlay_images == null) return;
    hvs.overlay(
        &screen.hvs,
        @intFromPtr(overlayBuffer(screen, screen.overlay_turn)),
        screen.overlay_width,
        screen.overlay_height,
        screen.overlay_left,
        screen.overlay_top,
        screen.overlay_shown,
    );
}

/// A new image into the buffer the overlay's plane is not reading, and
/// the plane turned to it; or none, and the plane hidden. The library's
/// image is not read again.
fn overlayImage(screen: *Screen, image: ?*const rtg.RtgPointerImage) void {
    const one = image orelse {
        screen.overlay_shown = false;
        return overlayPlane(screen);
    };
    if (screen.overlay_images == null) return;
    const side: u32 = hvs.overlay_side;
    const turn = screen.overlay_turn +% 1;
    const buffer = overlayBuffer(screen, turn);
    const rows = @min(one.height, side);
    const columns = @min(one.width, side);
    imageInto(buffer, side, one, rows, columns);
    screen.sys.CacheClearE(buffer, rows * side * 4, exec.CACRF_ClearD);
    screen.overlay_turn = turn;
    screen.overlay_width = columns;
    screen.overlay_height = rows;
    screen.overlay_shown = true;
    overlayPlane(screen);
}

fn setOverlay(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    const screen = screenOf(board);
    if (image) |one| {
        if (one.format != .bgra32) return err.RTGERR_BAD_FORMAT;
    }
    overlayImage(screen, image);
    return err.RTGERR_OK;
}

fn moveOverlay(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const screen = screenOf(board);
    screen.overlay_left = left;
    screen.overlay_top = top;
    overlayPlane(screen);
}

// --- the board -------------------------------------------------------------------

/// Everything the screen took given back: the channel given the
/// firmware's list again, the frame interrupt's server off, the planes'
/// images freed once the scaler no longer reads them. What it has not
/// taken, or has given back already, is passed over.
fn release(screen: *Screen) void {
    const sys = screen.sys;
    const was_scanning = screen.scanning != 0;
    halt(screen);
    if (was_scanning) drivers(screen).RtgDelay(give_back_us);
    if (screen.cursor_memory) |memory| sys.FreeMem(memory, 2 * cursor_bytes + page);
    screen.cursor_memory = null;
    screen.cursor = null;
    if (screen.overlay_memory) |memory| sys.FreeMem(memory, 2 * overlay_bytes + page);
    screen.overlay_memory = null;
    screen.overlay_images = null;
}

/// The channel given the firmware's list back, from its next frame on,
/// and the frame interrupt's server off: the firmware's picture is seen
/// again.
fn halt(screen: *Screen) void {
    unhookFrames(screen);
    if (screen.scanning == 0) return;
    screen.sys.ObtainSemaphore(&screen.port_lock);
    hvs.stop(&screen.hvs);
    screen.scanning = 0;
    screen.sys.ReleaseSemaphore(&screen.port_lock);
}

/// The scaler's panel part is offered: a board made of it, in the mode
/// the firmware lit.
fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const rb = driver.rtg_base;
    const sys = driver.sys_base;

    // What the tags have to say, looked at before anything is taken.
    const format: rtg.PixelFormat = @enumFromInt(@as(u8, @truncate(rb.GetRtgTagData(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32), tag_list))));
    if (format != .bgra32) return err.RTGERR_BAD_FORMAT;
    const width: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Width, 0, tag_list));
    const height: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Height, 0, tag_list));
    if (width == 0 or height == 0) return err.RTGERR_BAD_TAGS;

    // Where the port is: the scaler's registers from the part's address,
    // its other blocks from the table the part points at; and the
    // firmware's list on the channel that feeds it, showing its picture.
    const base = rb.GetRtgTagData(st.PART_Address, 0, tag_list);
    const channel: u32 = @truncate(rb.GetRtgTagData(st.PART_BusUnit, 1, tag_list));
    const blocks: ?*const HdmiPort = @ptrFromInt(rb.GetRtgTagData(st.PART_Blocks, 0, tag_list));
    const port = (blocks orelse return err.RTGERR_BAD_TAGS).*;
    const found = hvs.find(base, channel, port.pixel_valve, width, height) orelse return err.RTGERR_NO_DISPLAY;

    const board = rb.CreateBoard(driver, device, &.{
        .ops = &ops,
        .instance_size = @sizeOf(Screen),
        // The scaler reads a whole buffer in place of a frame, for a
        // program that shows one buffer after another.
        .flags = rtg.boards.RTGBF_DIRECT_FLIP,
        .format = format,
        .look_frames = look_frames,
    }) orelse return err.RTGERR_NO_MEMORY;
    const screen = screenOf(board);
    screen.* = .{ .sys = sys, .rtg_base = programs(rb), .hvs = found, .port = port, .width = width, .height = height, .board = board };
    // The board's buffers start, and their rows are rounded, as its tags
    // say; whole cache lines where they say nothing.
    const asked_alignment: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Alignment, 0, tag_list));
    if (asked_alignment != 0) screen.alignment = asked_alignment;
    // One mode of its own: the one the firmware lit, which the board
    // cannot change.
    const own: rtg.RtgTimings = .{ .h_active = width, .v_active = height };
    if (rb.AddBoardMode(board, &own, @intFromEnum(format), rtg.modes.RTGMF_DEFAULT) == 0) {
        rb.DeleteBoard(board);
        return err.RTGERR_NO_MEMORY;
    }
    screen.frame_irq = @truncate(rb.GetRtgTagData(st.PART_Irq, 0, tag_list));
    screen.pitch = rowBytes(screen, width);
    sys.InitSemaphore(&screen.port_lock);

    // At most as many pictures of the mode as the board asks for, each
    // taken by the library as it is allocated, from memory the scaler
    // reaches. The cursor plane's two images now, from a page on, the
    // system's and not the task's that happened to ask; the overlay's
    // too, without which the overlay is not shown.
    const frame: usize = @as(usize, screen.pitch) * height;
    screen.buffers = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list))), 1);
    const memory = sys.AllocMem(2 * cursor_bytes + page, exec.MEMF_DMA | exec.MEMF_SYSTEM) orelse {
        rb.DeleteBoard(board);
        return err.RTGERR_NO_MEMORY;
    };
    screen.cursor_memory = memory;
    screen.cursor = @ptrFromInt((@intFromPtr(memory) + page - 1) & ~@as(usize, page - 1));
    if (sys.AllocMem(2 * overlay_bytes + page, exec.MEMF_DMA | exec.MEMF_SYSTEM)) |images| {
        screen.overlay_memory = images;
        screen.overlay_images = @ptrFromInt((@intFromPtr(images) + page - 1) & ~@as(usize, page - 1));
    }
    // Flipped between two frames rtg.library makes its pictures in: no
    // band is read by the display itself.
    board.direct_bands = 0;
    board.region = .{
        .size = screen.buffers * frame,
        .alignment = screen.alignment,
        // The scaler reads past the caches: the library writes back
        // what is handed on.
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED |
            rtg.boards.RTGRF_SYSTEM_MEMORY | rtg.boards.RTGRF_DMA_MEMORY | rtg.boards.RTGRF_WRITE_BACK,
    };
    board.info.buffers = screen.buffers;
    device.driver_data = screen;
    exec.kprintf(sys, "%s: HDMI in the firmware's %ux%u, through the scaler's channel %u\n", .{ MODULE_NAME, width, height, channel });
    return err.RTGERR_OK;
}

/// The device is taken from the driver: the firmware's picture back.
fn detach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice) callconv(.c) void {
    _ = driver;
    const screen: *Screen = @ptrCast(@alignCast(device.driver_data orelse return));
    halt(screen);
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    release(screenOf(board));
}

/// Bytes a row of a buffer `width` pixels wide has: the pixels, rounded
/// up to the board's alignment, as the library rounds a mode's.
fn rowBytes(screen: *const Screen, width: u32) u32 {
    const row = width * 4;
    const step = screen.alignment;
    return (row + step - 1) / step * step;
}

/// A look at the board, every `look_frames` frames: the channel given the
/// driver's list again where the firmware took it (`keepHvs`). The
/// connector is the firmware's, which lit a mode for the monitor on it: a
/// monitor is there, and its EDID is not read.
fn detect(board: *rtg.RtgBoard, asked: *rtg.RtgDetect) callconv(.c) i32 {
    const screen = screenOf(board);
    screen.sys.ObtainSemaphore(&screen.port_lock);
    keepHvs(screen);
    screen.sys.ReleaseSemaphore(&screen.port_lock);
    asked.present = 1;
    return err.RTGERR_OK;
}

/// Whether the board can make `timings`: the firmware's mode, and no
/// other.
fn checkMode(board: *rtg.RtgBoard, timings: *const rtg.RtgTimings) callconv(.c) i32 {
    const screen = screenOf(board);
    return if (timings.h_active == screen.width and timings.v_active == screen.height) err.RTGERR_OK else err.RTGERR_BAD_MODE;
}

/// The board's one op for what is on the glass (`RtgShow`): the channel
/// given the driver's list, reading the first of the mode's two frames,
/// which rtg.library has made the whole picture in. Its pictures after
/// that reach it through `flipOp`.
fn showOp(board: *rtg.RtgBoard, what: *const rtg.RtgShow) callconv(.c) i32 {
    if (what.flags & rtg.boards.RTGSHOW_MODE_CHANGED == 0) return err.RTGERR_OK;
    const screen = screenOf(board);
    const mode = what.mode;
    // The firmware's mode, its rows as the library makes them.
    if (mode.format != .bgra32 or mode.width != screen.width or mode.height != screen.height) return err.RTGERR_BAD_MODE;
    if (mode.pitch != rowBytes(screen, mode.width)) return err.RTGERR_BAD_MODE;
    const start = what.frame orelse return err.RTGERR_BAD_ARG;
    const address = @intFromPtr(start.pixels orelse return err.RTGERR_BAD_ARG);
    screen.pitch = mode.pitch;
    screen.sys.ObtainSemaphore(&screen.port_lock);
    defer screen.sys.ReleaseSemaphore(&screen.port_lock);
    // The channel may be the firmware's again since the board was made.
    if (!hvs.ours(&screen.hvs) and screen.scanning != 0) {
        screen.hvs = hvs.find(screen.hvs.base, screen.hvs.channel, screen.hvs.pixel_valve, screen.width, screen.height) orelse return err.RTGERR_NO_DISPLAY;
    }
    startHvs(screen, address);
    return err.RTGERR_OK;
}

/// The scaler told to read `frame` from its next frame on: one of the
/// two rtg.library makes its pictures in, written back already, or a
/// buffer read in place of one. It takes the address as it starts a
/// frame, which is waited for here - the frame the flip was made in and
/// two more at the most - so the library waits for nothing more.
fn flipOp(board: *rtg.RtgBoard, frame: *rtg.RtgBitMap) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    const address = @intFromPtr(frame.pixels orelse return err.RTGERR_BAD_ARG);
    // A channel that does not read the driver's list has nothing to
    // flip: its start names the frame it reads.
    if (screen.scanning == 0) return err.RTGERR_NO_MODE;
    sys.ObtainSemaphore(&screen.port_lock);
    hvs.show(&screen.hvs, address);
    screen.scanning = address;
    screen.updates +%= 1;
    sys.ReleaseSemaphore(&screen.port_lock);
    var frames: u32 = 0;
    while (frames < flip_frames) : (frames += 1) {
        _ = screen.rtg_base.WaitVBlank(board, 1);
        if (hvs.taken(&screen.hvs)) break;
    }
    return rtg.boards.RTGFLIP_TAKEN;
}

/// The link's side of its sound (`SetBoardAudio`): the controller's MAI
/// set up for the stream - whose samples the sound's driver feeds its
/// FIFO - sent as audio sample packets with their infoframe and the
/// numbers the monitor rebuilds the sample clock from; or all of that
/// off again. RTGERR_NO_MODE while the channel does not read the
/// driver's list, RTGERR_NOT_SUPPORTED where the firmware sends the mode
/// as DVI, its pixel clock does not measure, or the MAI does not take
/// the format.
fn audio(board: *rtg.RtgBoard, format: ?*const rtg.RtgAudio) callconv(.c) i32 {
    const screen = screenOf(board);
    const one = format orelse {
        if (screen.audio != null) sound.audioStop(&screen.port, drivers(screen));
        screen.audio = null;
        return err.RTGERR_OK;
    };
    if (screen.scanning == 0) return err.RTGERR_NO_MODE;
    if (one.bits != 16) return err.RTGERR_NOT_SUPPORTED;
    if (!sound.audioStart(&screen.port, drivers(screen), one.sample_rate, one.channels)) return err.RTGERR_NOT_SUPPORTED;
    screen.audio = one.*;
    return err.RTGERR_OK;
}

fn stats(board: *rtg.RtgBoard, into: *rtg.RtgBoardStats) callconv(.c) void {
    into.frames = screenOf(board).updates;
}

const pointer_ops = rtg.RtgPointerOps{ .set = &setPointer, .move = &movePointer, .show = &showPointer };
const overlay_ops = rtg.RtgOverlayOps{ .set = &setOverlay, .move = &moveOverlay };

/// Flipped between frames the library makes its pictures in, looked at
/// for the firmware taking the channel back, the pointer and the overlay
/// each a plane of its own, and the link's sound.
const ops = rtg.boards.RtgBoardOps{
    .destroy = &destroy,
    .show = &showOp,
    .flip = &flipOp,
    .stats = &stats,
    .detect = &detect,
    .check_mode = &checkMode,
    .audio = &audio,
    .pointer = &pointer_ops,
    .overlay = &overlay_ops,
};

const driver_ops = rtg.RtgDriverOps{ .attach = &attach, .detach = &detach };

/// What it takes: the panel part that is the BCM2711's video scaler.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = st.CHIP_BCM2711_HVS },
    .{},
};

/// Whether this is a ROM's copy: the kernel's root lists the ROM's
/// modules, a file's does not.
const in_rom = @hasDecl(@import("root"), "rom_modules");

/// A driver is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
fn programEntry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    exec.kprintf(sys, "%s is a display driver, not a command\n", .{@as([*:0]const u8, DRIVER_NAME)});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

// The file's entry and its version string, which only the file in
// DEVS:gfxdrv/ has: in a ROM there is no file, and the host tests build
// this file beside the other modules.
comptime {
    if (!in_rom and !@import("builtin").is_test) {
        @export(&programEntry, .{ .name = "_program_entry" });
        @export(&version_tag, .{ .name = "version_tag" });
    }
}

/// The driver's tag: a description and no init. rtg.library reads it at
/// its own init and puts the driver on its list; nothing of this module
/// runs until a board is asked for.
export const rtg_bcm2711_tag: rtg.ResidentRtgDriver linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&rtg_bcm2711_tag),
        .version = VERSION,
        .type = .rtg_driver,
        .name = MODULE_NAME,
        .id_string = VERSION_STRING[1..], // past the NUL: a C string
    },
    .spec = .{
        .name = DRIVER_NAME,
        .id_string = VERSION_STRING[1..],
        .version = VERSION,
        .revision = REVISION,
        .kind = rtg.drivers.RTGDT_BOARD,
        .matches = &matches,
        .ops = &driver_ops,
    },
};

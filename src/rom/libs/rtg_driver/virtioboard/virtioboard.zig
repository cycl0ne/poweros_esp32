// SPDX-License-Identifier: MPL-2.0
//! QEMU's virtio GPU as a display board (`virtio.zig`): a display that
//! keeps a copy of each picture in the emulator and shows that.
//!
//! A module of its own, on the same footing as the other drivers: a
//! description of a driver called "virtio" behind a ROM tag, which
//! rtg.library puts on its list. It takes a panel part that is a virtio
//! GPU on a memory-mapped transport, and a virtio GPU's function on PCI
//! (`virtiopci.zig`), and makes a board of each it is offered.
//!
//! **Flipped.** Its pictures are copies the emulator keeps, so it is
//! never shown a buffer drawn in: rtg.library makes each picture in one
//! of two frames (its `compose/_flip.zig`), hands it on to this driver
//! (`refresh`) - the rectangle copied into the emulator's copy of the
//! frame - and has it name the frame the window shows (`flipOp`). The
//! bands and the overlay are the library's, laid in the pictures it
//! makes.
//!
//! **The mode** is the size the emulator's window has for it - QEMU's
//! xres and yres - where it says, else the size the part names; it
//! stands while the EDID the emulator gives names none. The driver says
//! what is on the connector (`detect`): a window that is always there,
//! and that EDID.
//!
//! **The pointer** is a cursor plane: the image copied into a buffer of
//! the driver's as ARGB, its mask the alpha, and laid over the window by
//! the emulator - with a tablet, as the host's own pointer - and moved by
//! a command. Two buffers take turns, so the one the device reads is
//! never the one written. The cursor cannot be switched off: while the
//! pointer is hidden its image is one with nothing in it.
//!
//! The buffers are the machine's RAM below 4 GiB (MEMF_DMA), taken by the
//! library as each is allocated (RTGRF_SYSTEM_MEMORY, RTGRF_DMA_MEMORY).
//!
//! The device has no interrupt at a frame here: the library waits as
//! long as a frame takes. A command's answer is waited for by the
//! library's clock (`RtgDelay`).
//!
//! The module keeps nothing of its own: a ROM image is read only, so what
//! changes is the library's to allocate - a `Screen` beside each board -
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

const virtio = @import("virtio.zig");

const MODULE_NAME = "rtg-virtio";
const DRIVER_NAME = "virtio";
const VERSION = 1;
const REVISION = 3;
const BUILD_DATE = "17.11.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// What every row and every buffer starts on: whole cache lines.
const row_alignment = 128;
/// Where the cursor plane's images start.
const page = 4096;
/// The most pixels a side of the picture has: what fourteen bits hold,
/// which every size here is kept in.
const largest_side = 0x3FFF;
/// The bytes of one of the cursor plane's two images.
const cursor_bytes = virtio.cursor_side * virtio.cursor_side * 4;

/// Everything one board of this driver has. The library allocates it
/// beside the handle.
const Screen = struct {
    sys: *ExecBase,
    /// rtg.library, as the driver calls it.
    rtg_base: *RtgBase,
    gpu: virtio.Gpu,
    /// Whether the GPU was started and is to be stopped.
    started: bool = false,
    /// The picture: its size, rows `pitch` bytes apart, four bytes a
    /// pixel.
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0,
    /// The board, and how many pictures it may have at once.
    board: *rtg.RtgBoard,
    buffers: u32 = 1,
    /// The number of the mode the display is in; 0 before the first.
    mode_id: u32 = 0,
    /// What a row of a buffer is rounded up to: the board's display
    /// memory's alignment, which the library rounds a mode's rows by.
    alignment: u32 = row_alignment,
    /// The frame the window shows; 0 before it has been told.
    scanning: usize = 0,
    /// How many times the display has been handed a picture.
    updates: u32 = 0,
    /// The cursor plane's two images, as AllocMem gave them and where they
    /// start; which of them is the plane's, and its image's hot spot.
    cursor_memory: ?*anyopaque = null,
    cursor: ?[*]u8 = null,
    cursor_turn: u1 = 0,
    cursor_hot_x: u32 = 0,
    cursor_hot_y: u32 = 0,
    /// The pointer: its image (the library's), where the image's top left
    /// is, and whether it is shown.
    pointer: ?*const rtg.RtgPointerImage = null,
    pointer_left: i32 = 0,
    pointer_top: i32 = 0,
    pointer_shown: bool = false,
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

/// What the GPU's commands wait with.
const Waiter = struct {
    screen: *Screen,

    pub fn wait(waiter: Waiter, micros: u32) void {
        drivers(waiter.screen).RtgDelay(micros);
    }
};

// --- the display -------------------------------------------------------------

/// A rectangle of a frame the CPU has written, copied into the
/// emulator's copy of it: the frame's rows written back first, and the
/// rectangle sent. A frame that is the one shown is shown at once.
fn handOn(screen: *Screen, picture: *const rtg.RtgBitMap, area: *const rtg.RtgRect) void {
    if (area.width <= 0 or area.height <= 0) return;
    const pixels = picture.pixels orelse return;
    const x: u32 = @intCast(area.x);
    const y: u32 = @intCast(area.y);
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    const sys = screen.sys;
    if (x == 0 and width >= picture.width) {
        sys.CacheClearE(pixels + y * picture.pitch, height * picture.pitch, exec.CACRF_ClearD);
    } else {
        var row = y;
        while (row < y + height) : (row += 1) sys.CacheClearE(pixels + row * picture.pitch + x * 4, width * 4, exec.CACRF_ClearD);
    }
    virtio.update(&screen.gpu, picture, .{ .x = x, .y = y, .width = width, .height = height }, Waiter{ .screen = screen });
}

/// The window told to show `picture` from now on: a frame of the mode it
/// is in, of which the device is told its copy. Whether it does: a device
/// that refuses goes on showing what it showed.
fn scanFrom(screen: *Screen, picture: *const rtg.RtgBitMap) bool {
    const address = @intFromPtr(picture.pixels orelse return false);
    if (address == screen.scanning) return true;
    if (!virtio.show(&screen.gpu, picture, Waiter{ .screen = screen })) return false;
    screen.scanning = address;
    return true;
}

// --- the pointer, on the device's cursor plane -------------------------------

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

/// A new image into the buffer the plane is not reading, and the plane
/// turned to it. The library's image is ARGB already, clear where its
/// mask leaves a pixel out (`RtgPointerImage`): its rows are copied.
/// While the pointer is hidden the image is one with nothing in it.
fn cursorImage(screen: *Screen) void {
    const drawn = if (screen.pointer_shown) screen.pointer else null;
    const side: u32 = virtio.cursor_side;
    const turn = screen.cursor_turn +% 1;
    const buffer = cursorBuffer(screen, turn);
    @memset(buffer[0 .. side * side * 4], 0);
    if (drawn) |one| {
        const rows = @min(one.height, side);
        const row_bytes = @min(one.width, side) * 4;
        var y: u32 = 0;
        while (y < rows) : (y += 1) @memcpy(buffer[y * side * 4 ..][0..row_bytes], one.pixels[y * one.pitch ..][0..row_bytes]);
        screen.cursor_hot_x = @min(one.hot_x, side - 1);
        screen.cursor_hot_y = @min(one.hot_y, side - 1);
    }
    screen.sys.CacheClearE(buffer, cursor_bytes, exec.CACRF_ClearD);
    screen.cursor_turn = turn;
    const at = hotSpot(screen);
    virtio.setCursor(&screen.gpu, buffer, turn, screen.cursor_hot_x, screen.cursor_hot_y, at.x, at.y, Waiter{ .screen = screen });
}

fn setPointer(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    const screen = screenOf(board);
    if (image) |one| {
        if (one.format != .bgra32) return err.RTGERR_BAD_FORMAT;
    }
    screen.pointer = image;
    cursorImage(screen);
    return err.RTGERR_OK;
}

fn movePointer(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const screen = screenOf(board);
    screen.pointer_left = left;
    screen.pointer_top = top;
    const at = hotSpot(screen);
    virtio.moveCursor(&screen.gpu, at.x, at.y);
}

/// The cursor is not switched off but emptied.
fn showPointer(board: *rtg.RtgBoard, show: bool) callconv(.c) i32 {
    const screen = screenOf(board);
    screen.pointer_shown = show;
    cursorImage(screen);
    return err.RTGERR_OK;
}

// --- the board -------------------------------------------------------------------

/// What a virtio GPU found on PCI is driven with: a function says what
/// it is by itself and carries no tags, so what a part's would say is
/// said here. The size is what stands where the emulator's window gives
/// none.
const function_tags = [_]TagItem{
    .{ .tag = tags.RTGA_Width, .data = 1280 },
    .{ .tag = tags.RTGA_Height, .data = 800 },
    .{ .tag = tags.RTGA_PixelFormat, .data = @intFromEnum(rtg.PixelFormat.bgra32) },
    // At most sixteen pictures at once - screens, and the buffers behind
    // them - each taken from memory as it is opened: a ceiling, not memory
    // set aside.
    .{ .tag = tags.RTGA_Buffers, .data = 16 },
    .{},
};

/// Everything the screen took given back: the GPU stopped - which lets
/// go of its copies before the frames are freed, and gives a function on
/// PCI back - the cursor's images freed. What it
/// has not taken, or has given back already, is passed over.
fn release(screen: *Screen) void {
    const sys = screen.sys;
    if (screen.started) virtio.stop(&screen.gpu);
    screen.started = false;
    if (screen.cursor_memory) |memory| sys.FreeMem(memory, 2 * cursor_bytes + page);
    screen.cursor_memory = null;
    screen.cursor = null;
}

/// A virtio GPU is offered - a panel part, or its function on PCI:
/// found, brought up, and a board made of it. On any answer but
/// RTGERR_OK everything it took is given back.
fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, device_tags: ?[*]const TagItem) callconv(.c) i32 {
    const rb = driver.rtg_base;
    const sys = driver.sys_base;
    const on_pci = device.kind == rtg.drivers.RTGDEV_PCI;
    const tag_list: ?[*]const TagItem = if (on_pci) &function_tags else device_tags;

    // What the tags have to say, looked at before anything is taken.
    const format: rtg.PixelFormat = @enumFromInt(@as(u8, @truncate(rb.GetRtgTagData(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32), tag_list))));
    if (format != .bgra32) return err.RTGERR_BAD_FORMAT;
    const width: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Width, 0, tag_list));
    const height: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Height, 0, tag_list));
    if (width == 0 or height == 0) return err.RTGERR_BAD_TAGS;
    if (width > largest_side or height > largest_side) return err.RTGERR_BAD_TAGS;

    // On PCI the device is the function itself; on a memory-mapped
    // transport the board names the block, or the first of a row of them.
    var gpu = (if (device.pci) |function|
        virtio.onPci(sys, function)
    else
        virtio.find(
            rb.GetRtgTagData(st.PART_Address, 0, tag_list),
            @truncate(rb.GetRtgTagData(st.PART_Windows, 1, tag_list)),
            rb.GetRtgTagData(st.PART_WindowSize, 0, tag_list),
        )) orelse return err.RTGERR_NO_DISPLAY;
    const board = rb.CreateBoard(driver, device, &.{
        .ops = &ops,
        .instance_size = @sizeOf(Screen),
        // The windows of a screen on a GPU found on PCI each draw into a
        // buffer of their own, and what can be seen of them is copied
        // into the screen's; a part says so in its tags.
        .flags = if (on_pci) rtg.boards.RTGBF_COMPOSE else 0,
        // A monitor's modes are made in the format the board shows.
        .format = format,
    }) orelse {
        virtio.giveBack(&gpu);
        return err.RTGERR_NO_MEMORY;
    };
    const screen = screenOf(board);
    screen.* = .{ .sys = sys, .rtg_base = programs(rb), .gpu = gpu, .width = width, .height = height, .board = board };
    const code = bringUp(rb, screen, tag_list);
    if (code != err.RTGERR_OK) {
        release(screen);
        rb.DeleteBoard(board);
        return code;
    }
    device.driver_data = screen;
    return err.RTGERR_OK;
}

/// The GPU started and the board filled in, as far as the first show
/// needs. What it took is the caller's to give back (`release`) on any
/// answer but RTGERR_OK.
fn bringUp(rb: *RtgDriverBase, screen: *Screen, tag_list: ?[*]const TagItem) i32 {
    const sys = screen.sys;
    const board = screen.board;
    // The board's buffers start, and their rows are rounded, as its tags
    // say; whole cache lines where they say nothing.
    const asked_alignment: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Alignment, 0, tag_list));
    if (asked_alignment != 0) screen.alignment = asked_alignment;
    // A GPU that does not start has given itself back, a function on PCI
    // with it.
    if (!virtio.start(&screen.gpu, sys)) return err.RTGERR_NO_DISPLAY;
    screen.started = true;
    // The picture as large as the emulator's window has it - QEMU's xres
    // and yres - where it says.
    if (virtio.displaySize(&screen.gpu, Waiter{ .screen = screen })) |size| {
        if (size.width <= largest_side and size.height <= largest_side) {
            screen.width = size.width;
            screen.height = size.height;
        }
    }
    // One mode of its own, the emulator's window, on a display with no
    // clock: it stands while the EDID names none.
    const own: rtg.RtgTimings = .{ .h_active = screen.width, .v_active = screen.height };
    if (rb.AddBoardMode(board, &own, @intFromEnum(rtg.PixelFormat.bgra32), rtg.modes.RTGMF_DEFAULT) == 0) return err.RTGERR_NO_MEMORY;
    screen.pitch = rowBytes(screen, screen.width);

    // At most as many pictures of the mode the display is in as the
    // board asks for, each taken by the library as it is allocated. Not
    // cleared: each is cleared before it is first shown. The cursor
    // plane's two images now, from a page on, the system's and not the
    // task's that happened to ask.
    const frame: usize = @as(usize, screen.pitch) * screen.height;
    screen.buffers = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list))), 1);
    const memory = sys.AllocMem(2 * cursor_bytes + page, exec.MEMF_DMA | exec.MEMF_SYSTEM) orelse return err.RTGERR_NO_MEMORY;
    screen.cursor_memory = memory;
    screen.cursor = @ptrFromInt((@intFromPtr(memory) + page - 1) & ~@as(usize, page - 1));
    // Flipped between two frames rtg.library makes its pictures in: no
    // band is read by the display itself.
    board.direct_bands = 0;
    board.region = .{
        .size = screen.buffers * frame,
        .alignment = screen.alignment,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED |
            rtg.boards.RTGRF_SYSTEM_MEMORY | rtg.boards.RTGRF_DMA_MEMORY,
    };
    board.info.buffers = screen.buffers;
    return err.RTGERR_OK;
}

/// The device is taken from the driver: the GPU stopped.
fn detach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice) callconv(.c) void {
    _ = driver;
    const screen: *Screen = @ptrCast(@alignCast(device.driver_data orelse return));
    if (screen.started) virtio.stop(&screen.gpu);
    screen.started = false;
    screen.scanning = 0;
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

/// What is on the display's connector, for the library: the emulator's
/// window, which is always there, and the EDID the emulator gives it.
fn detect(board: *rtg.RtgBoard, asked: *rtg.RtgDetect) callconv(.c) i32 {
    const screen = screenOf(board);
    asked.present = 1;
    asked.edid_size = virtio.readEdid(&screen.gpu, asked.edid[0..asked.edid_max], Waiter{ .screen = screen });
    return err.RTGERR_OK;
}

/// The board's one op for what is on the glass (`RtgShow`): put in the
/// mode where the library says it is to be, the window showing the first
/// of the mode's two frames, which rtg.library has made the whole
/// picture in. Its pictures after that reach it through `flipOp`.
fn showOp(board: *rtg.RtgBoard, what: *const rtg.RtgShow) callconv(.c) i32 {
    if (what.flags & rtg.boards.RTGSHOW_MODE_CHANGED == 0) return err.RTGERR_OK;
    const screen = screenOf(board);
    if (!screen.started) return err.RTGERR_NO_DISPLAY;
    const mode = what.mode;
    // A row as the library makes one of a buffer.
    if (mode.format != .bgra32 or mode.pitch != rowBytes(screen, mode.width)) return err.RTGERR_BAD_MODE;
    const start = what.frame orelse return err.RTGERR_BAD_ARG;
    screen.mode_id = mode.id;
    screen.width = mode.width;
    screen.height = mode.height;
    screen.pitch = mode.pitch;
    // Room for as many pictures of the mode as the board may have.
    board.region.size = @as(usize, screen.buffers) * @as(usize, mode.pitch) * mode.height;
    // What the window showed until now says nothing about the new mode.
    screen.scanning = 0;
    return if (scanFrom(screen, start)) err.RTGERR_OK else err.RTGERR_NO_DISPLAY;
}

/// The window told to show `frame` from now on: one of the two
/// rtg.library makes its pictures in, handed on already (`refresh`).
/// Nothing has to be waited for, but a picture a frame is all the window
/// shows, so the library waits one.
fn flipOp(board: *rtg.RtgBoard, frame: *rtg.RtgBitMap) callconv(.c) i32 {
    const screen = screenOf(board);
    if (frame.pixels == null) return err.RTGERR_BAD_ARG;
    if (!screen.started) return err.RTGERR_NO_DISPLAY;
    if (!scanFrom(screen, frame)) return err.RTGERR_IO;
    screen.updates +%= 1;
    return err.RTGERR_OK;
}

/// A rectangle of a frame was written by the CPU, after rtg.library made
/// a picture in it: copied into the emulator's copy of it.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect) callconv(.c) i32 {
    const screen = screenOf(board);
    if (!screen.started) return err.RTGERR_NO_DISPLAY;
    handOn(screen, bitmap, area);
    return err.RTGERR_OK;
}

fn stats(board: *rtg.RtgBoard, into: *rtg.RtgBoardStats) callconv(.c) void {
    into.frames = screenOf(board).updates;
}

const pointer_ops = rtg.RtgPointerOps{ .set = &setPointer, .move = &movePointer, .show = &showPointer };

/// Flipped between frames the library makes its pictures in, what the
/// emulator says its window is, and the pointer the host's own, a cursor
/// plane.
const ops = rtg.boards.RtgBoardOps{
    .destroy = &destroy,
    .show = &showOp,
    .refresh = &refresh,
    .flip = &flipOp,
    .stats = &stats,
    .detect = &detect,
    .pointer = &pointer_ops,
};

const driver_ops = rtg.RtgDriverOps{ .attach = &attach, .detach = &detach };

/// What it takes: a panel part that is a virtio GPU, and a virtio GPU's
/// function on PCI, in the arrangement the standard settled on and the
/// one before it.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = st.CHIP_VIRTIO_GPU },
    .{ .fields = rtg.drivers.RTGMATCH_VENDOR | rtg.drivers.RTGMATCH_DEVICE, .vendor = virtio.pci_vendor, .device = virtio.pci_device },
    .{ .fields = rtg.drivers.RTGMATCH_VENDOR | rtg.drivers.RTGMATCH_DEVICE, .vendor = virtio.pci_vendor, .device = virtio.pci_device_old },
    .{},
};

/// The driver's tag: a description and no init. rtg.library reads it at
/// its own init and puts the driver on its list; nothing of this module
/// runs until a board is asked for.
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

export const rtg_virtio_tag: rtg.ResidentRtgDriver linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&rtg_virtio_tag),
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

// SPDX-License-Identifier: MPL-2.0
//! The BCM2712's video scaler behind its first HDMI port as a display
//! board - the port in `bcm2712.zig`, its DDC in `ddc.zig`, the scaler's
//! display list in `list.zig`, the link's sound in `sound.zig`: a display that reads its picture out of the
//! machine's RAM by itself.
//!
//! A module of its own, on the same footing as the other drivers: a
//! description of a driver called "bcm2712" behind a ROM tag, which
//! rtg.library puts on its list. It takes the panel part that is the
//! scaler and makes a board of it.
//!
//! What it drives is an address. The scaler reads a whole picture from
//! RAM every frame, wherever its display list says the picture is, so
//! showing a frame is naming its address.
//!
//! **Flipped.** The scaler reads RAM past the caches, and the caches
//! write their lines back in an order of their own: a picture drawn over
//! while it is read shows, for a frame, a patchwork of old and new cache
//! lines, sixteen pixels each. So it is never shown a buffer drawn in:
//! rtg.library makes each picture in the one of two frames the display
//! is not reading (its `compose/_flip.zig`), hands it on to this driver
//! (`refresh`), which writes it out of the caches, and has it tell the
//! scaler to read that frame from the next frame on (`flipOp`), which
//! the library waits for.
//!
//! A whole picture is a copy of the whole display - at 2560x1440 14 MB,
//! which takes the cores 14 ms - and a program that draws each picture
//! in one buffer while it shows another, and then shows that one, would
//! wait for one each time: a frame lost to every picture. So the port
//! says it reads such a program's buffers themselves
//! (`RTGBF_DIRECT_FLIP`): the library then has it flipped to a whole
//! buffer shown in place of another that nothing was written in while it
//! was shown, handed on whole and read as it is, and nothing is copied.
//!
//! **The modes** are rtg.library's to make: the driver says what is on
//! the port (`detect`) - whether a monitor is there, by the port's
//! hot-plug line, and its EDID, read over the port's DDC - and which
//! timings the port can make (`checkMode`), and the library lists the
//! modes the monitor names. The line raises no interrupt here: the frame
//! interrupt has the library look at the connector twice a second
//! (`MonitorChanged`), and with a monitor on the port its scrambling is
//! looked after then. A monitor plugged in later has the port started
//! again for it, sent as that monitor takes it.
//!
//! **The pointer and the overlay** are each a plane of the scaler's own,
//! which it lays over the picture itself: the image copied into a buffer
//! of the driver's as ARGB, its mask the alpha, and a move is the plane
//! written again at its new place - so dragging an icon makes no picture
//! at all. Two buffers each take turns, so the one the scaler reads is
//! never the one written.
//!
//! **What the port does in its own hardware besides**: the picture
//! mirrored either way (MirrorBoard) is the scaler reading its planes
//! backwards; the board asleep (SetBoardPower) is the controller sending
//! blank pixels without their syncs, which a monitor sleeps at, the mode
//! and everything else left running; and the brightness is the
//! monitor's own, set and read over the DDC with DDC/CI, where the
//! monitor takes it. A start of the port - a mode set, a monitor plugged
//! in - puts the first two back as the board has them (`putBack`).
//!
//! The buffers are the machine's RAM below 4 GiB, which the scaler
//! reaches (MEMF_DMA), taken by the library as each is allocated
//! (RTGRF_SYSTEM_MEMORY, RTGRF_DMA_MEMORY). The driver's own are the two
//! planes' images.
//!
//! The pixel valve raises an interrupt at each frame (the part's
//! PART_Irq): its server says the frame to the library (`FrameDone`),
//! and a flip and WaitVBlank wait for it. The port's own waits - the
//! PHY, the DDC - are on timer.device, opened as the board is made and
//! closed with it.
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
const timer = sdk.devices.timer;

const bcm2712 = @import("bcm2712.zig");
const ddc = @import("ddc.zig");
const sound = @import("sound.zig");
const list = @import("list.zig");

const MODULE_NAME = "rtg-bcm2712";
const DRIVER_NAME = "bcm2712";
const VERSION = 1;
const REVISION = 3;
const BUILD_DATE = "16.11.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// What every row and every buffer starts on: whole cache lines, so a
/// refresh writes back exactly the rows it names, and as wide as the
/// scaler fetches in one go.
const row_alignment = 128;
/// Where the planes' images start.
const page = 4096;
/// The most pixels a side of the picture has: what fourteen bits hold,
/// which every size here is kept in.
const largest_side = 0x3FFF;
/// The bytes of one of the cursor plane's two images.
const cursor_bytes = list.cursor_side * list.cursor_side * 4;
/// The most bytes of a monitor's EDID the port reads.
const edid_block = rtg.modes.RTG_EDID_BLOCK;
const edid_most: usize = @as(usize, ddc.edid_blocks) * edid_block;
/// How many frames go by between two looks at the port's connector:
/// half a second of them at sixty a second.
const look_frames = 30;

/// Everything the board of this driver has. The library allocates it
/// beside the handle.
const Screen = struct {
    sys: *ExecBase,
    /// rtg.library, as the driver calls it.
    rtg_base: *RtgBase,
    /// Where the port is: the scaler's registers and the port's other
    /// blocks, as the board's list names them.
    port: bcm2712.Port,
    /// The picture: its size, rows `pitch` bytes apart, four bytes a
    /// pixel.
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0,
    /// The board, and how many pictures it may have at once.
    board: *rtg.RtgBoard,
    buffers: u32 = 1,
    /// The mode the display is in, as the library handed it over: its
    /// number - 0 before the first - and its timings.
    mode_id: u32 = 0,
    timings: rtg.RtgTimings = .{},
    /// What a row of a buffer is rounded up to: the board's display
    /// memory's alignment, which the library rounds a mode's rows by.
    alignment: u32 = row_alignment,
    /// What the monitor says of itself that decides how a mode is sent
    /// to it - HDMI or DVI, its range - as the library read it, taken as
    /// the mode is set; whether it was on the port when last looked at,
    /// how many looks in a row have seen otherwise, the frames since the
    /// library was last asked to look, and the monitor's EDID as it was
    /// read when it came (`detect`), with how often it was tried.
    sink: bcm2712.Sink = .{},
    plugged: bool = false,
    settling: u32 = 0,
    frames_unseen: u32 = 0,
    edid: [edid_most]u8 = undefined,
    edid_size: u32 = 0,
    edid_tries: u32 = 0,
    /// Held while the port's DDC is talked on and while a task writes
    /// what a start of the port also writes - the picture's address, how
    /// it is turned, whether it is sent.
    port_lock: exec.SignalSemaphore = .{},
    /// Where the scaler reads from; 0 while the port does not run.
    scanning: usize = 0,
    /// How many times the display has been handed a picture.
    updates: u32 = 0,
    /// timer.device, opened as the board is made: the request each wait
    /// copies.
    timer_io: timer.TimeRequest = .{},
    timer_open: bool = false,
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
    /// What a mode set and the link's sound both write, kept together,
    /// and the sound the link was told to carry: null for none.
    shared: bcm2712.Shared = .{},
    audio: ?rtg.RtgAudio = null,
    /// How the picture is turned, and whether the monitor is sent
    /// nothing.
    turn: list.Turn = .{},
    dark: bool = false,
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

/// Wait for `frames` frames, as the library waits (WaitVBlank): for the
/// display's frame interrupt to come that many times, where it comes, so
/// that a flip is waited out to the frame the new picture starts in;
/// else for as long as they take, which is what makes a program that
/// paces itself by the display run at the speed it would on one that
/// says when a frame begins. The CPU is given away meanwhile, either way.
fn pace(screen: *Screen, frames: u32) void {
    _ = screen.rtg_base.WaitVBlank(screen.board, frames);
}

/// The pixel valve's interrupt: the frame said to the library, which
/// counts it and wakes whoever waits for one.
fn frameServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const screen: *Screen = @ptrCast(@alignCast(data.?));
    if (bcm2712.takeInterrupts(&screen.port) == 0) return 0;
    drivers(screen).FrameDone(screen.board);
    // The port's hot-plug line raises no interrupt here: the library is
    // asked to look at the connector now and then (`detect`), which
    // changes nothing while the same monitor is there.
    screen.frames_unseen += 1;
    if (screen.frames_unseen >= look_frames) {
        screen.frames_unseen = 0;
        drivers(screen).MonitorChanged(screen.board);
    }
    return 1;
}

/// The frame interrupt's server on, once the port runs.
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

/// What the port's own waits wait with.
const Waiter = struct {
    screen: *Screen,

    pub fn wait(waiter: Waiter, micros: u32) void {
        sleep(waiter.screen, micros);
    }
};

/// Wait `micros` on timer.device, the CPU given away meanwhile. Nothing
/// is waited for when timer.device could not be had.
fn sleep(screen: *Screen, micros: u64) void {
    const sys = screen.sys;
    if (!screen.timer_open) return;
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

// --- the display -------------------------------------------------------------

/// The scaler told to read `picture` from its next frame on: a frame of
/// the mode it is in, of which its display list is told the address.
fn scanFrom(screen: *Screen, picture: *const rtg.RtgBitMap) void {
    const address = @intFromPtr(picture.pixels orelse return);
    if (address == screen.scanning) return;
    list.show(&screen.port, picture);
    screen.scanning = address;
}

// --- the pointer and the overlay, each a plane of the scaler's ---------------

/// Whether pixel (x, y) of an image is the image's own, by its mask.
fn opaqueAt(image: *const rtg.RtgPointerImage, x: u32, y: u32) bool {
    return image.mask[y * image.mask_pitch + x / 8] & (@as(u8, 0x80) >> @intCast(x % 8)) != 0;
}

/// `rows` by `columns` of an image into a plane's buffer whose rows are
/// `side` pixels apart, as ARGB: opaque where the mask says, clear
/// elsewhere.
fn imageInto(pixels: [*]u32, side: u32, one: *const rtg.RtgPointerImage, rows: u32, columns: u32) void {
    var y: u32 = 0;
    while (y < rows) : (y += 1) {
        const row: [*]const u32 = @ptrCast(@alignCast(one.pixels + y * one.pitch));
        var x: u32 = 0;
        while (x < columns) : (x += 1) {
            pixels[y * side + x] = if (opaqueAt(one, x, y)) row[x] | 0xFF00_0000 else 0;
        }
    }
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
    const at = hotSpot(screen);
    list.cursor(
        &screen.port,
        @intFromPtr(cursorBuffer(screen, screen.cursor_turn)),
        screen.cursor_small,
        screen.cursor_hot_x,
        screen.cursor_hot_y,
        at.x,
        at.y,
        screen.pointer_shown and screen.pointer != null,
    );
}

/// A new image into the buffer the cursor's plane is not reading, and
/// the plane turned to it.
fn cursorImage(screen: *Screen, image: ?*const rtg.RtgPointerImage) void {
    screen.pointer = image;
    const one = image orelse return cursorPlane(screen);
    const small = one.width <= list.cursor_side / 2 and one.height <= list.cursor_side / 2;
    const side: u32 = if (small) list.cursor_side / 2 else list.cursor_side;
    const turn = screen.cursor_turn +% 1;
    const buffer = cursorBuffer(screen, turn);
    const pixels: [*]u32 = @ptrCast(@alignCast(buffer));
    @memset(pixels[0 .. side * side], 0);
    imageInto(pixels, side, one, @min(one.height, side), @min(one.width, side));
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

/// The bytes of one of the overlay plane's buffers: rtg's largest image.
const overlay_bytes = list.overlay_side * list.overlay_side * 4;
comptime {
    std.debug.assert(list.overlay_side == rtg.boards.RTG_OVERLAY_MAX);
}

fn overlayBuffer(screen: *Screen, turn: u1) [*]u8 {
    return screen.overlay_images.? + @as(usize, turn) * overlay_bytes;
}

/// The plane told its buffer, the image's size and place, and whether it
/// is seen.
fn overlayPlane(screen: *Screen) void {
    if (screen.overlay_images == null) return;
    list.overlay(
        &screen.port,
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
    const side: u32 = list.overlay_side;
    const turn = screen.overlay_turn +% 1;
    const buffer = overlayBuffer(screen, turn);
    const rows = @min(one.height, side);
    const columns = @min(one.width, side);
    imageInto(@ptrCast(@alignCast(buffer)), side, one, rows, columns);
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

// --- what the port does itself -----------------------------------------------

/// What a start of the port leaves as it makes it - the picture unturned,
/// the monitor sent it, the cursor and the overlay hidden - put back as
/// the board has it.
fn putBack(screen: *Screen) void {
    list.mirror(&screen.port, screen.scanning, screen.turn);
    if (screen.dark) bcm2712.transmit(&screen.port, false);
    cursorPlane(screen);
    overlayPlane(screen);
}

/// The picture mirrored, from the next frame on; the cursor and the
/// overlay with it.
fn mirror(board: *rtg.RtgBoard, x: bool, y: bool) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    sys.ObtainSemaphore(&screen.port_lock);
    screen.turn = .{ .x = x, .y = y };
    if (screen.scanning != 0) list.mirror(&screen.port, screen.scanning, screen.turn);
    sys.ReleaseSemaphore(&screen.port_lock);
    cursorPlane(screen);
    overlayPlane(screen);
    return err.RTGERR_OK;
}

/// The monitor sent nothing, which it sleeps at, or the picture again.
/// The library has made the picture black before it is asked to sleep,
/// and makes it again once the monitor is sent it.
fn power(board: *rtg.RtgBoard, state: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    const asleep = state == rtg.boards.RTGPWR_ASLEEP;
    sys.ObtainSemaphore(&screen.port_lock);
    defer sys.ReleaseSemaphore(&screen.port_lock);
    screen.dark = asleep;
    bcm2712.transmit(&screen.port, !asleep);
    return @intCast(if (asleep) rtg.boards.RTGPWR_ASLEEP else rtg.boards.RTGPWR_ON);
}

/// The monitor's brightness set over DDC/CI, `percent` of its largest:
/// RTGERR_IO where it does not answer. The board's lock, which the
/// library holds around this, keeps the port's other talk on the DDC
/// away - a look at the connector, a start of the port - and the port's
/// own lock is not taken: the question and its answer take a tenth of a
/// second, and the pictures go on being flipped to meanwhile.
fn setBrightness(board: *rtg.RtgBoard, percent: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    const waiter = Waiter{ .screen = screen };
    const now = ddc.feature(&screen.port, ddc.VCP_BRIGHTNESS, waiter) orelse return err.RTGERR_IO;
    const value: u16 = @intCast((percent * now.most + 50) / 100);
    if (!ddc.setFeature(&screen.port, ddc.VCP_BRIGHTNESS, value, waiter)) return err.RTGERR_IO;
    return err.RTGERR_OK;
}

/// The monitor's brightness as it answers over DDC/CI, in per cent of
/// its largest - set with its own buttons, or by `setBrightness`:
/// RTGERR_IO where it does not answer. Under the board's lock and
/// without the port's, as `setBrightness`.
fn brightness(board: *rtg.RtgBoard) callconv(.c) i32 {
    const screen = screenOf(board);
    const now = ddc.feature(&screen.port, ddc.VCP_BRIGHTNESS, Waiter{ .screen = screen }) orelse return err.RTGERR_IO;
    const most: u32 = now.most;
    const value: u32 = @min(now.value, now.most);
    return @intCast((value * 100 + most / 2) / most);
}

// --- the board -------------------------------------------------------------------

/// Everything the screen took given back: the port stopped, its frame
/// interrupt's server off, timer.device closed, the planes' images
/// freed. What it has not taken, or has given back already, is passed
/// over.
fn release(screen: *Screen) void {
    const sys = screen.sys;
    halt(screen);
    if (screen.timer_open) sys.CloseDevice(&screen.timer_io.node);
    screen.timer_open = false;
    if (screen.cursor_memory) |memory| sys.FreeMem(memory, 2 * cursor_bytes + page);
    screen.cursor_memory = null;
    screen.cursor = null;
    if (screen.overlay_memory) |memory| sys.FreeMem(memory, 2 * overlay_bytes + page);
    screen.overlay_memory = null;
    screen.overlay_images = null;
}

/// The port stopped where it runs: its frame interrupt's server off, and
/// the monitor sent nothing, which it sleeps at. The scaler goes on
/// reading where it read; none of it reaches the monitor.
fn halt(screen: *Screen) void {
    unhookFrames(screen);
    if (screen.scanning == 0) return;
    screen.sys.ObtainSemaphore(&screen.port_lock);
    bcm2712.transmit(&screen.port, false);
    screen.sys.ReleaseSemaphore(&screen.port_lock);
    screen.scanning = 0;
}

/// The scaler's panel part is offered: a board made of it, its modes left
/// to the library.
fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const rb = driver.rtg_base;
    const sys = driver.sys_base;

    // What the tags have to say, looked at before anything is taken.
    const format: rtg.PixelFormat = @enumFromInt(@as(u8, @truncate(rb.GetRtgTagData(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32), tag_list))));
    if (format != .bgra32) return err.RTGERR_BAD_FORMAT;
    const width: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Width, 0, tag_list));
    const height: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Height, 0, tag_list));
    if (width == 0 or height == 0) return err.RTGERR_BAD_TAGS;
    if (width > largest_side or height > largest_side) return err.RTGERR_BAD_TAGS;

    // Where the port is: the scaler's registers from the part's address,
    // its other blocks from the table the part points at.
    const hvs = rb.GetRtgTagData(st.PART_Address, 0, tag_list);
    const blocks: ?*const sdk.hardware.bcm2712.HdmiPort = @ptrFromInt(rb.GetRtgTagData(st.PART_Blocks, 0, tag_list));
    if (hvs == 0) return err.RTGERR_BAD_TAGS;
    const port = bcm2712.Port{ .hvs = hvs, .blocks = (blocks orelse return err.RTGERR_BAD_TAGS).* };
    // Nothing is asked of the scaler here: not before the firmware has
    // its clocks running, which a mode's start sees to.
    const board = rb.CreateBoard(driver, device, &.{
        .ops = &ops,
        .instance_size = @sizeOf(Screen),
        // The port reads a whole buffer in place of a frame, for a
        // program that shows one buffer after another.
        .flags = rtg.boards.RTGBF_DIRECT_FLIP,
        // Its planes are read backwards either way, and the monitor on
        // its port takes a brightness.
        .caps = rtg.boards.RTGBC_MIRROR_X | rtg.boards.RTGBC_MIRROR_Y,
        .brightness_steps = 101,
        // A monitor's modes are made in the format the board shows.
        .format = format,
    }) orelse return err.RTGERR_NO_MEMORY;
    const screen = screenOf(board);
    screen.* = .{ .sys = sys, .rtg_base = programs(rb), .port = port, .width = width, .height = height, .board = board };
    // The port's waits are on timer.device.
    screen.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    screen.timer_open = sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &screen.timer_io.node, 0) == 0;
    // The board's buffers start, and their rows are rounded, as its tags
    // say; whole cache lines where they say nothing.
    const asked_alignment: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Alignment, 0, tag_list));
    if (asked_alignment != 0) screen.alignment = asked_alignment;
    // The modes are the library's to make, of what the monitor on the
    // port names (`detect`, `checkMode`) and of the part's size where
    // none does. Here: the pixel valve's frame interrupt.
    screen.frame_irq = @truncate(rb.GetRtgTagData(st.PART_Irq, 0, tag_list));
    screen.pitch = rowBytes(screen, width);
    sys.InitSemaphore(&screen.port_lock);
    sys.InitSemaphore(&screen.shared.lock);
    screen.shared.rtg_base = rb;

    // At most as many pictures of the mode the display is in as the
    // board asks for, each taken by the library as it is allocated, from
    // memory the scaler reaches. Not cleared: each is cleared before it
    // is first shown. The cursor plane's two images now, from a page on,
    // the system's and not the task's that happened to ask; the
    // overlay's too, without which the overlay is not shown.
    const frame: usize = @as(usize, screen.pitch) * height;
    screen.buffers = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list))), 1);
    const memory = sys.AllocMem(2 * cursor_bytes + page, exec.MEMF_DMA | exec.MEMF_SYSTEM) orelse {
        release(screen);
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
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED |
            rtg.boards.RTGRF_SYSTEM_MEMORY | rtg.boards.RTGRF_DMA_MEMORY,
    };
    board.info.buffers = screen.buffers;
    device.driver_data = screen;
    return err.RTGERR_OK;
}

/// The device is taken from the driver: the port stopped.
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

/// Whether a block of an EDID sums to zero, as every block does that was
/// read as the monitor holds it.
fn sumsToZero(block: *const [edid_block]u8) bool {
    var sum: u8 = 0;
    for (block) |byte| sum +%= byte;
    return sum == 0;
}

/// How many looks in a row must see a monitor come or go before it is
/// taken to have: a second of looks, which is what a plug that bounces as
/// it goes in, or a monitor that raises its hot-plug line before its EDID
/// reads, takes.
const settle_looks = 2;

/// How often the EDID of a monitor that has come to a running port is
/// tried.
const edid_tries_most = 3;

/// What is on the port, for the library: the port woken where it does
/// not run yet, its hot-plug line read, and the monitor's EDID - its
/// first block, read again once where it does not sum to zero, and as
/// many of the extensions it names as there is room for. The EDID is
/// read when a monitor has come - a few looks long where it does not
/// read; one that was there at the last look is the one read then, so a
/// look that finds nothing new costs the hot-plug line alone. With the
/// port running, a monitor that has come or gone is taken to have once
/// as many looks in a row as a plug takes to settle have seen it, and
/// what was there is answered until then. With a monitor on the running
/// port, its scrambling is looked after (`bcm2712.tend`). The DDC is the
/// port's one: held against every other task that talks on it.
fn detect(board: *rtg.RtgBoard, asked: *rtg.RtgDetect) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    const waiter = Waiter{ .screen = screen };
    sys.ObtainSemaphore(&screen.port_lock);
    defer sys.ReleaseSemaphore(&screen.port_lock);
    const running = screen.scanning != 0;
    // A port that runs is awake: waking it again would put the
    // controller's pixel clocks back on the divider under the picture.
    if (!running) {
        const failure = bcm2712.wake(&screen.port, sys, waiter);
        if (failure != .none) {
            exec.kprintf(sys, "%s: %s\n", .{ MODULE_NAME, bcm2712.why(failure) });
            return err.RTGERR_NO_DISPLAY;
        }
    }
    const plugged = bcm2712.monitor(&screen.port);
    if (plugged == screen.plugged) {
        screen.settling = 0;
    } else {
        screen.settling += 1;
        if (!running or screen.settling >= settle_looks) {
            screen.settling = 0;
            screen.plugged = plugged;
            screen.edid_size = 0;
            screen.edid_tries = 0;
            if (!plugged and running) exec.kprintf(sys, "%s: the monitor was taken off the HDMI port\n", .{MODULE_NAME});
        }
    }
    if (!screen.plugged) return err.RTGERR_OK;
    asked.present = 1;
    // A monitor whose EDID does not read is not asked at every look of a
    // running port: each try holds the port for as long as the DDC
    // takes to give up.
    if (screen.edid_size == 0 and (!running or screen.edid_tries < edid_tries_most)) {
        screen.edid_tries += 1;
        readEdid(screen, waiter);
    }
    if (running) bcm2712.tend(&screen.port, waiter);
    const length = @min(screen.edid_size, asked.edid_max);
    @memcpy(asked.edid[0..length], screen.edid[0..length]);
    asked.edid_size = length;
    return err.RTGERR_OK;
}

/// The EDID of the monitor on the port read into the screen's own copy:
/// nothing where it does not read.
fn readEdid(screen: *Screen, waiter: Waiter) void {
    const first: *[edid_block]u8 = screen.edid[0..edid_block];
    var read = ddc.readEdid(&screen.port, 0, first, waiter);
    if (read and !sumsToZero(first)) read = ddc.readEdid(&screen.port, 0, first, waiter);
    if (!read) return;
    var blocks: u32 = 1;
    const named = @min(@as(u32, first[126]) + 1, ddc.edid_blocks);
    while (blocks < named) : (blocks += 1) {
        const block: *[edid_block]u8 = screen.edid[blocks * edid_block ..][0..edid_block];
        if (!ddc.readEdid(&screen.port, @intCast(blocks), block, waiter)) break;
    }
    screen.edid_size = blocks * edid_block;
}

/// Whether the port can make `timings`: by its clock and by what its
/// registers hold.
fn checkMode(board: *rtg.RtgBoard, timings: *const rtg.RtgTimings) callconv(.c) i32 {
    _ = board;
    return if (bcm2712.makes(timings)) err.RTGERR_OK else err.RTGERR_BAD_MODE;
}

/// The port started in the screen's mode, sent as the monitor takes it
/// (`Screen.sink`), reading the frame at `address`; then what a start
/// leaves put back as the board has it, and the frame interrupt hooked.
/// False, and said on the raw port, when it did not come up.
fn startPort(screen: *Screen, address: usize) bool {
    const sys = screen.sys;
    const failure = bcm2712.start(&screen.port, sys, &screen.shared, &screen.timings, screen.sink, address, screen.pitch, Waiter{ .screen = screen });
    if (failure != .none) {
        exec.kprintf(sys, "%s: %s\n", .{ MODULE_NAME, bcm2712.why(failure) });
        return false;
    }
    screen.scanning = address;
    putBack(screen);
    const plugged = bcm2712.monitor(&screen.port);
    if (plugged != screen.plugged) {
        screen.edid_size = 0;
        screen.edid_tries = 0;
    }
    screen.plugged = plugged;
    screen.settling = 0;
    screen.frames_unseen = 0;
    if (!screen.plugged) exec.kprintf(sys, "%s: no monitor on the HDMI port\n", .{MODULE_NAME});
    hookFrames(screen);
    return true;
}

/// The board's one op for what is on the glass (`RtgShow`): put in the
/// mode where the library says it is to be, the scaler reading the first
/// of the mode's two frames, which rtg.library has made the whole
/// picture in. The mode it is in handed over again is a monitor that
/// came to the port, and the port is started again with the timings
/// handed over now, as that monitor takes them. Its pictures after that
/// reach it through `flipOp`.
fn showOp(board: *rtg.RtgBoard, what: *const rtg.RtgShow) callconv(.c) i32 {
    if (what.flags & rtg.boards.RTGSHOW_MODE_CHANGED == 0) return err.RTGERR_OK;
    const screen = screenOf(board);
    const mode = what.mode;
    // A row as the library makes one of a buffer.
    if (mode.format != .bgra32 or mode.pitch != rowBytes(screen, mode.width)) return err.RTGERR_BAD_MODE;
    const start = what.frame orelse return err.RTGERR_BAD_ARG;
    const address = @intFromPtr(start.pixels orelse return err.RTGERR_BAD_ARG);
    screen.mode_id = mode.id;
    screen.timings = what.timings.*;
    screen.width = mode.width;
    screen.height = mode.height;
    screen.pitch = mode.pitch;
    // How the mode goes to the monitor now on the port.
    var monitor: rtg.RtgMonitorInfo = .{};
    _ = screen.rtg_base.GetBoardMonitor(board, &monitor, @sizeOf(rtg.RtgMonitorInfo));
    screen.sink = bcm2712.Sink.of(&monitor);
    // Room for as many pictures of the mode as the board may have.
    board.region.size = @as(usize, screen.buffers) * @as(usize, mode.pitch) * mode.height;
    // What it read until now says nothing about the new mode, nor to a
    // monitor that came.
    screen.sys.ObtainSemaphore(&screen.port_lock);
    defer screen.sys.ReleaseSemaphore(&screen.port_lock);
    screen.scanning = 0;
    return if (startPort(screen, address)) err.RTGERR_OK else err.RTGERR_NO_DISPLAY;
}

/// The scaler told to read `frame` from its next frame on: one of the
/// two rtg.library makes its pictures in, handed on already (`refresh`),
/// or a buffer read in place of one. It takes the address at its next
/// frame, which the library waits for.
fn flipOp(board: *rtg.RtgBoard, frame: *rtg.RtgBitMap) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    if (frame.pixels == null) return err.RTGERR_BAD_ARG;
    // A port that does not run has nothing to flip: its start names the
    // frame it reads.
    if (screen.scanning == 0) return err.RTGERR_NO_MODE;
    // Against a task that turns the picture or starts the port.
    sys.ObtainSemaphore(&screen.port_lock);
    defer sys.ReleaseSemaphore(&screen.port_lock);
    scanFrom(screen, frame);
    screen.updates +%= 1;
    return err.RTGERR_OK;
}

/// A rectangle of a frame was written by the CPU, after rtg.library made
/// a picture in it, or of a buffer read in place of one: its pixels alone written back out of the caches,
/// which the scaler reads past - a run a row, one run over the rows
/// where the rectangle is as wide as the frame.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect) callconv(.c) i32 {
    const sys = screenOf(board).sys;
    const pixels = bitmap.pixels orelse return err.RTGERR_OK;
    if (area.width <= 0 or area.height <= 0) return err.RTGERR_OK;
    const x: u32 = @intCast(area.x);
    const y: u32 = @intCast(area.y);
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    if (x == 0 and width >= bitmap.width) {
        sys.CacheClearE(pixels + y * bitmap.pitch, height * bitmap.pitch, exec.CACRF_ClearD);
        return err.RTGERR_OK;
    }
    var row = y;
    while (row < y + height) : (row += 1) sys.CacheClearE(pixels + row * bitmap.pitch + x * 4, width * 4, exec.CACRF_ClearD);
    return err.RTGERR_OK;
}

/// The link's side of its sound (`SetBoardAudio`): the controller's MAI
/// set up for the stream - whose samples the sound's driver feeds its
/// FIFO - sent as audio sample packets with their infoframe and the
/// numbers the monitor rebuilds the sample clock from; or all of that
/// off again. A mode set while the sound plays sets the numbers and the
/// infoframe again (`bcm2712.start`). RTGERR_NO_MODE while the port does
/// not run, RTGERR_NOT_SUPPORTED where the mode goes out as DVI or the
/// MAI does not take the format.
fn audio(board: *rtg.RtgBoard, format: ?*const rtg.RtgAudio) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    const waiter = Waiter{ .screen = screen };
    const one = format orelse {
        if (screen.audio != null) sound.audioStop(&screen.port, sys, &screen.shared, waiter);
        screen.audio = null;
        return err.RTGERR_OK;
    };
    if (screen.scanning == 0) return err.RTGERR_NO_MODE;
    if (one.bits != 16) return err.RTGERR_NOT_SUPPORTED;
    if (!sound.audioStart(&screen.port, sys, &screen.shared, one.sample_rate, one.channels, waiter)) return err.RTGERR_NOT_SUPPORTED;
    screen.audio = one.*;
    return err.RTGERR_OK;
}

fn stats(board: *rtg.RtgBoard, into: *rtg.RtgBoardStats) callconv(.c) void {
    into.frames = screenOf(board).updates;
}

const pointer_ops = rtg.RtgPointerOps{ .set = &setPointer, .move = &movePointer, .show = &showPointer };
const overlay_ops = rtg.RtgOverlayOps{ .set = &setOverlay, .move = &moveOverlay };

/// Flipped between frames the library makes its pictures in, a
/// connector, the pointer and the overlay each a plane of its own, and
/// what its hardware does besides - the monitor sent to sleep, the
/// monitor's brightness, the picture mirrored.
const ops = rtg.boards.RtgBoardOps{
    .destroy = &destroy,
    .show = &showOp,
    .refresh = &refresh,
    .flip = &flipOp,
    .stats = &stats,
    .detect = &detect,
    .check_mode = &checkMode,
    .power = &power,
    .set_brightness = &setBrightness,
    .brightness = &brightness,
    .audio = &audio,
    .mirror = &mirror,
    .pointer = &pointer_ops,
    .overlay = &overlay_ops,
};

const driver_ops = rtg.RtgDriverOps{ .attach = &attach, .detach = &detach };

/// What it takes: the panel part that is the BCM2712's video scaler.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = st.CHIP_BCM2712_HVS },
    .{},
};

/// The driver's tag: a description and no init. rtg.library reads it at
/// its own init and puts the driver on its list; nothing of this module
/// runs until a board is asked for.
export const rtg_bcm2712_tag: rtg.ResidentRtgDriver linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&rtg_bcm2712_tag),
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

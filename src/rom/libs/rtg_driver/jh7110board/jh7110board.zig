// SPDX-License-Identifier: MPL-2.0
//! The JH7110's display controller behind its HDMI port (`jh7110.zig`,
//! the transmitter's PLLs in `phy.zig`) as a display board: a display
//! that reads its picture out of the machine's RAM by itself.
//!
//! A module of its own, on the same footing as the other drivers: a
//! description of a driver called "jh7110" behind a ROM tag, which
//! rtg.library puts on its list. It takes the panel part that is the
//! controller and makes a board of it.
//!
//! What it drives is an address. The controller reads a whole picture
//! from RAM every frame, wherever it is told the picture is, so showing
//! a frame is naming its address.
//!
//! **Flipped.** The controller reads RAM past the caches, and the caches
//! write their lines back in an order of their own: a picture drawn over
//! while it is read shows, for a frame, a patchwork of old and new cache
//! lines, sixteen pixels each. So it is never shown a buffer drawn in:
//! rtg.library makes each picture in the one of two frames the display
//! is not reading (its `compose/_flip.zig`), hands it on to this driver
//! (`refresh`), which writes it out of the caches, and has it tell the
//! controller to read that frame from the next frame on (`flipOp`),
//! which the library waits for. The bands and the overlay are the
//! library's, laid in the pictures it makes.
//!
//! **The modes** are rtg.library's to make: the driver says what is on
//! the port (`detect`) - whether a monitor is there, by the port's
//! hot-plug line, and its EDID, read over the port's DDC - and which
//! timings the port can make (`checkMode`), and the library lists the
//! modes the monitor names. The line raises no interrupt here: the frame
//! interrupt has the library look at the connector twice a second
//! (`MonitorChanged`). A monitor plugged in later has the port started
//! again for it, with the timings handed over then.
//!
//! **The pointer** is the controller's cursor plane, which it lays over
//! the picture itself: the image copied into a buffer of the driver's as
//! ARGB, its mask the alpha, and a move is the plane written again at
//! its new place. Two buffers take turns, so the one the controller
//! reads is never the one written. A start of the port puts the plane
//! back as the pointer has it.
//!
//! **A video layer**: the controller's first overlay, which reads a
//! film's frame in YUV planes itself - turning it into colours by a
//! matrix loaded into it - and scales it into a place on the display,
//! under the picture, seen where the picture has the layer's key colour
//! - or a shade of it a shadow darkened it to - or over it. A frame shown
//! is taken from the next frame on and waited for, so that the one
//! before may be given back; a place partly off the display is cut to
//! it; a start of the port puts the layer back as it was.
//!
//! The controller's planes share its hold and its commit bits, so
//! whatever writes one - a flip, the pointer's moves, a film, a start of
//! the port - holds `plane_lock`.
//!
//! The buffers are the machine's RAM below 4 GiB, which the controller
//! reaches (MEMF_DMA), taken by the library as each is allocated
//! (RTGRF_SYSTEM_MEMORY, RTGRF_DMA_MEMORY). The driver's own are the
//! cursor plane's two images.
//!
//! The controller raises an interrupt at each frame (the part's
//! PART_Irq): its server says the frame to the library (`FrameDone`),
//! and a flip and WaitVBlank wait for it. The port's own waits - a PLL,
//! the DDC - are on timer.device, opened as the board is made and closed
//! with it.
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

const jh7110 = @import("jh7110.zig");

const MODULE_NAME = "rtg-jh7110";
const DRIVER_NAME = "jh7110";
const VERSION = 1;
const REVISION = 1;
const BUILD_DATE = "16.11.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// What every row and every buffer starts on: whole cache lines, so a
/// refresh writes back exactly the rows it names, and as wide as the
/// controller fetches in one go.
const row_alignment = 128;
/// Where the cursor plane's images start.
const page = 4096;
/// The most pixels a side of the picture has: what the controller's
/// registers hold a place in, fourteen bits.
const largest_side = 0x3FFF;
/// The bytes of one of the cursor plane's two images.
const cursor_bytes = jh7110.cursor_side * jh7110.cursor_side * 4;
/// The most bytes of a monitor's EDID the port reads.
const edid_block = rtg.modes.RTG_EDID_BLOCK;
const edid_most: usize = @as(usize, jh7110.edid_blocks) * edid_block;
/// How many frames go by between two looks at the port's connector:
/// half a second of them at sixty a second.
const look_frames = 30;

/// Everything the board of this driver has. The library allocates it
/// beside the handle.
const Screen = struct {
    sys: *ExecBase,
    /// rtg.library, as the driver calls it.
    rtg_base: *RtgBase,
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
    /// Whether a monitor was on the port when last looked at, how many
    /// looks in a row have seen otherwise, the frames since the library
    /// was last asked to look, and the monitor's EDID as it was read when
    /// it came (`detect`), with how often it was tried.
    plugged: bool = false,
    settling: u32 = 0,
    frames_unseen: u32 = 0,
    edid: [edid_most]u8 = undefined,
    edid_size: u32 = 0,
    edid_tries: u32 = 0,
    /// The sound the link was told to carry: null for none.
    audio: ?rtg.RtgAudio = null,
    /// Held while the port's DDC is talked on and while a task writes
    /// what a start of the port also writes: the picture's address, the
    /// link's sound.
    port_lock: exec.SignalSemaphore = .{},
    /// Where the controller reads from; 0 while the port does not run.
    scanning: usize = 0,
    /// How many times the display has been handed a picture.
    updates: u32 = 0,
    /// timer.device, opened as the board is made: the request each wait
    /// copies.
    timer_io: timer.TimeRequest = .{},
    timer_open: bool = false,
    /// The cursor plane's two images, as AllocMem gave them and where they
    /// start; which of them is the plane's, whether it is the small size,
    /// and its image's hot spot.
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
    /// The controller's frame interrupt: its number (0 for none), its
    /// server and whether that is on.
    frame_irq: u32 = 0,
    frame_int: exec.Interrupt = .{},
    frame_hooked: bool = false,
    /// The video layer on the controller's first overlay (`videoOpen`):
    /// the layer while it is taken; the colours the picture shows it
    /// through, null over the picture; the picture last shown - a copy of
    /// what was handed in - the part of it, and its place on the display.
    /// Under `plane_lock`.
    video: ?*rtg.RtgVideoLayer = null,
    video_key: ?jh7110.VideoKey = null,
    video_picture: ?rtg.RtgYuv = null,
    video_src: rtg.RtgRect = .{},
    video_place: rtg.RtgRect = .{},
    /// Held while the controller's planes are written - the picture's,
    /// the cursor's, the video layer's - which share its hold and its
    /// commit bits, by the task that flips the picture, intuition's
    /// pointer task and a film's, each on any core.
    plane_lock: exec.Lock = .{},
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

/// The controller's interrupt: the frame said to the library, which
/// counts it and wakes whoever waits for one.
fn frameServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const screen: *Screen = @ptrCast(@alignCast(data.?));
    if (jh7110.takeInterrupts() == 0) return 0;
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

/// The controller told to read `picture` from its next frame on: a frame
/// of the mode it is in, of which it is told the address.
fn scanFrom(screen: *Screen, picture: *const rtg.RtgBitMap) void {
    const address = @intFromPtr(picture.pixels orelse return);
    if (address == screen.scanning) return;
    screen.sys.AcquireLock(&screen.plane_lock);
    jh7110.show(picture);
    screen.sys.ReleaseLock(&screen.plane_lock);
    screen.scanning = address;
}

// --- the pointer, on the controller's cursor plane ---------------------------

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

/// The plane told its buffer, size and hot spot, the hot spot's place,
/// and whether it is seen: only with an image. Holding `plane_lock`, on
/// a port that runs.
fn cursorWrite(screen: *Screen) void {
    const at = hotSpot(screen);
    jh7110.cursor(
        @intFromPtr(cursorBuffer(screen, screen.cursor_turn)),
        screen.cursor_small,
        screen.cursor_hot_x,
        screen.cursor_hot_y,
        at.x,
        at.y,
        screen.pointer_shown and screen.pointer != null,
    );
}

/// The plane written as the pointer has it. Nothing while the port does
/// not run: its registers do not answer, and its start writes the plane.
fn cursorPlane(screen: *Screen) void {
    if (screen.scanning == 0) return;
    screen.sys.AcquireLock(&screen.plane_lock);
    defer screen.sys.ReleaseLock(&screen.plane_lock);
    cursorWrite(screen);
}

/// Whether pixel (x, y) of an image is the image's own, by its mask.
fn opaqueAt(image: *const rtg.RtgPointerImage, x: u32, y: u32) bool {
    return image.mask[y * image.mask_pitch + x / 8] & (@as(u8, 0x80) >> @intCast(x % 8)) != 0;
}

/// A new image into the buffer the plane is not reading - ARGB, opaque
/// where the mask says, clear elsewhere - and the plane turned to it.
fn cursorImage(screen: *Screen, image: ?*const rtg.RtgPointerImage) void {
    screen.pointer = image;
    const one = image orelse return cursorPlane(screen);
    const small = one.width <= jh7110.cursor_side / 2 and one.height <= jh7110.cursor_side / 2;
    const side: u32 = if (small) jh7110.cursor_side / 2 else jh7110.cursor_side;
    const turn = screen.cursor_turn +% 1;
    const buffer = cursorBuffer(screen, turn);
    const pixels: [*]u32 = @ptrCast(@alignCast(buffer));
    @memset(pixels[0 .. side * side], 0);
    const rows = @min(one.height, side);
    const columns = @min(one.width, side);
    var y: u32 = 0;
    while (y < rows) : (y += 1) {
        const row: [*]const u32 = @ptrCast(@alignCast(one.pixels + y * one.pitch));
        var x: u32 = 0;
        while (x < columns) : (x += 1) {
            if (opaqueAt(one, x, y)) pixels[y * side + x] = row[x] | 0xFF00_0000;
        }
    }
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

// --- the video layer, on the controller's first overlay ----------------------

/// The colour the picture shows the layer through: near black, and the
/// same in each format a screen has here - five, six or eight bits a
/// channel. Keyed with it, each channel down to `video_key_darkest`, are
/// the shades of it shadows leave: layers' compose darkens what is under
/// a shadow by multiplying it, to (4, 0, 4) under one, (2, 0, 2) under
/// two laid over each other, (1, 0, 1) under three - so the film shows
/// under a window's shadow, undarkened, rather than a dark band.
const video_key: u32 = 0x0008_0008;
const video_key_darkest: u32 = 0x0001_0001;

/// What the source is cut by where the display cuts a place: whole runs
/// of 32 pixels across, which keep each plane's rows on the 16 bytes the
/// layer reads from, and pairs of rows down, which keep the colour's rows
/// with them.
const video_cut_across = 32;
const video_cut_down = 2;

/// Whether the overlay makes the display's colours out of such a
/// picture. Its converter holds one matrix at a time - BT.601's or
/// BT.709's, either range - and nothing else: there is no curve in it, so
/// a film of high dynamic range would come out flat and grey, no way to
/// move BT.2020's red, green and blue to the display's, and no ten-bit
/// path at all, since it reads a sample as a byte. Such a film is left to
/// graphics.library, which maps it.
fn videoColours(matrix: u8, transfer: u8, primaries: u8, depth: u8) bool {
    if (matrix != rtg.bitmaps.RTGYUV_BT601 and matrix != rtg.bitmaps.RTGYUV_BT709) return false;
    if (transfer != rtg.bitmaps.RTGYUV_SDR or primaries != rtg.bitmaps.RTGYUV_BT709) return false;
    return depth == 8;
}

/// The layer taken: under the picture unless asked over, nothing on it
/// and no place yet, the scaler's filter loaded. A picture the overlay
/// cannot make colours out of takes no layer, so that the caller puts
/// such a film down through graphics from the start.
fn videoOpen(board: *rtg.RtgBoard, layer: *rtg.RtgVideoLayer) callconv(.c) i32 {
    if (!videoColours(layer.matrix, layer.transfer, layer.primaries, layer.depth)) return err.RTGERR_NOT_SUPPORTED;
    const screen = screenOf(board);
    const sys = screen.sys;
    const under = layer.flags & rtg.RTGVLF_UNDER != 0;
    layer.key = if (under) video_key else 0;
    layer.max_width = jh7110.video_max_side;
    layer.max_height = jh7110.video_max_side;
    layer.max_up = jh7110.video_max_up;
    layer.max_down = jh7110.video_max_down;
    // A port that does not run has no registers that answer.
    if (screen.scanning == 0) return err.RTGERR_NO_MODE;
    sys.AcquireLock(&screen.plane_lock);
    defer sys.ReleaseLock(&screen.plane_lock);
    if (screen.video != null) return err.RTGERR_IN_USE;
    screen.video = layer;
    screen.video_key = if (under) .{ .low = video_key_darkest, .high = video_key } else null;
    screen.video_picture = null;
    screen.video_place = .{};
    jh7110.videoStart();
    jh7110.videoOrder(screen.video_key);
    return err.RTGERR_OK;
}

/// The layer off and the picture whole again, and a frame waited for, so
/// that the last picture is no longer read.
fn videoClose(board: *rtg.RtgBoard, layer: *rtg.RtgVideoLayer) callconv(.c) void {
    const screen = screenOf(board);
    const sys = screen.sys;
    sys.AcquireLock(&screen.plane_lock);
    if (screen.video == layer) {
        jh7110.videoHide();
        jh7110.videoOrder(null);
        screen.video = null;
        screen.video_key = null;
        screen.video_picture = null;
    }
    sys.ReleaseLock(&screen.plane_lock);
    pace(screen, 1);
}

/// A picture shown, or none, from the next frame - waited for, so that
/// the one before is no longer read. One the layer cannot read, or scale
/// into its place, is not kept: nothing is shown.
fn videoShow(board: *rtg.RtgBoard, layer: *rtg.RtgVideoLayer, picture: ?*const rtg.RtgYuv, src: ?*const rtg.RtgRect) callconv(.c) i32 {
    _ = layer;
    const screen = screenOf(board);
    const sys = screen.sys;
    const result = result: {
        sys.AcquireLock(&screen.plane_lock);
        defer sys.ReleaseLock(&screen.plane_lock);
        screen.video_picture = null;
        const one = picture orelse {
            jh7110.videoHide();
            break :result err.RTGERR_OK;
        };
        if (!videoReads(one, src.?.*)) {
            jh7110.videoHide();
            break :result err.RTGERR_BAD_ARG;
        }
        screen.video_picture = one.*;
        screen.video_src = src.?.*;
        if (videoPut(screen)) break :result err.RTGERR_OK;
        screen.video_picture = null;
        break :result err.RTGERR_BAD_ARG;
    };
    pace(screen, 1);
    return result;
}

/// The layer's new place, the picture shown in it from the next frame:
/// hidden while the picture cannot be scaled into it.
fn videoMove(board: *rtg.RtgBoard, layer: *rtg.RtgVideoLayer, place: *const rtg.RtgRect) callconv(.c) i32 {
    _ = layer;
    const screen = screenOf(board);
    const sys = screen.sys;
    sys.AcquireLock(&screen.plane_lock);
    defer sys.ReleaseLock(&screen.plane_lock);
    screen.video_place = place.*;
    return if (videoPut(screen)) err.RTGERR_OK else err.RTGERR_BAD_ARG;
}

/// Whether the layer reads `part` of `picture`: colours its converter
/// makes the display's out of (`videoColours` - the picture may not be
/// the kind the layer was opened for), its planes laid out as it takes
/// them - NV12, or I420 with both colour planes - each of the part's rows
/// starting on 16 bytes, the part's top left on a pair of pixels each
/// way, at least two of them each way, and every byte of it below 4 GiB,
/// where the controller reaches.
fn videoReads(picture: *const rtg.RtgYuv, part: rtg.RtgRect) bool {
    if (!videoColours(picture.matrix, picture.transfer, picture.primaries, picture.depth)) return false;
    const planar = picture.layout == rtg.bitmaps.RTGYUV_I420;
    if (!planar and picture.layout != rtg.bitmaps.RTGYUV_NV12) return false;
    if (planar and picture.cr == null) return false;
    if (part.width < 2 or part.height < 2 or @rem(part.x, 2) != 0 or @rem(part.y, 2) != 0) return false;
    if (picture.y_pitch % 16 != 0 or picture.c_pitch % 16 != 0) return false;
    const x: u64 = @intCast(part.x);
    const y: u64 = @intCast(part.y);
    const rows: u64 = @intCast(part.height);
    const chroma_x = if (planar) x / 2 else x;
    const planes = [_]struct { at: ?[*]const u8, x: u64, y: u64, rows: u64, pitch: u64 }{
        .{ .at = picture.y, .x = x, .y = y, .rows = rows, .pitch = picture.y_pitch },
        .{ .at = picture.cb, .x = chroma_x, .y = y / 2, .rows = (rows + 1) / 2, .pitch = picture.c_pitch },
        .{ .at = if (planar) picture.cr else null, .x = chroma_x, .y = y / 2, .rows = (rows + 1) / 2, .pitch = picture.c_pitch },
    };
    for (planes) |plane| {
        const at: u64 = @intFromPtr(plane.at orelse continue);
        const first = at + plane.y * plane.pitch + plane.x;
        if (first % 16 != 0) return false;
        if (first + plane.rows * plane.pitch > 1 << 32) return false;
    }
    return true;
}

/// One way of a place cut to the display: where on the display it starts
/// and how much of it is seen, and where in the part the source starts
/// and how much of it is read.
const VideoCut = struct { at: u32, shown: u32, from: u32, read: u32 };

/// `read` pixels of the source from `from`, scaled by `step` to `shown`
/// of the display from `at`, cut to the display's `side`: null where
/// fewer than two pixels are left. The source is cut from its start in
/// whole `unit`s, so where the display cuts a place's left or top the
/// picture may start up to a unit early.
fn videoCut(from: i32, read: i32, at: i32, shown: i32, side: u32, step: u32, unit: u32) ?VideoCut {
    const start = @max(at, 0);
    const end = @min(at + shown, @as(i32, @intCast(side)));
    if (end - start < 2) return null;
    const off: u64 = @intCast(start - at);
    const skipped: u32 = @intCast((off * @as(u64, @intCast(read)) / @as(u64, @intCast(shown))) / unit * unit);
    const left: u32 = @as(u32, @intCast(read)) - skipped;
    const seen: u32 = @intCast(end - start);
    const needed: u32 = if (step == jh7110.unscaled) seen else @intCast((@as(u64, seen - 1) * step >> 16) + 2);
    return .{
        .at = @intCast(start),
        .shown = seen,
        .from = @as(u32, @intCast(from)) + skipped,
        .read = @min(left, needed),
    };
}

/// The picture kept shown in its place, as much of it as the display
/// has: hidden with no picture or no place on the display, and false,
/// hidden, where it cannot be scaled into its place. Holding
/// `plane_lock`.
fn videoPut(screen: *Screen) bool {
    const one = screen.video_picture orelse {
        jh7110.videoHide();
        return true;
    };
    const part = screen.video_src;
    const place = screen.video_place;
    if (place.width < 2 or place.height < 2) {
        jh7110.videoHide();
        return place.width <= 0 or place.height <= 0;
    }
    if (!videoScales(part.width, place.width) or !videoScales(part.height, place.height)) {
        jh7110.videoHide();
        return false;
    }
    const step_x = jh7110.videoStep(@intCast(part.width), @intCast(place.width));
    const step_y = jh7110.videoStep(@intCast(part.height), @intCast(place.height));
    const across = videoCut(part.x, part.width, place.x, place.width, screen.width, step_x, video_cut_across);
    const down = videoCut(part.y, part.height, place.y, place.height, screen.height, step_y, video_cut_down);
    if (across == null or down == null) {
        jh7110.videoHide();
        return true;
    }
    const x = across.?;
    const y = down.?;
    const planar = one.layout == rtg.bitmaps.RTGYUV_I420;
    const chroma_x: usize = if (planar) x.from / 2 else x.from;
    const chroma = @as(usize, y.from / 2) * one.c_pitch + chroma_x;
    jh7110.videoShow(.{
        .y = @intFromPtr(one.y) + @as(usize, y.from) * one.y_pitch + x.from,
        .u = @intFromPtr(one.cb) + chroma,
        .v = if (one.cr) |cr| @intFromPtr(cr) + chroma else 0,
        .y_pitch = one.y_pitch,
        .c_pitch = one.c_pitch,
        .planar = planar,
        .width = x.read,
        .height = y.read,
        .bt709 = one.matrix == rtg.bitmaps.RTGYUV_BT709,
        .full = one.range == rtg.bitmaps.RTGYUV_FULL,
    }, .{
        .x = x.at,
        .y = y.at,
        .width = x.shown,
        .height = y.shown,
        .step_x = step_x,
        .step_y = step_y,
    });
    return true;
}

/// Whether `read` pixels scale to `shown`: three times up at most, a
/// tenth down.
fn videoScales(read: i32, shown: i32) bool {
    const r: u64 = @intCast(read);
    const s: u64 = @intCast(shown);
    return s <= r * jh7110.video_max_up and s * jh7110.video_max_down >= r;
}

/// What a start of the port leaves - its first overlay off, in U-Boot's
/// order, the primary unkeyed - put back as the layer has it. Holding
/// `plane_lock`.
fn videoPutBack(screen: *Screen) void {
    if (screen.video == null) return;
    jh7110.videoStart();
    jh7110.videoOrder(screen.video_key);
    _ = videoPut(screen);
}

// --- the board -------------------------------------------------------------------

/// Everything the screen took given back: the port stopped, its frame
/// interrupt's server off, timer.device closed, the cursor's images
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
}

/// The port stopped where it runs: its frame interrupt's server off, the
/// controller no longer sending the picture nor reading a frame.
fn halt(screen: *Screen) void {
    unhookFrames(screen);
    if (screen.scanning == 0) return;
    screen.sys.AcquireLock(&screen.plane_lock);
    jh7110.stop();
    screen.sys.ReleaseLock(&screen.plane_lock);
    screen.scanning = 0;
}

/// The controller's panel part is offered: a board made of it, its modes
/// left to the library.
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

    // Nothing is asked of the controller here: its registers do not
    // answer while its domain is off, which it is until a mode is set.
    const board = rb.CreateBoard(driver, device, &.{
        .ops = &ops,
        .instance_size = @sizeOf(Screen),
        // A monitor's modes are made in the format the board shows.
        .format = format,
    }) orelse return err.RTGERR_NO_MEMORY;
    const screen = screenOf(board);
    screen.* = .{ .sys = sys, .rtg_base = programs(rb), .width = width, .height = height, .board = board };
    // The port's waits are on timer.device.
    screen.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    screen.timer_open = sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &screen.timer_io.node, 0) == 0;
    // The board's buffers start, and their rows are rounded, as its tags
    // say; whole cache lines where they say nothing.
    const asked_alignment: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Alignment, 0, tag_list));
    if (asked_alignment != 0) screen.alignment = asked_alignment;
    // The modes are the library's to make, of what the monitor on the
    // port names (`detect`, `checkMode`) and of the part's size where
    // none does. Here: the controller's frame interrupt.
    screen.frame_irq = @truncate(rb.GetRtgTagData(st.PART_Irq, 0, tag_list));
    screen.pitch = rowBytes(screen, width);
    sys.InitSemaphore(&screen.port_lock);
    sys.InitLock(&screen.plane_lock, "rtg-jh7110 planes", exec.LOCKORDER_DRIVER + 1, 0);

    // At most as many pictures of the mode the display is in as the
    // board asks for, each taken by the library as it is allocated, from
    // memory the controller reaches. Not cleared: each is cleared before
    // it is first shown. The cursor plane's two images now, from a page
    // on, the system's and not the task's that happened to ask.
    const frame: usize = @as(usize, screen.pitch) * height;
    screen.buffers = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list))), 1);
    const memory = sys.AllocMem(2 * cursor_bytes + page, exec.MEMF_DMA | exec.MEMF_SYSTEM) orelse {
        release(screen);
        rb.DeleteBoard(board);
        return err.RTGERR_NO_MEMORY;
    };
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
/// what was there is answered until then. The DDC is the port's one:
/// held against every other task that talks on it.
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
        const failure = jh7110.wake(sys, waiter);
        if (failure != .none) {
            exec.kprintf(sys, "%s: %s\n", .{ MODULE_NAME, jh7110.why(failure) });
            return err.RTGERR_NO_DISPLAY;
        }
    }
    const plugged = jh7110.monitor();
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
    const length = @min(screen.edid_size, asked.edid_max);
    @memcpy(asked.edid[0..length], screen.edid[0..length]);
    asked.edid_size = length;
    return err.RTGERR_OK;
}

/// The EDID of the monitor on the port read into the screen's own copy:
/// nothing where it does not read.
fn readEdid(screen: *Screen, waiter: Waiter) void {
    const first: *[edid_block]u8 = screen.edid[0..edid_block];
    var read = jh7110.readEdid(0, first, waiter);
    if (read and !sumsToZero(first)) read = jh7110.readEdid(0, first, waiter);
    if (!read) return;
    var blocks: u32 = 1;
    const named = @min(@as(u32, first[126]) + 1, jh7110.edid_blocks);
    while (blocks < named) : (blocks += 1) {
        const block: *[edid_block]u8 = screen.edid[blocks * edid_block ..][0..edid_block];
        if (!jh7110.readEdid(@intCast(blocks), block, waiter)) break;
    }
    screen.edid_size = blocks * edid_block;
}

/// Whether the port can make `timings`: by its clock and by what its
/// registers hold.
fn checkMode(board: *rtg.RtgBoard, timings: *const rtg.RtgTimings) callconv(.c) i32 {
    _ = board;
    return if (jh7110.makes(timings)) err.RTGERR_OK else err.RTGERR_BAD_MODE;
}

/// The port started in the screen's mode, reading the frame at
/// `address`: the transmitter and its PLL first, which wait; then the
/// controller's planes under their lock - the picture's, and the cursor
/// and the video layer put back as the board has them, which a start
/// leaves off. False, and said on the raw port, when it did not come up.
fn startPort(screen: *Screen, address: usize) bool {
    const sys = screen.sys;
    const mode = &screen.timings;
    // A computer's picture, in the whole range.
    var avi: [rtg.RTG_AVI_BYTES]u8 = undefined;
    _ = drivers(screen).BuildAviInfoFrame(mode, rtg.RTGAVI_IT | rtg.RTGAVI_RANGE_FULL, &avi);
    const failure = jh7110.start(sys, mode, &avi, Waiter{ .screen = screen });
    if (failure != .none) {
        exec.kprintf(sys, "%s: %s\n", .{ MODULE_NAME, jh7110.why(failure) });
        return false;
    }
    sys.AcquireLock(&screen.plane_lock);
    jh7110.startPlanes(mode, address, screen.pitch);
    screen.scanning = address;
    cursorWrite(screen);
    videoPutBack(screen);
    sys.ReleaseLock(&screen.plane_lock);
    // The sound that plays, sent in the new mode: its numbers follow the
    // pixel clock.
    if (screen.audio) |playing| _ = linkSound(screen, &playing);
    const plugged = jh7110.monitor();
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
/// mode where the library says it is to be, the controller reading the
/// first of the mode's two frames, which rtg.library has made the whole
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
    // Room for as many pictures of the mode as the board may have.
    board.region.size = @as(usize, screen.buffers) * @as(usize, mode.pitch) * mode.height;
    // What it read until now says nothing about the new mode, nor to a
    // monitor that came.
    screen.sys.ObtainSemaphore(&screen.port_lock);
    defer screen.sys.ReleaseSemaphore(&screen.port_lock);
    screen.scanning = 0;
    return if (startPort(screen, address)) err.RTGERR_OK else err.RTGERR_NO_DISPLAY;
}

/// The controller told to read `frame` from its next frame on: one of
/// the two rtg.library makes its pictures in, handed on already
/// (`refresh`). It takes the address at its next frame, which the library
/// waits for.
fn flipOp(board: *rtg.RtgBoard, frame: *rtg.RtgBitMap) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    if (frame.pixels == null) return err.RTGERR_BAD_ARG;
    // A port that does not run has nothing to flip: its start names the
    // frame it reads.
    if (screen.scanning == 0) return err.RTGERR_NO_MODE;
    // Against a task that starts the port.
    sys.ObtainSemaphore(&screen.port_lock);
    defer sys.ReleaseSemaphore(&screen.port_lock);
    scanFrom(screen, frame);
    screen.updates +%= 1;
    return err.RTGERR_OK;
}

/// A rectangle of a frame was written by the CPU, after rtg.library made
/// a picture in it: its pixels alone written back out of the caches,
/// which the controller reads past - a run a row, one run over the rows
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

/// The transmitter set up for `format` at the mode's pixel clock, and
/// its sound on. Holding `port_lock`, on a port that runs.
fn linkSound(screen: *Screen, format: *const rtg.RtgAudio) i32 {
    if (format.channels != 2 or format.bits != 16) return err.RTGERR_NOT_SUPPORTED;
    const rate = jh7110.audioRate(format.sample_rate) orelse return err.RTGERR_NOT_SUPPORTED;
    var n: u32 = 0;
    var cts: u32 = 0;
    if (!drivers(screen).HdmiAudioClock(screen.timings.pixel_clock_hz, format.sample_rate, &n, &cts)) return err.RTGERR_NO_MODE;
    jh7110.audioStart(rate, n, cts);
    return err.RTGERR_OK;
}

/// The link's side of its sound (`SetBoardAudio`): the transmitter told
/// to send the stream on its first I2S input - which the sound's driver
/// feeds - with the numbers the monitor rebuilds the sample clock from,
/// or its sound off again. A mode set while the sound plays sets the
/// numbers again. RTGERR_NO_MODE while the port does not run,
/// RTGERR_NOT_SUPPORTED for anything but stereo of 16 bits at 48000 Hz.
fn audio(board: *rtg.RtgBoard, format: ?*const rtg.RtgAudio) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    sys.ObtainSemaphore(&screen.port_lock);
    defer sys.ReleaseSemaphore(&screen.port_lock);
    const one = format orelse {
        if (screen.audio != null and screen.scanning != 0) jh7110.audioStop();
        screen.audio = null;
        return err.RTGERR_OK;
    };
    if (screen.scanning == 0) return err.RTGERR_NO_MODE;
    const code = linkSound(screen, one);
    if (code == err.RTGERR_OK) screen.audio = one.*;
    return code;
}

fn stats(board: *rtg.RtgBoard, into: *rtg.RtgBoardStats) callconv(.c) void {
    into.frames = screenOf(board).updates;
}

const pointer_ops = rtg.RtgPointerOps{ .set = &setPointer, .move = &movePointer, .show = &showPointer };

/// The video layer, the controller's first overlay.
const video_ops = rtg.RtgVideoOps{ .open = &videoOpen, .close = &videoClose, .show = &videoShow, .move = &videoMove };

/// Flipped between frames the library makes its pictures in, a
/// connector, the pointer a cursor plane, and a video layer.
const ops = rtg.boards.RtgBoardOps{
    .destroy = &destroy,
    .show = &showOp,
    .refresh = &refresh,
    .flip = &flipOp,
    .stats = &stats,
    .detect = &detect,
    .check_mode = &checkMode,
    .audio = &audio,
    .pointer = &pointer_ops,
    .video = &video_ops,
};

const driver_ops = rtg.RtgDriverOps{ .attach = &attach, .detach = &detach };

/// What it takes: the panel part that is the JH7110's display
/// controller.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = st.CHIP_JH7110_DC8200 },
    .{},
};

/// The driver's tag: a description and no init. rtg.library reads it at
/// its own init and puts the driver on its list; nothing of this module
/// runs until a board is asked for.
export const rtg_jh7110_tag: rtg.ResidentRtgDriver linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&rtg_jh7110_tag),
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

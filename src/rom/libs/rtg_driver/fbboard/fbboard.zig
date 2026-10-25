// SPDX-License-Identifier: MPL-2.0
//! A display whose picture is in the machine's RAM, as a display board:
//! QEMU virt's ramfb (`ramfb.zig`) and the JH7110's display controller
//! behind its HDMI port (`jh7110.zig`), which read it out of RAM by
//! themselves, and QEMU's virtio GPU (`virtio.zig`), which is told what
//! changed.
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
//! whose display does not see them. The buffers are RAM the CPU reaches
//! through its caches (`RTGRF_CPU_CACHED`), so a refresh hands the rows on
//! with exec's CacheClearE, and whether that writes them back is the
//! machine's to say: it does on the JH7110, whose display goes past the
//! caches, and nothing on QEMU's virt, whose ramfb reads RAM through the
//! host's (SYSTAG_CacheFlush absent, SYSTAG_DmaCoherent).
//!
//! The virtio GPU keeps a copy of each picture in the emulator instead,
//! and shows that: the rectangle a refresh hands on is copied into it and
//! shown, so there it is the hand-on that puts what was written on the
//! glass, a rectangle at a time, and showing a buffer is naming its copy.
//!
//! The emulator's displays have one mode: the ramfb the size the board
//! names, the virtio GPU the size QEMU's window has for it. The
//! JH7110's has the modes the monitor on its HDMI port names in its EDID
//! and the port can send, read when the board is made (`monitor.zig`):
//! the one the monitor prefers is the default, and any of them can be set.
//!
//! The buffers are one block of RAM below 4 GiB, taken when the board is
//! made: as many pictures of its largest mode as the board asks for, and
//! one more. The library cuts the buffers from it.
//!
//! The pointer is laid over the picture in that last frame, as the qemu
//! board does it: while a pointer or the overlay is shown, or the picture
//! is several in bands, the display reads the composed frame instead - the
//! shown buffer's rectangles copied in as they are refreshed, no wider
//! than what was written, and the images laid over them. The copy is the
//! engine's, so a large one - the whole picture, when composing starts or
//! another buffer is shown - is shared between the cores. A move puts
//! back the pointer's old rectangle from the shown buffer and lays it at
//! the new one, so it costs the pointer's size and not the picture's.
//! With nothing over the picture the display reads the shown buffer
//! itself, and nothing is copied.
//!
//! A refresh comes from whichever task drew, a pointer move from
//! intuition's pointer task, each on any core: everything that writes the
//! composed frame or changes what is laid in it holds the board's
//! `compose_lock`, so that rows copied in on one core never cover a
//! pointer just laid on another, nor a restore cut a hole into rows just
//! copied.
//!
//! The JH7110's controller has a pointer of its own, its cursor plane,
//! which it lays over the picture itself: there the pointer is that
//! (`cursor`), the image copied into a buffer of the block's as ARGB, its
//! mask the alpha, and a move is the plane written again at its new place.
//! Two buffers take turns, so the one the controller reads is never the
//! one written. The overlay is still laid in the composed frame. The
//! virtio GPU's cursor is the same, laid over its window by the emulator -
//! with a tablet, as the host's own pointer - and moved by a command; so
//! there nothing is composed for the pointer either.
//!
//! The board's engine is the processor's own cores (`engine.zig`): a
//! fill, a copy, a colour or a picture with coverage laid over, a picture
//! scaled, a pattern or a template that covers much of a buffer is cut
//! into bands of rows, which exec's workers draw at once (ShareWork). The
//! write-back a refresh ends with is a CacheClearE, which exec shares
//! between the cores the same way. A rectangle refreshed (RefreshRect)
//! writes back only its own pixels, a run a row, so tiles drawn on
//! several cores can each hand on their own.
//!
//! Where the display raises an interrupt at each frame (the board's part
//! gives it as PART_Irq), a flip and WaitVBlank wait for it; elsewhere,
//! and should it stop coming, they wait as long as a frame takes.
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
const virtio = @import("virtio.zig");
const monitor = @import("monitor.zig");
const edid = @import("../edid.zig");
const engine = @import("engine.zig");
const tags = rtg.tags;
const timer = sdk.devices.timer;

const MODULE_NAME = "rtg-fb";
const DRIVER_NAME = "fb";
const VERSION = 1;
const REVISION = 8;
const BUILD_DATE = "25.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The chips this drives, as the board's panel part names them.
const chips = [_]u32{ st.CHIP_QEMU_RAMFB, st.CHIP_JH7110_DC8200, st.CHIP_VIRTIO_GPU };

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
    virtio: virtio.Gpu,
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
    /// The modes: the board's own, or on the JH7110 those the monitor
    /// takes (`monitor.zig`), with their timings; their names; which one
    /// the display is in; how long a frame of it takes.
    modes: [monitor.max_modes]rtg.RtgMode = undefined,
    timings: monitor.List = .{},
    names: [monitor.max_modes][16]u8 = undefined,
    mode_count: u32 = 0,
    current: u32 = 0,
    frame_us: u32 = 16_667,
    /// The block the buffers are cut from, as AllocMem gave it.
    memory: ?*anyopaque = null,
    memory_size: usize = 0,
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
    /// The frame the pointer is composed in, past the buffers.
    composed: ?[*]u8 = null,
    /// Held while the composed frame, or what is laid in it and what it
    /// is composed from, changes. A semaphore: a write-back may wait for
    /// exec's workers.
    compose_lock: exec.SignalSemaphore = .{},
    /// The cursor plane's two image buffers, past the composed frame, on
    /// a display that has one; which of them is the plane's, whether it is
    /// the small size, and its image's hot spot.
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
    /// The overlay (a dragged icon): its image, laid under the pointer
    /// whenever there is one, and where its top left is.
    overlay: ?*const rtg.RtgPointerImage = null,
    overlay_left: i32 = 0,
    overlay_top: i32 = 0,
    /// The bands shown, from the top: one, the shown buffer at its own
    /// origin, unless a screen is pulled down.
    bands: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined,
    band_count: u32 = 0,
    /// The cores, as the board's engine.
    engine: engine.Engine = .{},
    /// The display's frame interrupt, where it has one: its number (0 for
    /// none), its server and whether that is on, the frames it has
    /// counted, the tasks waiting for frames, and whether it has been seen
    /// to come.
    frame_irq: u32 = 0,
    frame_int: exec.Interrupt = .{},
    frame_hooked: bool = false,
    frames: u32 = 0,
    frame_waiters: ?*FrameWaiter = null,
    frames_come: bool = false,
};

/// Wait for `frames` frames: for the display's frame interrupt to come
/// that many times, where it comes, so that a flip is waited out to the
/// frame the new picture starts in; else for as long as they take, which
/// is what makes a program that paces itself by the display - a flip,
/// WaitVBlank - run at the speed it would on a display that says when a
/// frame begins. The CPU is given away meanwhile, either way.
fn pace(screen: *Screen, frames: u32) void {
    if (@atomicLoad(bool, &screen.frames_come, .acquire) and waitFrames(screen, frames)) return;
    sleep(screen, @as(u64, screen.frame_us) * frames);
}

/// A task waiting for frames, on its own stack: the count of frames it
/// waits for, and what the frame interrupt signals when it is reached.
const FrameWaiter = struct {
    next: ?*FrameWaiter = null,
    until: u32 = 0,
    reached: exec.Waitable = .{},
};

/// Until the frame interrupt has come `frames` more times. False when it
/// did not within two frames more: it is taken to have stopped, and the
/// clock paces from then on.
fn waitFrames(screen: *Screen, frames: u32) bool {
    const sys = screen.sys;
    var waiter = FrameWaiter{};
    sys.Disable();
    waiter.until = screen.frames +% frames;
    waiter.next = screen.frame_waiters;
    screen.frame_waiters = &waiter;
    sys.Enable();
    const answer = sys.WaitForAny(&[_]*exec.Waitable{&waiter.reached}, 1, @as(u64, screen.frame_us) * (frames + 2));
    sys.Disable();
    var link = &screen.frame_waiters;
    while (link.*) |at| : (link = &at.next) {
        if (at != &waiter) continue;
        link.* = at.next;
        break;
    }
    sys.Enable();
    if (answer != exec.WAIT_TIMEOUT) return true;
    @atomicStore(bool, &screen.frames_come, false, .release);
    return false;
}

/// The display's interrupt: a frame counted, and every task whose count
/// it reaches told.
fn frameServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const screen: *Screen = @ptrCast(@alignCast(data.?));
    if (jh7110.takeInterrupts() == 0) return 0;
    screen.frames +%= 1;
    @atomicStore(bool, &screen.frames_come, true, .release);
    var at = screen.frame_waiters;
    while (at) |waiter| : (at = waiter.next) {
        if (@as(i32, @bitCast(screen.frames -% waiter.until)) >= 0) screen.sys.SignalWaitable(&waiter.reached);
    }
    return 1;
}

/// The frame interrupt's server on, once the display runs.
fn hookFrames(screen: *Screen) void {
    if (screen.frame_irq == 0 or screen.frame_hooked) return;
    screen.frame_int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = screen,
        .code = &frameServer,
    };
    screen.sys.AddIntServer(screen.frame_irq, &screen.frame_int);
    screen.frame_hooked = true;
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

/// `length` bytes at `from`, which the CPU has written, written back out
/// of the caches, where the machine's display goes past them.
fn writeBack(screen: *Screen, from: [*]u8, length: usize) void {
    if (length == 0) return;
    screen.sys.CacheClearE(from, @intCast(length), exec.CACRF_ClearD);
}

/// `box` of a picture the CPU has written, where the display reads it:
/// written back - a run a row, one run over the rows where the box is as
/// wide as the picture - and on the virtio GPU copied into the emulator's
/// copy of the picture, and shown there when it is the one shown. Only a
/// picture the display can be shown is copied.
fn handOn(screen: *Screen, picture: *const rtg.RtgBitMap, box: Box) void {
    if (box.left >= box.right or box.top >= box.end) return;
    const pixels = picture.pixels orelse return;
    const pitch = picture.pitch;
    const bytes = rtg.formatBytes(picture.format);
    if (box.left == 0 and box.right >= picture.width) {
        writeBack(screen, pixels + box.top * pitch, (box.end - box.top) * pitch);
    } else {
        const left = box.left * bytes;
        const run = (box.right - box.left) * bytes;
        var y = box.top;
        while (y < box.end) : (y += 1) writeBack(screen, pixels + y * pitch + left, run);
    }
    switch (screen.scanout) {
        .virtio => |*gpu| if (showable(screen, picture)) virtio.update(gpu, .{
            .pixels = @intFromPtr(pixels),
            .pitch = pitch,
            .height = picture.height,
        }, .{
            .x = box.left,
            .y = box.top,
            .width = box.right - box.left,
            .height = box.end - box.top,
        }, Waiter{ .screen = screen }),
        else => {},
    }
}

/// Whether the display can be shown `picture`: its size, its rows and its
/// format are the display's.
fn showable(screen: *const Screen, picture: *const rtg.RtgBitMap) bool {
    return picture.width == screen.width and picture.height == screen.height and
        picture.pitch == screen.pitch and picture.format == screen.format;
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
        .virtio => |*gpu| virtio.show(gpu, .{
            .pixels = address,
            .pitch = screen.pitch,
            .height = screen.height,
        }, screen.width, screen.height, Waiter{ .screen = screen }),
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

/// The composed frame held by this task (`compose_lock`), until `letGo`.
fn hold(screen: *Screen) void {
    screen.sys.ObtainSemaphore(&screen.compose_lock);
}

fn letGo(screen: *Screen) void {
    screen.sys.ReleaseSemaphore(&screen.compose_lock);
}

/// Whether the display reads the composed frame: a pointer with an image
/// is shown over a picture, there is an overlay, or the picture is several
/// in bands.
fn composing(screen: *Screen) bool {
    if (screen.composed == null or screen.showing == null) return false;
    const pointer = screen.cursor == null and screen.pointer_shown and screen.pointer != null;
    return screen.band_count > 1 or pointer or screen.overlay != null;
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

/// A rectangle of the display: columns `left` up to `right`, rows `top`
/// up to `end`.
const Box = struct { left: u32, top: u32, right: u32, end: u32 };

/// The whole display.
fn whole(screen: *const Screen) Box {
    return .{ .left = 0, .top = 0, .right = screen.width, .end = screen.height };
}

/// A picture of the display's size and rows at `pixels` - the composed
/// frame, a buffer - for the engine to copy into and to be handed on.
fn pictureAt(screen: *const Screen, pixels: ?[*]u8) rtg.RtgBitMap {
    return .{
        .pixels = pixels,
        .width = screen.width,
        .height = screen.height,
        .pitch = screen.pitch,
        .format = screen.format,
    };
}

/// `box` of the display, each row from its band, into the composed frame,
/// and handed on.
fn copyArea(screen: *Screen, box: Box) void {
    const composed = screen.composed orelse return;
    if (box.left >= box.right or box.top >= box.end) return;
    for (screen.bands[0..screen.band_count], 0..) |band, i| {
        const band_end = if (i + 1 < screen.band_count) screen.bands[i + 1].line else screen.height;
        const first = @max(box.top, band.line);
        const end = @min(box.end, band_end);
        if (first < end) copyBand(screen, band, box, first, end);
    }
    handOn(screen, &pictureAt(screen, composed), box);
}

/// Display rows `first` to `end` of one band, across the box's columns.
/// The band's rows are one rectangle of its buffer, which the cores copy
/// (the engine, shared between them for a large one); a band of one row
/// repeated, or a format the engine does not take, a row at a time.
fn copyBand(screen: *Screen, band: rtg.RtgBand, box: Box, first: u32, end: u32) void {
    if (band.flags & rtg.RTGBANDF_REPEAT == 0) {
        var into = pictureAt(screen, screen.composed);
        const what = rtg.RtgCopy{
            .src_x = @intCast(box.left),
            .src_y = @intCast(band.rowAt(first)),
            .width = @intCast(box.right - box.left),
            .height = @intCast(end - first),
            .dest_x = @intCast(box.left),
            .dest_y = @intCast(first),
        };
        if (engine.copy(&screen.engine, band.bitmap, &into, &what) == err.RTGERR_OK) return;
    }
    const composed = screen.composed.?;
    const at = box.left * screen.bytes;
    const length = (box.right - box.left) * screen.bytes;
    var y = first;
    while (y < end) : (y += 1) {
        const from = band.bitmap.pixels.? + band.rowAt(y) * screen.pitch;
        screen.sys.CopyMem(from + at, composed + y * screen.pitch + at, length);
    }
}

/// The part of the image's rectangle at (left, top) that is on the
/// picture, as columns and rows; null when none of it is.
const Clip = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    fn box(clip: Clip) Box {
        return .{ .left = clip.x0, .top = clip.y0, .right = clip.x1, .end = clip.y1 };
    }
};

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
    if (screen.cursor == null) restoreImage(screen, screen.pointer, screen.pointer_left, screen.pointer_top);
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
        screen.sys.CopyMem(from + at, composed + y * screen.pitch + at, length);
    }
    handOn(screen, &pictureAt(screen, composed), clip.box());
}

/// The images laid over the composed frame: the overlay, then the pointer
/// over it when it is shown.
fn lay(screen: *Screen) void {
    layImage(screen, screen.overlay, screen.overlay_left, screen.overlay_top);
    if (screen.pointer_shown and screen.cursor == null) layImage(screen, screen.pointer, screen.pointer_left, screen.pointer_top);
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
    }
    handOn(screen, &pictureAt(screen, composed), clip.box());
}

/// The whole picture into the composed frame, with the images over it:
/// when composing starts, and when another buffer is shown.
fn rebuild(screen: *Screen) void {
    if (!composing(screen)) return;
    copyArea(screen, whole(screen));
    lay(screen);
}

/// A change to either image: both rectangles put back, the change made,
/// both laid again - they may overlap, and the one under must not be
/// left with a hole the other's restore cut. The frame is rebuilt when
/// composing starts or stops with it, and nothing is shown anew when the
/// display reads the shown buffer before and after. Made holding the
/// composed frame.
fn change(screen: *Screen, comptime apply: fn (*Screen, anytype) void, arg: anytype) void {
    hold(screen);
    defer letGo(screen);
    const was = composing(screen);
    if (was) restore(screen);
    apply(screen, arg);
    if (!was and !composing(screen)) return;
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
    if (screen.cursor != null) {
        cursorImage(screen, image);
        return err.RTGERR_OK;
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
    if (screen.cursor != null) {
        screen.pointer_left = left;
        screen.pointer_top = top;
        return cursorPlane(screen);
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
    if (screen.cursor != null) {
        const was = screen.pointer_shown;
        screen.pointer_shown = show;
        // The virtio GPU's cursor is not switched off but emptied.
        if (screen.scanout != .virtio) {
            cursorPlane(screen);
        } else if (was != show) {
            cursorImage(screen, screen.pointer);
        }
        return err.RTGERR_OK;
    }
    hold(screen);
    defer letGo(screen);
    screen.pointer_shown = show;
    rebuild(screen);
    present(screen);
    return err.RTGERR_OK;
}

// --- the pointer, on the controller's cursor plane ---------------------------

/// The bytes of one of the cursor plane's buffers: the JH7110's largest
/// image, which is the virtio GPU's one size.
const cursor_bytes = jh7110.cursor_side * jh7110.cursor_side * 4;
comptime {
    std.debug.assert(virtio.cursor_side == jh7110.cursor_side);
}

fn cursorBuffer(screen: *Screen, turn: u1) [*]u8 {
    return screen.cursor.? + @as(usize, turn) * cursor_bytes;
}

/// Where the pointer's hot spot is: where the image's top left puts it,
/// kept on the picture.
fn hotSpot(screen: *const Screen) struct { x: u32, y: u32 } {
    const x = screen.pointer_left + @as(i32, @intCast(screen.cursor_hot_x));
    const y = screen.pointer_top + @as(i32, @intCast(screen.cursor_hot_y));
    const max_x: i32 = @intCast(screen.width - 1);
    const max_y: i32 = @intCast(screen.height - 1);
    return .{ .x = @intCast(std.math.clamp(x, 0, max_x)), .y = @intCast(std.math.clamp(y, 0, max_y)) };
}

/// The plane told its buffer, size and hot spot, the hot spot's place,
/// and whether it is seen: only with an image. The virtio GPU's cursor
/// is only moved: its image says the rest.
fn cursorPlane(screen: *Screen) void {
    const at = hotSpot(screen);
    switch (screen.scanout) {
        .virtio => |*gpu| virtio.moveCursor(gpu, at.x, at.y),
        else => jh7110.cursor(
            @intFromPtr(cursorBuffer(screen, screen.cursor_turn)),
            screen.cursor_small,
            screen.cursor_hot_x,
            screen.cursor_hot_y,
            at.x,
            at.y,
            screen.pointer_shown and screen.pointer != null,
        ),
    }
}

/// A new image into the buffer the plane is not reading - ARGB, opaque
/// where the mask says, clear elsewhere - and the plane turned to it. The
/// virtio GPU's cursor cannot be switched off: while the pointer is
/// hidden its image is one with nothing in it.
fn cursorImage(screen: *Screen, image: ?*const rtg.RtgPointerImage) void {
    screen.pointer = image;
    const emptied = screen.scanout == .virtio;
    const drawn = if (emptied and !screen.pointer_shown) null else image;
    if (drawn == null and !emptied) return cursorPlane(screen);
    const small = if (drawn) |one| !emptied and one.width <= jh7110.cursor_side / 2 and one.height <= jh7110.cursor_side / 2 else false;
    const side: u32 = if (small) jh7110.cursor_side / 2 else jh7110.cursor_side;
    const turn = screen.cursor_turn +% 1;
    const buffer = cursorBuffer(screen, turn);
    const pixels: [*]u32 = @ptrCast(@alignCast(buffer));
    @memset(pixels[0 .. side * side], 0);
    if (drawn) |one| {
        const rows = @min(one.height, side);
        const columns = @min(one.width, side);
        var y: u32 = 0;
        while (y < rows) : (y += 1) {
            const row: [*]const u32 = @ptrCast(@alignCast(one.pixels + y * one.pitch));
            var x: u32 = 0;
            while (x < columns) : (x += 1) {
                if (one.opaqueAt(x, y)) pixels[y * side + x] = row[x] | 0xFF00_0000;
            }
        }
        screen.cursor_hot_x = @min(one.hot_x, side - 1);
        screen.cursor_hot_y = @min(one.hot_y, side - 1);
    }
    writeBack(screen, buffer, side * side * 4);
    screen.cursor_turn = turn;
    screen.cursor_small = small;
    switch (screen.scanout) {
        .virtio => |*gpu| {
            const at = hotSpot(screen);
            virtio.setCursor(gpu, buffer, turn, screen.cursor_hot_x, screen.cursor_hot_y, at.x, at.y, Waiter{ .screen = screen });
        },
        else => cursorPlane(screen),
    }
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
    change(screen, struct {
        fn apply(on: *Screen, place: anytype) void {
            on.overlay_left = place[0];
            on.overlay_top = place[1];
        }
    }.apply, .{ left, top });
}

// --- the board -------------------------------------------------------------------

/// The display the part describes, if it is there.
fn findScanout(rb: *RtgBase, chip: u32, tag_list: ?[*]const TagItem) ?Scanout {
    const address = rb.GetRtgTagData(st.PART_Address, 0, tag_list);
    return switch (chip) {
        st.CHIP_QEMU_RAMFB => .{ .ramfb = ramfb.find(address) orelse return null },
        // Its registers do not answer while its domain is off, so nothing
        // is asked of it before the mode is set.
        st.CHIP_JH7110_DC8200 => .jh7110,
        st.CHIP_VIRTIO_GPU => .{ .virtio = virtio.find(
            address,
            @truncate(rb.GetRtgTagData(st.PART_Windows, 1, tag_list)),
            rb.GetRtgTagData(st.PART_WindowSize, 0, tag_list),
        ) orelse return null },
        else => null,
    };
}

fn createBoard(made_by: *rtg.RtgDriver, board: *rtg.RtgBoard, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    if (state.board != null) return err.RTGERR_IN_USE;
    const rb = state.rtg_base;
    const sys = state.sys;

    const chip: u32 = @truncate(rb.GetRtgTagData(st.PART_Chip, st.CHIP_NONE, tag_list));
    const scanout = findScanout(rb, chip, tag_list) orelse return err.RTGERR_NO_DISPLAY;
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
    sys.InitSemaphore(&screen.compose_lock);
    if (screen.width == 0 or screen.height == 0) return err.RTGERR_BAD_ARG;
    if (screen.width > 0x3FFF or screen.height > 0x3FFF) return err.RTGERR_BAD_ARG;
    if (scanout == .virtio) {
        // The GPU up, and the picture as large as the emulator's window
        // has it - QEMU's xres and yres - where it says.
        if (format != .bgra32) return err.RTGERR_BAD_FORMAT;
        const gpu = &screen.scanout.virtio;
        if (!virtio.start(gpu, sys)) return err.RTGERR_NO_DISPLAY;
        if (virtio.displaySize(gpu, Waiter{ .screen = screen })) |size| {
            if (size.width <= 0x3FFF and size.height <= 0x3FFF) {
                screen.width = size.width;
                screen.height = size.height;
            }
        }
    }
    if (scanout == .jh7110) {
        // The modes the monitor takes, the part's size at 60 Hz without
        // one, and the display's frame interrupt.
        if (format != .bgra32) return err.RTGERR_BAD_FORMAT;
        const own = edid.knownMode(screen.width, screen.height, 60) orelse return err.RTGERR_BAD_ARG;
        screen.timings = hdmiModes(screen, own);
        screen.frame_irq = @truncate(rb.GetRtgTagData(st.PART_Irq, 0, tag_list));
        for (screen.timings.modes[0..screen.timings.count], 0..) |*timing, i| {
            addMode(screen, board, @intCast(i), timing.width, timing.height);
            screen.modes[i].pixel_clock_hz = timing.pixel_khz * 1000;
            screen.modes[i].refresh_mhz = timing.milliHz();
        }
        screen.current = screen.timings.default;
    } else {
        // One mode: the picture the board was built for.
        addMode(screen, board, 0, screen.width, screen.height);
    }
    screen.modes[screen.current].flags = rtg.boards.RTGMF_DEFAULT;
    take(screen, screen.current);

    // As many pictures of the largest mode as the board asks for, and one
    // to compose in, in memory every DMA engine reaches. Not cleared: each
    // is cleared before it is first shown.
    var frame: usize = 0;
    for (screen.modes[0..screen.mode_count]) |*mode| frame = @max(frame, @as(usize, mode.pitch) * mode.height);
    const frames: u32 = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list))), 1);
    // The cursor plane's two buffers after the composed frame.
    const cursors: usize = if (scanout == .ramfb) 0 else 2 * cursor_bytes;
    screen.memory_size = (frames + 1) * frame + cursors + page;
    screen.memory = sys.AllocMem(screen.memory_size, exec.MEMF_DMA) orelse {
        screen.memory_size = 0;
        if (scanout == .virtio) virtio.stop(&screen.scanout.virtio);
        return err.RTGERR_NO_MEMORY;
    };
    const base = std.mem.alignForward(usize, @intFromPtr(screen.memory.?), page);
    screen.composed = @ptrFromInt(base + frames * frame);
    if (cursors != 0) screen.cursor = @ptrFromInt(base + (frames + 1) * frame);
    board.region = .{
        .base = @ptrFromInt(base),
        .size = frames * frame,
        .alignment = row_alignment,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED,
    };
    board.ops = &ops;
    board.info.buffers = frames;
    board.info.pixel_clock_hz = screen.modes[screen.current].pixel_clock_hz;
    board.info.refresh_mhz = screen.modes[screen.current].refresh_mhz;
    engine.setUp(&screen.engine, sys);
    state.board = board;
    return err.RTGERR_OK;
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    const screen = screenOf(board);
    // The GPU lets go of the buffers before they are given back.
    if (screen.scanout == .virtio) virtio.stop(&screen.scanout.virtio);
    if (screen.frame_hooked) screen.sys.RemIntServer(screen.frame_irq, &screen.frame_int);
    screen.frame_hooked = false;
    if (screen.timer_open) screen.sys.CloseDevice(&screen.timer_io.node);
    screen.timer_open = false;
    if (screen.memory) |memory| screen.sys.FreeMem(memory, screen.memory_size);
    screen.memory = null;
    if (board.driver) |driver| stateOf(driver).board = null;
}

/// Mode `index` added to the board's list, `width` by `height` in the
/// screen's format, its name the size - and the refresh, when another
/// mode has the same size.
fn addMode(screen: *Screen, board: *rtg.RtgBoard, index: u32, width: u32, height: u32) void {
    const name = &screen.names[index];
    var at = writeNumber(name, 0, width);
    name[at] = 'x';
    at = writeNumber(name, at + 1, height);
    if (screen.timings.count > 1) {
        const rate = screen.timings.modes[index].hz();
        for (screen.timings.modes[0..screen.timings.count], 0..) |*other, i| {
            if (i == index or other.width != width or other.height != height) continue;
            name[at] = '@';
            at = writeNumber(name, at + 1, rate);
            break;
        }
    }
    name[at] = 0;
    screen.modes[index] = .{
        .node = .{ .name = @ptrCast(name), .pri = 0 },
        .id = index + 1,
        .width = width,
        .height = height,
        .format = screen.format,
        .pitch = std.mem.alignForward(u32, width * screen.bytes, row_alignment),
    };
    screen.mode_count = index + 1;
    screen.sys.AddTail(&board.modes, &screen.modes[index].node);
}

/// `value` in decimal into `into` from `at`; where it ends.
fn writeNumber(into: []u8, at: usize, value: u32) usize {
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var rest = value;
    while (true) {
        digits[count] = @intCast('0' + rest % 10);
        count += 1;
        rest /= 10;
        if (rest == 0) break;
    }
    for (0..count) |i| into[at + i] = digits[count - 1 - i];
    return at + count;
}

/// Mode `index` taken as the screen's: its picture, its rows, a frame's
/// time.
fn take(screen: *Screen, index: u32) void {
    const mode = &screen.modes[index];
    screen.current = index;
    screen.width = mode.width;
    screen.height = mode.height;
    screen.pitch = mode.pitch;
    screen.frame_us = if (mode.refresh_mhz != 0) 1_000_000_000 / mode.refresh_mhz else 16_667;
}

/// The modes of the monitor on the JH7110's HDMI port (`monitor.zig`),
/// from its EDID; the monitor's name, how many modes it has and the one
/// it gets said on the raw port. The board's own alone when no monitor is
/// on the port (which `begin` says), or its EDID does not read.
fn hdmiModes(screen: *Screen, own: edid.Timing) monitor.List {
    const waiter = Waiter{ .screen = screen };
    if (jh7110.wake(screen.sys, waiter) != .none or !jh7110.monitor()) return monitor.modesOf(null, null, own, jh7110.sends);
    var first: edid.Block = undefined;
    var extension: edid.Block = undefined;
    var name: [14]u8 = @splat(0);
    var base: ?*const edid.Block = null;
    var cea: ?*const edid.Block = null;
    if (jh7110.readEdid(0, &first, waiter) and edid.isFirst(&first) and edid.valid(&first)) {
        base = &first;
        edid.name(&first, &name);
        if (first[126] != 0 and jh7110.readEdid(1, &extension, waiter) and edid.valid(&extension)) cea = &extension;
    }
    const found = monitor.modesOf(base, cea, own, jh7110.sends);
    const shown = &found.modes[found.default];
    if (base == null) {
        exec.kprintf(screen.sys, "%s: HDMI to a monitor whose EDID did not read, %dx%d at %d Hz\n", .{ MODULE_NAME, shown.width, shown.height, shown.hz() });
    } else {
        const who: [*:0]const u8 = if (name[0] != 0) @ptrCast(&name) else "a monitor";
        exec.kprintf(screen.sys, "%s: HDMI to %s, %dx%d at %d Hz of %d modes\n", .{ MODULE_NAME, who, shown.width, shown.height, shown.hz(), found.count });
    }
    return found;
}

/// The display brought up the first time in `mode` - or changed to it -
/// black: the block's first frame, which the library has not handed out
/// yet.
fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode) callconv(.c) i32 {
    const screen = screenOf(board);
    const index = mode.id -% 1;
    if (index >= screen.mode_count or mode.format != screen.format) return err.RTGERR_BAD_MODE;
    const changed = index != screen.current;
    take(screen, index);
    if (screen.scanning == 0 or changed) {
        const first = board.region.base.?;
        const bytes = @as(usize, screen.pitch) * screen.height;
        @memset(first[0..bytes], 0);
        handOn(screen, &pictureAt(screen, first), whole(screen));
        // What it read until now says nothing about the new mode.
        screen.scanning = 0;
        if (!begin(screen, @intFromPtr(first))) return err.RTGERR_NO_DISPLAY;
    }
    board.info.width = screen.width;
    board.info.height = screen.height;
    board.info.format = screen.format;
    board.info.pitch = screen.pitch;
    board.info.pixel_clock_hz = screen.modes[index].pixel_clock_hz;
    board.info.refresh_mhz = screen.modes[index].refresh_mhz;
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
        .ramfb, .virtio => scanFrom(screen, address),
        .jh7110 => {
            const failure = jh7110.start(screen.sys, &screen.timings.modes[screen.current], address, screen.pitch, Waiter{ .screen = screen });
            switch (failure) {
                .none => screen.scanning = address,
                .power => exec.kprintf(screen.sys, "%s: the display's power domain did not come on\n", .{MODULE_NAME}),
                .clock => exec.kprintf(screen.sys, "%s: the HDMI transmitter's PLL makes no such pixel clock\n", .{MODULE_NAME}),
                .pll => exec.kprintf(screen.sys, "%s: the HDMI transmitter's PLL did not lock\n", .{MODULE_NAME}),
            }
            if (failure == .none and !jh7110.monitor()) {
                exec.kprintf(screen.sys, "%s: no monitor on the HDMI port\n", .{MODULE_NAME});
            }
            if (failure == .none) hookFrames(screen);
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
        if (!showable(screen, bm)) return err.RTGERR_NOT_DISPLAYABLE;
    }
    // A flip from one picture to another takes a frame. The first picture
    // shown is not waited for: it comes up at cold start.
    const flip = flip: {
        hold(screen);
        defer letGo(screen);
        const another = screen.showing != null and bitmap != null and (screen.showing != bitmap or screen.band_count > 1);
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
            handOn(screen, &pictureAt(screen, black), whole(screen));
            scanFrom(screen, @intFromPtr(black));
        }
        break :flip another;
    };
    // Waited out with the frame let go: the pointer moves meanwhile.
    if (flip) pace(screen, 1);
    return err.RTGERR_OK;
}

/// Rows were written by the CPU: handed on, and into the composed frame
/// while the display reads that - those of them the bands show, and the
/// pointer back over them where they cross it.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    const first = if (rows == 0) 0 else @min(y, bitmap.height);
    const last = if (rows == 0) bitmap.height else @min(y +| rows, bitmap.height);
    // Any buffer, shown or not: one drawn ahead is shown by naming it.
    handOn(screen, bitmap, .{ .left = 0, .top = first, .right = bitmap.width, .end = last });
    compose(screen, bitmap, .{ .left = 0, .top = first, .right = @min(bitmap.width, screen.width), .end = last });
    return err.RTGERR_OK;
}

/// A rectangle written: its pixels alone handed on, then that rectangle
/// composed, and no more of the rows.
fn refreshRect(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect) callconv(.c) i32 {
    const screen = screenOf(board);
    const x: u32 = @intCast(area.x);
    const first: u32 = @intCast(area.y);
    const box = Box{ .left = x, .top = first, .right = x + @as(u32, @intCast(area.width)), .end = first + @as(u32, @intCast(area.height)) };
    handOn(screen, bitmap, box);
    compose(screen, bitmap, .{ .left = box.left, .top = box.top, .right = @min(box.right, screen.width), .end = box.end });
    return err.RTGERR_OK;
}

/// `area` of a buffer handed on - its own rows and columns - copied into
/// the composed frame where the display reads that, and the images laid
/// over it again.
fn compose(screen: *Screen, bitmap: *rtg.RtgBitMap, area: Box) void {
    hold(screen);
    defer letGo(screen);
    if (!composing(screen)) return;
    if (area.left >= area.right) return;
    var shown = false;
    for (screen.bands[0..screen.band_count], 0..) |band, i| {
        if (band.bitmap != bitmap) continue;
        const band_end = if (i + 1 < screen.band_count) screen.bands[i + 1].line else screen.height;
        const lines = band.linesOf(area.top, area.end, band_end);
        if (lines.first >= lines.end) continue;
        copyArea(screen, .{ .left = area.left, .top = lines.first, .right = area.right, .end = lines.end });
        shown = true;
    }
    if (shown) lay(screen);
}

/// Several buffers at once, in bands: composed, shown, and a frame waited
/// out, as a flip is.
fn showBands(board: *rtg.RtgBoard, bands: [*]const rtg.RtgBand, count: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    for (bands[0..count]) |band| {
        const bm = band.bitmap;
        if (bm.pixels == null or bm.pitch != screen.pitch or bm.format != screen.format) return err.RTGERR_NOT_DISPLAYABLE;
    }
    const was_shown = shown: {
        hold(screen);
        defer letGo(screen);
        const before = screen.showing != null;
        @memcpy(screen.bands[0..count], bands[0..count]);
        screen.band_count = count;
        screen.showing = bands[count - 1].bitmap;
        rebuild(screen);
        present(screen);
        break :shown before;
    };
    if (was_shown) pace(screen, 1);
    return err.RTGERR_OK;
}

/// Frames waited for: by the frame interrupt where it comes, else by the
/// clock.
fn waitVBlank(board: *rtg.RtgBoard, frames: u32) callconv(.c) i32 {
    pace(screenOf(board), if (frames == 0) 1 else frames);
    return err.RTGERR_OK;
}

fn stats(board: *rtg.RtgBoard, into: *rtg.RtgBoardStats) callconv(.c) void {
    const screen = screenOf(board);
    into.frames = screen.updates;
}

// --- the engine: the cores (engine.zig) ---------------------------------------

fn fillRect(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) callconv(.c) i32 {
    return engine.fill(&screenOf(board).engine, bitmap, area, color);
}

fn copyRect(board: *rtg.RtgBoard, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, what: *const rtg.RtgCopy) callconv(.c) i32 {
    return engine.copy(&screenOf(board).engine, src, dest, what);
}

fn blitTemplate(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, shape: *const rtg.bitmaps.RtgTemplate) callconv(.c) i32 {
    return engine.template(&screenOf(board).engine, bitmap, area, shape);
}

fn blitPattern(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, tile: *const rtg.bitmaps.RtgPattern) callconv(.c) i32 {
    return engine.pattern(&screenOf(board).engine, bitmap, area, tile);
}

fn waitBlit(board: *rtg.RtgBoard) callconv(.c) void {
    engine.waitIdle(&screenOf(board).engine);
}

fn blendRect(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) callconv(.c) i32 {
    return engine.blendRect(&screenOf(board).engine, bitmap, area, color);
}

fn blendPixels(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, alpha: u32) callconv(.c) i32 {
    return engine.blendPixels(&screenOf(board).engine, bitmap, area, pixels, alpha);
}

fn scalePixels(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, width: u32, height: u32) callconv(.c) i32 {
    return engine.scale(&screenOf(board).engine, bitmap, area, pixels, width, height);
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
    .fill_rect = &fillRect,
    .copy_rect = &copyRect,
    .blit_template = &blitTemplate,
    .blit_pattern = &blitPattern,
    .wait_blit = &waitBlit,
    .blend_pixels = &blendPixels,
    .blend_rect = &blendRect,
    .scale_pixels = &scalePixels,
    .refresh_rect = &refreshRect,
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

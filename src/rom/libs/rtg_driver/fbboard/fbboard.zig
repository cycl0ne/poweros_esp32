// SPDX-License-Identifier: MPL-2.0
//! A display whose picture is in the machine's RAM, as a display board:
//! QEMU virt's ramfb (`ramfb.zig`), the JH7110's display controller
//! behind its HDMI port (`jh7110.zig`) and the BCM2712's video scaler
//! behind its first one (`bcm2712.zig`), which read it out of RAM by
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
//! by the next frame. The buffers are RAM the CPU reaches through its
//! caches (`RTGRF_CPU_CACHED`), so a refresh hands the rows on with exec's
//! CacheClearE, and whether that writes them back is the machine's to
//! say: nothing on QEMU's virt, whose ramfb reads RAM through the host's
//! caches (SYSTAG_CacheFlush absent, SYSTAG_DmaCoherent).
//!
//! The virtio GPU keeps a copy of each picture in the emulator instead,
//! and shows that: the rectangle a refresh hands on is copied into it and
//! shown, so there it is the hand-on that puts what was written on the
//! glass, a rectangle at a time, and showing a buffer is naming its copy.
//!
//! The emulator's displays have one mode: the ramfb the size the board
//! names, the virtio GPU the size QEMU's window has for it. An HDMI
//! port's - the JH7110's, the BCM2712's - has the modes the monitor on it
//! names in its EDID and the port can send, read when the board is made
//! (`monitor.zig`): the one the monitor prefers is the default, and any
//! of them can be set.
//!
//! The buffers are the machine's RAM below 4 GiB, which every display here
//! reaches (MEMF_DMA): the library takes each when it is allocated and
//! gives it back when it is freed (RTGRF_SYSTEM_MEMORY, RTGRF_DMA_MEMORY),
//! at most as many pictures of the largest mode as the board asks for
//! (RTGA_Buffers) - so a screen nobody has opened costs nothing. The
//! driver's own are a frame to compose in - two the display is shown,
//! behind an HDMI port - and, on a display with a cursor plane, the
//! plane's two images.
//!
//! The pointer is laid over the picture in that frame, as the qemu board
//! does it: while a pointer or the overlay is shown, or the picture is
//! several in bands, the display reads the composed frame instead - the
//! shown buffer's rectangles copied in as they are refreshed, no wider
//! than what was written, and the images laid over them. The copy is the
//! engine's, so a large one - the whole picture, when composing starts or
//! another buffer is shown - is shared between the cores. A move puts
//! back the pointer's old rectangle from the shown buffer and lays it at
//! the new one, so it costs the pointer's size and not the picture's.
//! With nothing over the picture the display reads the shown buffer
//! itself, and nothing is copied.
//!
//! The composed frame is taken when it is first needed. Where the pointer
//! is the display's own, on the virtio GPU, it is given back once the
//! display reads a buffer again, so it is there only while a screen is
//! pulled down or an icon dragged. On the ramfb, where the pointer is laid
//! in it, it stays. Black, as the display comes up or when nothing is
//! shown, is the composed frame cleared.
//!
//! A refresh comes from whichever task drew, a pointer move from
//! intuition's pointer task, each on any core: everything that writes the
//! composed frame or changes what is laid in it holds the board's
//! `compose_lock`, so that rows copied in on one core never cover a
//! pointer just laid on another, nor a restore cut a hole into rows just
//! copied.
//!
//! The HDMI ports' displays read RAM past the caches, and the caches write
//! their lines back in an order of their own: a picture drawn over while
//! it is read shows, for a frame, a patchwork of old and new cache lines,
//! sixteen pixels each. So there the display never reads a buffer anybody
//! draws in, nor the composed frame. It reads one of two frames of the
//! driver's own (`flipFrames`): what is written is noted as rectangles
//! (`damage.zig`), and a task of the driver's makes the next picture in
//! the frame the display is not reading - those rectangles, and those
//! that went into the other frame the time before, copied in from the
//! bands with the overlay laid over them - writes it out of the caches,
//! and tells the display to read it from the next frame on, which it
//! waits for before the frame read until then is written again. A
//! drawing is seen a frame or two after it was made, and whole. The
//! buffers drawn in are not written back, since nothing reads them past
//! the caches; showing a buffer, or bands, is a whole picture made and
//! waited for. A picture copied into a band all at once - a window's next
//! frame, which starts as the display's does, as the task's copy does - is
//! not copied while the task reads the bands (`bands_lock`): it would take
//! the top of the new picture and the rest of the old.
//!
//! A whole picture is a copy of the whole display - at 2560x1440 14 MB,
//! which takes the cores 14 ms - and a program that draws each picture in
//! one buffer while it shows another, and then shows that one, would wait
//! for one each time: a frame lost to every picture. So on the BCM2712's
//! port the display reads such a program's buffers themselves
//! (`directOf`): a whole buffer shown in place of another that nothing was
//! written in while it was shown is written out of the caches whole and
//! read as it is, from the next frame on, and nothing is copied. Should
//! anything then be written in it - a requester opened on that screen -
//! that is written out at once, and the task takes the frames up again
//! with the next picture, made whole: for a frame or two the drawing is
//! seen as it is written out.
//!
//! Their controllers have a pointer of their own, a cursor plane, which
//! they lay over the picture themselves: there the pointer is that
//! (`cursor`), the image copied into a buffer of the block's as ARGB, its
//! mask the alpha, and a move is the plane written again at its new place.
//! Two buffers take turns, so the one the controller reads is never the
//! one written. On the JH7110's the overlay is laid in the picture made
//! for it; the BCM2712's HVS lays it as a plane of its own under the
//! cursor's (`overlayPlane`), the same way, so dragging an icon makes no
//! picture at all. The virtio GPU's cursor is the same, laid over its
//! window by the emulator - with a tablet, as the host's own pointer - and
//! moved by a command; so there nothing is composed for the pointer
//! either.
//!
//! The BCM2712's port does more of what a board can be asked in its own
//! hardware (`bcm2712_ops`): the picture mirrored either way (MirrorBoard)
//! is the HVS reading its planes backwards; the display switched off
//! (SetBoardDisplay) is the controller sending blank pixels without their
//! syncs, which a monitor sleeps at, the mode and everything else left
//! running; and the brightness is the monitor's own, set and read over the DDC with
//! DDC/CI, where the monitor takes it. A start of the port - a mode set,
//! a monitor plugged in - puts all three back as the board has them
//! (`putBack`).
//!
//! The JH7110's port has a video layer besides (`jh7110_ops`): the
//! controller's first overlay, which reads a film's frame in YUV planes
//! itself - turning it into colours by a matrix loaded into it - and
//! scales it into a place on the display, under the picture, seen where
//! the picture has the layer's key colour - or a shade of it a shadow
//! darkened it to - or over it. A frame shown is
//! taken from the next frame on and waited for, so that the one before
//! may be given back; a place partly off the display is cut to it; a
//! start of the port puts the layer back as it was (`videoPutBack`).
//! The controller's planes share its hold and its commit bits, so
//! whatever writes one - the task that makes the pictures, the pointer's
//! moves, a film - holds `plane_lock`.
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
const bcm2712 = @import("bcm2712.zig");
const virtio = @import("virtio.zig");
const monitor = @import("monitor.zig");
const edid = @import("../edid.zig");
const engine = @import("engine.zig");
const damage = @import("damage.zig");
const tags = rtg.tags;
const timer = sdk.devices.timer;

const MODULE_NAME = "rtg-fb";
const DRIVER_NAME = "fb";
const VERSION = 1;
const REVISION = 21;
const BUILD_DATE = "30.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The chips this drives, as the board's panel part names them.
const chips = [_]u32{ st.CHIP_QEMU_RAMFB, st.CHIP_JH7110_DC8200, st.CHIP_VIRTIO_GPU, st.CHIP_BCM2712_HVS };

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
    bcm2712,
};

/// Whether the display is behind an HDMI port, whose monitor names its
/// modes, and which reads past the caches with a cursor plane of its own.
fn isHdmi(scanout: Scanout) bool {
    return scanout == .jh7110 or scanout == .bcm2712;
}

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
    /// The modes: the board's own, or behind an HDMI port those the
    /// monitor takes (`monitor.zig`), with their timings; their names; which one
    /// the display is in; how long a frame of it takes.
    modes: [monitor.max_modes]rtg.RtgMode = undefined,
    timings: monitor.List = .{},
    names: [monitor.max_modes][16]u8 = undefined,
    mode_count: u32 = 0,
    current: u32 = 0,
    frame_us: u32 = 16_667,
    /// Behind an HDMI port: what the monitor says of itself - HDMI or DVI,
    /// sound, range, its fastest clock - from its EDID; whether it was on
    /// the port when last looked at, how many looks in a row have seen
    /// otherwise, and when the port was last looked at (`watch`).
    sink: edid.Sink = .{},
    plugged: bool = false,
    settling: u32 = 0,
    watched_us: u64 = 0,
    /// A picture of the largest mode: what the composed frame takes.
    frame_bytes: usize = 0,
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
    /// The frame the pointer is composed in and black is shown from, as
    /// AllocMem gave it and where it starts: null until it is needed
    /// (`ownFrame`), and again once the display reads a buffer (`spare`).
    composed_memory: ?*anyopaque = null,
    composed: ?[*]u8 = null,
    /// Held while the composed frame, or what is laid in it and what it
    /// is composed from, changes. A semaphore: a write-back may wait for
    /// exec's workers.
    compose_lock: exec.SignalSemaphore = .{},
    /// Behind the BCM2712's port, the overlay's plane's two image buffers,
    /// as AllocMem gave them and where they start; which of them is the
    /// plane's, the size of the image in it, and whether it is shown.
    overlay_memory: ?*anyopaque = null,
    overlay_images: ?[*]u8 = null,
    overlay_turn: u1 = 0,
    overlay_width: u32 = 0,
    overlay_height: u32 = 0,
    overlay_shown: bool = false,
    /// Behind the BCM2712's port: how the picture is turned, whether the
    /// monitor is sent nothing, and the brightness last set or read.
    turn: bcm2712.Turn = .{},
    dark: bool = false,
    brightness: u32 = 100,
    /// The cursor plane's two image buffers on a display that has one, as
    /// AllocMem gave them and where they start; which of them is the
    /// plane's, whether it is the small size, and its image's hot spot.
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
    /// Where the display reads past the caches (`flipFrames`): the two
    /// frames it is shown, as AllocMem gave them and the bytes taken, and
    /// which of them it reads. Null where it is shown buffers itself.
    flip_memory: ?*anyopaque = null,
    flip_bytes: usize = 0,
    flip_frames: [2][*]u8 = undefined,
    front: u1 = 0,
    /// What was written since the last picture was made, and what went
    /// into that picture, which the other frame has not had: under
    /// `damage_lock`, which also keeps the bands and the overlay's place
    /// still while a refresh reads them. With them, whether the bands were
    /// written in since they were shown, and the buffer the display reads
    /// itself in place of a frame (`directOf`), if it does.
    fresh: damage.Damage = .{},
    last: damage.Damage = .{},
    written: bool = false,
    direct: ?*const rtg.RtgBitMap = null,
    damage_lock: exec.Lock = .{},
    /// Held while a picture is made and waited for, and while the bands or
    /// the overlay's image change, so that what a picture is made from
    /// stays for as long as it is made.
    flip_lock: exec.SignalSemaphore = .{},
    /// Held while the task reads the bands, and while the engine's copies
    /// are written into one: neither sees half of the other.
    bands_lock: exec.SignalSemaphore = .{},
    /// The task that makes the pictures, what wakes it, and what tells
    /// that it has stopped.
    flipper: ?*exec.Task = null,
    work: exec.Waitable = .{},
    stopping: bool = false,
    stopped: exec.Waitable = .{},
    /// Behind the JH7110's port, the video layer on its first overlay
    /// (`videoOpen`): the layer while it is taken; the colours the picture
    /// shows it through, null over the picture; the picture last shown -
    /// a copy of what was handed in - the part of it, and its place on
    /// the display. Under `plane_lock`.
    video: ?*rtg.RtgVideoLayer = null,
    video_key: ?jh7110.VideoKey = null,
    video_picture: ?rtg.RtgYuv = null,
    video_src: rtg.RtgRect = .{},
    video_place: rtg.RtgRect = .{},
    /// Behind the JH7110's port: held while the controller's planes are
    /// written - the picture's, the cursor's, the video layer's - which
    /// share its hold and its commit bits, by the task that makes the
    /// pictures, intuition's pointer task and a film's, each on any core.
    plane_lock: exec.Lock = .{},
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
    const raised = switch (screen.scanout) {
        .bcm2712 => bcm2712.takeInterrupts(),
        else => jh7110.takeInterrupts(),
    };
    if (raised == 0) return 0;
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
            screen.sys.AcquireLock(&screen.plane_lock);
            jh7110.show(address);
            screen.sys.ReleaseLock(&screen.plane_lock);
            break :done true;
        },
        .bcm2712 => done: {
            bcm2712.show(address);
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

/// Whether the display is to read the composed frame: a pointer with an
/// image is shown over a picture, there is an overlay, or the picture is
/// several in bands.
fn wanted(screen: *const Screen) bool {
    if (screen.showing == null) return false;
    const pointer = screen.cursor == null and screen.pointer_shown and screen.pointer != null;
    return screen.band_count > 1 or pointer or screen.overlay != null;
}

/// Whether the display reads the composed frame: it is wanted, and there
/// was memory for it.
fn composing(screen: *const Screen) bool {
    return screen.composed != null and wanted(screen);
}

/// Memory of the driver's own: `bytes` from a page on, where every display
/// here reads, the system's and not the task's that happened to ask - what
/// AllocMem gave, and where the page starts.
const Own = struct { memory: *anyopaque, at: [*]u8 };

fn takeOwn(screen: *Screen, bytes: usize) ?Own {
    const memory = screen.sys.AllocMem(bytes + page, exec.MEMF_DMA | exec.MEMF_SYSTEM) orelse return null;
    return .{ .memory = memory, .at = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(memory), page)) };
}

/// The composed frame, taken when there is none yet; null without memory.
/// Not cleared: it is written whole before the display reads it. Taken
/// holding the composed frame, or before anything else can reach it.
fn ownFrame(screen: *Screen) ?[*]u8 {
    if (screen.composed) |frame| return frame;
    const own = takeOwn(screen, screen.frame_bytes) orelse return null;
    screen.composed_memory = own.memory;
    screen.composed = own.at;
    return own.at;
}

/// The composed frame taken, when the display is to read it. Without
/// memory there is none, and the display goes on reading the shown buffer.
fn provide(screen: *Screen) void {
    if (wanted(screen)) _ = ownFrame(screen);
}

/// The composed frame let go of, once nothing is laid over the picture
/// and the display reads a buffer again: what AllocMem gave, for
/// `giveBack` once the frame is let go. Null while it is wanted, read, or
/// shown as black - and always on a display without a pointer of its own,
/// the ramfb, where the pointer is hidden at every key and shown again at
/// every move of the mouse, and the frame would come and go with it. The
/// virtio GPU forgets its copy, so that a buffer the library makes in the
/// same memory later is copied whole.
fn spare(screen: *Screen) ?*anyopaque {
    const frame = screen.composed orelse return null;
    if (screen.cursor == null) return null;
    if (screen.showing == null or wanted(screen) or screen.scanning == @intFromPtr(frame)) return null;
    const memory = screen.composed_memory;
    screen.composed = null;
    screen.composed_memory = null;
    switch (screen.scanout) {
        .virtio => |*gpu| virtio.forget(gpu, @intFromPtr(frame), Waiter{ .screen = screen }),
        else => {},
    }
    return memory;
}

/// What `spare` let go of, given back. The emulator's displays have let
/// go of it already.
fn giveBack(screen: *Screen, memory: ?*anyopaque) void {
    const frame = memory orelse return;
    screen.sys.FreeMem(frame, screen.frame_bytes + page);
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

const Box = damage.Box;

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
    if (box.isEmpty()) return;
    copyInto(screen, composed, box);
    handOn(screen, &pictureAt(screen, composed), box);
}

/// `box` of the display, each row from its band, into the frame at
/// `into`.
fn copyInto(screen: *Screen, into: [*]u8, box: Box) void {
    for (screen.bands[0..screen.band_count], 0..) |band, i| {
        const band_end = if (i + 1 < screen.band_count) screen.bands[i + 1].line else screen.height;
        const first = @max(box.top, band.line);
        const end = @min(box.end, band_end);
        if (first < end) copyBand(screen, into, band, box, first, end);
    }
}

/// Display rows `first` to `end` of one band, across the box's columns.
/// The band's rows are one rectangle of its buffer, which the cores copy
/// (the engine, shared between them for a large one); a band of one row
/// repeated, or a format the engine does not take, a row at a time.
fn copyBand(screen: *Screen, frame: [*]u8, band: rtg.RtgBand, box: Box, first: u32, end: u32) void {
    if (band.flags & rtg.RTGBANDF_REPEAT == 0) {
        var into = pictureAt(screen, frame);
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
    const at = box.left * screen.bytes;
    const length = (box.right - box.left) * screen.bytes;
    var y = first;
    while (y < end) : (y += 1) {
        const from = band.bitmap.pixels.? + band.rowAt(y) * screen.pitch;
        screen.sys.CopyMem(from + at, frame + y * screen.pitch + at, length);
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
    const composed = screen.composed orelse return;
    const clip = layOver(screen, composed, given, left, top, whole(screen)) orelse return;
    handOn(screen, &pictureAt(screen, composed), clip.box());
}

/// One image laid over the frame at `into`, cut to the picture and to
/// `within`: where it was laid, null when nowhere.
fn layOver(screen: *Screen, into_frame: [*]u8, given: ?*const rtg.RtgPointerImage, left: i32, top: i32, within: Box) ?Clip {
    const image = given orelse return null;
    var clip = clipOf(screen, image, left, top) orelse return null;
    if (image.format != screen.format) return null;
    clip.x0 = @max(clip.x0, within.left);
    clip.y0 = @max(clip.y0, within.top);
    clip.x1 = @min(clip.x1, within.right);
    clip.y1 = @min(clip.y1, within.end);
    if (clip.x0 >= clip.x1 or clip.y0 >= clip.y1) return null;
    var y = clip.y0;
    while (y < clip.y1) : (y += 1) {
        const image_y: u32 = @intCast(@as(i32, @intCast(y)) - top);
        const row = image.pixels + image_y * image.pitch;
        const into = into_frame + y * screen.pitch;
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
    return clip;
}

/// The whole picture into the composed frame, with the images over it:
/// when composing starts.
fn rebuild(screen: *Screen) void {
    if (!composing(screen)) return;
    copyArea(screen, whole(screen));
    lay(screen);
}

/// The bands now set made in the composed frame, which showed `old`:
/// when the display read it until now, only the rows that come from
/// another buffer or another row of it are copied and handed on - a
/// screen pulled further down leaves the rows above it - else the whole
/// picture. The images are laid over it again.
fn reband(screen: *Screen, old: []const rtg.RtgBand, was: bool) void {
    if (!composing(screen)) return;
    if (!was) return rebuild(screen);
    var changed: damage.Damage = .{};
    changed.rebanded(old, screen.bands[0..screen.band_count], screen.width, screen.height);
    if (changed.isEmpty()) return;
    for (changed.list()) |box| copyArea(screen, box);
    lay(screen);
}

/// A change to either image: both rectangles put back, the change made,
/// both laid again - they may overlap, and the one under must not be
/// left with a hole the other's restore cut. The frame is taken and
/// rebuilt when composing starts with it, given back when it stops, and
/// nothing is shown anew when the display reads the shown buffer before
/// and after. Made holding the composed frame.
fn change(screen: *Screen, comptime apply: fn (*Screen, anytype) void, arg: anytype) void {
    const unused = unused: {
        hold(screen);
        defer letGo(screen);
        const was = composing(screen);
        if (was) restore(screen);
        apply(screen, arg);
        provide(screen);
        if (!was and !composing(screen)) break :unused null;
        if (!was) {
            rebuild(screen);
        } else if (composing(screen)) {
            lay(screen);
        }
        present(screen);
        break :unused spare(screen);
    };
    giveBack(screen, unused);
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
    const unused = unused: {
        hold(screen);
        defer letGo(screen);
        screen.pointer_shown = show;
        provide(screen);
        rebuild(screen);
        present(screen);
        break :unused spare(screen);
    };
    giveBack(screen, unused);
    return err.RTGERR_OK;
}

// --- the pointer, on the controller's cursor plane ---------------------------

/// The bytes of one of the cursor plane's buffers: the HDMI ports'
/// largest image, which is the virtio GPU's one size.
const cursor_bytes = jh7110.cursor_side * jh7110.cursor_side * 4;
comptime {
    std.debug.assert(virtio.cursor_side == jh7110.cursor_side);
    std.debug.assert(bcm2712.cursor_side == jh7110.cursor_side);
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
        .bcm2712 => bcm2712.cursor(
            @intFromPtr(cursorBuffer(screen, screen.cursor_turn)),
            screen.cursor_small,
            screen.cursor_hot_x,
            screen.cursor_hot_y,
            at.x,
            at.y,
            screen.pointer_shown and screen.pointer != null,
        ),
        else => {
            screen.sys.AcquireLock(&screen.plane_lock);
            defer screen.sys.ReleaseLock(&screen.plane_lock);
            jh7110.cursor(
                @intFromPtr(cursorBuffer(screen, screen.cursor_turn)),
                screen.cursor_small,
                screen.cursor_hot_x,
                screen.cursor_hot_y,
                at.x,
                at.y,
                screen.pointer_shown and screen.pointer != null,
            );
        },
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
    if (screen.overlay_images != null) {
        overlayImage(screen, image);
        return err.RTGERR_OK;
    }
    if (flips(screen)) {
        overlayFlipped(screen, image);
        return err.RTGERR_OK;
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
    if (screen.overlay_images != null) {
        screen.overlay_left = left;
        screen.overlay_top = top;
        return overlayPlane(screen);
    }
    if (flips(screen)) return overlayMoved(screen, left, top);
    change(screen, struct {
        fn apply(on: *Screen, place: anytype) void {
            on.overlay_left = place[0];
            on.overlay_top = place[1];
        }
    }.apply, .{ left, top });
}

// --- the overlay, on the BCM2712's plane of its own ------------------------

/// The bytes of one of the overlay plane's buffers: rtg's largest image.
const overlay_bytes = bcm2712.overlay_side * bcm2712.overlay_side * 4;
comptime {
    std.debug.assert(bcm2712.overlay_side == rtg.boards.RTG_OVERLAY_MAX);
}

fn overlayBuffer(screen: *Screen, turn: u1) [*]u8 {
    return screen.overlay_images.? + @as(usize, turn) * overlay_bytes;
}

/// The plane told its buffer, the image's size and place, and whether it
/// is seen.
fn overlayPlane(screen: *Screen) void {
    if (screen.overlay_images == null) return;
    bcm2712.overlay(
        @intFromPtr(overlayBuffer(screen, screen.overlay_turn)),
        screen.overlay_width,
        screen.overlay_height,
        screen.overlay_left,
        screen.overlay_top,
        screen.overlay_shown,
    );
}

/// A new image into the buffer the plane is not reading - ARGB, opaque
/// where the mask says, clear elsewhere - and the plane turned to it; or
/// none, and the plane hidden. The library's image is not read again.
fn overlayImage(screen: *Screen, image: ?*const rtg.RtgPointerImage) void {
    const one = image orelse {
        screen.overlay_shown = false;
        return overlayPlane(screen);
    };
    const side: u32 = bcm2712.overlay_side;
    const turn = screen.overlay_turn +% 1;
    const buffer = overlayBuffer(screen, turn);
    const pixels: [*]u32 = @ptrCast(@alignCast(buffer));
    const rows = @min(one.height, side);
    const columns = @min(one.width, side);
    var y: u32 = 0;
    while (y < rows) : (y += 1) {
        const row: [*]const u32 = @ptrCast(@alignCast(one.pixels + y * one.pitch));
        var x: u32 = 0;
        while (x < columns) : (x += 1) {
            pixels[y * side + x] = if (one.opaqueAt(x, y)) row[x] | 0xFF00_0000 else 0;
        }
    }
    writeBack(screen, buffer, rows * side * 4);
    screen.overlay_turn = turn;
    screen.overlay_width = columns;
    screen.overlay_height = rows;
    screen.overlay_shown = true;
    overlayPlane(screen);
}

// --- what the BCM2712's port does itself ------------------------------------

/// What a start of the BCM2712's port leaves as it makes it - the picture
/// unturned, the monitor sent it, the cursor and the overlay hidden - put
/// back as the board has it.
fn putBack(screen: *Screen) void {
    bcm2712.mirror(screen.scanning, screen.turn);
    if (screen.dark) bcm2712.transmit(false);
    cursorPlane(screen);
    overlayPlane(screen);
}

/// The picture mirrored, from the next frame on; the cursor and the
/// overlay with it.
fn mirror(board: *rtg.RtgBoard, x: bool, y: bool) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    sys.ObtainSemaphore(&screen.flip_lock);
    screen.turn = .{ .x = x, .y = y };
    if (screen.scanning != 0) bcm2712.mirror(screen.scanning, screen.turn);
    sys.ReleaseSemaphore(&screen.flip_lock);
    cursorPlane(screen);
    overlayPlane(screen);
    return err.RTGERR_OK;
}

/// The monitor sent the picture, or nothing, which it sleeps at.
fn display(board: *rtg.RtgBoard, on: bool) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    sys.ObtainSemaphore(&screen.flip_lock);
    defer sys.ReleaseSemaphore(&screen.flip_lock);
    screen.dark = !on;
    bcm2712.transmit(on);
    return err.RTGERR_OK;
}

/// The monitor's brightness set over DDC/CI, `percent` of its largest:
/// RTGERR_IO where it does not answer. Holding `flip_lock`, which keeps
/// the port's other talk on the DDC away - the EDID, the SCDC.
fn setBrightness(board: *rtg.RtgBoard, percent: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    const waiter = Waiter{ .screen = screen };
    sys.ObtainSemaphore(&screen.flip_lock);
    defer sys.ReleaseSemaphore(&screen.flip_lock);
    const now = bcm2712.feature(bcm2712.VCP_BRIGHTNESS, waiter) orelse return err.RTGERR_IO;
    const wanted_percent: u32 = @min(percent, 100);
    const value: u16 = @intCast((wanted_percent * now.most + 50) / 100);
    if (!bcm2712.setFeature(bcm2712.VCP_BRIGHTNESS, value, waiter)) return err.RTGERR_IO;
    screen.brightness = wanted_percent;
    return err.RTGERR_OK;
}

/// The monitor's brightness as it answers it - set with its own buttons,
/// too - in per cent; what was last set or read where it does not answer.
fn brightness(board: *rtg.RtgBoard) callconv(.c) u32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    sys.ObtainSemaphore(&screen.flip_lock);
    defer sys.ReleaseSemaphore(&screen.flip_lock);
    if (bcm2712.feature(bcm2712.VCP_BRIGHTNESS, Waiter{ .screen = screen })) |now| {
        screen.brightness = (@as(u32, @min(now.value, now.most)) * 100 + now.most / 2) / now.most;
    }
    return screen.brightness;
}

// --- the video layer, on the JH7110's first overlay -------------------------

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

/// The layer taken: under the picture unless asked over, nothing on it
/// and no place yet, the scaler's filter loaded.
fn videoOpen(board: *rtg.RtgBoard, layer: *rtg.RtgVideoLayer) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    const under = layer.flags & rtg.RTGVLF_UNDER != 0;
    layer.key = if (under) video_key else 0;
    layer.max_width = jh7110.video_max_side;
    layer.max_height = jh7110.video_max_side;
    layer.max_up = jh7110.video_max_up;
    layer.max_down = jh7110.video_max_down;
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

/// Whether the layer reads `part` of `picture`: its planes laid out as it
/// takes them - NV12, or I420 with both colour planes - each of the part's
/// rows starting on 16 bytes, the part's top left on a pair of pixels
/// each way, at least two of them each way, and every byte of it below
/// 4 GiB, where the controller reaches.
fn videoReads(picture: *const rtg.RtgYuv, part: rtg.RtgRect) bool {
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
        .bt709 = one.colors & rtg.bitmaps.RTGYUV_MATRIX == rtg.bitmaps.RTGYUV_BT709,
        .full = one.colors & rtg.bitmaps.RTGYUV_FULL != 0,
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

/// What a start of the JH7110's port leaves - its first overlay off, in
/// U-Boot's order, the primary unkeyed - put back as the layer has it.
fn videoPutBack(screen: *Screen) void {
    const sys = screen.sys;
    sys.AcquireLock(&screen.plane_lock);
    defer sys.ReleaseLock(&screen.plane_lock);
    if (screen.video == null) return;
    jh7110.videoStart();
    jh7110.videoOrder(screen.video_key);
    _ = videoPut(screen);
}

// --- a display that reads past the caches: two frames, flipped --------------

/// The task that makes the pictures: above the programs that draw, so that
/// what they drew is shown at the pace of the display, and below
/// intuition's tasks, which move what is drawn.
const flipper_name = "rtg-fb frames";
const flipper_pri = 19;

/// Whether the display is shown two frames of the driver's own, the next
/// picture made in the one it is not reading (`flipFrames`), rather than
/// the buffers themselves: where it reads past the caches.
fn flips(screen: *const Screen) bool {
    return screen.flip_memory != null;
}

/// The two frames taken, each a picture of the largest mode from a page
/// on, black and written back, and the task that makes the pictures
/// started. False without memory for either.
fn startFlipping(screen: *Screen) bool {
    const sys = screen.sys;
    const size = std.mem.alignForward(usize, screen.frame_bytes, page);
    const own = takeOwn(screen, 2 * size) orelse return false;
    @memset(own.at[0 .. 2 * size], 0);
    writeBack(screen, own.at, 2 * size);
    screen.flip_frames = .{ own.at, own.at + size };
    screen.flip_bytes = 2 * size;
    screen.front = 0;
    sys.InitSemaphore(&screen.flip_lock);
    sys.InitSemaphore(&screen.bands_lock);
    sys.InitLock(&screen.damage_lock, "rtg-fb damage", exec.LOCKORDER_DRIVER, 0);
    sys.InitLock(&screen.plane_lock, "rtg-fb planes", exec.LOCKORDER_DRIVER + 1, 0);
    // The task is the system's, not that of whoever made the board.
    sys.BeginSystemMemory();
    const task = sys.CreateTask(flipper_name, flipper_pri, &flipperCode, 0);
    sys.EndSystemMemory();
    const made = task orelse {
        sys.FreeMem(own.memory, screen.flip_bytes + page);
        return false;
    };
    screen.flip_memory = own.memory;
    screen.flipper = made;
    @atomicStore(?*anyopaque, &made.user_data, screen, .release);
    sys.Signal(made, exec.SIGF_SINGLE);
    return true;
}

/// The task stopped and the frames given back.
fn stopFlipping(screen: *Screen) void {
    const sys = screen.sys;
    const memory = screen.flip_memory orelse return;
    @atomicStore(bool, &screen.stopping, true, .release);
    sys.SignalWaitable(&screen.work);
    _ = sys.WaitForAny(&[_]*exec.Waitable{&screen.stopped}, 1, exec.WAIT_FOREVER);
    sys.FreeMem(memory, screen.flip_bytes + page);
    screen.flip_memory = null;
    screen.flipper = null;
}

/// The task: a picture made each time something was noted, at most one a
/// frame, since each is waited for.
fn flipperCode(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    while (@atomicLoad(?*anyopaque, &me.user_data, .acquire) == null) _ = sys.Wait(exec.SIGF_SINGLE);
    const screen: *Screen = @ptrCast(@alignCast(me.user_data.?));
    while (true) {
        _ = sys.WaitForAny(&[_]*exec.Waitable{&screen.work}, 1, untilWatch(screen));
        // Reset before what was noted is taken: whatever is noted after
        // it wakes the task again.
        sys.ResetWaitable(&screen.work);
        if (@atomicLoad(bool, &screen.stopping, .acquire)) break;
        sys.ObtainSemaphore(&screen.flip_lock);
        _ = flipFrames(screen);
        if (watches(screen)) watch(screen);
        sys.ReleaseSemaphore(&screen.flip_lock);
    }
    // The last it does with the screen: it is freed once this is seen.
    sys.SignalWaitable(&screen.stopped);
}

// --- the HDMI port watched: a monitor plugged in or taken off ----------------

/// How often the port is looked at, and how many looks in a row must see
/// a monitor come or go before it is taken to have: a second, which is
/// what a plug that bounces as it goes in, or a monitor that raises its
/// hot-plug line before its EDID reads, takes.
const watch_us: u64 = 500_000;
const settle_looks = 2;

/// Whether the task looks at the port now and then: the BCM2712's, whose
/// hot-plug line has no interrupt of its own here, once the display
/// runs. The JH7110's is not looked at.
fn watches(screen: *const Screen) bool {
    return screen.scanout == .bcm2712 and screen.scanning != 0;
}

/// How long the task waits for work before it looks at the port again;
/// for good where it does not look.
fn untilWatch(screen: *const Screen) u64 {
    if (!watches(screen)) return exec.WAIT_FOREVER;
    const now = sdk.hardware.systimer.uptimeUs();
    const due = screen.watched_us + watch_us;
    return if (due > now + 1000) due - now else 1000;
}

/// The port looked at, when it is time: a monitor that has come is
/// read - its EDID, what it says of itself - and the display started
/// again for it in the mode it is in, in the monitor's own timing of
/// that mode where it names it; one that has gone is said on the raw
/// port, the display left running. With a monitor on it, its scrambling
/// is looked after (`bcm2712.tend`). The modes the board lists stay as
/// they were made: a monitor that does not take the mode shows nothing
/// until another is set. Made holding `flip_lock`.
fn watch(screen: *Screen) void {
    const now = sdk.hardware.systimer.uptimeUs();
    if (now -% screen.watched_us < watch_us - watch_us / 8) return;
    screen.watched_us = now;
    const waiter = Waiter{ .screen = screen };
    const plugged = bcm2712.monitor();
    if (plugged == screen.plugged) {
        screen.settling = 0;
        if (plugged) bcm2712.tend(waiter);
        return;
    }
    screen.settling += 1;
    if (screen.settling < settle_looks) return;
    screen.settling = 0;
    screen.plugged = plugged;
    if (!plugged) {
        exec.kprintf(screen.sys, "%s: the monitor was taken off the HDMI port\n", .{MODULE_NAME});
        return;
    }
    const current = &screen.timings.modes[screen.current];
    const found = portModes(bcm2712, screen, current.*);
    for (found.modes[0..found.count]) |*timing| {
        if (timing.sameAs(current)) {
            current.* = timing.*;
            break;
        }
    } else exec.kprintf(screen.sys, "%s: the monitor does not name %dx%d at %d Hz\n", .{ MODULE_NAME, current.width, current.height, current.hz() });
    const failure = bcm2712.start(screen.sys, current, screen.sink, screen.scanning, screen.pitch, waiter);
    if (failure != .none) {
        exec.kprintf(screen.sys, "%s: %s\n", .{ MODULE_NAME, bcm2712.why(failure) });
        return;
    }
    putBack(screen);
}

/// `box` of the display noted for the next picture. Made holding
/// `damage_lock`.
fn noteBox(screen: *Screen, box: Box) void {
    screen.fresh.add(box);
}

/// Where an image is on the picture noted, if it is on it. Made holding
/// `damage_lock`.
fn noteImage(screen: *Screen, given: ?*const rtg.RtgPointerImage, left: i32, top: i32) void {
    const image = given orelse return;
    const clip = clipOf(screen, image, left, top) orelse return;
    noteBox(screen, clip.box());
}

/// `area` of `bitmap` written: noted where the bands show it, and the task
/// woken. Nothing is written back - the display does not read the buffer -
/// but where it reads it itself (`directOf`): there it is written out at
/// once, and the task takes the frames up again.
fn noteWritten(screen: *Screen, bitmap: *const rtg.RtgBitMap, area: Box) void {
    if (area.isEmpty()) return;
    const sys = screen.sys;
    var noted = false;
    sys.AcquireLock(&screen.damage_lock);
    for (screen.bands[0..screen.band_count], 0..) |band, i| {
        if (band.bitmap != bitmap) continue;
        const band_end = if (i + 1 < screen.band_count) screen.bands[i + 1].line else screen.height;
        const lines = band.linesOf(area.top, area.end, band_end);
        if (lines.first >= lines.end) continue;
        noteBox(screen, .{ .left = area.left, .top = lines.first, .right = area.right, .end = lines.end });
        noted = true;
    }
    if (noted) screen.written = true;
    const read = noted and screen.direct == bitmap;
    sys.ReleaseLock(&screen.damage_lock);
    if (read) handOn(screen, bitmap, area);
    if (noted) sys.SignalWaitable(&screen.work);
}

/// The overlay as a picture is made with it.
const Laid = struct { image: ?*const rtg.RtgPointerImage, left: i32, top: i32 };

/// The next picture made in the frame the display is not reading, and
/// switched to: what was noted since the last one and what went into
/// that one, which this frame has not had, copied in from the bands with
/// the overlay laid over it and written out of the caches; then the
/// display told to read this frame, which it takes up as the next frame
/// starts - waited for, since until then it reads the other, which the
/// next picture is made in. False, and nothing switched, when nothing was
/// noted. Where the display read a buffer itself, neither frame has had
/// what it showed: the picture is made whole, and the next one too. Made
/// holding `flip_lock`.
fn flipFrames(screen: *Screen) bool {
    const sys = screen.sys;
    sys.AcquireLock(&screen.damage_lock);
    const fresh = screen.fresh;
    screen.fresh = .{};
    const over = Laid{ .image = screen.overlay, .left = screen.overlay_left, .top = screen.overlay_top };
    const stale = screen.direct != null and !fresh.isEmpty();
    if (stale) screen.direct = null;
    sys.ReleaseLock(&screen.damage_lock);
    if (fresh.isEmpty()) return false;
    const back = screen.flip_frames[screen.front ^ 1];
    var boxes = fresh;
    if (stale) boxes.add(whole(screen)) else boxes.addAll(&screen.last);
    sys.ObtainSemaphore(&screen.bands_lock);
    for (boxes.list()) |box| makeBox(screen, back, box, over);
    sys.ReleaseSemaphore(&screen.bands_lock);
    screen.last = if (stale) boxes else fresh;
    scanFrom(screen, @intFromPtr(back));
    pace(screen, 1);
    screen.front ^= 1;
    screen.updates +%= 1;
    return true;
}

/// One rectangle of a picture, in the frame at `into`: each row from its
/// band, black where nothing is shown, the overlay laid over it, and
/// written out of the caches.
fn makeBox(screen: *Screen, into: [*]u8, box: Box, over: Laid) void {
    var picture = pictureAt(screen, into);
    if (screen.band_count == 0) {
        const area = rtg.RtgRect{
            .x = @intCast(box.left),
            .y = @intCast(box.top),
            .width = @intCast(box.right - box.left),
            .height = @intCast(box.end - box.top),
        };
        _ = engine.fill(&screen.engine, &picture, &area, 0);
    } else {
        copyInto(screen, into, box);
    }
    _ = layOver(screen, into, over.image, over.left, over.top, box);
    handOn(screen, &picture, box);
}

/// What the display shows changed - `bands`, none for black - and the
/// picture of it made and waited for, as a flip is: the rows that show
/// something else than before, nothing when none does; or a buffer the
/// display reads itself (`directOf`), and that waited for.
fn showFlipped(screen: *Screen, bands: []const rtg.RtgBand) void {
    const sys = screen.sys;
    sys.ObtainSemaphore(&screen.flip_lock);
    defer sys.ReleaseSemaphore(&screen.flip_lock);
    sys.AcquireLock(&screen.damage_lock);
    const direct = directOf(screen, bands);
    var changed: damage.Damage = .{};
    changed.rebanded(screen.bands[0..screen.band_count], bands, screen.width, screen.height);
    @memcpy(screen.bands[0..bands.len], bands);
    screen.band_count = @intCast(bands.len);
    screen.showing = if (bands.len == 0) null else bands[bands.len - 1].bitmap;
    screen.written = false;
    if (direct != null) {
        // The frames are made whole when they are taken up again.
        screen.fresh = .{};
        screen.direct = direct;
    } else {
        for (changed.list()) |box| noteBox(screen, box);
    }
    sys.ReleaseLock(&screen.damage_lock);
    if (direct) |bitmap| return showDirect(screen, bitmap);
    _ = flipFrames(screen);
}

/// The buffer the display can read itself in place of a frame, as `bands`
/// show it: one whole buffer - the display's size, rows and format, from
/// its first row - shown in place of another nothing was written in while
/// it was shown, or in place of itself while the display reads it so, and
/// nothing laid over the picture by the cores. That is a program that
/// draws a picture in one buffer while it shows the other and then shows
/// that one (ChangeScreenBuffer, facet.library's swapchains): its buffers
/// are read as they are, and nothing is copied. A screen drawn in while
/// it is shown - intuition's windows - is shown frames as before. On the
/// BCM2712's port. Asked holding `damage_lock`.
fn directOf(screen: *const Screen, bands: []const rtg.RtgBand) ?*const rtg.RtgBitMap {
    if (screen.scanout != .bcm2712 or screen.overlay != null or screen.written) return null;
    if (bands.len != 1 or screen.band_count != 1) return null;
    const new = bands[0];
    const old = screen.bands[0];
    if (!wholeBand(screen, new) or !wholeBand(screen, old)) return null;
    if (new.bitmap == old.bitmap and screen.direct != new.bitmap) return null;
    return new.bitmap;
}

/// Whether `band` is a whole buffer the display could be shown.
fn wholeBand(screen: *const Screen, band: rtg.RtgBand) bool {
    return band.line == 0 and band.origin == 0 and band.flags & rtg.RTGBANDF_REPEAT == 0 and showable(screen, band.bitmap);
}

/// `bitmap` read by the display itself: written out of the caches whole -
/// nothing of it was as it was drawn - and the display told to read it,
/// which it takes up as the next frame starts: waited for, since until
/// then it reads what it read before. Nothing where it reads it already.
/// Made holding `flip_lock`.
fn showDirect(screen: *Screen, bitmap: *const rtg.RtgBitMap) void {
    const address = @intFromPtr(bitmap.pixels.?);
    if (address == screen.scanning) return;
    handOn(screen, bitmap, whole(screen));
    scanFrom(screen, address);
    pace(screen, 1);
    screen.updates +%= 1;
}

/// The display brought up, or changed to the mode taken, black: both
/// frames cleared and written back, nothing shown in them until a buffer
/// is again, and the display reading the first. False when it did not
/// come up.
fn beginFlipped(screen: *Screen) bool {
    const sys = screen.sys;
    sys.ObtainSemaphore(&screen.flip_lock);
    defer sys.ReleaseSemaphore(&screen.flip_lock);
    const bytes = @as(usize, screen.pitch) * screen.height;
    for (screen.flip_frames) |frame| {
        @memset(frame[0..bytes], 0);
        writeBack(screen, frame, bytes);
    }
    sys.AcquireLock(&screen.damage_lock);
    screen.band_count = 0;
    screen.showing = null;
    screen.fresh = .{};
    screen.written = false;
    screen.direct = null;
    sys.ReleaseLock(&screen.damage_lock);
    screen.last = .{};
    screen.front = 0;
    // What it read until now says nothing about the new mode.
    screen.scanning = 0;
    return begin(screen, @intFromPtr(screen.flip_frames[0]));
}

/// The overlay's image changed, its old and new places noted. The image
/// laid until now is not read again once this returns: a picture being
/// made with it is waited out.
fn overlayFlipped(screen: *Screen, image: ?*const rtg.RtgPointerImage) void {
    const sys = screen.sys;
    sys.ObtainSemaphore(&screen.flip_lock);
    sys.AcquireLock(&screen.damage_lock);
    noteImage(screen, screen.overlay, screen.overlay_left, screen.overlay_top);
    screen.overlay = image;
    noteImage(screen, image, screen.overlay_left, screen.overlay_top);
    sys.ReleaseLock(&screen.damage_lock);
    sys.ReleaseSemaphore(&screen.flip_lock);
    sys.SignalWaitable(&screen.work);
}

/// The overlay moved, its old and new places noted.
fn overlayMoved(screen: *Screen, left: i32, top: i32) void {
    const sys = screen.sys;
    sys.AcquireLock(&screen.damage_lock);
    noteImage(screen, screen.overlay, screen.overlay_left, screen.overlay_top);
    screen.overlay_left = left;
    screen.overlay_top = top;
    noteImage(screen, screen.overlay, left, top);
    sys.ReleaseLock(&screen.damage_lock);
    sys.SignalWaitable(&screen.work);
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
        // Nor of the BCM2712's before the firmware has its clocks running.
        st.CHIP_BCM2712_HVS => .bcm2712,
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
    if (isHdmi(scanout)) {
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

    // At most as many pictures of the largest mode as the board asks for,
    // each taken by the library as it is allocated, from memory every
    // display here reaches. Not cleared: each is cleared before it is
    // first shown. The composed frame is taken as it is needed, the
    // cursor plane's two images now.
    var frame: usize = 0;
    for (screen.modes[0..screen.mode_count]) |*mode| frame = @max(frame, @as(usize, mode.pitch) * mode.height);
    screen.frame_bytes = frame;
    const frames: u32 = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list))), 1);
    if (scanout != .ramfb) {
        const own = takeOwn(screen, 2 * cursor_bytes) orelse {
            if (scanout == .virtio) virtio.stop(&screen.scanout.virtio);
            return err.RTGERR_NO_MEMORY;
        };
        screen.cursor_memory = own.memory;
        screen.cursor = own.at;
    }
    if (scanout == .bcm2712) {
        if (takeOwn(screen, 2 * overlay_bytes)) |own| {
            screen.overlay_memory = own.memory;
            screen.overlay_images = own.at;
        }
    }
    // A display that reads past the caches is shown frames of the
    // driver's own, never a buffer drawn in.
    if (isHdmi(scanout) and !startFlipping(screen)) {
        if (screen.cursor_memory) |memory| sys.FreeMem(memory, 2 * cursor_bytes + page);
        if (screen.overlay_memory) |memory| sys.FreeMem(memory, 2 * overlay_bytes + page);
        screen.cursor_memory = null;
        screen.cursor = null;
        screen.overlay_memory = null;
        screen.overlay_images = null;
        return err.RTGERR_NO_MEMORY;
    }
    board.region = .{
        .size = frames * frame,
        .alignment = row_alignment,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED |
            rtg.boards.RTGRF_SYSTEM_MEMORY | rtg.boards.RTGRF_DMA_MEMORY,
    };
    board.ops = switch (scanout) {
        .bcm2712 => &bcm2712_ops,
        .jh7110 => &jh7110_ops,
        else => &ops,
    };
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
    stopFlipping(screen);
    if (screen.frame_hooked) screen.sys.RemIntServer(screen.frame_irq, &screen.frame_int);
    screen.frame_hooked = false;
    if (screen.timer_open) screen.sys.CloseDevice(&screen.timer_io.node);
    screen.timer_open = false;
    if (screen.composed_memory) |memory| screen.sys.FreeMem(memory, screen.frame_bytes + page);
    if (screen.cursor_memory) |memory| screen.sys.FreeMem(memory, 2 * cursor_bytes + page);
    if (screen.overlay_memory) |memory| screen.sys.FreeMem(memory, 2 * overlay_bytes + page);
    screen.overlay_memory = null;
    screen.overlay_images = null;
    screen.composed_memory = null;
    screen.composed = null;
    screen.cursor_memory = null;
    screen.cursor = null;
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

/// The modes of the monitor on the HDMI port (`monitor.zig`), from its
/// EDID; the monitor's name, how many modes it has and the one it gets
/// said on the raw port. The board's own alone when no monitor is on the
/// port (which `begin` says), or its EDID does not read.
fn hdmiModes(screen: *Screen, own: edid.Timing) monitor.List {
    return switch (screen.scanout) {
        .bcm2712 => portModes(bcm2712, screen, own),
        else => portModes(jh7110, screen, own),
    };
}

/// `hdmiModes` on the port `port` drives (`jh7110.zig`, `bcm2712.zig`).
fn portModes(comptime port: type, screen: *Screen, own: edid.Timing) monitor.List {
    const waiter = Waiter{ .screen = screen };
    screen.sink = .{};
    if (port.wake(screen.sys, waiter) != .none or !port.monitor()) return monitor.modesOf(null, null, own, port.sends);
    var first: edid.Block = undefined;
    var extension: edid.Block = undefined;
    var name: [14]u8 = @splat(0);
    var base: ?*const edid.Block = null;
    var cea: ?*const edid.Block = null;
    if (port.readEdid(0, &first, waiter) and edid.isFirst(&first) and edid.valid(&first)) {
        base = &first;
        edid.name(&first, &name);
        if (first[126] != 0 and port.readEdid(1, &extension, waiter) and edid.valid(&extension)) cea = &extension;
    }
    const found = monitor.modesOf(base, cea, own, port.sends);
    if (base != null) screen.sink = edid.sinkOf(cea);
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
/// black: the composed frame cleared, given back once a buffer is shown.
fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode) callconv(.c) i32 {
    const screen = screenOf(board);
    const index = mode.id -% 1;
    if (index >= screen.mode_count or mode.format != screen.format) return err.RTGERR_BAD_MODE;
    const changed = index != screen.current;
    take(screen, index);
    if (flips(screen) and (screen.scanning == 0 or changed)) {
        if (!beginFlipped(screen)) return err.RTGERR_NO_DISPLAY;
    } else if (screen.scanning == 0 or changed) {
        hold(screen);
        defer letGo(screen);
        const black = ownFrame(screen) orelse return err.RTGERR_NO_MEMORY;
        const bytes = @as(usize, screen.pitch) * screen.height;
        @memset(black[0..bytes], 0);
        handOn(screen, &pictureAt(screen, black), whole(screen));
        // What it read until now says nothing about the new mode.
        screen.scanning = 0;
        if (!begin(screen, @intFromPtr(black))) return err.RTGERR_NO_DISPLAY;
    }
    board.info.width = screen.width;
    board.info.height = screen.height;
    board.info.format = screen.format;
    board.info.pitch = screen.pitch;
    board.info.pixel_clock_hz = screen.modes[index].pixel_clock_hz;
    board.info.refresh_mhz = screen.modes[index].refresh_mhz;
    return err.RTGERR_OK;
}

/// What the HDMI ports' `start` waits with.
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
        .jh7110 => startPort(jh7110, screen, address),
        .bcm2712 => startPort(bcm2712, screen, address),
    }
    return screen.scanning == address;
}

/// `begin` on the HDMI port `port` drives: the mode set - on the
/// BCM2712's, sent as the monitor takes it (`Screen.sink`) - and the
/// frame interrupt hooked once it runs.
fn startPort(comptime port: type, screen: *Screen, address: usize) void {
    const mode = &screen.timings.modes[screen.current];
    const waiter = Waiter{ .screen = screen };
    const failure = if (port == bcm2712)
        port.start(screen.sys, mode, screen.sink, address, screen.pitch, waiter)
    else
        port.start(screen.sys, mode, address, screen.pitch, waiter);
    if (failure != .none) {
        exec.kprintf(screen.sys, "%s: %s\n", .{ MODULE_NAME, port.why(failure) });
        return;
    }
    screen.scanning = address;
    if (port == bcm2712) putBack(screen);
    if (port == jh7110) videoPutBack(screen);
    screen.plugged = port.monitor();
    screen.settling = 0;
    if (!screen.plugged) exec.kprintf(screen.sys, "%s: no monitor on the HDMI port\n", .{MODULE_NAME});
    hookFrames(screen);
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
    if (flips(screen)) {
        if (bitmap) |bm| {
            showFlipped(screen, &[_]rtg.RtgBand{.{ .bitmap = bm }});
        } else {
            showFlipped(screen, &.{});
        }
        return err.RTGERR_OK;
    }
    // A flip from one picture to another takes a frame. The first picture
    // shown is not waited for: it comes up at cold start.
    var unused: ?*anyopaque = null;
    const flip = flip: {
        hold(screen);
        defer letGo(screen);
        if (bitmap == null and ownFrame(screen) == null) return err.RTGERR_NO_MEMORY;
        const another = screen.showing != null and bitmap != null and (screen.showing != bitmap or screen.band_count > 1);
        const was = composing(screen);
        var old: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined;
        const old_count = screen.band_count;
        @memcpy(old[0..old_count], screen.bands[0..old_count]);
        screen.showing = bitmap;
        screen.band_count = 0;
        if (bitmap) |bm| {
            screen.bands[0] = .{ .bitmap = bm };
            screen.band_count = 1;
            provide(screen);
            reband(screen, old[0..old_count], was);
            present(screen);
        } else {
            const black = screen.composed.?;
            const bytes = @as(usize, screen.pitch) * screen.height;
            @memset(black[0..bytes], 0);
            handOn(screen, &pictureAt(screen, black), whole(screen));
            scanFrom(screen, @intFromPtr(black));
        }
        unused = spare(screen);
        break :flip another;
    };
    // Waited out with the frame let go: the pointer moves meanwhile.
    if (flip) pace(screen, 1);
    giveBack(screen, unused);
    return err.RTGERR_OK;
}

/// Rows were written by the CPU: handed on, and into the composed frame
/// while the display reads that - those of them the bands show, and the
/// pointer back over them where they cross it.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    const first = if (rows == 0) 0 else @min(y, bitmap.height);
    const last = if (rows == 0) bitmap.height else @min(y +| rows, bitmap.height);
    if (flips(screen)) {
        noteWritten(screen, bitmap, .{ .left = 0, .top = first, .right = @min(bitmap.width, screen.width), .end = last });
        return err.RTGERR_OK;
    }
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
    if (flips(screen)) {
        noteWritten(screen, bitmap, .{ .left = box.left, .top = box.top, .right = @min(box.right, screen.width), .end = box.end });
        return err.RTGERR_OK;
    }
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

/// Several buffers at once, in bands: composed - the rows that show
/// something else than before - shown, and a frame waited out, as a flip
/// is. With no memory to compose them in, the last alone,
/// as a board that cannot show bands would show it.
fn showBands(board: *rtg.RtgBoard, bands: [*]const rtg.RtgBand, count: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    for (bands[0..count]) |band| {
        const bm = band.bitmap;
        if (bm.pixels == null or bm.pitch != screen.pitch or bm.format != screen.format) return err.RTGERR_NOT_DISPLAYABLE;
    }
    if (flips(screen)) {
        showFlipped(screen, bands[0..count]);
        return err.RTGERR_OK;
    }
    var code = err.RTGERR_OK;
    var unused: ?*anyopaque = null;
    const was_shown = shown: {
        hold(screen);
        defer letGo(screen);
        const before = screen.showing != null;
        const was = composing(screen);
        var old: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined;
        const old_count = screen.band_count;
        @memcpy(old[0..old_count], screen.bands[0..old_count]);
        @memcpy(screen.bands[0..count], bands[0..count]);
        screen.band_count = count;
        screen.showing = bands[count - 1].bitmap;
        provide(screen);
        if (count > 1 and screen.composed == null) {
            screen.bands[0] = .{ .bitmap = bands[count - 1].bitmap };
            screen.band_count = 1;
            code = err.RTGERR_NO_MEMORY;
        }
        reband(screen, old[0..old_count], was);
        present(screen);
        unused = spare(screen);
        break :shown before;
    };
    if (was_shown) pace(screen, 1);
    giveBack(screen, unused);
    return code;
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
    const screen = screenOf(board);
    const held = holdBands(screen, dest);
    defer if (held) screen.sys.ReleaseSemaphore(&screen.bands_lock);
    return engine.copy(&screen.engine, src, dest, what);
}

fn copyRects(board: *rtg.RtgBoard, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, list: [*]const rtg.RtgCopy, count: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    const held = holdBands(screen, dest);
    defer if (held) screen.sys.ReleaseSemaphore(&screen.bands_lock);
    return engine.copyMany(&screen.engine, src, dest, list, count);
}

/// `bands_lock` taken where the display's picture is made from `dest`:
/// whether it was. A buffer changing bands meanwhile is a flip, whose picture
/// is made whole after it.
fn holdBands(screen: *Screen, dest: *const rtg.RtgBitMap) bool {
    if (!flips(screen)) return false;
    for (screen.bands[0..screen.band_count]) |band| {
        if (band.bitmap != dest) continue;
        screen.sys.ObtainSemaphore(&screen.bands_lock);
        return true;
    }
    return false;
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
    .copy_rects = &copyRects,
};

/// The BCM2712's port's: the same, and what its hardware does besides -
/// the display switched off, the monitor's brightness, the picture
/// mirrored.
const bcm2712_ops = ops: {
    var more = ops;
    more.display = &display;
    more.set_brightness = &setBrightness;
    more.brightness = &brightness;
    more.mirror = &mirror;
    break :ops more;
};

/// The JH7110's port's: the same, and a video layer, its first overlay.
const jh7110_ops = ops: {
    var more = ops;
    more.video_open = &videoOpen;
    more.video_close = &videoClose;
    more.video_show = &videoShow;
    more.video_move = &videoMove;
    break :ops more;
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

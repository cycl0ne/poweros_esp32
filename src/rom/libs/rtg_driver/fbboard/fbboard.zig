// SPDX-License-Identifier: MPL-2.0
//! A display whose picture is in the machine's RAM, as a display board:
//! QEMU virt's ramfb (`ramfb.zig`), the JH7110's display controller
//! behind its HDMI port (`jh7110.zig`) and the BCM2712's video scaler
//! behind its first one (`bcm2712.zig`), which read it out of RAM by
//! themselves, QEMU's virtio GPU (`virtio.zig`), which is told what
//! changed, and the framebuffer a UEFI firmware has already lit
//! (`uefi.zig`), which reads the one buffer it was given - behind which
//! the engine doing the reading is looked at where it is one this knows
//! (`dcn.zig`, through amdgpu.resource, which holds the device), to say
//! what it is, to switch on the sound the link it lit can carry, and to
//! flip it between that buffer and a frame of the device's own.
//!
//! A module of its own, on the same footing as the other drivers: a
//! description of a driver called "fb" behind a ROM tag, which
//! rtg.library puts on its list. It takes a panel part of one of the
//! chips above and a virtio GPU's function on PCI, and makes a board of
//! each it is offered: a machine with two of them has two boards.
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
//! The ramfb and the firmware's framebuffer have one mode, the size the
//! board names. The others have a connector, and their modes are
//! rtg.library's to make: the driver says what is on it (`detect`) - an
//! HDMI port's monitor and its EDID, read over the port's DDC, the virtio
//! GPU's window as the emulator describes it - and which timings the
//! display can make (`checkMode`), and the library lists the modes the
//! monitor names; the one it prefers is the default, and any of them can
//! be set. A monitor plugged in later is said to the library
//! (`MonitorChanged`, from `watch`), which asks again and has the port
//! started again for it. The virtio GPU's own mode, the size QEMU's
//! window has for it, stands where its EDID names none.
//!
//! The buffers are the machine's RAM below 4 GiB, which every display here
//! reaches (MEMF_DMA): the library takes each when it is allocated and
//! gives it back when it is freed (RTGRF_SYSTEM_MEMORY, RTGRF_DMA_MEMORY),
//! at most as many pictures of the mode the display is in as the board
//! asks for (RTGA_Buffers) - so a screen nobody has opened costs nothing. The
//! driver's own are a frame for a picture that is not one buffer - two
//! the display is shown, behind an HDMI port - and, on a display with a
//! cursor plane, the plane's two images.
//!
//! **A display that is not flipped** - the ramfb, the virtio GPU, the
//! firmware's framebuffer with no engine behind it that this knows - has
//! its picture composed by rtg.library. With nothing over the picture
//! the ramfb and the virtio GPU read the shown buffer themselves, and
//! nothing is copied. While a pointer or the overlay is shown, or the
//! picture is several in bands, the display reads a frame of the
//! driver's own instead: the board is told which rectangle of the display
//! changed (`update`) and fetches it from the library into that frame
//! (`ComposeLines`), no wider than what was written, so a pointer's move
//! costs the pointer's size and not the picture's. The firmware's
//! framebuffer is such a frame already, the only thing the display
//! reads: the library's picture is fetched straight into it, at the
//! firmware's own row length.
//!
//! The frame of the driver's own is taken when it is first needed. Where
//! the pointer is the display's own, on the virtio GPU, it is given back
//! once the display reads a buffer again, so it is there only while a
//! screen is pulled down or an icon dragged. On the ramfb, where the
//! pointer is laid in it, it stays. Black, as the display comes up or
//! when nothing is shown, is that frame cleared.
//!
//! The HDMI ports' displays read RAM past the caches, and the caches write
//! their lines back in an order of their own: a picture drawn over while
//! it is read shows, for a frame, a patchwork of old and new cache lines,
//! sixteen pixels each. So there the display never reads a buffer anybody
//! draws in, and the driver makes its pictures itself. It reads one of two frames of the
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
//! either: the overlay is the library's there, in the composed picture.
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
//! An AMD display behind the firmware's framebuffer is shown two frames
//! the same way, for a reason of its own: a picture copied into the one
//! buffer it reads, while it reads it, shows the top of one picture and
//! the bottom of the other. The frames are that buffer and one of the
//! device's own memory, both reached write-combining, so nothing is
//! written back: the gathered writes are fenced before the flip. The
//! engine takes a flip at the pipe's next update, between two frames,
//! and says when it has: a flip it has not taken two frames after the one
//! waited for puts the display back on the firmware's buffer for good,
//! each picture then made in it, and says so on the log. The display has
//! no cursor plane, so the pointer is laid in the pictures with the
//! overlay, its old and new places noted as a move is made.
//!
//! Where the display raises an interrupt at each frame (the board's part
//! gives it as PART_Irq; on the AMD display, the pipe's update, through
//! the device's interrupt ring), its server says the frame to the
//! library (`FrameDone`), and a flip and WaitVBlank wait for it;
//! elsewhere, and should it stop coming, the library waits as long as a
//! frame takes.
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

const ramfb = @import("ramfb.zig");
const jh7110 = @import("jh7110.zig");
const bcm2712 = @import("bcm2712.zig");
const virtio = @import("virtio.zig");
const uefi = @import("uefi.zig");
const dcn = @import("dcn.zig");
const engine = @import("engine.zig");
const damage = @import("damage.zig");
const tags = rtg.tags;
const timer = sdk.devices.timer;

const MODULE_NAME = "rtg-fb";
const DRIVER_NAME = "fb";
const VERSION = 1;
const REVISION = 41;
const BUILD_DATE = "16.11.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// What every row and every buffer starts on: whole cache lines, so a
/// refresh writes back exactly the rows it names, and as wide as any
/// display here fetches in one go.
const row_alignment = 128;
/// Where the block of buffers starts.
const page = 4096;

/// Which display, and what it was found to be.
const Scanout = union(enum) {
    ramfb: ramfb.Ramfb,
    jh7110,
    virtio: virtio.Gpu,
    bcm2712,
    uefi: uefi.Framebuffer,
};

/// Whether the display is behind an HDMI port, whose monitor names its
/// modes, and which reads past the caches with a cursor plane of its own.
fn isHdmi(scanout: Scanout) bool {
    return scanout == .jh7110 or scanout == .bcm2712;
}

/// Whether the display lays the pointer over the picture itself, in a
/// plane of its own: the HDMI ports' controllers do, and the virtio GPU.
/// On the others the pointer is laid into the composed frame.
fn hasCursorPlane(scanout: Scanout) bool {
    return scanout != .ramfb and scanout != .uefi;
}

/// Everything one board of this driver has. The library allocates it
/// beside the handle.
const Screen = struct {
    sys: *ExecBase,
    /// rtg.library, as the driver calls it.
    rtg_base: *RtgBase,
    scanout: Scanout,
    /// The picture: RTGA_Width by RTGA_Height in RTGA_PixelFormat, rows
    /// `pitch` bytes apart, `bytes` a pixel.
    width: u32 = 0,
    height: u32 = 0,
    format: rtg.PixelFormat = .bgra32,
    bytes: u32 = 4,
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
    /// Behind the firmware's framebuffer, the display engine reading it
    /// where that engine is one this driver knows: what it says of itself,
    /// read when the board is made (`dcn.zig`). Null on every other
    /// display, and on a machine whose engine this is not.
    dcn: ?dcn.Engine = null,
    /// On that engine: the frame of the device's own memory the display
    /// is flipped to and from the firmware's framebuffer, whether it still
    /// is - it is given up on once a flip is not taken - and the device's
    /// address of the frame last flipped to.
    amd_frame: ?sdk.resources.amdgpu.GPUMemory = null,
    amd_flipping: bool = false,
    flip_wanted: u64 = 0,
    /// Behind an HDMI port: what the monitor says of itself that decides
    /// how a mode is sent to it - HDMI or DVI, its range - as the library
    /// read it, taken as the mode is set; whether it was on the port when
    /// last looked at, how many looks in a row have seen otherwise, and
    /// when the port was last looked at (`watch`).
    sink: bcm2712.Sink = .{},
    plugged: bool = false,
    settling: u32 = 0,
    watched_us: u64 = 0,
    /// A picture of the largest mode the display has been in: what the
    /// composed frame takes, and each of the two frames a display is
    /// flipped between.
    frame_bytes: usize = 0,
    /// Where the display reads from; 0 before it has been told.
    scanning: usize = 0,
    /// The buffer at the display's bottom, as last shown, and on a
    /// display that is not flipped whether a picture is shown at all.
    showing: ?*rtg.RtgBitMap = null,
    shown: bool = false,
    /// How many times the display has been handed a picture.
    updates: u32 = 0,
    /// timer.device, opened the first time a frame is waited for: the
    /// request each wait copies.
    timer_io: timer.TimeRequest = .{},
    timer_open: bool = false,
    /// On a display that is not flipped and reads a frame of the
    /// driver's own: the frame the library's picture is fetched into and
    /// black is shown from, as AllocMem gave it and where it starts.
    /// Null until it is needed (`ownFrame`), and on the virtio GPU again
    /// once the display reads a buffer (`dropFrame`).
    composed_memory: ?*anyopaque = null,
    composed: ?[*]u8 = null,
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
    /// none), its server and whether that is on.
    frame_irq: u32 = 0,
    frame_int: exec.Interrupt = .{},
    frame_hooked: bool = false,
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

/// Wait for `frames` frames, as the library waits (WaitVBlank): for the
/// display's frame interrupt to come that many times, where it comes, so
/// that a flip is waited out to the frame the new picture starts in;
/// else for as long as they take, which is what makes a program that
/// paces itself by the display run at the speed it would on one that
/// says when a frame begins. The CPU is given away meanwhile, either way.
fn pace(screen: *Screen, frames: u32) void {
    _ = screen.rtg_base.WaitVBlank(screen.board, frames);
}

/// The display's interrupt: the frame said to the library, which counts
/// it and wakes whoever waits for one.
fn frameServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const screen: *Screen = @ptrCast(@alignCast(data.?));
    const raised: u32 = switch (screen.scanout) {
        .bcm2712 => bcm2712.takeInterrupts(),
        // The device's ring hands on the pipe's update alone.
        .uefi => taken: {
            dcn.takeFrame(screen.dcn.?);
            break :taken 1;
        },
        else => jh7110.takeInterrupts(),
    };
    if (raised == 0) return 0;
    drivers(screen).FrameDone(screen.board);
    return 1;
}

/// The frame interrupt's server on, once the display runs: the board
/// part's interrupt behind an HDMI port, the pipe's update through the
/// device's interrupt ring on the AMD display (`dcn.hookFrames`).
fn hookFrames(screen: *Screen) void {
    if (screen.frame_hooked) return;
    if (screen.frame_irq == 0 and screen.dcn == null) return;
    screen.frame_int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = screen,
        .code = &frameServer,
    };
    if (screen.dcn) |found| {
        screen.frame_hooked = dcn.hookFrames(found, &screen.frame_int);
        if (!screen.frame_hooked) exec.kprintf(screen.sys, "%s: the display's frames cannot be had from the device, so they are timed by the clock\n", .{MODULE_NAME});
        return;
    }
    screen.sys.AddIntServer(screen.frame_irq, &screen.frame_int);
    screen.frame_hooked = true;
}

/// The frame interrupt's server off again.
fn unhookFrames(screen: *Screen) void {
    if (!screen.frame_hooked) return;
    if (screen.dcn) |found| {
        dcn.unhookFrames(found, &screen.frame_int);
    } else {
        screen.sys.RemIntServer(screen.frame_irq, &screen.frame_int);
    }
    screen.frame_hooked = false;
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

/// `length` bytes at `from`, which the CPU has written, written back out
/// of the caches, where the machine's display goes past them. Nothing on
/// the firmware's framebuffer: the display reads only what is reached
/// write-combining there, and the buffers drawn in are read by the cores.
fn writeBack(screen: *Screen, from: [*]u8, length: usize) void {
    if (length == 0 or screen.scanout == .uefi) return;
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
    const bytes = screen.rtg_base.RtgFormatBits(@intFromEnum(picture.format)) / 8;
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
        // The firmware's framebuffer is what the display reads: where
        // it is not flipped, the library's picture is fetched straight
        // into it (`update`), and where it is, what is handed on is a
        // frame of its own.
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
/// Whether it does: a device that refuses goes on reading where it read.
fn scanFrom(screen: *Screen, address: usize) bool {
    if (address == screen.scanning) return true;
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
        // The AMD display flipped to the frame, from the pipe's next
        // update on (`dcn.flip`), named by the device's own address of
        // it: the framebuffer's the fetcher read at start, the frame's
        // the resource gave with it. The frame is not in the window the
        // framebuffer is in - on a machine whose device memory is part of
        // its RAM the CPU reaches it there - so its address in the
        // machine says nothing of the device's. Where it is not flipped,
        // nothing tells it to read elsewhere: it reads the one buffer
        // the firmware gave it, which the picture is fetched into. Where
        // flipping was given up, the frames are that buffer.
        .uefi => done: {
            if (screen.amd_flipping) {
                const found = screen.dcn.?;
                const frame = screen.amd_frame.?;
                screen.flip_wanted = if (address == @intFromPtr(screen.flip_frames[1])) frame.device else found.surface;
                dcn.flip(found, screen.flip_wanted, false);
            }
            break :done true;
        },
    };
    if (shown) screen.scanning = address;
    return shown;
}

// --- the driver's own frame -------------------------------------------------

/// Memory of the driver's own: `bytes` from a page on, where every display
/// here reads, the system's and not the task's that happened to ask - what
/// AllocMem gave, and where the page starts.
const Own = struct { memory: *anyopaque, at: [*]u8 };

fn takeOwn(screen: *Screen, bytes: usize) ?Own {
    const memory = screen.sys.AllocMem(bytes + page, exec.MEMF_DMA | exec.MEMF_SYSTEM) orelse return null;
    return .{ .memory = memory, .at = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(memory), page)) };
}

/// The frame of the driver's own that the library's picture is fetched
/// into, and black is shown from, taken when there is none yet; null
/// without memory. Not cleared: it is written whole before the display
/// reads it.
fn ownFrame(screen: *Screen) ?[*]u8 {
    if (screen.composed) |frame| return frame;
    const own = takeOwn(screen, screen.frame_bytes) orelse return null;
    screen.composed_memory = own.memory;
    screen.composed = own.at;
    return own.at;
}

/// That frame given back, on a display that has it only while something
/// lies over the picture: the virtio GPU, whose pointer is the host's
/// own, so the frame is there only while a screen is pulled down or an
/// icon dragged. The GPU forgets its copy, so that a buffer the library
/// makes in the same memory later is copied whole. On the ramfb, where
/// the pointer is laid in it - hidden at every key and shown again at
/// every move of the mouse - it stays.
fn dropFrame(screen: *Screen) void {
    const frame = screen.composed orelse return;
    switch (screen.scanout) {
        .virtio => |*gpu| virtio.forget(gpu, @intFromPtr(frame), Waiter{ .screen = screen }),
        else => return,
    }
    if (screen.composed_memory) |memory| screen.sys.FreeMem(memory, screen.frame_bytes + page);
    screen.composed = null;
    screen.composed_memory = null;
}

const Box = damage.Box;

/// The buffer row display line `y` of a band shows: that far below the
/// band's origin, the first where the band repeats one row.
fn rowOf(band: rtg.RtgBand, y: u32) u32 {
    return if (band.flags & rtg.RTGBANDF_REPEAT != 0) 0 else y - band.origin;
}

/// Whether pixel (x, y) of an image is the image's own, by its mask.
fn opaqueAt(image: *const rtg.RtgPointerImage, x: u32, y: u32) bool {
    return image.mask[y * image.mask_pitch + x / 8] & (@as(u8, 0x80) >> @intCast(x % 8)) != 0;
}

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
            .src_y = @intCast(rowOf(band, first)),
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
        const from = band.bitmap.pixels.? + rowOf(band, y) * screen.pitch;
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
            if (!opaqueAt(image, image_x, image_y)) continue;
            switch (screen.bytes) {
                2 => @as([*]u16, @ptrCast(@alignCast(into)))[x] = @as([*]const u16, @ptrCast(@alignCast(row)))[image_x],
                else => @as([*]u32, @ptrCast(@alignCast(into)))[x] = @as([*]const u32, @ptrCast(@alignCast(row)))[image_x],
            }
        }
    }
    return clip;
}

// --- the pointer and the overlay a display lays itself ---------------------
//
// A cursor plane, the BCM2712's overlay plane, and the pictures a flipped
// display is shown: the boards that name these ops. Where the picture is
// one the library composes, the library lays both, and these are not in
// the board's table.

fn setPointer(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    const screen = screenOf(board);
    if (image) |one| {
        if (one.format != screen.format) return err.RTGERR_BAD_FORMAT;
    }
    if (screen.cursor != null) {
        cursorImage(screen, image);
        return err.RTGERR_OK;
    }
    pointerFlipped(screen, image);
    return err.RTGERR_OK;
}

fn movePointer(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const screen = screenOf(board);
    if (screen.cursor != null) {
        screen.pointer_left = left;
        screen.pointer_top = top;
        return cursorPlane(screen);
    }
    pointerMoved(screen, left, top);
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
    pointerShown(screen, show);
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
                if (opaqueAt(one, x, y)) pixels[y * side + x] = row[x] | 0xFF00_0000;
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
    overlayFlipped(screen, image);
    return err.RTGERR_OK;
}

fn moveOverlay(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const screen = screenOf(board);
    if (screen.overlay_images != null) {
        screen.overlay_left = left;
        screen.overlay_top = top;
        return overlayPlane(screen);
    }
    overlayMoved(screen, left, top);
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
            pixels[y * side + x] = if (opaqueAt(one, x, y)) row[x] | 0xFF00_0000 else 0;
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
/// the buffers themselves: where it reads past the caches, and on the AMD
/// display, which would otherwise be copied into while it is read.
fn flips(screen: *const Screen) bool {
    return screen.flipper != null;
}

/// The task that makes the pictures started, and the two frames taken
/// (`takeFrames`) where the picture's size is known already - the AMD
/// display's; an HDMI port's are taken with the mode it is put in
/// (`sizeFor`). False where there are no frames, or no task.
fn startFlipping(screen: *Screen, with_frames: bool) bool {
    const sys = screen.sys;
    if (with_frames and !takeFrames(screen)) return false;
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
        if (with_frames) giveFrames(screen);
        return false;
    };
    screen.flipper = made;
    @atomicStore(?*anyopaque, &made.user_data, screen, .release);
    sys.Signal(made, exec.SIGF_SINGLE);
    return true;
}

/// The two frames the display is flipped between. Behind an HDMI port
/// two of the driver's own, each a picture of the largest mode from a
/// page on, black and written back. On the AMD display the firmware's
/// framebuffer and a frame of the device's own memory (`dcn.newFrame`),
/// which the fetcher reads with the framebuffer's pitch - so only where
/// the board's rows are as far apart as the firmware's; they are cleared
/// as the mode is set (`beginFlipped`). False without memory for them, and
/// on the AMD display said why.
fn takeFrames(screen: *Screen) bool {
    if (screen.scanout == .uefi) {
        const fb = screen.scanout.uefi;
        const found = screen.dcn orelse return false;
        if (fb.pitch != screen.pitch or fb.height < screen.height) {
            exec.kprintf(screen.sys, "%s: the firmware's rows are %d bytes apart and the board's %d, so the picture is copied into its framebuffer\n", .{ MODULE_NAME, fb.pitch, screen.pitch });
            return false;
        }
        const frame = dcn.newFrame(found, screen.frame_bytes) orelse {
            exec.kprintf(screen.sys, "%s: no room in the device's memory for a frame, so the picture is copied into the firmware's framebuffer\n", .{MODULE_NAME});
            return false;
        };
        screen.amd_frame = frame;
        screen.amd_flipping = true;
        screen.flip_frames = .{ @ptrFromInt(fb.pixels), @ptrFromInt(@as(usize, @intCast(frame.cpu))) };
        exec.kprintf(screen.sys, "%s: the display is flipped between the firmware's framebuffer and a frame at 0x%lx\n", .{ MODULE_NAME, frame.device });
        return true;
    }
    const size = std.mem.alignForward(usize, screen.frame_bytes, page);
    const own = takeOwn(screen, 2 * size) orelse return false;
    @memset(own.at[0 .. 2 * size], 0);
    writeBack(screen, own.at, 2 * size);
    screen.flip_frames = .{ own.at, own.at + size };
    screen.flip_bytes = 2 * size;
    screen.flip_memory = own.memory;
    return true;
}

/// The frames given back. The AMD display's is only once the fetcher
/// reads the firmware's framebuffer again, told so at once: one it would
/// not leave is kept.
fn giveFrames(screen: *Screen) void {
    if (screen.flip_memory) |memory| screen.sys.FreeMem(memory, screen.flip_bytes + page);
    screen.flip_memory = null;
    var frame = screen.amd_frame orelse return;
    screen.amd_frame = null;
    screen.amd_flipping = false;
    const found = screen.dcn.?;
    dcn.flip(found, found.surface, true);
    var looks: u32 = 0;
    while (!dcn.flipTaken(found, found.surface)) : (looks += 1) {
        if (looks == 3) return;
        pace(screen, 1);
    }
    dcn.freeFrame(found, &frame);
}

/// The task stopped and the frames given back.
fn stopFlipping(screen: *Screen) void {
    const sys = screen.sys;
    if (screen.flipper == null) return;
    @atomicStore(bool, &screen.stopping, true, .release);
    sys.SignalWaitable(&screen.work);
    _ = sys.WaitForAny(&[_]*exec.Waitable{&screen.stopped}, 1, exec.WAIT_FOREVER);
    screen.flipper = null;
    giveFrames(screen);
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

/// Whether the task looks at the port now and then: an HDMI port's,
/// whose hot-plug line has no interrupt of its own here, once the
/// display runs.
fn watches(screen: *const Screen) bool {
    return isHdmi(screen.scanout) and screen.scanning != 0;
}

/// How long the task waits for work before it looks at the port again;
/// for good where it does not look.
fn untilWatch(screen: *const Screen) u64 {
    if (!watches(screen)) return exec.WAIT_FOREVER;
    const now = sdk.hardware.systimer.uptimeUs();
    const due = screen.watched_us + watch_us;
    return if (due > now + 1000) due - now else 1000;
}

/// The port looked at, when it is time: a monitor that has come or gone
/// - seen so for as many looks as it takes a plug to settle - is said to
/// the library (`MonitorChanged`), which asks what is there (`detect`),
/// makes the board's modes of it and has the port started again in the
/// mode it is in (`setMode`). With a monitor on the BCM2712's, its
/// scrambling is looked after (`bcm2712.tend`). Made holding
/// `flip_lock`.
fn watch(screen: *Screen) void {
    const now = sdk.hardware.systimer.uptimeUs();
    if (now -% screen.watched_us < watch_us - watch_us / 8) return;
    screen.watched_us = now;
    const waiter = Waiter{ .screen = screen };
    const plugged = switch (screen.scanout) {
        .bcm2712 => bcm2712.monitor(),
        else => jh7110.monitor(),
    };
    if (plugged == screen.plugged) {
        screen.settling = 0;
        if (plugged and screen.scanout == .bcm2712) bcm2712.tend(waiter);
        return;
    }
    screen.settling += 1;
    if (screen.settling < settle_looks) return;
    screen.settling = 0;
    screen.plugged = plugged;
    if (!plugged) exec.kprintf(screen.sys, "%s: the monitor was taken off the HDMI port\n", .{MODULE_NAME});
    drivers(screen).MonitorChanged(screen.board);
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
        // The display lines that show the rows written: all of a band
        // that repeats its buffer's first row, where that row is among
        // them.
        const repeats = band.flags & rtg.RTGBANDF_REPEAT != 0;
        if (repeats and area.top != 0) continue;
        const first = if (repeats) band.line else @max(band.line, area.top +| band.origin);
        const end = if (repeats) band_end else @min(band_end, area.end +| band.origin);
        if (first >= end) continue;
        noteBox(screen, .{ .left = area.left, .top = first, .right = area.right, .end = end });
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
    const pointer = Laid{
        .image = if (screen.cursor == null and screen.pointer_shown) screen.pointer else null,
        .left = screen.pointer_left,
        .top = screen.pointer_top,
    };
    const stale = screen.direct != null and !fresh.isEmpty();
    if (stale) screen.direct = null;
    sys.ReleaseLock(&screen.damage_lock);
    if (fresh.isEmpty()) return false;
    // An HDMI port has its frames from its first mode on.
    if (isHdmi(screen.scanout) and screen.flip_memory == null) return false;
    const back = screen.flip_frames[screen.front ^ 1];
    var boxes = fresh;
    if (stale) boxes.add(whole(screen)) else boxes.addAll(&screen.last);
    sys.ObtainSemaphore(&screen.bands_lock);
    for (boxes.list()) |box| makeBox(screen, back, box, over, pointer);
    sys.ReleaseSemaphore(&screen.bands_lock);
    screen.last = if (stale) boxes else fresh;
    _ = scanFrom(screen, @intFromPtr(back));
    pace(screen, 1);
    screen.updates +%= 1;
    if (!flipTaken(screen)) {
        giveUpFlipping(screen);
        return true;
    }
    screen.front ^= 1;
    return true;
}

/// Whether the display took the flip just made, the frame after it was
/// made waited for. Behind an HDMI port the controller takes it at that
/// frame. On the AMD display it is taken once the fetcher reads the new
/// frame (`dcn.flipTaken`) - looked at then, and after each of two
/// frames more: one made just as the pipe's update came is taken at the
/// next. The frame it read until then is not written before.
fn flipTaken(screen: *Screen) bool {
    if (!screen.amd_flipping) return true;
    const found = screen.dcn.?;
    var looks: u32 = 0;
    while (!dcn.flipTaken(found, screen.flip_wanted)) : (looks += 1) {
        if (looks == 2) return false;
        pace(screen, 1);
    }
    return true;
}

/// The AMD display's flips given up, once one was not taken: the fetcher
/// told to read the firmware's framebuffer again at once, both frames
/// that framebuffer from now on - each picture made in it, as the copying
/// did - and the whole picture noted for the next. Said once on the log.
/// The device's frame is kept: the fetcher might still read it. Made
/// holding `flip_lock`.
fn giveUpFlipping(screen: *Screen) void {
    const sys = screen.sys;
    const found = screen.dcn.?;
    screen.amd_flipping = false;
    dcn.flip(found, found.surface, true);
    exec.kprintf(sys, "%s: the display did not take the flip to 0x%lx, so the picture goes into the firmware's framebuffer again\n", .{ MODULE_NAME, screen.flip_wanted });
    const fb = screen.flip_frames[0];
    screen.flip_frames[1] = fb;
    screen.front = 0;
    screen.scanning = @intFromPtr(fb);
    sys.AcquireLock(&screen.damage_lock);
    noteBox(screen, whole(screen));
    sys.ReleaseLock(&screen.damage_lock);
    sys.SignalWaitable(&screen.work);
}

/// One rectangle of a picture, in the frame at `into`: each row from its
/// band, black where nothing is shown, the overlay laid over it and the
/// pointer over that - where the display has no plane of its own for it -
/// and written out of the caches.
fn makeBox(screen: *Screen, into: [*]u8, box: Box, over: Laid, pointer: Laid) void {
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
    _ = layOver(screen, into, pointer.image, pointer.left, pointer.top, box);
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
    _ = scanFrom(screen, address);
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

/// Where the display that is flipped has no plane for the pointer - the
/// AMD display - the pointer is laid in the pictures made, as the
/// overlay is: its image changed, its old and new places noted. The image
/// laid until now is not read again once this returns.
fn pointerFlipped(screen: *Screen, image: ?*const rtg.RtgPointerImage) void {
    const sys = screen.sys;
    sys.ObtainSemaphore(&screen.flip_lock);
    sys.AcquireLock(&screen.damage_lock);
    if (screen.pointer_shown) noteImage(screen, screen.pointer, screen.pointer_left, screen.pointer_top);
    screen.pointer = image;
    if (screen.pointer_shown) noteImage(screen, image, screen.pointer_left, screen.pointer_top);
    sys.ReleaseLock(&screen.damage_lock);
    sys.ReleaseSemaphore(&screen.flip_lock);
    sys.SignalWaitable(&screen.work);
}

/// The pointer laid in the pictures moved, its old and new places noted.
fn pointerMoved(screen: *Screen, left: i32, top: i32) void {
    const sys = screen.sys;
    sys.AcquireLock(&screen.damage_lock);
    if (screen.pointer_shown) noteImage(screen, screen.pointer, screen.pointer_left, screen.pointer_top);
    screen.pointer_left = left;
    screen.pointer_top = top;
    if (screen.pointer_shown) noteImage(screen, screen.pointer, left, top);
    sys.ReleaseLock(&screen.damage_lock);
    sys.SignalWaitable(&screen.work);
}

/// The pointer laid in the pictures shown or hidden, its place noted.
fn pointerShown(screen: *Screen, show: bool) void {
    const sys = screen.sys;
    sys.AcquireLock(&screen.damage_lock);
    const changed = screen.pointer_shown != show;
    screen.pointer_shown = show;
    if (changed) noteImage(screen, screen.pointer, screen.pointer_left, screen.pointer_top);
    sys.ReleaseLock(&screen.damage_lock);
    if (changed) sys.SignalWaitable(&screen.work);
}

// --- the board -------------------------------------------------------------------

/// The display the device is, if it is there.
fn findScanout(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, chip: u32, tag_list: ?[*]const TagItem) ?Scanout {
    const rb = driver.rtg_base;
    const sys = driver.sys_base;
    const address = rb.GetRtgTagData(st.PART_Address, 0, tag_list);
    return switch (chip) {
        st.CHIP_QEMU_RAMFB => .{ .ramfb = ramfb.find(address) orelse return null },
        // Its registers do not answer while its domain is off, so nothing
        // is asked of it before the mode is set.
        st.CHIP_JH7110_DC8200 => .jh7110,
        // Nor of the BCM2712's before the firmware has its clocks running.
        st.CHIP_BCM2712_HVS => .bcm2712,
        // On PCI the device is the function itself; on a memory-mapped
        // transport the board names the block, or the first of a row of
        // them.
        st.CHIP_VIRTIO_GPU => if (device.pci) |function|
            .{ .virtio = virtio.onPci(sys, function) orelse return null }
        else
            .{ .virtio = virtio.find(
                address,
                @truncate(rb.GetRtgTagData(st.PART_Windows, 1, tag_list)),
                rb.GetRtgTagData(st.PART_WindowSize, 0, tag_list),
            ) orelse return null },
        // Nothing to probe: the firmware set this one up, and the board
        // says what it set up.
        st.CHIP_UEFI_FB => found: {
            const format: rtg.PixelFormat = @enumFromInt(@as(u8, @truncate(rb.GetRtgTagData(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32), tag_list))));
            break :found .{ .uefi = uefi.find(
                address,
                @truncate(rb.GetRtgTagData(tags.RTGA_Pitch, 0, tag_list)),
                @truncate(rb.GetRtgTagData(tags.RTGA_Width, 0, tag_list)),
                @truncate(rb.GetRtgTagData(tags.RTGA_Height, 0, tag_list)),
                programs(rb).RtgFormatBits(@intFromEnum(format)) / 8,
            ) orelse return null };
        },
        else => null,
    };
}

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

/// A display this drives is offered - a panel part of one of its chips,
/// or a virtio GPU's function on PCI: found, brought up, and a board made
/// of it.
fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, device_tags: ?[*]const TagItem) callconv(.c) i32 {
    const rb = driver.rtg_base;
    const on_pci = device.kind == rtg.drivers.RTGDEV_PCI;
    const tag_list: ?[*]const TagItem = if (on_pci) &function_tags else device_tags;
    const chip: u32 = if (on_pci) st.CHIP_VIRTIO_GPU else device.chip;

    // What the tags have to say, looked at before anything is taken.
    const format: rtg.PixelFormat = @enumFromInt(@as(u8, @truncate(rb.GetRtgTagData(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32), tag_list))));
    if (format != .bgra32 and format != .rgb565) return err.RTGERR_BAD_FORMAT;
    const width: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Width, 0, tag_list));
    const height: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Height, 0, tag_list));
    if (width == 0 or height == 0) return err.RTGERR_BAD_TAGS;
    if (width > 0x3FFF or height > 0x3FFF) return err.RTGERR_BAD_TAGS;

    const scanout = findScanout(driver, device, chip, tag_list) orelse return err.RTGERR_NO_DISPLAY;
    const board = rb.CreateBoard(driver, device, &.{
        .ops = switch (scanout) {
            .bcm2712 => &bcm2712_ops,
            .jh7110 => &jh7110_ops,
            .virtio => &virtio_ops,
            else => &ops,
        },
        .instance_size = @sizeOf(Screen),
        // The windows of a screen on a GPU found on PCI each draw into a
        // buffer of their own, and what can be seen of them is copied
        // into the screen's; a part says so in its tags.
        .flags = if (on_pci) rtg.boards.RTGBF_COMPOSE else 0,
        // A monitor's modes are made in the format the board shows.
        .format = format,
        // How many bands the display reads itself is said once it is
        // known whether it is flipped (`bringUp`).
    }) orelse {
        var found = scanout;
        if (found == .virtio) virtio.giveBack(&found.virtio);
        return err.RTGERR_NO_MEMORY;
    };
    const code = bringUp(driver, board, scanout, tag_list);
    if (code != err.RTGERR_OK) rb.DeleteBoard(board);
    return code;
}

/// The board's screen filled in and its display brought up as far as the
/// first show needs. On any answer but RTGERR_OK it has given back what
/// it took, the board excepted, which is the caller's to delete.
fn bringUp(driver: *rtg.RtgDriver, board: *rtg.RtgBoard, scanout: Scanout, tag_list: ?[*]const TagItem) i32 {
    const rb = driver.rtg_base;
    const sys = driver.sys_base;
    const format: rtg.PixelFormat = @enumFromInt(@as(u8, @truncate(rb.GetRtgTagData(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32), tag_list))));
    const bytes: u32 = if (format == .bgra32) 4 else 2;
    const screen = screenOf(board);
    screen.* = .{
        .sys = sys,
        .rtg_base = programs(rb),
        .scanout = scanout,
        .width = @truncate(rb.GetRtgTagData(tags.RTGA_Width, 0, tag_list)),
        .height = @truncate(rb.GetRtgTagData(tags.RTGA_Height, 0, tag_list)),
        .format = format,
        .bytes = bytes,
        .board = board,
    };
    // The board's buffers start, and their rows are rounded, as its tags
    // say; whole cache lines where they say nothing.
    const asked_alignment: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Alignment, 0, tag_list));
    if (asked_alignment != 0) screen.alignment = asked_alignment;
    if (scanout == .virtio) {
        // The GPU up, and the picture as large as the emulator's window
        // has it - QEMU's xres and yres - where it says.
        const gpu = &screen.scanout.virtio;
        if (format != .bgra32) {
            virtio.giveBack(gpu);
            return err.RTGERR_BAD_FORMAT;
        }
        if (!virtio.start(gpu, sys)) return err.RTGERR_NO_DISPLAY;
        if (virtio.displaySize(gpu, Waiter{ .screen = screen })) |size| {
            if (size.width <= 0x3FFF and size.height <= 0x3FFF) {
                screen.width = size.width;
                screen.height = size.height;
            }
        }
    }
    if (scanout == .uefi) {
        // The engine reading the firmware's framebuffer, where it is one
        // this driver knows: what it says of itself goes in the boot's
        // lines, and the display is flipped (below).
        screen.dcn = dcn.find(sys, screen.scanout.uefi);
        if (screen.dcn) |*found| found.rtg_base = rb;
        // The sound the link it lit can carry, which the firmware leaves
        // switched off and which no other driver can reach. The machine's
        // audio driver has its sinks already and asks the codec what is
        // at the far end of a link when a sink is started, so switching
        // this on here is all that is wanted of this side.
        if (screen.dcn) |found| _ = dcn.soundUp(found);
    }
    if (isHdmi(scanout)) {
        // The modes are the library's to make, of what the monitor on the
        // port names (`detect`, `checkMode`) and of the part's size where
        // none does. Here: the display's frame interrupt.
        if (format != .bgra32) return err.RTGERR_BAD_FORMAT;
        screen.frame_irq = @truncate(rb.GetRtgTagData(st.PART_Irq, 0, tag_list));
    } else {
        // One mode of its own: the picture the board was built for - the
        // emulator's window, on the virtio GPU - on a display with no
        // clock. A virtio GPU's stands while its EDID names none.
        const own: rtg.RtgTimings = .{ .h_active = screen.width, .v_active = screen.height };
        if (rb.AddBoardMode(board, &own, @intFromEnum(format), rtg.modes.RTGMF_DEFAULT) == 0) {
            if (scanout == .virtio) virtio.stop(&screen.scanout.virtio);
            return err.RTGERR_NO_MEMORY;
        }
    }
    screen.pitch = rowBytes(screen, screen.width);

    // At most as many pictures of the mode the display is in as the
    // board asks for, each taken by the library as it is allocated, from
    // memory every display here reaches (`sizeFor` follows the mode). Not
    // cleared: each is cleared before it is first shown. The composed
    // frame is taken as it is needed, the cursor plane's two images now.
    const frame: usize = @as(usize, screen.pitch) * screen.height;
    // An HDMI port's frames are taken with its first mode.
    screen.frame_bytes = if (isHdmi(scanout)) 0 else frame;
    const frames: u32 = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list))), 1);
    screen.buffers = frames;
    if (hasCursorPlane(scanout)) {
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
    if (isHdmi(scanout) and !startFlipping(screen, false)) {
        if (screen.cursor_memory) |memory| sys.FreeMem(memory, 2 * cursor_bytes + page);
        if (screen.overlay_memory) |memory| sys.FreeMem(memory, 2 * overlay_bytes + page);
        screen.cursor_memory = null;
        screen.cursor = null;
        screen.overlay_memory = null;
        screen.overlay_images = null;
        return err.RTGERR_NO_MEMORY;
    }
    // The AMD display behind the firmware's framebuffer is flipped too,
    // its frames counted by the pipe's interrupt. Where it cannot be, it
    // is said why, and the picture is copied into the framebuffer.
    if (scanout == .uefi and screen.dcn != null) {
        hookFrames(screen);
        _ = startFlipping(screen, true);
    }
    // How the picture reaches the glass, now that it is known whether
    // the display is flipped. One that is has every band of a show
    // handed to it, and makes its pictures itself. One that is not shows
    // the picture the library composes: the ramfb and the virtio GPU read
    // one whole buffer by themselves besides, the firmware's framebuffer
    // none.
    if (flips(screen)) {
        board.direct_bands = rtg.RTG_MAX_BANDS;
        if (scanout == .uefi) board.ops = &flipped_ops;
    } else {
        board.direct_bands = if (scanout == .uefi) 0 else 1;
    }
    board.region = .{
        .size = frames * frame,
        .alignment = screen.alignment,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED |
            rtg.boards.RTGRF_SYSTEM_MEMORY | rtg.boards.RTGRF_DMA_MEMORY,
    };
    board.info.buffers = frames;
    engine.setUp(&screen.engine, sys);
    return err.RTGERR_OK;
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    const screen = screenOf(board);
    // The GPU lets go of the buffers before they are given back.
    if (screen.scanout == .virtio) virtio.stop(&screen.scanout.virtio);
    // The frames go before the frame interrupt, which giving the AMD
    // display's back waits by. The device is amdgpu.resource's, which is
    // never given back.
    stopFlipping(screen);
    unhookFrames(screen);
    screen.dcn = null;
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
}

/// Bytes a row of a buffer `width` pixels wide has: the pixels, rounded
/// up to the board's alignment, as the library rounds a mode's.
fn rowBytes(screen: *const Screen, width: u32) u32 {
    const row = width * screen.bytes;
    const step = screen.alignment;
    return (row + step - 1) / step * step;
}

/// How many blocks of an EDID the ports read at the most: the first, and
/// the extensions it names.
const edid_block = rtg.modes.RTG_EDID_BLOCK;

/// Whether a block of an EDID sums to zero, as every block does that was
/// read as the monitor holds it.
fn sumsToZero(block: *const [edid_block]u8) bool {
    var sum: u8 = 0;
    for (block) |byte| sum +%= byte;
    return sum == 0;
}

/// What is on the display's connector, for the library: an HDMI port's
/// monitor and its EDID, read over the port's DDC; the virtio GPU's
/// window, which is always there, and the EDID the emulator gives it.
fn detect(board: *rtg.RtgBoard, asked: *rtg.RtgDetect) callconv(.c) i32 {
    const screen = screenOf(board);
    switch (screen.scanout) {
        .jh7110 => return detectPort(jh7110, screen, asked),
        .bcm2712 => return detectPort(bcm2712, screen, asked),
        .virtio => |*gpu| {
            asked.present = 1;
            asked.edid_size = virtio.readEdid(gpu, asked.edid[0..asked.edid_max], Waiter{ .screen = screen });
            return err.RTGERR_OK;
        },
        else => return err.RTGERR_NOT_SUPPORTED,
    }
}

/// `detect` on the HDMI port `port` drives: the port woken where it does
/// not run yet, its hot-plug line read, and the monitor's EDID - its
/// first block, read again once where it does not sum to zero, and as
/// many of the extensions it names as there is room for and the port
/// reads. The DDC is the port's one: held against the task that makes the
/// pictures, which looks after a monitor over it.
fn detectPort(comptime port: type, screen: *Screen, asked: *rtg.RtgDetect) i32 {
    const sys = screen.sys;
    const waiter = Waiter{ .screen = screen };
    sys.ObtainSemaphore(&screen.flip_lock);
    defer sys.ReleaseSemaphore(&screen.flip_lock);
    // A port that runs is awake: waking it again would put the
    // controller's pixel clocks back on the divider under the picture.
    if (screen.scanning == 0) {
        const failure = port.wake(sys, waiter);
        if (failure != .none) {
            exec.kprintf(sys, "%s: %s\n", .{ MODULE_NAME, port.why(failure) });
            return err.RTGERR_NO_DISPLAY;
        }
    }
    if (!port.monitor()) return err.RTGERR_OK;
    asked.present = 1;
    if (asked.edid_max < edid_block) return err.RTGERR_OK;
    const first: *[edid_block]u8 = @ptrCast(asked.edid);
    var read = port.readEdid(0, first, waiter);
    if (read and !sumsToZero(first)) read = port.readEdid(0, first, waiter);
    if (!read) return err.RTGERR_OK;
    var blocks: u32 = 1;
    const named = @min(@as(u32, first[126]) + 1, asked.edid_max / edid_block, port.edid_blocks);
    while (blocks < named) : (blocks += 1) {
        const block: *[edid_block]u8 = @ptrCast(asked.edid + blocks * edid_block);
        if (!port.readEdid(@intCast(blocks), block, waiter)) break;
    }
    asked.edid_size = blocks * edid_block;
    return err.RTGERR_OK;
}

/// Whether the display can make `timings`: an HDMI port by its clock and
/// by what its registers hold; any other takes what it is offered.
fn checkMode(board: *rtg.RtgBoard, timings: *const rtg.RtgTimings) callconv(.c) i32 {
    const made = switch (screenOf(board).scanout) {
        .jh7110 => jh7110.makes(timings),
        .bcm2712 => bcm2712.makes(timings),
        else => true,
    };
    return if (made) err.RTGERR_OK else err.RTGERR_BAD_MODE;
}

/// Room for the mode the screen has just taken: the composed frame, or
/// the two frames a display is flipped between, taken anew where a
/// picture of the mode is larger than they are - an HDMI port's with its
/// first mode - and the board's display memory let hold as many such
/// pictures as the board may have. False without memory for the frames.
/// What the display read is then gone: it is started again.
fn sizeFor(screen: *Screen, board: *rtg.RtgBoard) bool {
    const sys = screen.sys;
    const picture = @as(usize, screen.pitch) * screen.height;
    if (isHdmi(screen.scanout)) {
        if (picture > screen.frame_bytes or screen.flip_memory == null) {
            sys.ObtainSemaphore(&screen.flip_lock);
            defer sys.ReleaseSemaphore(&screen.flip_lock);
            if (screen.flip_memory) |memory| sys.FreeMem(memory, screen.flip_bytes + page);
            screen.flip_memory = null;
            screen.flip_bytes = 0;
            screen.scanning = 0;
            screen.frame_bytes = @max(screen.frame_bytes, picture);
            if (!takeFrames(screen)) return false;
        }
    } else if (picture > screen.frame_bytes) {
        // The frame of the driver's own goes, and is taken anew for the
        // larger picture when it is next needed. A show holds the
        // board's compose lock: nothing is fetched into it meanwhile.
        const memory = screen.composed_memory;
        const frame = screen.composed;
        screen.composed_memory = null;
        screen.composed = null;
        if (frame) |gone| {
            switch (screen.scanout) {
                .virtio => |*gpu| virtio.forget(gpu, @intFromPtr(gone), Waiter{ .screen = screen }),
                else => {},
            }
            if (screen.scanning == @intFromPtr(gone)) screen.scanning = 0;
        }
        if (memory) |old| sys.FreeMem(old, screen.frame_bytes + page);
        screen.frame_bytes = picture;
    }
    board.region.size = @as(usize, screen.buffers) * screen.frame_bytes;
    return true;
}

/// The display brought up the first time in `mode` - or changed to it -
/// black: the composed frame cleared, given back once a buffer is shown.
/// The mode it is in handed over again is a monitor that came to an HDMI
/// port: the port is started again with the timings handed over now, as
/// that monitor takes them, reading what it read.
fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode, timings: *const rtg.RtgTimings) i32 {
    const screen = screenOf(board);
    // A row as the library makes one of a buffer: what this driver sizes
    // its frames by.
    if (mode.format != screen.format or mode.pitch != rowBytes(screen, mode.width)) return err.RTGERR_BAD_MODE;
    const changed = mode.id != screen.mode_id;
    screen.mode_id = mode.id;
    screen.timings = timings.*;
    screen.width = mode.width;
    screen.height = mode.height;
    screen.pitch = mode.pitch;
    if (isHdmi(screen.scanout)) {
        // How the mode goes to the monitor now on the port.
        var monitor: rtg.RtgMonitorInfo = .{};
        _ = screen.rtg_base.GetBoardMonitor(board, &monitor, @sizeOf(rtg.RtgMonitorInfo));
        screen.sink = bcm2712.Sink.of(&monitor);
        if (!changed and screen.scanning != 0) {
            return if (begin(screen, screen.scanning)) err.RTGERR_OK else err.RTGERR_NO_DISPLAY;
        }
    }
    if (!sizeFor(screen, board)) return err.RTGERR_NO_MEMORY;
    if (flips(screen) and (screen.scanning == 0 or changed)) {
        if (!beginFlipped(screen)) return err.RTGERR_NO_DISPLAY;
    } else if (screen.scanning == 0 or changed) {
        // What it read until now says nothing about the new mode.
        screen.scanning = 0;
        screen.shown = false;
        if (!showBlack(screen)) return err.RTGERR_NO_DISPLAY;
    }
    return err.RTGERR_OK;
}

/// A display that is not flipped showing black: the firmware's
/// framebuffer cleared where the display reads that, else the frame of
/// the driver's own, cleared, and the display reading it. False without
/// memory for that frame, and where the display does not take it.
fn showBlack(screen: *Screen) bool {
    switch (screen.scanout) {
        .uefi => |fb| {
            var y: u32 = 0;
            while (y < @min(screen.height, fb.height)) : (y += 1) @memset(fb.row(y)[0 .. screen.width * screen.bytes], 0);
            screen.scanning = fb.pixels;
            return true;
        },
        else => {
            const black = ownFrame(screen) orelse return false;
            const bytes = @as(usize, screen.pitch) * screen.height;
            @memset(black[0..bytes], 0);
            handOn(screen, &pictureAt(screen, black), whole(screen));
            return begin(screen, @intFromPtr(black));
        },
    }
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
        .ramfb, .virtio, .uefi => _ = scanFrom(screen, address),
        .jh7110 => startPort(jh7110, screen, address),
        .bcm2712 => startPort(bcm2712, screen, address),
    }
    return screen.scanning == address;
}

/// `begin` on the HDMI port `port` drives: the mode set - on the
/// BCM2712's, sent as the monitor takes it (`Screen.sink`) - and the
/// frame interrupt hooked once it runs.
fn startPort(comptime port: type, screen: *Screen, address: usize) void {
    const mode = &screen.timings;
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

/// What a display that is not flipped shows from now on. No band is
/// black. One whole buffer the display is to read itself
/// (`RTGSHOW_DIRECT`: the ramfb, the virtio GPU) is read where it lies.
/// Anything else is the picture the library composes - bands, an overlay,
/// a pointer - fetched whole into the firmware's framebuffer, where the
/// display reads that, or into the frame of the driver's own, which the
/// display then reads. A picture that takes the place of another is
/// waited out for a frame, as a flip is.
///
/// Nothing is changed where it fails: with no memory for that frame
/// (RTGERR_NO_MEMORY), and where the device does not take the address
/// (RTGERR_IO), the display reads what it read.
fn showPlain(screen: *Screen, what: *const rtg.RtgShow) i32 {
    const bands: []const rtg.RtgBand = if (what.bands) |list| list[0..what.count] else &.{};
    if (bands.len == 0) {
        if (!showBlack(screen)) return err.RTGERR_NO_MEMORY;
        screen.shown = false;
        return err.RTGERR_OK;
    }
    const last = bands[bands.len - 1].bitmap;
    // The same buffer shown the other way - the pointer come or gone -
    // is no other picture, and is not waited for.
    const flip = screen.shown and !(bands.len == 1 and screen.showing == last);
    if (what.flags & rtg.boards.RTGSHOW_DIRECT != 0) {
        if (!scanFrom(screen, @intFromPtr(last.pixels.?))) return err.RTGERR_IO;
        dropFrame(screen);
    } else {
        const code = fetch(screen, &.{ .width = @intCast(screen.width), .height = @intCast(screen.height) });
        if (code != err.RTGERR_OK) return code;
        if (screen.composed) |frame| {
            if (!scanFrom(screen, @intFromPtr(frame))) return err.RTGERR_IO;
        }
    }
    screen.showing = last;
    screen.shown = true;
    screen.updates +%= 1;
    // Waited out inside the show: the library holds the board's compose
    // lock, and a pointer's move waits that frame.
    if (flip) pace(screen, 1);
    return err.RTGERR_OK;
}

/// A rectangle of the library's picture fetched to where the display
/// reads it: straight into the firmware's framebuffer, whose rows are as
/// far apart as the firmware set them - the memory is write-combining, so
/// the rows are gathered into bursts as they are written and nothing is
/// written back afterwards - or into the frame of the driver's own, which
/// is then handed on: written back, and on the virtio GPU copied into the
/// emulator's copy of it.
fn fetch(screen: *Screen, area: *const rtg.RtgRect) i32 {
    const x: u32 = @intCast(area.x);
    const y: u32 = @intCast(area.y);
    switch (screen.scanout) {
        .uefi => |fb| {
            if (y + @as(u32, @intCast(area.height)) > fb.height) return err.RTGERR_BAD_ARG;
            return drivers(screen).ComposeLines(screen.board, area, fb.row(y) + x * screen.bytes, fb.pitch);
        },
        else => {
            const frame = ownFrame(screen) orelse return err.RTGERR_NO_MEMORY;
            const code = drivers(screen).ComposeLines(screen.board, area, frame + y * screen.pitch + x * screen.bytes, screen.pitch);
            if (code != err.RTGERR_OK) return code;
            handOn(screen, &pictureAt(screen, frame), .{
                .left = x,
                .top = y,
                .right = x + @as(u32, @intCast(area.width)),
                .end = y + @as(u32, @intCast(area.height)),
            });
            return err.RTGERR_OK;
        },
    }
}

/// A rectangle of the display's own picture changed, on a display that
/// is not flipped: fetched from the library to where the display reads
/// it.
fn update(board: *rtg.RtgBoard, area: *const rtg.RtgRect) callconv(.c) i32 {
    return fetch(screenOf(board), area);
}

/// The board's one op for what is on the glass (`RtgShow`): put in the
/// mode where the library says it is to be, then shown the bands - one
/// whole buffer, several in bands, or nothing. With the mode set anew a
/// show that fails leaves the board showing nothing.
fn showOp(board: *rtg.RtgBoard, what: *const rtg.RtgShow) callconv(.c) i32 {
    const anew = what.flags & rtg.boards.RTGSHOW_MODE_CHANGED != 0;
    if (anew) {
        const code = setMode(board, what.mode, what.timings);
        if (code != err.RTGERR_OK) return code;
    }
    const screen = screenOf(board);
    const code = showThese(screen, what);
    if (code != err.RTGERR_OK and anew) _ = showThese(screen, &.{ .mode = what.mode, .timings = what.timings });
    return code;
}

/// The bands of a show, in the mode the board is in; none shows nothing.
/// They are the mode's: the library hands on none that is not.
fn showThese(screen: *Screen, what: *const rtg.RtgShow) i32 {
    if (!flips(screen)) return showPlain(screen, what);
    showFlipped(screen, if (what.bands) |list| list[0..what.count] else &.{});
    return err.RTGERR_OK;
}

/// A rectangle was written by the CPU: its pixels alone handed on - any
/// buffer's, shown or not: one drawn ahead is shown by naming it. On a
/// display that is flipped it is noted for the next picture instead.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect) callconv(.c) i32 {
    const screen = screenOf(board);
    const x: u32 = @intCast(area.x);
    const first: u32 = @intCast(area.y);
    const box = Box{ .left = x, .top = first, .right = x + @as(u32, @intCast(area.width)), .end = first + @as(u32, @intCast(area.height)) };
    if (flips(screen)) {
        noteWritten(screen, bitmap, .{ .left = box.left, .top = box.top, .right = @min(box.right, screen.width), .end = box.end });
        return err.RTGERR_OK;
    }
    handOn(screen, bitmap, box);
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

fn blendRect(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) callconv(.c) i32 {
    return engine.blendRect(&screenOf(board).engine, bitmap, area, color);
}

fn blendPixels(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, alpha: u32) callconv(.c) i32 {
    return engine.blendPixels(&screenOf(board).engine, bitmap, area, pixels, alpha);
}

fn scalePixels(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, width: u32, height: u32) callconv(.c) i32 {
    return engine.scale(&screenOf(board).engine, bitmap, area, pixels, width, height);
}

/// A display that is not flipped - the ramfb, the firmware's
/// framebuffer: the picture the library composes fetched to where the
/// display reads it, so the bands, the overlay and the pointer are the
/// library's.
const ops = rtg.boards.RtgBoardOps{
    .destroy = &destroy,
    .show = &showOp,
    .refresh = &refresh,
    .update = &update,
    .stats = &stats,
    .engine = &engine_ops,
};

/// A display that is flipped - the AMD display behind the firmware's
/// framebuffer: it makes its pictures itself, the overlay and the
/// pointer laid in them.
const flipped_ops = rtg.boards.RtgBoardOps{
    .destroy = &destroy,
    .show = &showOp,
    .refresh = &refresh,
    .stats = &stats,
    .pointer = &pointer_ops,
    .overlay = &overlay_ops,
    .engine = &engine_ops,
};

const pointer_ops = rtg.RtgPointerOps{ .set = &setPointer, .move = &movePointer, .show = &showPointer };
const overlay_ops = rtg.RtgOverlayOps{ .set = &setOverlay, .move = &moveOverlay };

/// The engine: the cores (engine.zig).
const engine_ops = rtg.RtgEngineOps{
    .fill_rect = &fillRect,
    .copy_rect = &copyRect,
    .copy_rects = &copyRects,
    .blit_template = &blitTemplate,
    .blit_pattern = &blitPattern,
    .blend_pixels = &blendPixels,
    .blend_rect = &blendRect,
    .scale_pixels = &scalePixels,
};

/// The JH7110's video layer, its first overlay.
const video_ops = rtg.RtgVideoOps{ .open = &videoOpen, .close = &videoClose, .show = &videoShow, .move = &videoMove };

/// The BCM2712's port's: the same, and what its hardware does besides -
/// the display switched off, the monitor's brightness, the picture
/// mirrored.
const bcm2712_ops = ops: {
    var more = flipped_ops;
    more.detect = &detect;
    more.check_mode = &checkMode;
    more.display = &display;
    more.set_brightness = &setBrightness;
    more.brightness = &brightness;
    more.mirror = &mirror;
    break :ops more;
};

/// The JH7110's port's: the same, and a video layer, its first overlay.
const jh7110_ops = ops: {
    var more = flipped_ops;
    more.detect = &detect;
    more.check_mode = &checkMode;
    more.video = &video_ops;
    break :ops more;
};

/// The virtio GPU's: a display that is not flipped, what the emulator
/// says its window is, and the pointer the host's own, a cursor plane.
const virtio_ops = ops: {
    var more = ops;
    more.detect = &detect;
    more.pointer = &pointer_ops;
    break :ops more;
};

const driver_ops = rtg.RtgDriverOps{ .attach = &attach };

/// What it takes: a panel part of one of these chips, and a virtio GPU's
/// function on PCI, in the arrangement the standard settled on and the
/// one before it.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = st.CHIP_QEMU_RAMFB },
    .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = st.CHIP_JH7110_DC8200 },
    .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = st.CHIP_VIRTIO_GPU },
    .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = st.CHIP_BCM2712_HVS },
    .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = st.CHIP_UEFI_FB },
    .{ .fields = rtg.drivers.RTGMATCH_VENDOR | rtg.drivers.RTGMATCH_DEVICE, .vendor = virtio.pci_vendor, .device = virtio.pci_device },
    .{ .fields = rtg.drivers.RTGMATCH_VENDOR | rtg.drivers.RTGMATCH_DEVICE, .vendor = virtio.pci_vendor, .device = virtio.pci_device_old },
    .{},
};

/// The driver's tag: a description and no init. rtg.library reads it at
/// its own init and puts the driver on its list; nothing of this module
/// runs until a board is asked for.
export const rtg_fb_tag: rtg.ResidentRtgDriver linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&rtg_fb_tag),
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

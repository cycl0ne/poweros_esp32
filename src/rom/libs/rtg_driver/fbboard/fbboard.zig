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
//! **A display that is not flipped** - the ramfb, and the firmware's
//! framebuffer with no engine behind it that this knows - has its
//! picture composed by rtg.library where it stands. With nothing over
//! the picture the ramfb reads the shown buffer itself, and nothing is
//! copied. While a pointer or the overlay is shown, or the picture is
//! several in bands, it reads a frame of the driver's own instead: the
//! board is told which rectangle of the display changed (`update`) and
//! fetches it from the library into that frame (`ComposeLines`), no
//! wider than what was written, so a pointer's move costs the pointer's
//! size and not the picture's. The firmware's framebuffer is such a
//! frame already, the only thing the display reads: the library's
//! picture is fetched straight into it, at the firmware's own row
//! length. The ramfb's frame is taken when it is first needed, and
//! stays. Black, as the display comes up or when nothing is shown, is
//! that frame cleared.
//!
//! **A display that is flipped** reads one of two frames, and rtg.library
//! makes its pictures in the other (its `compose/_flip.zig`): what is
//! written is noted as rectangles, and a task of the library's makes the
//! next picture in the frame the display is not reading, hands it on to
//! this driver (`refresh`) and has it tell the display to read that frame
//! from the next frame on (`flipOp`), which the library waits for before
//! the frame read until then is written again. A drawing is seen a frame
//! or two after it was made, and whole. All this driver does of it is
//! start the display on the first frame, as it is put in a mode, hand a
//! frame on, and flip.
//!
//! The HDMI ports' displays are flipped because they read RAM past the
//! caches, and the caches write their lines back in an order of their
//! own: a picture drawn over while it is read shows, for a frame, a
//! patchwork of old and new cache lines, sixteen pixels each. A frame
//! handed on is written out of the caches; the buffers drawn in are not,
//! since nothing reads them past the caches.
//!
//! A whole picture is a copy of the whole display - at 2560x1440 14 MB,
//! which takes the cores 14 ms - and a program that draws each picture in
//! one buffer while it shows another, and then shows that one, would wait
//! for one each time: a frame lost to every picture. So the BCM2712's
//! port says it reads such a program's buffers themselves
//! (`RTGBF_DIRECT_FLIP`): the library then has it flipped to a whole
//! buffer shown in place of another that nothing was written in while it
//! was shown, handed on whole and read as it is, and nothing is copied.
//!
//! The virtio GPU is flipped because its pictures are copies the emulator
//! keeps: the two frames are two of its resources, a frame handed on is
//! copied into the emulator's copy of it, and a flip names the resource
//! the window shows.
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
//! moved by a command. Where a display has no plane for one of the two -
//! the JH7110's and the virtio GPU's overlay, both on the AMD display -
//! rtg.library lays it in the pictures it makes.
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
//! whatever writes one - a flip, the pointer's moves, a film - holds
//! `plane_lock`.
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
//! An AMD display behind the firmware's framebuffer is flipped too, for
//! a reason of its own: a picture copied into the one buffer it reads,
//! while it reads it, shows the top of one picture and the bottom of the
//! other. Its frames are the driver's own, handed to the library
//! (`framesOp`): that buffer and one of the device's own memory, both
//! reached write-combining, so nothing is written back: the gathered
//! writes are fenced before the flip. The engine takes a flip at the
//! pipe's next update, between two frames, and says when it has
//! (`flipAmd`): a flip it has not taken two frames after the one waited
//! for puts the display back on the firmware's buffer for good, each
//! picture then made in it, and says so on the log. The display has no
//! cursor plane, so the pointer is laid in the pictures by the library,
//! with the overlay.
//!
//! An HDMI port's hot-plug line raises no interrupt here. The frame's
//! interrupt has the library look at the connector twice a second
//! (`MonitorChanged`), and the look (`detectPort`) reads the line, and
//! the monitor's EDID when one has come.
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
const tags = rtg.tags;
const timer = sdk.devices.timer;

const MODULE_NAME = "rtg-fb";
const DRIVER_NAME = "fb";
const VERSION = 1;
const REVISION = 42;
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
    /// is - it is given up on once a flip is not taken - the device's
    /// address of the frame last flipped to, and the two frames as the
    /// library is handed them (`framesOp`).
    amd_frame: ?sdk.resources.amdgpu.GPUMemory = null,
    amd_flipping: bool = false,
    flip_wanted: u64 = 0,
    amd_frames: [2]rtg.RtgBitMap = .{ .{}, .{} },
    /// Whether the display is flipped between frames, which rtg.library
    /// makes its pictures in (`flipOp`): an HDMI port's, the virtio
    /// GPU's, the AMD display's.
    flipped: bool = false,
    /// Behind an HDMI port: what the monitor says of itself that decides
    /// how a mode is sent to it - HDMI or DVI, its range - as the library
    /// read it, taken as the mode is set; whether it was on the port when
    /// last looked at, how many looks in a row have seen otherwise, the
    /// frames since the library was last asked to look, and the
    /// monitor's EDID as it was read when it came (`detectPort`), with
    /// how often it was tried.
    sink: bcm2712.Sink = .{},
    plugged: bool = false,
    settling: u32 = 0,
    frames_unseen: u32 = 0,
    edid: [edid_most]u8 = undefined,
    edid_size: u32 = 0,
    edid_tries: u32 = 0,
    /// Behind an HDMI port: held while the port's DDC is talked on and
    /// while a task writes what a start of the port also writes - the
    /// picture's address, how it is turned, whether it is sent.
    port_lock: exec.SignalSemaphore = .{},
    /// On a display that is not flipped: a picture of the largest mode
    /// it has been in, which the frame of the driver's own takes.
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
    /// On the ramfb: the frame of the driver's own that the library's
    /// picture is fetched into and black is shown from, as AllocMem gave
    /// it and where it starts. Null until it is needed (`ownFrame`).
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
    /// Behind the BCM2712's port: where the top left of the overlay's
    /// image is, for its plane.
    overlay_left: i32 = 0,
    overlay_top: i32 = 0,
    /// The cores, as the board's engine.
    engine: engine.Engine = .{},
    /// The display's frame interrupt, where it has one: its number (0 for
    /// none), its server and whether that is on.
    frame_irq: u32 = 0,
    frame_int: exec.Interrupt = .{},
    frame_hooked: bool = false,
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
    /// share its hold and its commit bits, by the task that flips the
    /// picture, intuition's pointer task and a film's, each on any core.
    plane_lock: exec.Lock = .{},
};

/// The most bytes of a monitor's EDID an HDMI port reads.
const edid_most: usize = @as(usize, @max(jh7110.edid_blocks, bcm2712.edid_blocks)) * rtg.modes.RTG_EDID_BLOCK;

/// How many frames go by between two looks at an HDMI port's connector:
/// half a second of them at sixty a second.
const look_frames = 30;

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
    // An HDMI port's hot-plug line raises no interrupt here: the library
    // is asked to look at the connector now and then (`detectPort`),
    // which changes nothing while the same monitor is there.
    if (isHdmi(screen.scanout)) {
        screen.frames_unseen += 1;
        if (screen.frames_unseen >= look_frames) {
            screen.frames_unseen = 0;
            drivers(screen).MonitorChanged(screen.board);
        }
    }
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
/// wide as the picture - and on the virtio GPU noted for the emulator's
/// copy of the picture, which has it when the picture is next shown; a
/// picture that is the one shown is copied and shown at once.
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
        .virtio => |*gpu| virtio.update(gpu, picture, .{
            .x = box.left,
            .y = box.top,
            .width = box.right - box.left,
            .height = box.end - box.top,
        }, Waiter{ .screen = screen }),
        // The firmware's framebuffer and the AMD display's frames are
        // reached write-combining: nothing is written back.
        else => {},
    }
}

/// The display told to read `picture` from its next frame on: a buffer
/// of the mode it is in, as the library describes one - which is what
/// every display here is handed, whatever it then makes of it. Whether
/// it does: a device that refuses goes on reading where it read.
fn scanFrom(screen: *Screen, picture: *const rtg.RtgBitMap) bool {
    const address = @intFromPtr(picture.pixels orelse return false);
    if (address == screen.scanning) return true;
    const shown = switch (screen.scanout) {
        .ramfb => |device| ramfb.show(device, picture),
        .jh7110 => done: {
            screen.sys.AcquireLock(&screen.plane_lock);
            jh7110.show(picture);
            screen.sys.ReleaseLock(&screen.plane_lock);
            break :done true;
        },
        .bcm2712 => done: {
            bcm2712.show(picture);
            break :done true;
        },
        .virtio => |*gpu| virtio.show(gpu, picture, Waiter{ .screen = screen }),
        // The AMD display flipped to the frame, from the pipe's next
        // update on (`dcn.flip`), named by the device's own address of
        // it: the framebuffer's the fetcher read at start, the frame's
        // the resource gave with it. The frame is not in the window the
        // framebuffer is in - on a machine whose device memory is part of
        // its RAM the CPU reaches it there - so its address in the
        // machine says nothing of the device's. Where it is not flipped,
        // nothing tells it to read elsewhere: it reads the one buffer
        // the firmware gave it, which the picture is fetched into. Where
        // flipping was given up, the frames are that buffer. So of the
        // picture it is handed, this display takes which of its two
        // frames it is.
        .uefi => done: {
            if (screen.amd_flipping) {
                const found = screen.dcn.?;
                const frame = screen.amd_frame.?;
                screen.flip_wanted = if (address == @as(usize, @intCast(frame.cpu))) frame.device else found.surface;
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

/// A rectangle of a picture: columns `left` up to `right`, rows `top` up
/// to `end`.
const Box = struct {
    left: u32,
    top: u32,
    right: u32,
    end: u32,
};

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

// --- the pointer and the overlay a display lays itself ---------------------
//
// A cursor plane - the HDMI ports', the virtio GPU's - and the BCM2712's
// overlay plane: the boards that name these ops. Every other pointer and
// overlay is rtg.library's to lay, in the picture it composes.

fn setPointer(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    const screen = screenOf(board);
    if (image) |one| {
        if (one.format != screen.format) return err.RTGERR_BAD_FORMAT;
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
    overlayImage(screen, image);
    return err.RTGERR_OK;
}

fn moveOverlay(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const screen = screenOf(board);
    screen.overlay_left = left;
    screen.overlay_top = top;
    overlayPlane(screen);
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
    sys.ObtainSemaphore(&screen.port_lock);
    screen.turn = .{ .x = x, .y = y };
    if (screen.scanning != 0) bcm2712.mirror(screen.scanning, screen.turn);
    sys.ReleaseSemaphore(&screen.port_lock);
    cursorPlane(screen);
    overlayPlane(screen);
    return err.RTGERR_OK;
}

/// The monitor sent the picture, or nothing, which it sleeps at.
fn display(board: *rtg.RtgBoard, on: bool) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    sys.ObtainSemaphore(&screen.port_lock);
    defer sys.ReleaseSemaphore(&screen.port_lock);
    screen.dark = !on;
    bcm2712.transmit(on);
    return err.RTGERR_OK;
}

/// The monitor's brightness set over DDC/CI, `percent` of its largest:
/// RTGERR_IO where it does not answer. Holding `port_lock`, which keeps
/// the port's other talk on the DDC away - the EDID, the SCDC.
fn setBrightness(board: *rtg.RtgBoard, percent: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    const waiter = Waiter{ .screen = screen };
    sys.ObtainSemaphore(&screen.port_lock);
    defer sys.ReleaseSemaphore(&screen.port_lock);
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
    sys.ObtainSemaphore(&screen.port_lock);
    defer sys.ReleaseSemaphore(&screen.port_lock);
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

// --- a display that is flipped between frames ----------------------------------

/// Whether the display is flipped between two frames, the next picture
/// made in the one it is not reading, rather than shown the buffers
/// themselves: where it reads past the caches, on the virtio GPU, whose
/// frames are copies the emulator keeps, and on the AMD display, which
/// would otherwise be copied into while it is read. The pictures are
/// rtg.library's to make: the board is told which frame to read
/// (`flipOp`).
fn flips(screen: *const Screen) bool {
    return screen.flipped;
}

/// The display told to read `frame` from its next frame on: one of the
/// two rtg.library makes its pictures in, handed on already (`refresh`),
/// or on the BCM2712's port a buffer read in place of one. Behind an HDMI
/// port the controller takes the address at its next frame, which the
/// library waits for; so it does on the virtio GPU, where nothing has to
/// be waited for but a picture a frame is all the display shows. The AMD
/// display is seen to have taken it (`flipAmd`).
fn flipOp(board: *rtg.RtgBoard, frame: *rtg.RtgBitMap) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    if (frame.pixels == null) return err.RTGERR_BAD_ARG;
    switch (screen.scanout) {
        .uefi => return flipAmd(screen, frame),
        .jh7110, .bcm2712 => {
            // A port that does not run has nothing to flip: its start
            // names the frame it reads.
            if (screen.scanning == 0) return err.RTGERR_NO_MODE;
            // Against a task that turns the picture or starts the port.
            sys.ObtainSemaphore(&screen.port_lock);
            defer sys.ReleaseSemaphore(&screen.port_lock);
            _ = scanFrom(screen, frame);
        },
        else => if (!scanFrom(screen, frame)) return err.RTGERR_IO,
    }
    screen.updates +%= 1;
    return err.RTGERR_OK;
}

/// The AMD display flipped to `frame`. The engine takes a
/// flip at the pipe's next update, between two frames, and says when it
/// has: that frame is waited for and the flip looked at - then, and
/// after each of two frames more, since one made just as the pipe's
/// update came is taken at the next. Taken: `RTGFLIP_TAKEN`, and the
/// frame read until now may be written. Not taken: the flips are given
/// up (`giveUpFlipping`) and RTGERR_IO is answered, upon which the
/// library asks for the frames again and is handed the firmware's
/// framebuffer twice.
///
/// Where the frames are that one framebuffer already, the picture is in
/// what the display reads: nothing is flipped, and the library waits a
/// frame, so that no more than a picture a frame is made.
fn flipAmd(screen: *Screen, frame: *const rtg.RtgBitMap) i32 {
    screen.updates +%= 1;
    if (!screen.amd_flipping) return err.RTGERR_OK;
    _ = scanFrom(screen, frame);
    pace(screen, 1);
    const found = screen.dcn.?;
    var looks: u32 = 0;
    while (!dcn.flipTaken(found, screen.flip_wanted)) : (looks += 1) {
        if (looks == 2) {
            giveUpFlipping(screen);
            return err.RTGERR_IO;
        }
        pace(screen, 1);
    }
    return rtg.boards.RTGFLIP_TAKEN;
}

/// The AMD display's flips given up, once one was not taken: the fetcher
/// told to read the firmware's framebuffer again at once, and both
/// frames that framebuffer from now on - each picture made in it. Said
/// once on the log. The device's frame is kept: the fetcher might still
/// read it.
fn giveUpFlipping(screen: *Screen) void {
    const found = screen.dcn.?;
    screen.amd_flipping = false;
    dcn.flip(found, found.surface, true);
    exec.kprintf(screen.sys, "%s: the display did not take the flip to 0x%lx, so the picture goes into the firmware's framebuffer again\n", .{ MODULE_NAME, screen.flip_wanted });
    screen.scanning = screen.scanout.uefi.pixels;
}

/// The AMD display's two frames, for rtg.library to make its pictures
/// in: the firmware's framebuffer and a frame of the device's own memory
/// (`takeAmdFrame`), both reached write-combining and both with the
/// framebuffer's row length, which is what the fetcher reads with.
/// Without such a frame, and once the flips were given up, the
/// framebuffer twice: the pictures are then made in the one frame the
/// display reads.
fn framesOp(board: *rtg.RtgBoard, mode: *const rtg.RtgMode, into: *[2]?*rtg.RtgBitMap) callconv(.c) i32 {
    const screen = screenOf(board);
    const fb = screen.scanout.uefi;
    if (mode.width > fb.width or mode.height > fb.height) return err.RTGERR_BAD_MODE;
    screen.amd_frames[0] = .{
        .pixels = @ptrFromInt(fb.pixels),
        .width = mode.width,
        .height = mode.height,
        .pitch = fb.pitch,
        .format = mode.format,
        .size_bytes = @as(usize, fb.pitch) * mode.height,
    };
    screen.amd_frames[1] = screen.amd_frames[0];
    if (screen.amd_flipping) {
        if (screen.amd_frame) |frame| screen.amd_frames[1].pixels = @ptrFromInt(@as(usize, @intCast(frame.cpu)));
    }
    into.* = .{ &screen.amd_frames[0], &screen.amd_frames[1] };
    return err.RTGERR_OK;
}

/// A frame of the AMD device's own memory for the display to be flipped
/// to, as large as the firmware's framebuffer. Without room for it the
/// pictures are made in that framebuffer, and it is said why.
fn takeAmdFrame(screen: *Screen) void {
    const fb = screen.scanout.uefi;
    const found = screen.dcn orelse return;
    const frame = dcn.newFrame(found, @as(usize, fb.pitch) * fb.height) orelse {
        exec.kprintf(screen.sys, "%s: no room in the device's memory for a frame, so the picture is made in the firmware's framebuffer\n", .{MODULE_NAME});
        return;
    };
    screen.amd_frame = frame;
    screen.amd_flipping = true;
    exec.kprintf(screen.sys, "%s: the display is flipped between the firmware's framebuffer and a frame at 0x%lx\n", .{ MODULE_NAME, frame.device });
}

/// The AMD device's frame given back, once the fetcher reads the
/// firmware's framebuffer again, told so at once: one it would not leave
/// is kept.
fn giveAmdFrame(screen: *Screen) void {
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
        // into the screen's; a part says so in its tags. The BCM2712's
        // port reads a whole buffer in place of a frame, for a program
        // that shows one buffer after another.
        .flags = (if (on_pci) rtg.boards.RTGBF_COMPOSE else 0) |
            (if (scanout == .bcm2712) rtg.boards.RTGBF_DIRECT_FLIP else 0),
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
    // memory every display here reaches. Not cleared: each is cleared
    // before it is first shown. The ramfb's own frame is taken as it is
    // needed, the cursor plane's two images now.
    const frame: usize = @as(usize, screen.pitch) * screen.height;
    screen.frame_bytes = frame;
    const frames: u32 = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list))), 1);
    screen.buffers = frames;
    sys.InitSemaphore(&screen.port_lock);
    sys.InitLock(&screen.plane_lock, "rtg-fb planes", exec.LOCKORDER_DRIVER + 1, 0);
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
    // How the picture reaches the glass. A display that reads past the
    // caches is never shown a buffer drawn in, and neither is the virtio
    // GPU, whose pictures are copies the emulator keeps: they are
    // flipped between two frames, which rtg.library makes its pictures
    // in. So is the AMD display behind the firmware's framebuffer, its
    // frames counted by the pipe's interrupt and the second of them the
    // device's own memory. Every other display shows the picture the
    // library composes where it stands: the ramfb reads one whole buffer
    // by itself besides, the firmware's framebuffer none.
    if (scanout == .uefi and screen.dcn != null) {
        hookFrames(screen);
        takeAmdFrame(screen);
        board.ops = &amd_ops;
    }
    screen.flipped = isHdmi(scanout) or scanout == .virtio or (scanout == .uefi and screen.dcn != null);
    board.direct_bands = if (scanout == .ramfb) 1 else 0;
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
    // The AMD display's frame goes before the frame interrupt, which
    // giving it back waits by. The device is amdgpu.resource's, which is
    // never given back.
    giveAmdFrame(screen);
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

/// How many looks in a row must see a monitor come or go before it is
/// taken to have: a second of looks, which is what a plug that bounces as
/// it goes in, or a monitor that raises its hot-plug line before its EDID
/// reads, takes.
const settle_looks = 2;

/// How often the EDID of a monitor that has come to a running port is
/// tried.
const edid_tries_most = 3;

/// `detect` on the HDMI port `port` drives: the port woken where it does
/// not run yet, its hot-plug line read, and the monitor's EDID - its
/// first block, read again once where it does not sum to zero, and as
/// many of the extensions it names as there is room for and the port
/// reads. The EDID is read when a monitor has come - a few looks long
/// where it does not read; one that was there at the last look is the
/// one read then, so a look that finds nothing new costs the hot-plug
/// line alone. With the port running, a monitor
/// that has come or gone is taken to have once as many looks in a row as
/// a plug takes to settle have seen it, and what was there is answered
/// until then. With a monitor on the BCM2712's port, its scrambling is
/// looked after (`bcm2712.tend`). The DDC is the port's one: held
/// against every other task that talks on it.
fn detectPort(comptime port: type, screen: *Screen, asked: *rtg.RtgDetect) i32 {
    const sys = screen.sys;
    const waiter = Waiter{ .screen = screen };
    sys.ObtainSemaphore(&screen.port_lock);
    defer sys.ReleaseSemaphore(&screen.port_lock);
    const running = screen.scanning != 0;
    // A port that runs is awake: waking it again would put the
    // controller's pixel clocks back on the divider under the picture.
    if (!running) {
        const failure = port.wake(sys, waiter);
        if (failure != .none) {
            exec.kprintf(sys, "%s: %s\n", .{ MODULE_NAME, port.why(failure) });
            return err.RTGERR_NO_DISPLAY;
        }
    }
    const plugged = port.monitor();
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
        readPortEdid(port, screen, waiter);
    }
    if (running and port == bcm2712) bcm2712.tend(waiter);
    const length = @min(screen.edid_size, asked.edid_max);
    @memcpy(asked.edid[0..length], screen.edid[0..length]);
    asked.edid_size = length;
    return err.RTGERR_OK;
}

/// The EDID of the monitor on the port read into the screen's own copy:
/// nothing where it does not read.
fn readPortEdid(comptime port: type, screen: *Screen, waiter: Waiter) void {
    const first: *[edid_block]u8 = screen.edid[0..edid_block];
    var read = port.readEdid(0, first, waiter);
    if (read and !sumsToZero(first)) read = port.readEdid(0, first, waiter);
    if (!read) return;
    var blocks: u32 = 1;
    const named = @min(@as(u32, first[126]) + 1, edid_most / edid_block, port.edid_blocks);
    while (blocks < named) : (blocks += 1) {
        const block: *[edid_block]u8 = screen.edid[blocks * edid_block ..][0..edid_block];
        if (!port.readEdid(@intCast(blocks), block, waiter)) break;
    }
    screen.edid_size = blocks * edid_block;
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

/// Room for the mode the screen has just taken: the board's display
/// memory let hold as many pictures of it as the board may have, and on
/// the ramfb the frame of the driver's own given back where a picture of
/// the mode is larger than it is, to be taken anew when it is next
/// needed. What the display read is then gone: it is started again.
fn sizeFor(screen: *Screen, board: *rtg.RtgBoard) void {
    const picture = @as(usize, screen.pitch) * screen.height;
    if (!flips(screen) and picture > screen.frame_bytes) {
        // A show holds the board's compose lock: nothing is fetched into
        // the frame meanwhile.
        if (screen.composed_memory) |old| screen.sys.FreeMem(old, screen.frame_bytes + page);
        if (screen.composed) |gone| {
            if (screen.scanning == @intFromPtr(gone)) screen.scanning = 0;
        }
        screen.composed_memory = null;
        screen.composed = null;
        screen.frame_bytes = picture;
    }
    board.region.size = @as(usize, screen.buffers) * picture;
}

/// The display brought up in `mode`, or changed to it. One that is
/// flipped starts reading `frame`, the first of the mode's two, which
/// rtg.library has made the whole picture in; the mode it is in handed
/// over again is a monitor that came to an HDMI port, and the port is
/// started again with the timings handed over now, as that monitor takes
/// them. One that is not flipped comes up black.
fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode, timings: *const rtg.RtgTimings, frame: ?*rtg.RtgBitMap) i32 {
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
    }
    sizeFor(screen, board);
    if (flips(screen)) {
        const start = frame orelse return err.RTGERR_BAD_ARG;
        // What it read until now says nothing about the new mode, nor
        // to a monitor that came.
        screen.sys.ObtainSemaphore(&screen.port_lock);
        defer screen.sys.ReleaseSemaphore(&screen.port_lock);
        screen.scanning = 0;
        return if (begin(screen, start)) err.RTGERR_OK else err.RTGERR_NO_DISPLAY;
    }
    if (screen.scanning == 0 or changed) {
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
            const picture = pictureAt(screen, black);
            handOn(screen, &picture, whole(screen));
            return begin(screen, &picture);
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

/// The display started, reading `picture`. False, and said on the raw
/// port, when it did not come up.
fn begin(screen: *Screen, picture: *const rtg.RtgBitMap) bool {
    const address = @intFromPtr(picture.pixels orelse return false);
    switch (screen.scanout) {
        .ramfb, .virtio, .uefi => _ = scanFrom(screen, picture),
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
    const plugged = port.monitor();
    if (plugged != screen.plugged) {
        screen.edid_size = 0;
        screen.edid_tries = 0;
    }
    screen.plugged = plugged;
    screen.settling = 0;
    screen.frames_unseen = 0;
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
        if (!scanFrom(screen, last)) return err.RTGERR_IO;
    } else {
        const code = fetch(screen, &.{ .width = @intCast(screen.width), .height = @intCast(screen.height) });
        if (code != err.RTGERR_OK) return code;
        if (screen.composed) |frame| {
            if (!scanFrom(screen, &pictureAt(screen, frame))) return err.RTGERR_IO;
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
/// mode where the library says it is to be. A display that is flipped has
/// no more to do: its pictures are rtg.library's to make, and reach it
/// through `flipOp`. One that is not is then shown the bands - one whole
/// buffer, the library's picture, or nothing; with the mode set anew a
/// show that fails leaves it showing nothing.
fn showOp(board: *rtg.RtgBoard, what: *const rtg.RtgShow) callconv(.c) i32 {
    const anew = what.flags & rtg.boards.RTGSHOW_MODE_CHANGED != 0;
    if (anew) {
        const code = setMode(board, what.mode, what.timings, what.frame);
        if (code != err.RTGERR_OK) return code;
    }
    const screen = screenOf(board);
    if (flips(screen)) return err.RTGERR_OK;
    const code = showPlain(screen, what);
    if (code != err.RTGERR_OK and anew) _ = showPlain(screen, &.{ .mode = what.mode, .timings = what.timings });
    return code;
}

/// A rectangle of a buffer the display reads, or may be shown to read,
/// was written by the CPU: its pixels alone handed on - written back out
/// of the caches where the display goes past them, and on the virtio GPU
/// copied into the emulator's copy of it. On a display that is flipped
/// that is a frame after rtg.library made a picture in it, and on the
/// BCM2712's port a buffer read in place of one.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect) callconv(.c) i32 {
    const screen = screenOf(board);
    const x: u32 = @intCast(area.x);
    const first: u32 = @intCast(area.y);
    handOn(screen, bitmap, .{ .left = x, .top = first, .right = x + @as(u32, @intCast(area.width)), .end = first + @as(u32, @intCast(area.height)) });
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

fn copyRects(board: *rtg.RtgBoard, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, list: [*]const rtg.RtgCopy, count: u32) callconv(.c) i32 {
    return engine.copyMany(&screenOf(board).engine, src, dest, list, count);
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

/// A display that is flipped between frames the library makes its
/// pictures in: it is told which frame to read, and is handed on what
/// went into it. The bands, and the overlay and the pointer where the
/// display has no plane for them, are the library's.
const flipped_ops = rtg.boards.RtgBoardOps{
    .destroy = &destroy,
    .show = &showOp,
    .refresh = &refresh,
    .flip = &flipOp,
    .stats = &stats,
    .engine = &engine_ops,
};

/// The AMD display behind the firmware's framebuffer: flipped, between
/// frames of its own, which are written and never written back.
const amd_ops = made: {
    var more = flipped_ops;
    more.refresh = null;
    more.frames = &framesOp;
    break :made more;
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

/// The BCM2712's port's: flipped, a connector, the pointer and the
/// overlay each a plane of its own, and what its hardware does besides -
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
    more.pointer = &pointer_ops;
    more.overlay = &overlay_ops;
    break :ops more;
};

/// The JH7110's port's: flipped, a connector, the pointer a cursor
/// plane, and a video layer, its first overlay.
const jh7110_ops = ops: {
    var more = flipped_ops;
    more.detect = &detect;
    more.check_mode = &checkMode;
    more.pointer = &pointer_ops;
    more.video = &video_ops;
    break :ops more;
};

/// The virtio GPU's: flipped, what the emulator says its window is, and
/// the pointer the host's own, a cursor plane.
const virtio_ops = ops: {
    var more = flipped_ops;
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

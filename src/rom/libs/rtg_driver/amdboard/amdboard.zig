// SPDX-License-Identifier: MPL-2.0
//! An AMD display behind the framebuffer a UEFI firmware lit, as a
//! display board: the display engine that reads that framebuffer
//! (`dcn.zig`, through amdgpu.resource, which holds the device), flipped
//! between that buffer and a frame of the device's own.
//!
//! A module of its own, on the same footing as the other drivers: a
//! description of a driver called "amd" behind a ROM tag, in a file of
//! DEVS:gfxdrv/ or in a ROM, which rtg.library puts on its list. It is
//! offered the device's display function on PCI, and takes it where the
//! framebuffer the firmware lit - a panel part of the board's list -
//! lies in that function's memory and the engine reading it is one it
//! knows; where not, it declines, and the picture stays with the driver
//! that only copies into the framebuffer. Once it has made its board,
//! rtg.library retires that driver's: the framebuffer is this board's
//! first frame from then on.
//!
//! **Flipped**, for a reason of its own: a picture copied into the one
//! buffer the display reads, while it reads it, shows the top of one
//! picture and the bottom of the other. Its frames are the driver's own,
//! handed to rtg.library (`framesOp`): the firmware's framebuffer and one
//! of the device's own memory, both reached write-combining, so nothing
//! is written back - the gathered writes are fenced before the flip. The
//! library makes each picture in the frame the display is not reading
//! (its `compose/_flip.zig`) and has this driver tell the engine to read
//! it (`flipOp`). The engine takes a flip at the pipe's next update,
//! between two frames, and says when it has: a flip it has not taken two
//! frames after the one waited for puts the display back on the
//! firmware's buffer for good, each picture then made in it, and says so
//! on the log.
//!
//! The display has no cursor plane: the pointer and the overlay are
//! laid in the pictures by the library. Its connector - the one whose
//! PHY drives the lit link - is looked at by the library (`detect`,
//! `monitor.zig`): whether its hot-plug line senses a monitor, and that
//! monitor's EDID over its DDC line (`i2c.zig`). Of the timings the
//! monitor names, `check_mode` takes the one the pipe scans and, once the
//! display controller runs, every other the pipe can make (`mode.zig`):
//! progressive, no larger than the frames, up to 340 MHz on HDMI and 165
//! MHz on DVI. `show` with another mode sets it (`pipe.set`): the
//! display's clocks held at their top first (`smu.holdTop`), the link
//! HDMI where the monitor's EDID says it takes HDMI, with the mode's AVI
//! infoframe, DVI otherwise; what the set did is kept for
//! RTGCTRL_AMD_MODE.
//!
//! The pipe's update is the frame: through the device's interrupt ring,
//! its server says it to the library (`FrameDone`), and a flip and
//! WaitVBlank wait for it; where the ring cannot be had, the library
//! waits as long as a frame takes.
//!
//! The sound the link it lit can carry, which the firmware leaves
//! switched off and which no other driver can reach, is switched on as
//! the board is made: the machine's audio driver has its sinks already
//! and asks the codec what is at the far end of a link when a sink is
//! started.
//!
//! The display's clocks are asked of the device's power manager through
//! the display's own mailbox, and read from the engine (`smu.zig`) - on
//! request only, through the board's controls (RTGCTRL_AMD_*).
//!
//! The display controller - the engine's own processor - is started with
//! its firmware as the board is made, before the library first looks at
//! the monitor (`dmub.zig`), and read, or started again, through the
//! board's controls: the memory it runs with stays the board's once
//! given. Where it does not start - in a task, which reads no files,
//! without the firmware's files, or with a controller that does not come
//! up - the board stays in the pipe the firmware lit, its one mode.
//! The picture's checksum, as the timing generator sums it, is a test
//! tool asked for the same way (`crc.zig`). The engine's hot-plug lines
//! (`hpd.zig`) are listened to from the board's start, the controller's
//! notifications from the first ask for them once it runs, each through
//! a server on the device's interrupt ring; a change of the connector's
//! line has the library look at it again. AUX transactions go through
//! the controller.
//!
//! The pipe can be taken down and brought up again in its mode
//! (`pipe.zig`), on request (RTGCTRL_AMD_PIPE) and in a mode set,
//! through the video BIOS's command tables the controller runs: a flip
//! waits while it is down.
//!
//! The buffers drawn in are the machine's RAM, taken by the library as
//! each is allocated (RTGRF_SYSTEM_MEMORY, RTGRF_DMA_MEMORY).
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

const uefi = @import("uefi.zig");
const dcn = @import("dcn.zig");
const sound = @import("sound.zig");
const smu = @import("smu.zig");
const dmub = @import("dmub.zig");
const crc = @import("crc.zig");
const hpd = @import("hpd.zig");
const aux = @import("aux.zig");
const monitor = @import("monitor.zig");
const pipe = @import("pipe.zig");
const mode = @import("mode.zig");

const MODULE_NAME = "rtg-amd";
const DRIVER_NAME = "amd";
const VERSION = 1;
const REVISION = 12;
const BUILD_DATE = "26.11.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// What every row and every buffer starts on: whole cache lines.
const row_alignment = 128;
/// The most pixels a side of the picture has: what fourteen bits hold,
/// which every size here is kept in.
const largest_side = 0x3FFF;

/// Everything the board of this driver has. The library allocates it
/// beside the handle.
const Screen = struct {
    sys: *ExecBase,
    /// rtg.library, as the driver calls it.
    rtg_base: *RtgBase,
    /// The firmware's framebuffer, and the engine reading it: what it
    /// says of itself, read when the board is made.
    fb: uefi.Framebuffer,
    dcn: dcn.Engine,
    /// The frame of the device's own memory the display is flipped to and
    /// from the firmware's framebuffer, whether it still is - it is given
    /// up on once a flip is not taken - the device's address of the frame
    /// last flipped to, and the two frames as the library is handed them
    /// (`framesOp`).
    amd_frame: ?sdk.resources.amdgpu.GPUMemory = null,
    amd_flipping: bool = false,
    flip_wanted: u64 = 0,
    amd_frames: [2]rtg.RtgBitMap = .{ .{}, .{} },
    /// The picture: its size and format, rows `pitch` bytes apart in a
    /// buffer drawn in, `bytes` a pixel.
    width: u32 = 0,
    height: u32 = 0,
    format: rtg.PixelFormat = .bgra32,
    bytes: u32 = 4,
    pitch: u32 = 0,
    /// The board, and how many pictures it may have at once.
    board: *rtg.RtgBoard,
    buffers: u32 = 1,
    /// The number of the mode the display is in, 0 before the first,
    /// and its pixel clock as the library has it, 0 where not known.
    mode_id: u32 = 0,
    pixel_clock_hz: u32 = 0,
    /// What a row of a buffer is rounded up to: the board's display
    /// memory's alignment, which the library rounds a mode's rows by.
    alignment: u32 = row_alignment,
    /// The frame the display reads; 0 before it has been told.
    scanning: usize = 0,
    /// How many times the display has been handed a picture.
    updates: u32 = 0,
    /// The pipe's update, through the device's interrupt ring: its server
    /// and whether that is on.
    frame_int: exec.Interrupt = .{},
    frame_hooked: bool = false,
    /// The display's mailbox to the power manager and the clock
    /// generator, and the lock that keeps one message at a time in it.
    smu: smu.Mailbox = .{},
    smu_lock: exec.SignalSemaphore = .{},
    /// The display controller once started - the memory it runs with -
    /// and the lock that keeps one asker at a time at it.
    controller: dmub.Controller = .{},
    controller_lock: exec.SignalSemaphore = .{},
    /// The hot-plug lines and what they did, and the servers for them
    /// and for the controller's outbox.
    lines: hpd.Lines = .{},
    hot_plug_int: exec.Interrupt = .{},
    outbox_int: exec.Interrupt = .{},
    /// The board's connector, and the lock that keeps one reader at a
    /// time at the I2C engine.
    connector: monitor.Connector = .{},
    ddc_lock: exec.SignalSemaphore = .{},
    /// How many times the library has looked at it.
    looks: u32 = 0,
    /// The lock a flip and the pipe taken down and up take, one at a time.
    pipe_lock: exec.SignalSemaphore = .{},
    /// What the last mode set did.
    last_set: rtg.tags.RtgAmdPipe = .{},
    /// The top of the display clock's and the pipes' clock's levels, in
    /// kHz, once read: what a mode is worked out at.
    top_display_khz: u32 = 0,
    top_pipes_khz: u32 = 0,
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

/// The pipe's update: the frame said to the library, which counts it and
/// wakes whoever waits for one. The device's ring hands on that update
/// alone.
fn frameServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const screen: *Screen = @ptrCast(@alignCast(data.?));
    dcn.takeFrame(screen.dcn);
    drivers(screen).FrameDone(screen.board);
    return 1;
}

/// A hot-plug line's change, counted.
fn hotPlugServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const screen: *Screen = @ptrCast(@alignCast(data.?));
    const raised = hpd.take(screen.dcn, &screen.lines);
    // The board's own connector's line: the library looks at it again.
    const line = screen.connector.hpd_line;
    if (line != monitor.no_line and raised & @as(u32, 1) << @intCast(line) != 0) {
        drivers(screen).MonitorChanged(screen.board);
    }
    return 1;
}

/// The controller's notifications, read.
fn outboxServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const screen: *Screen = @ptrCast(@alignCast(data.?));
    dmub.take(screen.dcn, &screen.controller);
    return 1;
}

/// The hot-plug lines listened to, and the controller where it runs;
/// under the controller's lock.
fn listen(screen: *Screen) void {
    if (!screen.lines.listening) {
        screen.hot_plug_int = .{
            .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
            .data = screen,
            .code = &hotPlugServer,
        };
        _ = hpd.listen(screen.dcn, &screen.lines, &screen.hot_plug_int);
    }
    if (screen.controller.running and !screen.controller.listening) {
        screen.outbox_int = .{
            .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
            .data = screen,
            .code = &outboxServer,
        };
        _ = dmub.listen(screen.dcn, &screen.controller, &screen.outbox_int);
    }
}

/// The frame's server on, through the device's interrupt ring.
fn hookFrames(screen: *Screen) void {
    if (screen.frame_hooked) return;
    screen.frame_int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = screen,
        .code = &frameServer,
    };
    screen.frame_hooked = dcn.hookFrames(screen.dcn, &screen.frame_int);
    if (!screen.frame_hooked) exec.kprintf(screen.sys, "%s: the display's frames cannot be had from the device, so they are timed by the clock\n", .{MODULE_NAME});
}

/// The frame's server off again.
fn unhookFrames(screen: *Screen) void {
    if (!screen.frame_hooked) return;
    dcn.unhookFrames(screen.dcn, &screen.frame_int);
    screen.frame_hooked = false;
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

/// The display flipped to `picture`, from the pipe's next update on
/// (`dcn.flip`), named by the device's own address of it: the
/// framebuffer's the fetcher read at start, the frame's the resource
/// gave with it. The frame is not in the window the framebuffer is in -
/// on a machine whose device memory is part of its RAM the CPU reaches
/// it there - so its address in the machine says nothing of the
/// device's. Where flipping was given up, the frames are that
/// framebuffer and nothing tells the display to read elsewhere. So of
/// the picture it is handed, this takes which of its two frames it is.
fn scanFrom(screen: *Screen, picture: *const rtg.RtgBitMap) void {
    const address = @intFromPtr(picture.pixels orelse return);
    if (address == screen.scanning) return;
    if (screen.amd_flipping) {
        const frame = screen.amd_frame.?;
        screen.flip_wanted = if (address == @as(usize, @intCast(frame.cpu))) frame.device else screen.dcn.surface;
        dcn.flip(screen.dcn, screen.flip_wanted, false);
    }
    screen.scanning = address;
}

/// The display told to read `frame` from its next frame on: one of the
/// two rtg.library makes its pictures in. It is seen to have taken it
/// (`flipAmd`).
fn flipOp(board: *rtg.RtgBoard, frame: *rtg.RtgBitMap) callconv(.c) i32 {
    if (frame.pixels == null) return err.RTGERR_BAD_ARG;
    const screen = screenOf(board);
    // Not while the pipe is down: no update would take it.
    screen.sys.ObtainSemaphore(&screen.pipe_lock);
    defer screen.sys.ReleaseSemaphore(&screen.pipe_lock);
    return flipAmd(screen, frame);
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
    scanFrom(screen, frame);
    pace(screen, 1);
    const found = screen.dcn;
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
    const found = screen.dcn;
    screen.amd_flipping = false;
    dcn.flip(found, found.surface, true);
    exec.kprintf(screen.sys, "%s: the display did not take the flip to 0x%lx, so the picture goes into the firmware's framebuffer again\n", .{ MODULE_NAME, screen.flip_wanted });
    screen.scanning = screen.fb.pixels;
}

/// The AMD display's two frames, for rtg.library to make its pictures
/// in: the firmware's framebuffer and a frame of the device's own memory
/// (`takeAmdFrame`), both reached write-combining and both with the
/// framebuffer's row length, which is what the fetcher reads with.
/// Without such a frame, and once the flips were given up, the
/// framebuffer twice: the pictures are then made in the one frame the
/// display reads.
fn framesOp(board: *rtg.RtgBoard, shown: *const rtg.RtgMode, into: *[2]?*rtg.RtgBitMap) callconv(.c) i32 {
    const screen = screenOf(board);
    const fb = screen.fb;
    if (shown.width > fb.width or shown.height > fb.height) return err.RTGERR_BAD_MODE;
    screen.amd_frames[0] = .{
        .pixels = @ptrFromInt(fb.pixels),
        .width = shown.width,
        .height = shown.height,
        .pitch = fb.pitch,
        .format = shown.format,
        .size_bytes = @as(usize, fb.pitch) * shown.height,
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
    const fb = screen.fb;
    const found = screen.dcn;
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
    const found = screen.dcn;
    dcn.flip(found, found.surface, true);
    var looks: u32 = 0;
    while (!dcn.flipTaken(found, found.surface)) : (looks += 1) {
        if (looks == 3) return;
        pace(screen, 1);
    }
    dcn.freeFrame(found, &frame);
}

// --- the board -------------------------------------------------------------------

/// The framebuffer the firmware lit, where it lies in a memory range of
/// a function on PCI: the tags of the board's part for it, which say
/// its address, its size, its row and its format. Null on a machine
/// whose firmware lit none, and where that one lies elsewhere.
fn litBy(driver: *rtg.RtgDriver, function: *const sdk.pci.PCIDevice) ?[*]const TagItem {
    const eb = driver.expansion_base orelse return null;
    const part = eb.FindBoardPart(null, st.PARTKIND_PANEL, st.CHIP_UEFI_FB) orelse return null;
    const address: u64 = driver.rtg_base.GetRtgTagData(st.PART_Address, 0, part.tags);
    if (address == 0) return null;
    for (function.bars) |bar| {
        if (bar.size == 0 or bar.flags & sdk.pci.PCIBAR_IO != 0) continue;
        if (address >= bar.address and address - bar.address < bar.size) return part.tags;
    }
    return null;
}

/// The device's display function is offered: taken where the framebuffer
/// the firmware lit lies in its memory and the engine reading it is one
/// this knows, and a board made of it with the firmware's mode. Declined
/// where not, and the firmware's picture stays as it is shown.
///
/// What the picture is - its size, its row, its format, where it lies -
/// is the board's part's to say, as the firmware said it; what the
/// device's own tags add is the settings' (`RTGA_Buffers`), and that the
/// display is lit (`RTGA_Adopt`).
fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, device_tags: ?[*]const TagItem) callconv(.c) i32 {
    const rb = driver.rtg_base;
    const sys = driver.sys_base;
    const function = device.pci orelse return err.RTGERR_NO_DISPLAY;
    const tag_list = litBy(driver, function) orelse return err.RTGERR_NO_DISPLAY;

    // What the tags have to say, looked at before anything is taken.
    const format: rtg.PixelFormat = @enumFromInt(@as(u8, @truncate(rb.GetRtgTagData(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32), tag_list))));
    if (format != .bgra32 and format != .rgb565) return err.RTGERR_BAD_FORMAT;
    const width: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Width, 0, tag_list));
    const height: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Height, 0, tag_list));
    if (width == 0 or height == 0) return err.RTGERR_BAD_TAGS;
    if (width > largest_side or height > largest_side) return err.RTGERR_BAD_TAGS;
    const bytes = programs(rb).RtgFormatBits(@intFromEnum(format)) / 8;
    // Nothing to probe of the framebuffer: the firmware set it up, and
    // the board says what it set up.
    const fb = uefi.find(
        rb.GetRtgTagData(st.PART_Address, 0, tag_list),
        @truncate(rb.GetRtgTagData(tags.RTGA_Pitch, 0, tag_list)),
        width,
        height,
        bytes,
    ) orelse return err.RTGERR_NO_DISPLAY;
    // The engine reading it, where it is one this driver knows: what it
    // says of itself goes in the boot's lines.
    var found = dcn.find(sys, fb) orelse return err.RTGERR_NO_DISPLAY;
    found.rtg_base = rb;

    const board = rb.CreateBoard(driver, device, &.{
        .ops = &ops,
        .instance_size = @sizeOf(Screen),
        // The display runs as the firmware lit it: its mode is kept.
        .flags = rtg.boards.RTGBF_ADOPTED,
        .format = format,
    }) orelse return err.RTGERR_NO_MEMORY;
    const screen = screenOf(board);
    screen.* = .{
        .sys = sys,
        .rtg_base = programs(rb),
        .fb = fb,
        .dcn = found,
        .width = width,
        .height = height,
        .format = format,
        .bytes = bytes,
        .board = board,
        .smu = smu.find(found),
    };
    sys.InitSemaphore(&screen.smu_lock);
    sys.InitSemaphore(&screen.controller_lock);
    sys.InitSemaphore(&screen.ddc_lock);
    sys.InitSemaphore(&screen.pipe_lock);
    screen.connector = monitor.boards(found);
    tellConnector(screen);
    // Its hot-plug lines listened to from the start, so a monitor that
    // comes or goes has the library look at the connector again.
    listen(screen);
    // The display controller started before the library first looks at
    // the monitor, so the board offers every mode it can set.
    startController(screen);
    // The board's buffers start, and their rows are rounded, as its tags
    // say; whole cache lines where they say nothing.
    const asked_alignment: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Alignment, 0, tag_list));
    if (asked_alignment != 0) screen.alignment = asked_alignment;
    // One mode of its own: the picture the firmware lit.
    const own: rtg.RtgTimings = .{ .h_active = width, .v_active = height };
    if (rb.AddBoardMode(board, &own, @intFromEnum(format), rtg.modes.RTGMF_DEFAULT) == 0) {
        rb.DeleteBoard(board);
        return err.RTGERR_NO_MEMORY;
    }
    screen.pitch = rowBytes(screen, width);
    // The sound the link can carry, switched on: all that is wanted of
    // this side.
    _ = sound.soundUp(found);
    // Its frames counted by the pipe's interrupt, and the second of them
    // the device's own memory.
    hookFrames(screen);
    takeAmdFrame(screen);

    // At most as many pictures of the mode as the board asks for, each
    // taken by the library as it is allocated. Not cleared: each is
    // cleared before it is first shown. No band is read by the display
    // itself.
    const frame: usize = @as(usize, screen.pitch) * height;
    // As many as the settings say of the device, else as the part does.
    const part_buffers = rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list);
    screen.buffers = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, part_buffers, device_tags))), 1);
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

/// The display controller started with its firmware as the board is
/// made, so the board can set modes (`dmub.start`). Where it cannot be -
/// in a task, which reads no files, without the firmware's files, or with
/// a controller that does not come up - the board stays in the pipe the
/// firmware lit, and the log says why.
fn startController(screen: *Screen) void {
    const sys = screen.sys;
    if (sys.FindTask(null).?.node.type != .process) {
        exec.kprintf(sys, "%s: the board is made in a task, which reads no files: the display controller is not started, and the display stays in the firmware's mode\n", .{MODULE_NAME});
        return;
    }
    sys.ObtainSemaphore(&screen.controller_lock);
    defer sys.ReleaseSemaphore(&screen.controller_lock);
    var started: rtg.tags.RtgAmdController = .{};
    const result = dmub.start(screen.dcn, &screen.controller, &started);
    if (result == err.RTGERR_OK) return;
    exec.kprintf(sys, "%s: the display controller did not start (%ld, at stage %d): the display stays in the firmware's mode\n", .{ MODULE_NAME, @as(i64, result), started.stage });
}

/// The board's connector on the boot's lines.
fn tellConnector(screen: *const Screen) void {
    const on = screen.connector;
    if (!on.found) {
        exec.kprintf(screen.sys, "%s: no connector the video BIOS lists drives the lit link\n", .{dcn.owner});
        return;
    }
    exec.kprintf(screen.sys, "%s: the board's connector is the BIOS's %d (kind %d), DDC line %d, hot-plug line %d (0 for none)\n", .{
        dcn.owner,
        on.index,
        on.kind,
        if (on.ddc_line == monitor.no_line) @as(u32, 0) else on.ddc_line + 1,
        if (on.hpd_line == monitor.no_line) @as(u32, 0) else on.hpd_line + 1,
    });
}

/// The display put back on the firmware's framebuffer, where it reads
/// the device's frame, and the frame's server off: the frame goes before
/// the server, which giving it back waits by. The device is
/// amdgpu.resource's, which is never given back.
fn halt(screen: *Screen) void {
    giveAmdFrame(screen);
    unhookFrames(screen);
    hpd.unlisten(screen.dcn, &screen.lines, &screen.hot_plug_int);
    dmub.unlisten(screen.dcn, &screen.controller, &screen.outbox_int);
    screen.scanning = 0;
}

/// The device is taken from the driver: the display reads the firmware's
/// framebuffer again, as the firmware left it.
fn detach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice) callconv(.c) void {
    _ = driver;
    const screen: *Screen = @ptrCast(@alignCast(device.driver_data orelse return));
    halt(screen);
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    halt(screenOf(board));
}

/// Bytes a row of a buffer `width` pixels wide has: the pixels, rounded
/// up to the board's alignment, as the library rounds a mode's.
fn rowBytes(screen: *const Screen, width: u32) u32 {
    const row = width * screen.bytes;
    const step = screen.alignment;
    return (row + step - 1) / step * step;
}

/// The board's one op for what is on the glass (`RtgShow`): put in the
/// mode where the library says it is to be - set where the pipe scans
/// another - the display reading the first of its two frames, which
/// rtg.library has made the whole picture in. Its pictures after that
/// reach it through `flipOp`.
fn showOp(board: *rtg.RtgBoard, what: *const rtg.RtgShow) callconv(.c) i32 {
    if (what.flags & rtg.boards.RTGSHOW_MODE_CHANGED == 0) return err.RTGERR_OK;
    const screen = screenOf(board);
    const shown = what.mode;
    // A row as the library makes one of a buffer.
    if (shown.format != screen.format or shown.pitch != rowBytes(screen, shown.width)) return err.RTGERR_BAD_MODE;
    const start = what.frame orelse return err.RTGERR_BAD_ARG;
    if (start.pixels == null) return err.RTGERR_BAD_ARG;
    if (!scans(screen, what.timings)) {
        const code = setMode(screen, what.timings);
        if (code != err.RTGERR_OK) return code;
    }
    screen.mode_id = shown.id;
    screen.pixel_clock_hz = shown.pixel_clock_hz;
    screen.width = shown.width;
    screen.height = shown.height;
    screen.pitch = shown.pitch;
    // Room for as many pictures of the mode as the board may have.
    board.region.size = @as(usize, screen.buffers) * @as(usize, shown.pitch) * shown.height;
    // What it read until now says nothing about the new mode.
    screen.scanning = 0;
    scanFrom(screen, start);
    return err.RTGERR_OK;
}

/// What is on the connector (`monitor.detect`), one reader at a time at
/// the I2C engine.
fn detectOp(board: *rtg.RtgBoard, into: *rtg.modes.RtgDetect) callconv(.c) i32 {
    const screen = screenOf(board);
    screen.sys.ObtainSemaphore(&screen.ddc_lock);
    defer screen.sys.ReleaseSemaphore(&screen.ddc_lock);
    screen.looks +%= 1;
    return monitor.detect(screen.dcn, screen.connector, into);
}

/// The timings the board makes: the one the pipe scans, whose picture
/// and whose line and frame it has; once the display controller runs,
/// every other a mode can be made of in the frames (`mode.of`, at the
/// display's clocks' top) on an HDMI or DVI connector, at a pixel clock
/// the link the monitor takes carries.
fn checkModeOp(board: *rtg.RtgBoard, timings: *const rtg.RtgTimings) callconv(.c) i32 {
    const screen = screenOf(board);
    if (monitor.isLit(screen.dcn, timings.*)) return err.RTGERR_OK;
    if (!screen.controller.running) return err.RTGERR_BAD_MODE;
    if (screen.connector.kind != sdk.resources.amdgpu.GPUCONNECTOR_HDMI and screen.connector.kind != sdk.resources.amdgpu.GPUCONNECTOR_DVI) return err.RTGERR_BAD_MODE;
    const held = topHeld(screen) orelse return err.RTGERR_BAD_MODE;
    _ = mode.of(timings.*, screen.fb.width, screen.fb.height, held) orelse return err.RTGERR_BAD_MODE;
    const most_khz: u32 = if (takesHdmi(screen)) hdmi_most_khz else dvi_most_khz;
    if (timings.pixel_clock_hz / 1000 > most_khz) return err.RTGERR_BAD_MODE;
    return err.RTGERR_OK;
}

/// The fastest pixel clock HDMI is set at, unscrambled, and DVI on one
/// link, in kHz.
const hdmi_most_khz: u32 = 340_000;
const dvi_most_khz: u32 = 165_000;

/// What a mode is worked out at before it is set: the display's clocks
/// at the top of their levels - read from the power manager the first
/// time, one asker at a time at the mailbox - the fetcher's rows and the
/// hub's watermarks. Null where the levels cannot be read.
fn topHeld(screen: *Screen) ?mode.Held {
    if (screen.top_display_khz == 0) {
        screen.sys.ObtainSemaphore(&screen.smu_lock);
        defer screen.sys.ReleaseSemaphore(&screen.smu_lock);
        var levels: rtg.tags.RtgAmdClocks = .{};
        if (smu.clocks(screen.dcn, screen.smu, &levels) == err.RTGERR_OK and levels.disp_count != 0) {
            screen.top_pipes_khz = smu.top(levels.dpp_mhz[0..levels.disp_count]) * 1000;
            screen.top_display_khz = smu.top(levels.disp_mhz[0..levels.disp_count]) * 1000;
        }
    }
    if (screen.top_display_khz == 0 or screen.top_pipes_khz == 0) return null;
    return mode.heldOf(screen.dcn, screen.dcn.fetcher, screen.top_display_khz, screen.top_pipes_khz);
}

/// Whether the pipe scans `timings`: its picture, its line and its frame,
/// at the pixel clock the board's mode has where both are known.
fn scans(screen: *const Screen, timings: *const rtg.RtgTimings) bool {
    if (!monitor.isLit(screen.dcn, timings.*)) return false;
    if (screen.pixel_clock_hz == 0 or timings.pixel_clock_hz == 0) return true;
    return screen.pixel_clock_hz == timings.pixel_clock_hz;
}

/// Whether the link is set up as HDMI: on an HDMI connector, where the
/// monitor's EDID says it takes HDMI; without an EDID, as the firmware
/// lit it.
fn takesHdmi(screen: *Screen) bool {
    if (screen.connector.kind != sdk.resources.amdgpu.GPUCONNECTOR_HDMI) return false;
    var said: rtg.RtgMonitorInfo = .{};
    _ = screen.rtg_base.GetBoardMonitor(screen.board, &said, @sizeOf(rtg.RtgMonitorInfo));
    if (said.flags & rtg.modes.RTGMON_EDID == 0) return pipe.litAsHdmi(screen.dcn);
    return said.flags & rtg.modes.RTGMON_HDMI != 0;
}

/// What the AVI infoframe says beyond the picture: the RGB range in
/// full, where the monitor lets it be said; no number for a mode that
/// HDMI 1.4's vendor infoframe names to a monitor short of HDMI 2.0.
fn aviFlags(said: *const rtg.RtgMonitorInfo, timings: *const rtg.RtgTimings) u32 {
    var flags: u32 = 0;
    if (said.flags & rtg.modes.RTGMON_RANGE_SELECTABLE != 0) flags |= rtg.RTGAVI_RANGE_FULL;
    const vendor_named = switch (timings.vic) {
        93, 94, 95, 98 => true,
        else => false,
    };
    if (vendor_named and said.flags & rtg.modes.RTGMON_HDMI2 == 0) flags |= rtg.RTGAVI_NO_VIC;
    return flags;
}

/// The pipe set to `timings` (`pipe.set`): the display's clocks held at
/// their top first, the link HDMI or DVI as the monitor takes it, with
/// the mode's AVI infoframe on HDMI. One asker at a time at the
/// controller and the mailbox, and no flip meanwhile. What it did is
/// kept (RTGCTRL_AMD_MODE) and said on the log; on success the engine is
/// taken to scan the new mode.
fn setMode(screen: *Screen, timings: *const rtg.RtgTimings) i32 {
    const sys = screen.sys;
    const at_top = topHeld(screen) orelse return err.RTGERR_BAD_MODE;
    _ = mode.of(timings.*, screen.fb.width, screen.fb.height, at_top) orelse return err.RTGERR_BAD_MODE;
    const hdmi = takesHdmi(screen);
    var avi: [rtg.RTG_AVI_BYTES]u8 = @splat(0);
    var sends_avi = false;
    if (hdmi) {
        var said: rtg.RtgMonitorInfo = .{};
        _ = screen.rtg_base.GetBoardMonitor(screen.board, &said, @sizeOf(rtg.RtgMonitorInfo));
        sends_avi = drivers(screen).BuildAviInfoFrame(timings, aviFlags(&said, timings), &avi) == rtg.RTG_AVI_BYTES;
    }

    sys.ObtainSemaphore(&screen.controller_lock);
    defer sys.ReleaseSemaphore(&screen.controller_lock);
    if (!screen.controller.running) return err.RTGERR_NOT_SUPPORTED;
    sys.ObtainSemaphore(&screen.smu_lock);
    var clocks: rtg.tags.RtgAmdClocks = .{};
    const hold = smu.holdTop(screen.dcn, screen.smu, &clocks);
    sys.ReleaseSemaphore(&screen.smu_lock);
    if (hold != err.RTGERR_OK) {
        exec.kprintf(sys, "%s: the display's clocks could not be held at their top (%ld), so the mode is not set\n", .{ MODULE_NAME, @as(i64, hold) });
        return @intCast(hold);
    }
    // Worked out at the clocks as they run now, where they read.
    var running = at_top;
    if (clocks.disp_khz != 0 and clocks.dpp_khz != 0) running = mode.heldOf(screen.dcn, screen.dcn.fetcher, clocks.disp_khz, clocks.dpp_khz);
    const new = mode.of(timings.*, screen.fb.width, screen.fb.height, running) orelse return err.RTGERR_BAD_MODE;

    sys.ObtainSemaphore(&screen.pipe_lock);
    defer sys.ReleaseSemaphore(&screen.pipe_lock);
    const code = pipe.set(screen.dcn, &screen.controller, screen.connector, &new, hdmi, if (sends_avi) &avi else null, screen.pixel_clock_hz, &screen.last_set);
    const done = &screen.last_set;
    if (code != err.RTGERR_OK) {
        exec.kprintf(sys, "%s: %dx%d at %d kHz not set (%ld), stopped at stage %d\n", .{ MODULE_NAME, new.width, new.height, timings.pixel_clock_hz / 1000, @as(i64, code), done.stage });
        return code;
    }
    screen.dcn.width = new.width;
    screen.dcn.height = new.height;
    screen.dcn.h_total = new.h_total;
    screen.dcn.v_total = new.v_total;
    crc.fit(screen.dcn);
    exec.kprintf(sys, "%s: the display set to %dx%d at %d kHz on %s, display clock %d kHz, down for %d us%s\n", .{
        MODULE_NAME,
        new.width,
        new.height,
        timings.pixel_clock_hz / 1000,
        if (hdmi) @as([*:0]const u8, "HDMI") else "DVI",
        clocks.disp_khz,
        done.down_us,
        if (done.underflow != 0) @as([*:0]const u8, ", and it ran short of pixels") else "",
    });
    return err.RTGERR_OK;
}

fn stats(board: *rtg.RtgBoard, into: *rtg.RtgBoardStats) callconv(.c) void {
    into.frames = screenOf(board).updates;
}

/// The board's own controls (RTGCTRL_AMD_*): the display's mailbox to the
/// power manager asked, the display controller read, started or sent an
/// AUX transaction, the hot-plug lines and the controller's
/// notifications listened to and counted - one asker at a time at the
/// mailbox and at the controller - the picture's checksum read, the
/// pipe taken down and up, and what the last mode set did read. Nothing
/// else is taken.
fn control(board: *rtg.RtgBoard, what: u32, value: isize) callconv(.c) isize {
    const screen = screenOf(board);
    switch (what) {
        rtg.tags.RTGCTRL_AMD_FIRMWARE => {
            screen.sys.ObtainSemaphore(&screen.smu_lock);
            defer screen.sys.ReleaseSemaphore(&screen.smu_lock);
            return smu.version(screen.sys, screen.smu);
        },
        rtg.tags.RTGCTRL_AMD_CLOCKS => {
            if (value == 0) return err.RTGERR_BAD_ARG;
            const into: *rtg.tags.RtgAmdClocks = @ptrFromInt(@as(usize, @bitCast(value)));
            screen.sys.ObtainSemaphore(&screen.smu_lock);
            defer screen.sys.ReleaseSemaphore(&screen.smu_lock);
            return smu.clocks(screen.dcn, screen.smu, into);
        },
        rtg.tags.RTGCTRL_AMD_CONTROLLER, rtg.tags.RTGCTRL_AMD_START_CONTROLLER => {
            if (value == 0) return err.RTGERR_BAD_ARG;
            const into: *rtg.tags.RtgAmdController = @ptrFromInt(@as(usize, @bitCast(value)));
            screen.sys.ObtainSemaphore(&screen.controller_lock);
            defer screen.sys.ReleaseSemaphore(&screen.controller_lock);
            if (what == rtg.tags.RTGCTRL_AMD_CONTROLLER) {
                into.* = .{};
                dmub.read(screen.dcn, into);
                into.firmware = screen.controller.version;
                return err.RTGERR_OK;
            }
            return dmub.start(screen.dcn, &screen.controller, into);
        },
        rtg.tags.RTGCTRL_AMD_EVENTS => {
            if (value == 0) return err.RTGERR_BAD_ARG;
            const into: *rtg.tags.RtgAmdEvents = @ptrFromInt(@as(usize, @bitCast(value)));
            screen.sys.ObtainSemaphore(&screen.controller_lock);
            defer screen.sys.ReleaseSemaphore(&screen.controller_lock);
            listen(screen);
            if (into.poke != 0) {
                if (!hpd.poke(screen.dcn, &screen.lines, into.poke -% 1)) return err.RTGERR_BAD_ARG;
                // The line's filter and the ring's way take a few
                // milliseconds; the count is read past them.
                var never: exec.Waitable = .{};
                const list = [_]*exec.Waitable{&never};
                _ = screen.sys.WaitForAny(&list, 1, 50_000);
            }
            into.* = .{};
            into.lines_heard = @intFromBool(screen.lines.listening);
            into.hot_plug_interrupts = screen.lines.interrupts;
            into.line_changes = screen.lines.changes;
            hpd.read(screen.dcn, into);
            dmub.counts(&screen.controller, into);
            into.connector_looks = screen.looks;
            return err.RTGERR_OK;
        },
        rtg.tags.RTGCTRL_AMD_AUX => {
            if (value == 0) return err.RTGERR_BAD_ARG;
            const request: *rtg.tags.RtgAmdAux = @ptrFromInt(@as(usize, @bitCast(value)));
            if (request.through == rtg.tags.RTG_AMD_AUX_BY_ENGINE) return auxByEngine(screen, request);
            screen.sys.ObtainSemaphore(&screen.controller_lock);
            defer screen.sys.ReleaseSemaphore(&screen.controller_lock);
            listen(screen);
            if (!screen.controller.listening) return err.RTGERR_NOT_SUPPORTED;
            aux.read(screen.dcn, request.instance, &request.found);
            if (!aux.ready(screen.dcn, request.instance)) return err.RTGERR_IN_USE;
            const result = dmub.aux(screen.dcn, &screen.controller, request);
            aux.read(screen.dcn, request.instance, &request.after);
            return result;
        },
        rtg.tags.RTGCTRL_AMD_EDID => {
            if (value == 0) return err.RTGERR_BAD_ARG;
            const into: *rtg.tags.RtgAmdEdid = @ptrFromInt(@as(usize, @bitCast(value)));
            screen.sys.ObtainSemaphore(&screen.ddc_lock);
            defer screen.sys.ReleaseSemaphore(&screen.ddc_lock);
            return monitor.edid(screen.dcn, screen.connector, into);
        },
        rtg.tags.RTGCTRL_AMD_CRC => {
            if (value == 0) return err.RTGERR_BAD_ARG;
            const into: *rtg.tags.RtgAmdCrc = @ptrFromInt(@as(usize, @bitCast(value)));
            return crc.read(screen.dcn, into);
        },
        rtg.tags.RTGCTRL_AMD_PIPE => {
            if (value == 0) return err.RTGERR_BAD_ARG;
            const into: *rtg.tags.RtgAmdPipe = @ptrFromInt(@as(usize, @bitCast(value)));
            screen.sys.ObtainSemaphore(&screen.controller_lock);
            defer screen.sys.ReleaseSemaphore(&screen.controller_lock);
            screen.sys.ObtainSemaphore(&screen.pipe_lock);
            defer screen.sys.ReleaseSemaphore(&screen.pipe_lock);
            return pipe.cycle(screen.dcn, &screen.controller, screen.connector, screen.pixel_clock_hz, into);
        },
        rtg.tags.RTGCTRL_AMD_MODE => {
            if (value == 0) return err.RTGERR_BAD_ARG;
            const into: *rtg.tags.RtgAmdPipe = @ptrFromInt(@as(usize, @bitCast(value)));
            screen.sys.ObtainSemaphore(&screen.pipe_lock);
            defer screen.sys.ReleaseSemaphore(&screen.pipe_lock);
            into.* = screen.last_set;
            return err.RTGERR_OK;
        },
        else => return err.RTGERR_NOT_SUPPORTED,
    }
}

/// One AUX transaction by the channel's own engine, as RTGCTRL_AMD_AUX
/// asks, one at a time with the board's looks at its connector.
fn auxByEngine(screen: *Screen, request: *rtg.tags.RtgAmdAux) isize {
    if (request.length > request.data.len) return err.RTGERR_BAD_ARG;
    if (request.instance >= aux.lines) return err.RTGERR_BAD_ARG;
    screen.sys.ObtainSemaphore(&screen.ddc_lock);
    defer screen.sys.ReleaseSemaphore(&screen.ddc_lock);
    aux.read(screen.dcn, request.instance, &request.found);
    const reply = aux.transfer(screen.dcn, request.instance, dmub.auxAction(request), request.address, request.data[0..request.length]);
    aux.read(screen.dcn, request.instance, &request.after);
    if (reply.result == rtg.tags.RTG_AMD_AUX_BUSY) return err.RTGERR_IN_USE;
    request.result = reply.result;
    request.reply = reply.answer;
    request.replied = reply.bytes;
    return err.RTGERR_OK;
}

/// Flipped, between frames of its own, which are written and never
/// written back: no `refresh`. The bands, the overlay and the pointer are
/// the library's.
const ops = rtg.boards.RtgBoardOps{
    .destroy = &destroy,
    .show = &showOp,
    .flip = &flipOp,
    .frames = &framesOp,
    .stats = &stats,
    .control = &control,
    .detect = &detectOp,
    .check_mode = &checkModeOp,
};

const driver_ops = rtg.RtgDriverOps{ .attach = &attach, .detach = &detach };

/// What it takes: the panel part that is the firmware's framebuffer,
/// before the driver that only copies into it.
/// A display function of AMD's on PCI.
const amd_vendor: u32 = 0x1002;
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_VENDOR | rtg.drivers.RTGMATCH_CLASS, .vendor = amd_vendor, .class_code = 0x03_0000, .class_mask = 0xFF_0000 },
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

export const rtg_amd_tag: rtg.ResidentRtgDriver linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&rtg_amd_tag),
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

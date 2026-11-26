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
//! The picture is mirrored about either axis by the fetcher that reads
//! it (`mode.writeTurn`): its horizontal mirror, half a turn, or both -
//! the frames and the firmware's framebuffer alike - and the pointer and
//! the overlay are turned with it. The firmware's picture is put where
//! it belongs as the board takes the pipe: its scaler in its bypass
//! (`mode.passThrough`), where the firmware leaves it laying the picture
//! a pixel or two right of and below its place.
//!
//! The pointer is the pipe's own cursor (`cursor.zig`), on a board in
//! `bgra32` whose engine's blender is reached: the library's image
//! copied into one of two of the device's memory, and the cursor told
//! to read it, where it is and whether it is shown - so the pictures
//! never hold it, and a move rewrites nothing but the cursor's place.
//!
//! The overlay is a plane of its own (`plane.zig`) where the pointer is
//! the cursor: a free pipe of the engine lit on the picture's timing
//! generator, reading one of two images of the device's memory that take
//! turns - the library's image copied into the one not read, once the
//! plane has taken the one before - and laid over the picture by the
//! blender with its pixels' alpha. Only the part of it on the glass is
//! fetched, and with the picture mirrored the plane is mirrored with it,
//! its place on the glass mirrored too. Its pipe's cursor is the pointer
//! too, so the pointer stays above it. It goes down with the pipe - for
//! a mode set, the monitor's sleep - and is lit again after; its schedule
//! is worked out for its width on the glass at the display's clocks as
//! they are set with it counted at its largest, so it moves with the
//! clocks as they are. Its connector - the one whose
//! PHY drives the lit link - is looked at by the library (`detect`,
//! `monitor.zig`): whether its hot-plug line senses a monitor, and that
//! monitor's EDID over its DDC line (`i2c.zig`). Of the timings the
//! monitor names, `check_mode` takes the one the pipe scans and, once the
//! display controller runs, every other the pipe can make (`mode.zig`):
//! progressive, no larger than the frames, up to 340 MHz on HDMI and 165
//! MHz on DVI - and at the clocks one of the power manager's states
//! serves for its picture. `show` with another mode sets it
//! (`pipe.set`): the display's clocks raised first where its picture
//! needs them faster, the link HDMI where the monitor's EDID says it
//! takes HDMI, with the mode's AVI infoframe, DVI otherwise, and the
//! clocks lowered to what the picture needs once it runs; what the set
//! did is kept for RTGCTRL_AMD_MODE.
//!
//! The pipe's update is the frame: through the device's interrupt ring,
//! its server says it to the library (`FrameDone`), and a flip and
//! WaitVBlank wait for it; where the ring cannot be had, the library
//! waits as long as a frame takes.
//!
//! The colours go out in full or limited range (`colours.zig`): the one
//! the settings ask for, else limited for a CEA mode to an HDMI monitor
//! that does not let its range be chosen, else full - set in the
//! blender's output matrix at each show, and said in the AVI infoframe,
//! which is written into the running link where it changed, in the
//! firmware's mode as well, which sends none.
//!
//! The monitor's brightness is its own, asked for and set over its DDC
//! with DDC/CI - its control 0x10, in per cent of its largest - by
//! rtg.library's GetMonitorControl and SetMonitorControl, each transfer
//! a transaction of the I2C engine's on the connector's DDC line. A
//! monitor without DDC/CI, or with it switched off in its menu, answers
//! nothing; a DisplayPort connector has none of it yet.
//!
//! Asleep (`power`), the monitor is sent nothing, which it sleeps at:
//! the pipe goes down in its mode - an HDMI monitor muted, the timing
//! generator stopped, the link let go of, the PHY off and its PLL
//! powered down - and comes up in it again on waking (`pipe.sleep`,
//! `pipe.wake`), the link's sound with it. No frames are counted
//! meanwhile: a flip is where the fetcher reads once it runs again, and
//! the library waits by the clock. A mode set while asleep wakes the
//! pipe for the set and puts it to sleep after. Without the display
//! controller, which runs the tables the PHY is switched by, the board
//! does not sleep.
//!
//! The sound the link it lit can carry, which the firmware leaves
//! switched off and which no other driver can reach, is set each time
//! the board is put in a mode (`sound.soundUp`): at the mode's pixel
//! clock, the codec's endpoint told what the monitor plays as its EDID
//! says - none where it plays none, or the link is DVI. The machine's
//! audio driver has its sinks already and asks the codec what is at the
//! far end of a link when a sink is started.
//!
//! The display's clocks are set for what its pipes read (`bandwidth.zig`,
//! `clocks.zig`): the vendor's model of the engine's bandwidth works out,
//! for the picture and each plane lit beside it - the picture counted in
//! the frames' rows, a buffer read in place of a frame as well, the
//! overlay at its largest - the display clock, the pipes' clock and each
//! pipe's share of it, the controller's clock in deep sleep, and the
//! lowest of the power manager's states whose controller and fabric
//! clocks and memory return what the pipes read, the memory as the video
//! BIOS names it. They are asked of the power manager through the
//! display's own mailbox (`smu.zig`) before a change, where one goes up,
//! and once the pipes have taken it, where one goes down; each pipe's
//! divider of the pipes' clock is set in the engine, and the display
//! controller is told them. Each lit pipe's schedule is worked out at
//! them, and the other pipes' anew where they change, with the timing
//! generator's global sync, at one update. The hub's watermark sets are
//! written from the same model in the same two passes (`hub.zig`), and
//! the memory let into self-refresh, which the firmware forbids, once the
//! pipes have taken the first change; each fetcher the board gives a
//! schedule reads with its time to urgency, which in a blank starts from
//! those watermarks. A mode or a plane no state serves is refused. The
//! clocks, the states, what was asked, the manager's readings and the
//! hub's sets are read through the board's controls (RTGCTRL_AMD_CLOCKS),
//! which ask the manager nothing else.
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
//! each is allocated (RTGRF_SYSTEM_MEMORY, RTGRF_DMA_MEMORY), their rows
//! and starts on the 256 bytes a fetcher reads a linear surface by. The
//! engine reads them through a page table of its own (`gart.zig`),
//! whose reads see the CPU's caches: so a program that draws a picture
//! in one buffer while it shows another, and then shows that one, has
//! the display flipped to that buffer itself (`RTGBF_DIRECT_FLIP`), and
//! nothing is copied - its rows, where they are of another length than
//! the frames', told to the fetcher with its address at the same
//! update.
//!
//! The video layer (`RTGBC_VIDEO`, `video_ops`) is a plane of its own
//! (`plane.lightFilm`) on a free pipe, on a board whose page table and
//! blender are reached: one layer, under the picture or over it. A frame
//! is NV12 of eight bits in BT.601 or BT.709, video's range or the whole
//! byte, with rows of a whole number of 256 bytes, which the engine reads
//! through the page table as it reads a flipped buffer - each plane's
//! run of pages mapped as the frame is shown, one run where the two lie
//! close - while the one before is kept from being mapped over until the
//! plane has taken the new one; up to 4096 pixels a side, sixteen times
//! up and a sixth down. Under the picture it is seen where the picture
//! has the key colour, or the shades of it a shadow leaves, which the
//! picture's keyer makes clear; over it, it covers the picture, the
//! pointer too. It goes down with the pipe - for a mode set, the
//! monitor's sleep - and is lit again after from the frame it shows; while
//! it is open, bands are made in frames.
//!
//! The engine (`engine_ops`) is the graphics block's DMA engine
//! (`dma.zig`): FillRect, CopyRect and CopyRects of more than the CPU's
//! caches hold, on the machine's memory the buffers are in. The block
//! and its queue are started in a process of its own begun at the end of
//! `attach`, which neither the board nor its first picture waits for;
//! `RTGCTRL_SETTLED` and `halt` wait until nothing of it runs.
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
const utility = sdk.utility;
const TagItem = utility.TagItem;
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
const i2c = @import("i2c.zig");
const colours = @import("colours.zig");
const cursor = @import("cursor.zig");
const plane = @import("plane.zig");
const pipe = @import("pipe.zig");
const mode = @import("mode.zig");
const gart = @import("gart.zig");
const video = @import("video.zig");
const coefficients = @import("coefficients.zig");
const bandwidth = @import("bandwidth.zig");
const clocks = @import("clocks.zig");
const hub = @import("hub.zig");
const dma = @import("dma.zig");

const MODULE_NAME = "rtg-amd";
const DRIVER_NAME = "amd";
const VERSION = 1;
const REVISION = 25;
const BUILD_DATE = "26.11.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// What every row and every buffer starts on: the 256 bytes a fetcher
/// reads a linear surface's rows and its start by, whole cache lines.
const row_alignment = 256;
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
    /// The engine's page table onto the machine's memory, through which a
    /// buffer of the library's is read in place of a frame; null where
    /// there is none and the display reads the frames alone. Under
    /// `pipe_lock`.
    gart: ?gart.Table = null,
    /// How far apart the rows the fetcher is told to read are, in bytes:
    /// the frames', or a buffer's read in place of one.
    scan_pitch: u32 = 0,
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
    /// The mode's timings as the library showed it, what the sound is
    /// set for again on waking.
    timings: rtg.RtgTimings = .{},
    /// Whether the monitor is sent nothing, and the stream it is sent
    /// again on waking.
    asleep: bool = false,
    /// The AVI infoframe the link was last given, null for none or one
    /// not known - the firmware's.
    avi_sent: ?[rtg.RTG_AVI_BYTES]u8 = null,
    sleeping: pipe.Stream = .{},
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
    /// How many times the library has looked at it, and whether the
    /// monitor answered its brightness when last asked - null before it
    /// was.
    looks: u32 = 0,
    ddcci_heard: ?bool = null,
    /// The lock a flip and the pipe taken down and up take, one at a time.
    pipe_lock: exec.SignalSemaphore = .{},
    /// What the last mode set did.
    last_set: rtg.tags.RtgAmdPipe = .{},
    /// The display's clocks as what its pipes read asks (`raiseTo`,
    /// `lowerDue`): what they are worked out from, read once, under
    /// `smu_lock`; and under `pipe_lock` what each pipe reads, by its
    /// number - null for one that reads nothing - the demand they were
    /// last set for, what the power manager and the pipes' dividers were
    /// told and the hub's watermark sets last written (`hub.program`),
    /// whether the other pipes' schedules are to be worked out anew
    /// and the clocks lowered once the pipes have taken a change, whether
    /// a mode set makes the change - its drops only counted - whether the
    /// display controller still waits to be told them, and what the log
    /// has said.
    facts: ?bandwidth.Facts = null,
    reading: [pipe_count]?Reading = @splat(null),
    fitted: ?Fitted = null,
    told: clocks.Told = .{},
    marks: hub.Marks = @splat(0),
    rewrite_due: bool = false,
    lower_due: bool = false,
    setting_mode: bool = false,
    notify_due: bool = false,
    fit_refused: bool = false,
    refusal_said: u32 = 0,
    /// The pointer as the pipe's cursor: the device's memory of its two
    /// images, null on a board whose library lays the pointer; which of
    /// them the cursor was last told to read; what it was told; and the
    /// lock that keeps one writer at a time at it.
    cursor_memory: ?sdk.resources.amdgpu.GPUMemory = null,
    /// The library's image, kept until its next `set`: copied again,
    /// turned, when the picture is mirrored another way.
    pointer_image: ?*const rtg.RtgPointerImage = null,
    cursor_turn: u32 = 0,
    cursor_told: cursor.Cursor = .{},
    cursor_lock: exec.SignalSemaphore = .{},
    /// The overlay's plane as its pipe's cursor is laid over it: the
    /// pipe, the part of the overlay on the glass, and where that part's
    /// top left is on the picture, before any turn. Null while no plane
    /// is lit. Under `cursor_lock`, written holding `pipe_lock` too.
    cursor_plane: ?CursorPlane = null,
    /// The overlay as a plane of its own: the device's memory of its two
    /// images, null on a board whose library lays the overlay; the
    /// library's image, kept until its next `set`; which of the two the
    /// plane reads; the image's top left on the picture; and the pipe the
    /// plane is lit on, null while it is not. Under `pipe_lock`.
    overlay_memory: ?sdk.resources.amdgpu.GPUMemory = null,
    overlay_image: ?*const rtg.RtgPointerImage = null,
    overlay_turn: u32 = 0,
    overlay_left: i32 = 0,
    overlay_top: i32 = 0,
    overlay_pipe: ?u32 = null,
    /// Whether the log has said the overlay could not be lit, since it
    /// last was: said once, not at every move.
    overlay_refused: bool = false,
    /// How the picture is mirrored (`mirrorOp`), which a plane is too.
    /// Under `pipe_lock`.
    turn_x: bool = false,
    turn_y: bool = false,
    /// The bands the display reads itself (`showBands`): each one's pipe
    /// - the picture's own fetcher for the first that shows anything, a
    /// plane for each after it - and its place; how many; and the bands
    /// as the library handed them over, laid again when the picture is
    /// mirrored another way. None while the display reads a frame or a
    /// buffer whole. Under `pipe_lock`.
    band_planes: [pipe_count]BandPlane = undefined,
    band_count: u32 = 0,
    bands: [pipe_count]rtg.RtgBand = undefined,
    bands_handed: u32 = 0,
    /// Whether the hub gave a band's plane no buffer: bands are made in
    /// frames from then on, until the next mode set.
    bands_refused: bool = false,
    /// The cursor as each of the bands' pipes lays it, for as many as
    /// the bands have; none while the picture's fetcher reads all of the
    /// picture. Under `cursor_lock`, written holding `pipe_lock` too.
    band_cursors: [pipe_count]CursorPlane = undefined,
    band_cursor_count: u32 = 0,
    /// The video layer (`videoOpen`), null while none is open: under the
    /// picture or over it; the frame shown, the part of it shown and its
    /// place on the display, before any turn - kept, so that it is lit
    /// again once the pipe has gone down and come up; the pipe its plane
    /// is lit on, null while it is not; what that pipe's scaler holds,
    /// the colour matrix it was given, and the device's addresses of the
    /// frame it reads, whose pages the engine's page table keeps; and the
    /// picture's keyer and stage as they were before the film under it
    /// was seen through it. Under `pipe_lock`.
    film: ?*rtg.RtgVideoLayer = null,
    film_layer: plane.Layer = .under,
    film_frame: ?rtg.RtgYuv = null,
    film_part: rtg.RtgRect = .{},
    film_place: rtg.RtgRect = .{},
    film_pipe: ?u32 = null,
    film_filters: ?video.Filters = null,
    film_matrix: ?*const [12]u16 = null,
    film_reads: [2]u64 = .{ 0, 0 },
    film_unkeyed: plane.Unkeyed = .{},
    /// Whether the log has said a film's plane could not be lit, since
    /// one last was.
    film_refused: bool = false,
    /// The graphics block's DMA engine, as FillRect, CopyRect and
    /// CopyRects reach it (dma.zig).
    dma: dma.Dma = .{},
};

/// A plane the cursor is laid over too (`Screen.cursor_plane`,
/// `Screen.band_cursors`): its pipe, the part of its surface shown, and
/// where the cursor falls on that part - the picture's place less
/// (`left`, `top`), at the plane's scale (`times` the surface's pixels a
/// pixel of the picture is, both ways), less the rows of the surface
/// above the part (`row`).
const CursorPlane = struct { index: u32, view: cursor.View, left: i32, top: i32, times: u32 = 1, row: u32 = 0 };

/// A band read by a plane: its pipe and its place.
const BandPlane = struct { index: u32, band: plane.Band };

/// The overlay's two images in the device's memory: rows of the largest
/// overlay, rounded up to the 256 bytes a linear surface's rows are, and
/// the room each takes; the engine's pipes, which planes are lit on.
const overlay_pitch: u32 = 192;
const overlay_image_bytes: usize = @as(usize, overlay_pitch) * rtg.boards.RTG_OVERLAY_MAX * 4;
const pipe_count: u32 = 4;
/// How long a new overlay image waits for the plane to take the one
/// before, in microseconds: two frames at 24 Hz.
const flip_wait_us: u64 = 84_000;

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
/// gave with it, a buffer's in the engine's page table (`bufferAddress`).
/// The frame is not in the window the framebuffer is in - on a machine
/// whose device memory is part of its RAM the CPU reaches it there - so
/// its address in the machine says nothing of the device's. Where
/// flipping was given up, the frames are that framebuffer and nothing
/// tells the display to read elsewhere. False for a buffer the display
/// cannot read, and the display reads what it read.
fn scanFrom(screen: *Screen, picture: *const rtg.RtgBitMap) bool {
    const address = @intFromPtr(picture.pixels orelse return false);
    if (address == screen.scanning) return true;
    if (screen.amd_flipping) {
        const frame = screen.amd_frame.?;
        const wanted = if (address == @as(usize, @intCast(frame.cpu)))
            frame.device
        else if (address == screen.fb.pixels)
            screen.dcn.surface
        else
            bufferAddress(screen, picture) orelse return false;
        screen.flip_wanted = wanted;
        tell(screen, wanted, picture.pitch, false);
    } else if (address != screen.fb.pixels) {
        return false;
    }
    screen.scanning = address;
    return true;
}

/// The device's address of a buffer of the library's the display is to
/// read in place of a frame: the rows the fetcher reads of it mapped in
/// the engine's page table, by the machine's address exec names for it.
/// Null for a buffer of another format than the picture's, smaller than
/// the mode, or with rows or a start off the 256 bytes a fetcher reads
/// them by - and where the table cannot map it.
fn bufferAddress(screen: *Screen, picture: *const rtg.RtgBitMap) ?u64 {
    const table = if (screen.gart) |*one| one else return null;
    if (picture.width < screen.width or picture.height < screen.height) return null;
    // The buffer read until now keeps its pages, and so does the film's
    // frame.
    const busy = [_]u64{ screen.flip_wanted, screen.film_reads[0], screen.film_reads[1] };
    return mapRows(screen, table, picture, screen.height, &busy);
}

/// The device's address of the first `rows` rows of a buffer of the
/// library's, mapped in the engine's page table by the machine's address
/// exec names for them; `busy` are the device's addresses fetchers read
/// now, whose pages stay as they are. Null for a buffer of another format
/// than the picture's or with rows or a start off the 256 bytes a fetcher
/// reads them by, and where the table cannot map it.
fn mapRows(screen: *Screen, table: *gart.Table, picture: *const rtg.RtgBitMap, rows: u32, busy: []const u64) ?u64 {
    const pixels = picture.pixels orelse return null;
    if (picture.format != screen.format) return null;
    if (picture.pitch % row_alignment != 0 or @intFromPtr(pixels) % row_alignment != 0) return null;
    const all = @as(u64, picture.pitch) * rows;
    if (all > 0xffff_ffff) return null;
    var bytes: u32 = @intCast(all);
    const machine = @intFromPtr(screen.sys.CachePreDMA(@ptrCast(pixels), &bytes, exec.DMAF_ReadFromRAM));
    return gart.map(table, machine, bytes, busy);
}

/// The fetcher told to read the device's `address`, its rows `pitch`
/// bytes apart, from the pipe's next update on - or, `now`, at once. Rows
/// of another length than it reads now go with the address under the
/// timing generator's update lock, so the pipe takes both at one update.
fn tell(screen: *Screen, address: u64, pitch: u32, now: bool) void {
    const engine = screen.dcn;
    if (screen.band_count != 0) return leaveBands(screen, address, pitch, now);
    if (pitch == screen.scan_pitch) {
        dcn.flip(engine, address, now);
        return;
    }
    plane.lock(engine, engine.pipe);
    dcn.setPitch(engine, pitch / screen.bytes);
    dcn.flip(engine, address, now);
    plane.unlock(engine, engine.pipe);
    screen.scan_pitch = pitch;
}

// --- bands read by the display ------------------------------------------------------

/// The bands the library hands over with its show (`RTGSHOW_DIRECT`),
/// read by the display itself until its next flip: the first that shows
/// anything by the picture's own fetcher, each after it by a plane on a
/// pipe of its own - kept where it had one, lit on a free one where not,
/// laid whole - each with its place and scale (`plane.bandOf`) and its
/// buffer's rows mapped in the engine's page table; the blender's tree
/// written whole, the overlay's plane on top, the bands' planes, the
/// picture's stage at the bottom; planes no longer needed taken out; and
/// the cursor laid by each band's pipe on its band. All of it at one
/// update of the pipe, which is waited for as a flip is. Lines no band
/// shows are the blender's background.
///
/// Refused - the display reading what it read - while the monitor
/// sleeps, where the display is not flipped or has no page table, for
/// more bands than the pipes and where no pipe is free, for a repeating
/// band, one of another format or with rows or a start off 256 bytes, or
/// of a buffer wider than the picture or narrower by no whole number,
/// where the table cannot map its rows, and where the hub gives a new
/// plane no buffer - after which bands are refused until the next mode
/// set - and while a video layer is open, whose place is on the picture
/// whole. Holding `pipe_lock`.
fn showBands(screen: *Screen, bands: []const rtg.RtgBand) i32 {
    const refused = err.RTGERR_NOT_SUPPORTED;
    if (screen.asleep or !screen.amd_flipping or screen.bands_refused or screen.film != null) return refused;
    if (bands.len < 2 or bands.len > pipe_count) return refused;
    const table = if (screen.gart) |*one| one else return refused;
    const engine = screen.dcn;
    // What the fetchers read now keeps its pages, and so does each band's
    // buffer once mapped.
    var busy: [2 * pipe_count + 1]u64 = undefined;
    busy[0] = screen.flip_wanted;
    var busy_count: usize = 1;
    for (screen.band_planes[0..screen.band_count]) |one| {
        busy[busy_count] = one.band.place.address;
        busy_count += 1;
    }
    var wanted: [pipe_count]BandPlane = undefined;
    var count: usize = 0;
    for (bands, 0..) |band, i| {
        const bitmap = band.bitmap;
        if (band.flags & rtg.RTGBANDF_REPEAT != 0) return refused;
        if (bitmap.width == 0 or bitmap.width > screen.width or screen.width % bitmap.width != 0) return refused;
        const end = if (i + 1 < bands.len) bands[i + 1].line else screen.height;
        var placed = plane.bandOf(band.line, end, band.origin, bitmap.width, bitmap.height, screen.width, screen.height, screen.turn_x, screen.turn_y) orelse continue;
        const address = bandAddress(screen, table, bitmap, busy[0..busy_count]) orelse return refused;
        busy[busy_count] = address;
        busy_count += 1;
        placed.place.address = address;
        placed.place.pitch = bitmap.pitch / screen.bytes;
        wanted[count] = .{ .index = engine.fetcher, .band = placed };
        count += 1;
    }
    if (count == 0) return refused;

    // The pipes: the planes the bands had first, free ones after; what
    // each reads counted, the planes the bands no longer need not; and
    // each plane's schedule for its width at the clocks that serves.
    var fresh: [pipe_count]bool = @splat(false);
    var taken: [pipe_count]u32 = undefined;
    var schedules: [pipe_count]mode.Schedule = undefined;
    const vstartup = mode.vstartupOf(engine, engine.pipe);
    var next = screen.reading;
    for (screen.band_planes[1..@max(screen.band_count, 1)]) |old| next[old.index] = null;
    for (1..count) |i| {
        if (i < screen.band_count) {
            wanted[i].index = screen.band_planes[i].index;
        } else {
            wanted[i].index = freePipeBut(engine, taken[0 .. i - 1]) orelse return refused;
            fresh[i] = true;
        }
        taken[i - 1] = wanted[i].index;
        const place = &wanted[i].band.place;
        next[wanted[i].index] = readingOf(mode.pictureFetch(place.width, place.pitch));
    }
    const fitted = demandFor(screen, screen.timings, vstartup, &next) orelse return refused;
    for (1..count) |i| {
        const held = fitted.heldOf(wanted[i].index) orelse return refused;
        schedules[i] = mode.fetchSchedule(screen.timings, next[wanted[i].index].?.fetch, held, vstartup) orelse return refused;
    }
    raiseTo(screen, fitted, next);

    const output = mode.outputOf(engine, engine.pipe);
    for (1..count) |i| {
        if (!fresh[i]) continue;
        gart.reach(engine, wanted[i].index);
        plane.prepare(engine, wanted[i].index, engine.fetcher);
    }
    var cursors: [pipe_count]CursorPlane = undefined;
    for (wanted[0..count], 0..) |one, i| cursors[i] = bandCursor(one);
    plane.lock(engine, engine.pipe);
    plane.writePlace(engine, engine.fetcher, &wanted[0].band.place);
    for (1..count) |i| {
        const index = wanted[i].index;
        if (fresh[i]) {
            plane.lit(engine, index, engine.pipe, output, engine.fetcher, screen.width | screen.height << 16, &schedules[i], &wanted[i].band.place, .whole);
        } else {
            mode.writeSchedule(engine, index, &schedules[i]);
            plane.writePlace(engine, index, &wanted[i].band.place);
        }
    }
    plane.stack(engine, output, screen.overlay_pipe, taken[0 .. count - 1], engine.fetcher);
    const kept: usize = @max(screen.band_count, 1);
    for (screen.band_planes[@min(count, kept)..kept]) |old| plane.release(engine, old.index);
    bandCursors(screen, cursors[0..count]);
    writeOthers(screen, taken[0 .. count - 1]);
    plane.unlock(engine, engine.pipe);
    for (screen.band_planes[@min(count, kept)..kept]) |old| plane.shut(engine, old.index);

    @memcpy(screen.band_planes[0..count], wanted[0..count]);
    screen.band_count = @intCast(count);
    @memcpy(screen.bands[0..bands.len], bands);
    screen.bands_handed = @intCast(bands.len);
    screen.flip_wanted = wanted[0].band.place.address;
    screen.scan_pitch = wanted[0].band.place.pitch * screen.bytes;
    screen.scanning = 0;
    var settled = true;
    for (1..count) |i| {
        if (fresh[i] and !plane.settled(engine, wanted[i].index, engine.fetcher)) settled = false;
    }
    if (!settled) {
        screen.bands_refused = true;
        exec.kprintf(screen.sys, "%s: the hub gave a band's plane no buffer, so bands are made in frames\n", .{MODULE_NAME});
        dropBands(screen);
        return refused;
    }
    // Taken at the pipe's next update, as a flip; the clocks lowered
    // after it, where the bands need them slower.
    screen.updates +%= 1;
    pace(screen, 1);
    var looks: u32 = 0;
    while (!dcn.flipTaken(engine, screen.flip_wanted)) : (looks += 1) {
        if (looks == 2) {
            giveUpFlipping(screen);
            return err.RTGERR_IO;
        }
        pace(screen, 1);
    }
    lowerDue(screen, true);
    return err.RTGERR_OK;
}

/// The device's address a plane reads a band's buffer by: the frame's or
/// the framebuffer's own where it is one of them, else all its rows
/// mapped in the engine's page table (`mapRows`).
fn bandAddress(screen: *Screen, table: *gart.Table, bitmap: *const rtg.RtgBitMap, busy: []const u64) ?u64 {
    const address = @intFromPtr(bitmap.pixels orelse return null);
    if (screen.amd_frame) |frame| {
        if (address == @as(usize, @intCast(frame.cpu))) return frame.device;
    }
    if (address == screen.fb.pixels) return screen.dcn.surface;
    return mapRows(screen, table, bitmap, bitmap.height, busy);
}

/// The cursor as a band's pipe lays it: where the band's rows start, at
/// its scale, on the part of its buffer it reads.
fn bandCursor(one: BandPlane) CursorPlane {
    const place = one.band.place;
    return .{
        .index = one.index,
        .view = .{ .x = place.view_x, .y = place.view_y, .width = place.width, .height = place.height },
        .left = 0,
        .top = @intCast(one.band.origin),
        .times = one.band.times,
        .row = place.view_y,
    };
}

/// The cursor laid by the bands' pipes `over` from now on - by the
/// picture's fetcher on all of the picture for none - and switched off
/// on the planes that laid it and lay it no more. Holding `pipe_lock`.
fn bandCursors(screen: *Screen, over: []const CursorPlane) void {
    if (screen.cursor_memory == null) return;
    const engine = screen.dcn;
    screen.sys.ObtainSemaphore(&screen.cursor_lock);
    defer screen.sys.ReleaseSemaphore(&screen.cursor_lock);
    const output = mode.outputOf(engine, engine.pipe);
    next: for (screen.band_cursors[0..screen.band_cursor_count]) |was| {
        if (was.index == engine.fetcher) continue;
        for (over) |still| {
            if (still.index == was.index) continue :next;
        }
        var off = screen.cursor_told;
        off.shown = false;
        cursor.write(engine, was.index, output, off, was.view);
    }
    @memcpy(screen.band_cursors[0..over.len], over);
    screen.band_cursor_count = @intCast(over.len);
    writeCursor(screen);
}

/// The display back on a whole picture from the bands it read: the
/// frame or buffer at the device's `address`, its rows `pitch` bytes
/// apart, read by the picture's fetcher with all of the picture as its
/// place, unscaled; the bands' planes out of the blender's tree, the
/// cursor laid by the picture's fetcher alone and the other pipes'
/// schedules for what is left, at one update - or, `now`, the address at
/// once; then the planes taken down. The clocks are lowered for what is
/// left once the pipe has taken it (`lowerDue`), by the caller. Holding
/// `pipe_lock`.
fn leaveBands(screen: *Screen, address: u64, pitch: u32, now: bool) void {
    const engine = screen.dcn;
    const output = mode.outputOf(engine, engine.pipe);
    const whole = plane.Place{
        .address = address,
        .pitch = pitch / screen.bytes,
        .width = screen.width,
        .height = screen.height,
        .mirror_x = screen.turn_x,
        .mirror_y = screen.turn_y,
    };
    const planes = screen.band_planes[1..@max(screen.band_count, 1)];
    // A film's plane over the picture stays right above it.
    var film_over: [1]u32 = undefined;
    var over_picture: []const u32 = &.{};
    if (screen.film_pipe) |index| {
        if (screen.film_layer == .over) {
            film_over[0] = index;
            over_picture = &film_over;
        }
    }
    // What is left counted, the clocks raised for it where they go up,
    // and the other pipes' schedules worked out anew at the same update;
    // lowered once it is taken.
    var next = screen.reading;
    for (planes) |one| next[one.index] = null;
    if (screen.setting_mode) {
        screen.reading = next;
    } else if (demandFor(screen, screen.timings, mode.vstartupOf(engine, engine.pipe), &next)) |fitted| {
        raiseTo(screen, fitted, next);
    } else {
        screen.reading = next;
    }
    plane.lock(engine, engine.pipe);
    plane.writePlace(engine, engine.fetcher, &whole);
    dcn.flip(engine, address, now);
    plane.stack(engine, output, screen.overlay_pipe, over_picture, engine.fetcher);
    for (planes) |one| plane.release(engine, one.index);
    bandCursors(screen, &.{});
    writeOthers(screen, &.{});
    plane.unlock(engine, engine.pipe);
    for (planes) |one| plane.shut(engine, one.index);
    screen.band_count = 0;
    screen.bands_handed = 0;
    screen.scan_pitch = pitch;
}

/// Bands the display reads given up for the firmware's framebuffer, read
/// whole: before the pipe goes down or is set anew, and as the board
/// goes. Holding `pipe_lock`.
fn dropBands(screen: *Screen) void {
    if (screen.band_count == 0) return;
    leaveBands(screen, screen.dcn.surface, screen.fb.pitch, false);
    screen.flip_wanted = screen.dcn.surface;
    screen.scanning = screen.fb.pixels;
    if (!screen.setting_mode) lowerDue(screen, false);
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
    // Asleep, the pipe is down and takes no update: the frame is where
    // the fetcher reads once it runs again, and taken a frame on, by the
    // library's clock.
    if (screen.asleep) {
        if (!scanFrom(screen, frame)) return err.RTGERR_NOT_SUPPORTED;
        screen.updates +%= 1;
        pace(screen, 1);
        return rtg.boards.RTGFLIP_TAKEN;
    }
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
/// frame, so that no more than a picture a frame is made. A buffer the
/// display cannot read in place of a frame (`scanFrom`) is
/// RTGERR_NOT_SUPPORTED, upon which the library makes the picture in a
/// frame.
fn flipAmd(screen: *Screen, frame: *const rtg.RtgBitMap) i32 {
    if (!screen.amd_flipping) {
        if (@intFromPtr(frame.pixels) != screen.fb.pixels) return err.RTGERR_NOT_SUPPORTED;
        screen.updates +%= 1;
        return err.RTGERR_OK;
    }
    if (!scanFrom(screen, frame)) return err.RTGERR_NOT_SUPPORTED;
    screen.updates +%= 1;
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
    // Bands the flip left: the clocks lowered for what is left.
    lowerDue(screen, true);
    return rtg.boards.RTGFLIP_TAKEN;
}

/// The AMD display's flips given up, once one was not taken: the fetcher
/// told to read the firmware's framebuffer again at once, and both
/// frames that framebuffer from now on - each picture made in it, none
/// read in place of a frame. Said once on the log. The device's frame
/// and the page table are kept: the fetcher might still read through
/// them.
fn giveUpFlipping(screen: *Screen) void {
    const found = screen.dcn;
    screen.amd_flipping = false;
    screen.board.info.flags &= ~(rtg.boards.RTGBF_DIRECT_FLIP | rtg.boards.RTGBF_SCALES);
    tell(screen, found.surface, screen.fb.pitch, true);
    exec.kprintf(screen.sys, "%s: the display did not take the flip to 0x%lx, so the picture goes into the firmware's framebuffer again\n", .{ MODULE_NAME, screen.flip_wanted });
    screen.scanning = screen.fb.pixels;
    lowerDue(screen, false);
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
    screen.board.info.flags &= ~(rtg.boards.RTGBF_DIRECT_FLIP | rtg.boards.RTGBF_SCALES);
    const found = screen.dcn;
    tell(screen, found.surface, screen.fb.pitch, true);
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
    // The pointer the pipe's cursor, where the cursor can be had: room
    // for its two images in the device's memory.
    const cursor_memory = cursorMemory(found, format);
    // The overlay a plane of its own, where planes can be lit: room for
    // its two images.
    // The pointer is then the pipes' cursor too: a pointer laid into the
    // picture would be under the plane.
    const overlay_memory = if (cursor_memory != null) overlayMemory(found, format) else null;

    const board = rb.CreateBoard(driver, device, &.{
        .ops = opsFor(cursor_memory != null, overlay_memory != null, false),
        .instance_size = @sizeOf(Screen),
        // The display runs as the firmware lit it: its mode is kept.
        .flags = rtg.boards.RTGBF_ADOPTED,
        // The monitor on its connector takes a brightness in per cent,
        // and its colours in full or limited range where the engine's
        // blender is reached.
        .brightness_steps = 101,
        .caps = rtg.boards.RTGBC_MIRROR_X | rtg.boards.RTGBC_MIRROR_Y | if (colours.reached(found)) rtg.boards.RTGBC_COLOR_RANGE else 0,
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
        .scan_pitch = fb.pitch,
        .smu = smu.find(found),
        .cursor_memory = cursor_memory,
        .overlay_memory = overlay_memory,
    };
    sys.InitSemaphore(&screen.smu_lock);
    sys.InitSemaphore(&screen.cursor_lock);
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
    // Its frames counted by the pipe's interrupt, and the second of them
    // the device's own memory.
    hookFrames(screen);
    takeAmdFrame(screen);
    // The firmware's picture laid where it belongs: its scaler in its
    // bypass, where the firmware leaves it shifting the picture by a
    // pixel or two.
    mode.passThrough(found, found.fetcher);
    // A program's buffer read in place of a frame, through the engine's
    // page table, where the display is flipped; and a film's frames read
    // through it by a plane of their own, where planes can be lit.
    if (screen.amd_flipping) readBuffers(screen);
    board.ops = opsFor(cursor_memory != null, overlay_memory != null, screen.gart != null and plane.reached(found));

    // At most as many pictures of the mode as the board asks for, each
    // taken by the library as it is allocated. Not cleared: each is
    // cleared before it is first shown. With the page table, bands as
    // many as the engine's pipes are read by the display itself.
    const frame: usize = @as(usize, screen.pitch) * height;
    // As many as the settings say of the device, else as the part does.
    const part_buffers = rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list);
    screen.buffers = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, part_buffers, device_tags))), 1);
    board.direct_bands = if (screen.gart != null) pipe_count else 0;
    board.region = .{
        .size = screen.buffers * frame,
        .alignment = screen.alignment,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED |
            rtg.boards.RTGRF_SYSTEM_MEMORY | rtg.boards.RTGRF_DMA_MEMORY,
    };
    board.info.buffers = screen.buffers;
    device.driver_data = screen;
    // The graphics block and its DMA engine's queue started beside the
    // board, which does not wait for them.
    dma.start(&screen.dma, sys, screen.dcn.gpu);
    return err.RTGERR_OK;
}

/// The engine's page table made, the fetcher told to read through it
/// past the device's memory, and the board said to read a program's
/// buffers in place of a frame (`RTGBF_DIRECT_FLIP`); where there is no
/// room for the table, the display reads the frames alone, and the log
/// says so.
fn readBuffers(screen: *Screen) void {
    const found = screen.dcn;
    screen.gart = gart.open(found) orelse {
        exec.kprintf(screen.sys, "%s: no room in the device's memory for a page table, so every picture is made in a frame\n", .{MODULE_NAME});
        return;
    };
    gart.reach(found, found.fetcher);
    screen.board.info.flags |= rtg.boards.RTGBF_DIRECT_FLIP | rtg.boards.RTGBF_SCALES;
    exec.kprintf(screen.sys, "%s: the display reads a program's buffers through a page table at 0x%lx in the machine\n", .{ MODULE_NAME, screen.gart.?.machine });
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
    dma.stop(&screen.dma, screen.sys);
    screen.sys.ObtainSemaphore(&screen.pipe_lock);
    dropBands(screen);
    dropFilm(screen);
    screen.film = null;
    screen.film_frame = null;
    screen.sys.ReleaseSemaphore(&screen.pipe_lock);
    if (screen.overlay_memory) |*memory| {
        screen.sys.ObtainSemaphore(&screen.pipe_lock);
        dropOverlay(screen);
        screen.overlay_memory = null;
        screen.sys.ReleaseSemaphore(&screen.pipe_lock);
        dcn.freeFrame(screen.dcn, memory);
    }
    if (screen.cursor_memory) |*memory| {
        screen.sys.ObtainSemaphore(&screen.cursor_lock);
        screen.cursor_told = .{};
        writeCursor(screen);
        screen.cursor_memory = null;
        screen.sys.ReleaseSemaphore(&screen.cursor_lock);
        // Read no more once the pipe has updated.
        pace(screen, 2);
        dcn.freeFrame(screen.dcn, memory);
    }
    giveAmdFrame(screen);
    // The page table given back once the fetcher reads the firmware's
    // framebuffer: kept where it might still read through it.
    if (screen.amd_frame == null) {
        if (screen.gart) |*table| {
            gart.close(screen.dcn, table);
            screen.gart = null;
        }
    }
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
/// reach it through `flipOp`, but for bands the library hands over to be
/// read by the display itself (`showBands`).
fn showOp(board: *rtg.RtgBoard, what: *const rtg.RtgShow) callconv(.c) i32 {
    const screen = screenOf(board);
    if (what.flags & rtg.boards.RTGSHOW_MODE_CHANGED == 0) {
        // In the mode it is in: bands handed over to be read by the
        // display itself, or nothing to do.
        if (what.flags & rtg.boards.RTGSHOW_DIRECT == 0 or what.count < 2) return err.RTGERR_OK;
        const bands = what.bands orelse return err.RTGERR_BAD_ARG;
        screen.sys.ObtainSemaphore(&screen.pipe_lock);
        defer screen.sys.ReleaseSemaphore(&screen.pipe_lock);
        return showBands(screen, bands[0..what.count]);
    }
    const shown = what.mode;
    // A row as the library makes one of a buffer.
    if (shown.format != screen.format or shown.pitch != rowBytes(screen, shown.width)) return err.RTGERR_BAD_MODE;
    const start = what.frame orelse return err.RTGERR_BAD_ARG;
    if (start.pixels == null) return err.RTGERR_BAD_ARG;
    if (!scans(screen, what.timings)) {
        const code = setMode(screen, what.timings);
        if (code != err.RTGERR_OK) return code;
    }
    screen.timings = what.timings.*;
    // The link's sound for the mode - its clock and the numbers the
    // monitor rebuilds it from at the mode's pixel clock, and what the
    // monitor plays - or on waking where the monitor sleeps.
    if (!screen.asleep) soundFor(screen);
    // Its colours in the range the settings or the monitor ask for, and
    // the AVI infoframe that says so - in the firmware's mode as well,
    // which sends none.
    if (!screen.asleep) coloursFor(screen);
    screen.mode_id = shown.id;
    screen.pixel_clock_hz = shown.pixel_clock_hz;
    screen.width = shown.width;
    screen.height = shown.height;
    screen.pitch = shown.pitch;
    // Room for as many pictures of the mode as the board may have.
    board.region.size = @as(usize, screen.buffers) * @as(usize, shown.pitch) * shown.height;
    // What it read until now says nothing about the new mode.
    screen.scanning = 0;
    _ = scanFrom(screen, start);
    // The cursor's fetch timed by the mode's pixel clock, and kept on
    // its picture.
    if (screen.cursor_memory != null) {
        screen.sys.ObtainSemaphore(&screen.cursor_lock);
        writeCursor(screen);
        screen.sys.ReleaseSemaphore(&screen.cursor_lock);
    }
    // The display's clocks set for the mode's picture and what else the
    // pipes read; the overlay's plane and the film's worked out for the
    // mode, and lit again where a set took them down.
    screen.sys.ObtainSemaphore(&screen.pipe_lock);
    fitPicture(screen);
    if (screen.overlay_memory != null) showOverlay(screen);
    _ = showFilm(screen, false);
    screen.sys.ReleaseSemaphore(&screen.pipe_lock);
    return err.RTGERR_OK;
}

// --- the pointer, as the pipe's cursor ------------------------------------------

/// The device's memory for the cursor's two images, on a board in
/// `bgra32` - the cursor's own format - whose blender is reached; null
/// where not, or where there is no room, and the library lays the
/// pointer.
fn cursorMemory(engine: dcn.Engine, format: rtg.PixelFormat) ?sdk.resources.amdgpu.GPUMemory {
    if (format != .bgra32 or !cursor.reached(engine)) return null;
    return dcn.newFrame(engine, 2 * cursor.image_bytes);
}

/// The cursor told what the board's pointer is now, on the picture the
/// mode has, its fetch timed by the mode's pixel clock. Holding
/// `cursor_lock`.
fn writeCursor(screen: *Screen) void {
    const engine = screen.dcn;
    screen.cursor_told.pixel_hz = screen.timings.pixel_clock_hz;
    const output = mode.outputOf(engine, engine.pipe);
    // On all of the picture, or where the display reads bands, by each
    // band's pipe on its band.
    if (screen.band_cursor_count == 0) {
        cursor.write(engine, engine.fetcher, output, screen.cursor_told, .{ .width = screen.width, .height = screen.height });
    } else {
        for (screen.band_cursors[0..screen.band_cursor_count]) |over| layCursor(screen, output, over);
    }
    // Over the overlay's plane, whose stage is above the picture's, its
    // own pipe's cursor: its place from the part of the overlay shown.
    if (screen.cursor_plane) |over| layCursor(screen, output, over);
}

/// The cursor laid by plane `over`'s pipe, where it falls on the part of
/// the plane's surface shown. A scaled plane lays its image at the
/// plane's scale: the pipe's cursor is drawn in its surface's pixels.
/// Holding `cursor_lock`.
fn layCursor(screen: *Screen, output: u32, over: CursorPlane) void {
    var on_plane = screen.cursor_told;
    const times: i32 = @intCast(over.times);
    on_plane.left = @divFloor(on_plane.left - over.left, times);
    on_plane.top = @divFloor(on_plane.top - over.top, times) - @as(i32, @intCast(over.row));
    cursor.write(screen.dcn, over.index, output, on_plane, over.view);
}

/// A new image, or none: copied into the image the cursor does not read,
/// and the cursor told to read that one from the pipe's next update.
fn setPointer(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    const screen = screenOf(board);
    if (image) |one| {
        if (one.format != .bgra32) return err.RTGERR_BAD_FORMAT;
    }
    screen.sys.ObtainSemaphore(&screen.cursor_lock);
    defer screen.sys.ReleaseSemaphore(&screen.cursor_lock);
    if (screen.cursor_memory == null) return err.RTGERR_NOT_SUPPORTED;
    screen.pointer_image = image;
    cursorImage(screen);
    writeCursor(screen);
    return err.RTGERR_OK;
}

/// The library's image copied into the image the cursor does not read,
/// turned as the picture is mirrored, and the cursor to read that one;
/// none without an image. Holding `cursor_lock`.
fn cursorImage(screen: *Screen) void {
    const told = &screen.cursor_told;
    const memory = screen.cursor_memory orelse return;
    const one = screen.pointer_image orelse {
        told.address = 0;
        told.width = 0;
        told.height = 0;
        return;
    };
    const turn = screen.cursor_turn ^ 1;
    const offset = @as(usize, turn) * cursor.image_bytes;
    const into: [*]u8 = @ptrFromInt(@as(usize, @intCast(memory.cpu)) + offset);
    const size = cursor.copyImage(into, one, cursor.reversedOf(told.mirror_x, told.mirror_y));
    screen.cursor_turn = turn;
    told.address = memory.device + offset;
    told.width = size.width;
    told.height = size.height;
}

/// The picture mirrored about each axis by the fetcher (`mode.writeTurn`)
/// from the pipe's next update on, and the pointer and the overlay's
/// plane turned with it.
fn mirrorOp(board: *rtg.RtgBoard, x: bool, y: bool) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    sys.ObtainSemaphore(&screen.pipe_lock);
    const was_x = screen.turn_x;
    const was_y = screen.turn_y;
    screen.turn_x = x;
    screen.turn_y = y;
    // Bands the display reads are laid again, turned; the picture's
    // fetcher is turned with the first.
    if (screen.band_count != 0) {
        const kept = screen.bands;
        const code = showBands(screen, kept[0..screen.bands_handed]);
        if (code != err.RTGERR_OK) {
            screen.turn_x = was_x;
            screen.turn_y = was_y;
            sys.ReleaseSemaphore(&screen.pipe_lock);
            return code;
        }
    } else {
        mode.writeTurn(screen.dcn, screen.dcn.fetcher, x, y);
    }
    showOverlay(screen);
    _ = showFilm(screen, false);
    sys.ReleaseSemaphore(&screen.pipe_lock);
    sys.ObtainSemaphore(&screen.cursor_lock);
    defer sys.ReleaseSemaphore(&screen.cursor_lock);
    screen.cursor_told.mirror_x = x;
    screen.cursor_told.mirror_y = y;
    cursorImage(screen);
    if (screen.cursor_memory != null) writeCursor(screen);
    return err.RTGERR_OK;
}

fn movePointer(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const screen = screenOf(board);
    screen.sys.ObtainSemaphore(&screen.cursor_lock);
    defer screen.sys.ReleaseSemaphore(&screen.cursor_lock);
    screen.cursor_told.left = left;
    screen.cursor_told.top = top;
    writeCursor(screen);
}

fn showPointer(board: *rtg.RtgBoard, show: bool) callconv(.c) i32 {
    const screen = screenOf(board);
    screen.sys.ObtainSemaphore(&screen.cursor_lock);
    defer screen.sys.ReleaseSemaphore(&screen.cursor_lock);
    screen.cursor_told.shown = show;
    writeCursor(screen);
    return err.RTGERR_OK;
}

// --- the overlay, as a plane of its own -------------------------------------------

/// The device's memory for the overlay's two images, on a board in
/// `bgra32` - the plane's format - whose blender is reached; null where
/// not, or where there is no room, and the library lays the overlay.
fn overlayMemory(engine: dcn.Engine, format: rtg.PixelFormat) ?sdk.resources.amdgpu.GPUMemory {
    if (format != .bgra32 or !plane.reached(engine)) return null;
    return dcn.newFrame(engine, 2 * overlay_image_bytes);
}

/// A new image, or none: copied into the image the plane does not read,
/// and the plane lit, or told to read that one, from the pipe's next
/// update; none takes the plane down.
fn setOverlay(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    const screen = screenOf(board);
    if (image) |one| {
        if (one.format != .bgra32) return err.RTGERR_BAD_FORMAT;
        if (one.width > rtg.boards.RTG_OVERLAY_MAX or one.height > rtg.boards.RTG_OVERLAY_MAX) return err.RTGERR_BAD_ARG;
    }
    const memory = screen.overlay_memory orelse return err.RTGERR_NOT_SUPPORTED;
    screen.sys.ObtainSemaphore(&screen.pipe_lock);
    defer screen.sys.ReleaseSemaphore(&screen.pipe_lock);
    screen.overlay_image = image;
    if (image) |one| {
        // The image the plane read before: it may still read it until
        // its next update.
        if (screen.overlay_pipe) |index| {
            const deadline = screen.sys.UptimeUs() + flip_wait_us;
            while (!plane.taken(screen.dcn, index) and screen.sys.UptimeUs() < deadline) dcn.pause(screen.sys, 200);
        }
        const turn = screen.overlay_turn ^ 1;
        const into: [*]u8 = @ptrFromInt(@as(usize, @intCast(memory.cpu)) + turn * overlay_image_bytes);
        copyOverlay(into, one);
        screen.overlay_turn = turn;
    }
    showOverlay(screen);
    return err.RTGERR_OK;
}

/// The overlay's image put with its top left at (`left`, `top`) of the
/// picture.
fn moveOverlay(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const screen = screenOf(board);
    screen.sys.ObtainSemaphore(&screen.pipe_lock);
    defer screen.sys.ReleaseSemaphore(&screen.pipe_lock);
    screen.overlay_left = left;
    screen.overlay_top = top;
    if (screen.overlay_image != null) showOverlay(screen);
}

/// The library's image copied as it is - its pixels are ARGB as a plane
/// takes them, each either covering fully or clear - in rows the plane's
/// apart, and fenced: the device's memory is reached write-combining.
fn copyOverlay(into: [*]u8, image: *const rtg.RtgPointerImage) void {
    const row_bytes = @as(usize, image.width) * 4;
    var row: usize = 0;
    while (row < image.height) : (row += 1) {
        @memcpy(into[row * overlay_pitch * 4 ..][0..row_bytes], image.pixels[row * image.pitch ..][0..row_bytes]);
    }
    sdk.hardware.barrier.full();
}

/// The overlay's plane where the overlay is now, reading the image last
/// copied: lit on a free pipe where it is not, moved where it is, taken
/// down where there is no image or none of it is on the glass. Holding
/// `pipe_lock`; nothing while the pipe is asleep, which took it down.
fn showOverlay(screen: *Screen) void {
    const engine = screen.dcn;
    const memory = screen.overlay_memory orelse return;
    if (screen.asleep) return;
    const one = screen.overlay_image orelse return dropOverlay(screen);
    var where = plane.placeOf(screen.overlay_left, screen.overlay_top, one.width, one.height, screen.width, screen.height, screen.turn_x, screen.turn_y) orelse return dropOverlay(screen);
    where.address = memory.device + @as(u64, screen.overlay_turn) * overlay_image_bytes;
    where.pitch = overlay_pitch;
    // Read where it is on the glass; counted at its largest.
    const shown: Reading = .{
        .fetch = mode.pictureFetch(where.width, overlay_pitch),
        .counted = mode.pictureFetch(rtg.boards.RTG_OVERLAY_MAX, overlay_pitch),
    };
    const vstartup = mode.vstartupOf(engine, engine.pipe);
    const view: cursor.View = .{ .x = where.view_x, .y = where.view_y, .width = where.width, .height = where.height };
    const left = screen.overlay_left + @as(i32, @intCast(where.view_x));
    const top = screen.overlay_top + @as(i32, @intCast(where.view_y));
    if (screen.overlay_pipe) |index| {
        screen.reading[index] = shown;
        const held = heldFor(screen, index) orelse return dropOverlay(screen);
        const schedule = mode.fetchSchedule(screen.timings, shown.fetch, held, vstartup) orelse return dropOverlay(screen);
        plane.move(engine, index, engine.pipe, &schedule, &where);
        planeCursor(screen, .{ .index = index, .view = view, .left = left, .top = top });
        return;
    }
    const index = freePipe(engine) orelse {
        if (!screen.overlay_refused) exec.kprintf(screen.sys, "%s: no pipe is free for the overlay, which is not shown\n", .{MODULE_NAME});
        screen.overlay_refused = true;
        return;
    };
    // The clocks raised for the overlay as well before it is lit, the
    // other pipes worked out anew after, the clocks lowered once taken.
    var next = screen.reading;
    next[index] = shown;
    const fitted = demandFor(screen, screen.timings, vstartup, &next) orelse {
        if (!screen.overlay_refused) exec.kprintf(screen.sys, "%s: the display's clocks cannot serve the overlay as well, which is not shown\n", .{MODULE_NAME});
        screen.overlay_refused = true;
        return;
    };
    const held = fitted.heldOf(index) orelse return;
    const schedule = mode.fetchSchedule(screen.timings, shown.fetch, held, vstartup) orelse return;
    raiseTo(screen, fitted, next);
    const output = mode.outputOf(engine, engine.pipe);
    if (!plane.light(engine, index, engine.pipe, output, engine.fetcher, screen.width | screen.height << 16, &schedule, &where)) {
        plane.darken(engine, index, engine.pipe, output);
        if (!screen.overlay_refused) exec.kprintf(screen.sys, "%s: the hub gave pipe %d no buffer, so the overlay is not shown\n", .{ MODULE_NAME, index });
        screen.overlay_refused = true;
        fitWithout(screen, index, true);
        return;
    }
    screen.overlay_pipe = index;
    screen.overlay_refused = false;
    rewriteOthers(screen, &.{index});
    planeCursor(screen, .{ .index = index, .view = view, .left = left, .top = top });
    lowerDue(screen, false);
}

/// The cursor laid over the overlay's plane `over` as well from now on,
/// or no longer for null - written off on the plane before it goes down.
/// Holding `pipe_lock`.
fn planeCursor(screen: *Screen, over: ?CursorPlane) void {
    if (screen.cursor_memory == null) return;
    screen.sys.ObtainSemaphore(&screen.cursor_lock);
    defer screen.sys.ReleaseSemaphore(&screen.cursor_lock);
    if (over == null) if (screen.cursor_plane) |was| {
        var off = screen.cursor_told;
        off.shown = false;
        cursor.write(screen.dcn, was.index, mode.outputOf(screen.dcn, screen.dcn.pipe), off, was.view);
    };
    screen.cursor_plane = over;
    writeCursor(screen);
}

/// The overlay's plane taken down, where it is lit, and the clocks set
/// for what is left (`fitWithout`). Holding `pipe_lock`.
fn dropOverlay(screen: *Screen) void {
    const index = screen.overlay_pipe orelse return;
    const engine = screen.dcn;
    planeCursor(screen, null);
    plane.darken(engine, index, engine.pipe, mode.outputOf(engine, engine.pipe));
    screen.overlay_pipe = null;
    fitWithout(screen, index, true);
}

/// The first pipe free for a plane, other than the picture's.
fn freePipe(engine: dcn.Engine) ?u32 {
    return freePipeBut(engine, &.{});
}

/// The first pipe free for a plane, other than the picture's and those
/// `taken`.
fn freePipeBut(engine: dcn.Engine, taken: []const u32) ?u32 {
    var index: u32 = 0;
    next: while (index < pipe_count) : (index += 1) {
        if (index == engine.fetcher) continue;
        if (!plane.isFree(engine, index)) continue;
        for (taken) |one| {
            if (one == index) continue :next;
        }
        return index;
    }
    return null;
}

// --- the display's clocks, as what the pipes read asks ----------------------------

/// What a lit pipe reads, for the display's clocks: what its schedule is
/// worked out for, and what the clocks are worked out for - the same but
/// for the overlay, which is counted at its largest, so that it moves on
/// the glass with the clocks as they are.
const Reading = struct {
    fetch: mode.Fetch,
    counted: mode.Fetch,
};

fn readingOf(fetch: mode.Fetch) Reading {
    return .{ .fetch = fetch, .counted = fetch };
}

/// A demand of the model's (`bandwidth.Demand`) with what it was worked
/// out from: the timings, the timing generator's start - null for a mode
/// about to be set, whose start is worked out - and each plane with the
/// pipe that reads it, in the pipes' order.
const Fitted = struct {
    demand: bandwidth.Demand = .{},
    timings: rtg.RtgTimings,
    vstartup: ?u32,
    planes: [pipe_count]bandwidth.Plane = undefined,
    pipes: [pipe_count]u32 = undefined,
    count: u32 = 0,

    fn load(fitted: *const Fitted) bandwidth.Load {
        return .{ .timings = fitted.timings, .vstartup = fitted.vstartup, .planes = fitted.planes[0..fitted.count] };
    }

    /// What pipe `index`'s schedule is worked out at: its share of the
    /// pipes' clock, the controller's deep sleep, the memory's wait, and
    /// its time to urgency in a blank from the longest of the watermarks
    /// the hub is given that the blank allows. Null for a pipe it has no
    /// plane of.
    fn heldOf(fitted: *const Fitted, index: u32) ?mode.Held {
        for (fitted.pipes[0..fitted.count], 0..) |pipe_index, plane_index| {
            if (pipe_index != index) continue;
            return bandwidth.heldOf(fitted.load(), plane_index, fitted.demand.clocks, @as(u64, fitted.demand.wait_ns) * 1000, fitted.demand.blankPs());
        }
        return null;
    }
};

/// The least of the hub's buffer a plane is counted with: one segment,
/// where the picture's share reads none.
const smallest_buffer: u32 = 64 * 1024;

/// The frames' rows, in pixels: what the picture's fetcher is counted as
/// reading in, a buffer read in place of a frame too.
fn framesPitch(screen: *const Screen) u32 {
    return screen.fb.pitch / screen.bytes;
}

/// What the display's clocks are worked out from, read once - one asker
/// at a time at the mailbox: the power manager's states and the clocks'
/// tops (`smu.clocks`), the PLL the display's clocks are divided from,
/// and the memory the video BIOS names. Null where the manager's table or
/// the PLL cannot be read, read again the next time.
fn factsOf(screen: *Screen) ?bandwidth.Facts {
    screen.sys.ObtainSemaphore(&screen.smu_lock);
    defer screen.sys.ReleaseSemaphore(&screen.smu_lock);
    if (screen.facts) |known| return known;
    var table: rtg.tags.RtgAmdClocks = .{};
    if (smu.clocks(screen.dcn, screen.smu, &table) != err.RTGERR_OK) return null;
    if (table.disp_count == 0 or table.fabric_count == 0 or table.pll_khz == 0) return null;
    var facts: bandwidth.Facts = .{
        .display_most_khz = smu.top(table.disp_mhz[0..table.disp_count]) * 1000,
        .pipes_most_khz = smu.top(table.dpp_mhz[0..table.disp_count]) * 1000,
        .pll_khz = table.pll_khz,
        .memory = biosMemory(screen.dcn),
    };
    var fabric: [rtg.tags.RTG_AMD_FABRIC_STATES]bandwidth.Fabric = undefined;
    const states = @min(table.fabric_count, rtg.tags.RTG_AMD_FABRIC_STATES);
    for (fabric[0..states], 0..) |*state, index| state.* = .{
        .fabric_mhz = table.fabric_mhz[index],
        .memory_mhz = table.memory_mhz[index],
        .voltage = table.fabric_voltage[index],
        .ratio = @intCast(table.fabric_ratio[index] & 0xff),
    };
    bandwidth.levelsOf(&facts, &table.dcf_mhz, table.dcf_count, &table.soc_voltage, fabric[0..states]);
    if (facts.count == 0) return null;
    screen.facts = facts;
    const top = facts.levels[facts.count - 1];
    exec.kprintf(screen.sys, "%s: the display's clocks worked out for %d of the power manager's states, up to %d MHz in the controller, %d MHz in the fabric and %d MT/s of %d channels of %d bytes\n", .{
        MODULE_NAME,
        facts.count,
        top.controller_khz / 1000,
        top.fabric_khz / 1000,
        top.memory_mts,
        facts.memory.channels,
        facts.memory.channel_bytes,
    });
    return facts;
}

/// The memory the video BIOS names (`bandwidth.memoryOfBios`); the
/// vendor's default where the BIOS cannot be had.
fn biosMemory(engine: dcn.Engine) bandwidth.Memory {
    var found: sdk.resources.amdgpu.GPUBios = .{};
    if (!engine.gpu.GetGPUBios(&found)) return bandwidth.memoryOf(0, 0);
    const image = found.image orelse return bandwidth.memoryOf(0, 0);
    return bandwidth.memoryOfBios(image[0..found.bytes]);
}

/// The demand of the pipes reading `reading` at `timings` from the timing
/// generator's start `vstartup` (`bandwidth.demandOf`), each plane with
/// the share of the hub's buffer the picture's fetcher has, which a plane
/// is given as it is lit: null where the facts cannot be read or no state
/// of the power manager serves it.
fn demandFor(screen: *Screen, timings: rtg.RtgTimings, vstartup: ?u32, reading: *const [pipe_count]?Reading) ?Fitted {
    const facts = factsOf(screen) orelse return null;
    const buffer = @max(plane.bufferBytes(screen.dcn, screen.dcn.fetcher), smallest_buffer);
    var fitted: Fitted = .{ .timings = timings, .vstartup = vstartup };
    for (reading, 0..) |maybe, index| {
        const one = maybe orelse continue;
        fitted.planes[fitted.count] = .{ .fetch = one.counted, .buffer_bytes = buffer };
        fitted.pipes[fitted.count] = @intCast(index);
        fitted.count += 1;
    }
    fitted.demand = bandwidth.demandOf(&facts, fitted.load()) orelse return null;
    return fitted;
}

/// Whether two demands set the same clocks, the same schedules and the
/// same watermarks: the same pipes at the same shares, the same clocks,
/// state, wait, blank and hub's sets.
fn sameFit(was: *const Fitted, now: *const Fitted) bool {
    if (was.count != now.count) return false;
    for (0..now.count) |index| {
        if (was.pipes[index] != now.pipes[index]) return false;
        if (was.demand.clocks.pipe_khz[index] != now.demand.clocks.pipe_khz[index]) return false;
    }
    const before = &was.demand;
    const after = &now.demand;
    return before.clocks.display_khz == after.clocks.display_khz and
        before.clocks.pipes_khz == after.clocks.pipes_khz and
        before.clocks.deep_sleep_hz == after.clocks.deep_sleep_hz and
        before.level == after.level and
        before.controller_khz == after.controller_khz and
        before.prefetch_mode == after.prefetch_mode and
        before.wait_ns == after.wait_ns and
        before.blankPs() == after.blankPs() and
        sameMarks(hub.marksOf(before.watermarks), hub.marksOf(after.watermarks));
}

fn sameMarks(was: hub.Marks, now: hub.Marks) bool {
    for (was, now) |was_mark, now_mark| {
        if (was_mark != now_mark) return false;
    }
    return true;
}

/// The controller clock's first four states, in MHz: what the watermark
/// sets the manager picks by it are bounded by.
fn firstLevels(facts: *const bandwidth.Facts) [4]u32 {
    var levels: [4]u32 = undefined;
    for (&levels, 0..) |*level, index| level.* = facts.levels[@min(index, facts.count - 1)].controller_khz / 1000;
    return levels;
}

/// The display's clocks raised for `fitted` before a change makes the
/// pipes read what it counts - `next`, by pipe - where they go up
/// (`clocks.raise`): the first time from what runs, after the manager is
/// told the display is in use and handed the watermark sets' ranges; then
/// the hub's watermarks that go up (`hub.program`). The demand kept, and
/// where it changed the other pipes' schedules and the lowering left due.
/// Holding `pipe_lock`.
fn raiseTo(screen: *Screen, fitted: Fitted, next: [pipe_count]?Reading) void {
    screen.reading = next;
    const changed = if (screen.fitted) |*was| !sameFit(was, &fitted) else true;
    screen.fitted = fitted;
    if (!changed) {
        if (screen.notify_due) notifyClocks(screen);
        return;
    }
    screen.rewrite_due = true;
    screen.lower_due = true;
    const engine = screen.dcn;
    const kept = &screen.fitted.?;
    const asked = clocks.askedOf(&kept.demand, kept.pipes[0..kept.count]);
    screen.sys.ObtainSemaphore(&screen.smu_lock);
    clocks.startFrom(engine, screen.smu, &screen.told);
    const levels = firstLevels(&screen.facts.?);
    clocks.raise(engine, screen.smu, &screen.told, asked, levels);
    screen.sys.ReleaseSemaphore(&screen.smu_lock);
    sayRefused(screen);
    notifyClocks(screen);
    hub.program(engine, &screen.marks, hub.marksOf(kept.demand.watermarks), false);
}

/// The display's clocks lowered to the demand they were raised for, once
/// the pipes have taken the change - a frame waited for, unless `waited`
/// says the caller has - where a change left them to be (`clocks.lower`):
/// every pipe's divider written too, and before them every one of the
/// hub's watermarks, the memory let into self-refresh after
/// (`hub.program`). Holding `pipe_lock`.
fn lowerDue(screen: *Screen, waited: bool) void {
    if (!screen.lower_due) return;
    screen.lower_due = false;
    const fitted = if (screen.fitted) |*one| one else return;
    if (!waited) pace(screen, 1);
    hub.program(screen.dcn, &screen.marks, hub.marksOf(fitted.demand.watermarks), true);
    const asked = clocks.askedOf(&fitted.demand, fitted.pipes[0..fitted.count]);
    screen.sys.ObtainSemaphore(&screen.smu_lock);
    clocks.lower(screen.dcn, screen.smu, &screen.told, asked);
    screen.sys.ReleaseSemaphore(&screen.smu_lock);
    sayRefused(screen);
    notifyClocks(screen);
}

/// The display controller told the clocks the manager was last asked for
/// (`dmub.notifyClocks`), as the vendor's clock manager tells it after
/// each change: where the controller's lock can be had without waiting -
/// a mode set and a sleep hold it already - else at the next change.
/// Holding `pipe_lock`.
fn notifyClocks(screen: *Screen) void {
    if (!screen.controller.running) {
        screen.notify_due = false;
        return;
    }
    if (!screen.sys.AttemptSemaphore(&screen.controller_lock)) {
        screen.notify_due = true;
        return;
    }
    defer screen.sys.ReleaseSemaphore(&screen.controller_lock);
    const told = &screen.told;
    screen.notify_due = !dmub.notifyClocks(screen.dcn, &screen.controller, told.display_khz, told.pipes_khz, told.controller_khz, told.deep_sleep_khz);
}

/// A message the power manager refused or did not answer, said on the log
/// once.
fn sayRefused(screen: *Screen) void {
    const refused = screen.told.refused;
    if (refused == 0 or refused == screen.refusal_said) return;
    screen.refusal_said = refused;
    exec.kprintf(screen.sys, "%s: the power manager did not take message 0x%x for the display's clocks\n", .{ MODULE_NAME, refused });
}

/// Every lit pipe's schedule but those `made`, which the change wrote,
/// worked out anew for the demand the clocks were raised for, where it
/// changed, and the timing generator's global sync for all of them
/// (`mode.syncOf`). Holding `pipe_lock` and the timing generator's
/// update lock, so the pipe takes it with the change.
fn writeOthers(screen: *Screen, made: []const u32) void {
    if (!screen.rewrite_due or screen.setting_mode) return;
    screen.rewrite_due = false;
    const fitted = if (screen.fitted) |*one| one else return;
    const engine = screen.dcn;
    const vstartup = mode.vstartupOf(engine, engine.pipe);
    var schedules: [pipe_count]mode.Schedule = undefined;
    var lit: [pipe_count]u32 = undefined;
    var count: usize = 0;
    var picture: ?usize = null;
    for (screen.reading, 0..) |maybe, index| {
        const one = maybe orelse continue;
        const pipe_index: u32 = @intCast(index);
        const held = fitted.heldOf(pipe_index) orelse continue;
        schedules[count] = mode.fetchSchedule(fitted.timings, one.fetch, held, vstartup) orelse continue;
        if (pipe_index == engine.fetcher) picture = count;
        lit[count] = pipe_index;
        count += 1;
    }
    const whole = picture orelse return;
    next: for (lit[0..count], schedules[0..count]) |pipe_index, *schedule| {
        for (made) |one| {
            if (one == pipe_index) continue :next;
        }
        mode.writeSchedule(engine, pipe_index, schedule);
    }
    mode.writeSync(engine, engine.pipe, lit[0..count], mode.syncOf(fitted.timings, &schedules[whole], schedules[0..count]));
}

/// `writeOthers` at the pipe's next update, under the timing generator's
/// update lock of its own: after a change whose lock is its plane's.
/// Holding `pipe_lock`.
fn rewriteOthers(screen: *Screen, made: []const u32) void {
    if (!screen.rewrite_due or screen.setting_mode) return;
    const engine = screen.dcn;
    plane.lock(engine, engine.pipe);
    writeOthers(screen, made);
    plane.unlock(engine, engine.pipe);
}

/// What pipe `index` is worked out at for the demand the clocks are set
/// for: null where they are set for none it is in.
fn heldFor(screen: *const Screen, index: u32) ?mode.Held {
    const fitted = if (screen.fitted) |*one| one else return null;
    return fitted.heldOf(index);
}

/// What pipe `index` read no longer counted, once it reads nothing: the
/// clocks raised for what is left where they go up, the other pipes'
/// schedules worked out anew, and - `lower_now` - the clocks lowered once
/// the pipes have taken it, a frame waited for; a mode set only counts
/// it, and makes its own change. Holding `pipe_lock`.
fn fitWithout(screen: *Screen, index: u32, lower_now: bool) void {
    var next = screen.reading;
    next[index] = null;
    if (screen.setting_mode) {
        screen.reading = next;
        return;
    }
    const engine = screen.dcn;
    const fitted = demandFor(screen, screen.timings, mode.vstartupOf(engine, engine.pipe), &next) orelse {
        // What is left runs at the clocks as they are.
        screen.reading = next;
        return;
    };
    raiseTo(screen, fitted, next);
    rewriteOthers(screen, &.{});
    if (lower_now) lowerDue(screen, false);
}

/// The picture's fetcher counted as reading the mode's whole picture in
/// the frames' rows, and the display's clocks set for it and for what
/// the planes read: at each show of a mode. Holding `pipe_lock`; nothing
/// while the monitor sleeps.
fn fitPicture(screen: *Screen) void {
    if (screen.asleep) return;
    const engine = screen.dcn;
    var next = screen.reading;
    next[engine.fetcher] = readingOf(mode.pictureFetch(screen.timings.h_active, framesPitch(screen)));
    const fitted = demandFor(screen, screen.timings, mode.vstartupOf(engine, engine.pipe), &next) orelse {
        if (!screen.fit_refused) exec.kprintf(screen.sys, "%s: the display's clocks could not be worked out for %dx%d, so they stay as they run\n", .{ MODULE_NAME, screen.timings.h_active, screen.timings.v_active });
        screen.fit_refused = true;
        return;
    };
    screen.fit_refused = false;
    const first = !screen.told.started;
    raiseTo(screen, fitted, next);
    rewriteOthers(screen, &.{});
    lowerDue(screen, false);
    if (first) sayClocks(screen, "worked out for the picture");
}

/// The clocks the manager was last asked for, said on the log.
fn sayClocks(screen: *const Screen, what: [*:0]const u8) void {
    const told = &screen.told;
    const level = if (screen.fitted) |one| one.demand.level else 0;
    exec.kprintf(screen.sys, "%s: the display's clocks %s: display %d kHz, pipes %d kHz, the controller at least %d kHz and %d kHz in deep sleep, state %d\n", .{
        MODULE_NAME,
        what,
        told.display_khz,
        told.pipes_khz,
        told.controller_khz,
        told.deep_sleep_khz,
        level,
    });
}

// --- the video layer, a film's plane ----------------------------------------------

/// The colour the picture shows a film under it through: near black, and
/// the same in each format a screen has - five, six or eight bits a
/// channel. Keyed with it, each channel down to `video_key_darkest`, are
/// the shades of it shadows leave: the library darkens what is under a
/// shadow by multiplying it, to (4, 0, 4) under one, (2, 0, 2) under two
/// laid over each other, (1, 0, 1) under three - so the film shows under
/// a window's shadow, undarkened, rather than a dark band.
const video_key: u32 = 0x0008_0008;
const video_key_darkest: u32 = 0x0001_0001;
/// The keyer's mode: a pixel whose colour lies in its ranges made clear,
/// every other opaque. Its other modes, as the engine shows them: 0 makes
/// every pixel clear, 1 every pixel opaque, 2 the pixels in the ranges
/// opaque and every other clear.
const video_keyer_mode: u32 = 3;

/// The largest frame a layer takes each way, and how far it scales one,
/// each way on its own: sixteen times up, a sixth down, the vendor's
/// limits for these frames - as far as the line buffer holds the rows
/// the taps read and the hub the bytes (`video.scalingOf`,
/// `mode.fetchSchedule`).
const video_max_side: u32 = 4096;
const video_max_up: u32 = 16;
const video_max_down: u32 = 6;

/// The keyer's range for a channel of the key's shades, the channel
/// `shift` bits up in 0x00RRGGBB: its eight bits at the top of the
/// keyer's sixteen, the least with nothing below them and the most with
/// all, however the converter widens eight bits.
fn keyRange(shift: u5) [2]u16 {
    const least: u16 = @intCast((video_key_darkest >> shift) & 0xff);
    const most: u16 = @intCast((video_key >> shift) & 0xff);
    return .{ least << 8, most << 8 | 0xff };
}

const video_keyed: plane.Key = .{
    .red = keyRange(16),
    .green = keyRange(8),
    .blue = keyRange(0),
    .mode = video_keyer_mode,
};

/// Whether a film's plane makes the display's colours out of such a
/// picture. Its colour matrix holds BT.601's or BT.709's weights, either
/// range, and there is nothing after it the board sets: no curve, so a
/// film of high dynamic range would come out flat and grey, and no way
/// to move BT.2020's red, green and blue to the display's; and its
/// fetcher is told 4:2:0 frames of a byte a sample. Such a film is left
/// to graphics.library, which maps it.
fn videoColours(matrix: u8, transfer: u8, primaries: u8, depth: u8) bool {
    if (matrix != rtg.bitmaps.RTGYUV_BT601 and matrix != rtg.bitmaps.RTGYUV_BT709) return false;
    if (transfer != rtg.bitmaps.RTGYUV_SDR or primaries != rtg.bitmaps.RTGYUV_BT709) return false;
    return depth == 8;
}

/// The layer taken: under the picture unless asked over, with the key
/// colour the picture shows it through, nothing on it and no place yet.
/// None for a picture the plane cannot make colours out of, or where the
/// engine has no page table to read a frame through, which is in the
/// machine's memory; RTGERR_IN_USE while one is open. Bands the display
/// reads are given up for the picture whole - the film's place is on
/// it - and refused while the layer is open.
fn videoOpen(board: *rtg.RtgBoard, layer: *rtg.RtgVideoLayer) callconv(.c) i32 {
    if (!videoColours(layer.matrix, layer.transfer, layer.primaries, layer.depth)) return err.RTGERR_NOT_SUPPORTED;
    const screen = screenOf(board);
    if (screen.gart == null or !plane.reached(screen.dcn)) return err.RTGERR_NOT_SUPPORTED;
    const under = layer.flags & rtg.RTGVLF_UNDER != 0;
    layer.key = if (under) video_key else 0;
    layer.max_width = video_max_side;
    layer.max_height = video_max_side;
    layer.max_up = video_max_up;
    layer.max_down = video_max_down;
    screen.sys.ObtainSemaphore(&screen.pipe_lock);
    defer screen.sys.ReleaseSemaphore(&screen.pipe_lock);
    if (screen.film != null) return err.RTGERR_IN_USE;
    dropBands(screen);
    screen.film = layer;
    screen.film_layer = if (under) .under else .over;
    screen.film_frame = null;
    screen.film_place = .{};
    screen.film_refused = false;
    return err.RTGERR_OK;
}

/// The layer given back: its plane taken down, the picture whole again,
/// and a frame waited for, so that the last frame is no longer read.
fn videoClose(board: *rtg.RtgBoard, layer: *rtg.RtgVideoLayer) callconv(.c) void {
    const screen = screenOf(board);
    screen.sys.ObtainSemaphore(&screen.pipe_lock);
    if (screen.film == layer) {
        dropFilm(screen);
        screen.film = null;
        screen.film_frame = null;
    }
    screen.sys.ReleaseSemaphore(&screen.pipe_lock);
    pace(screen, 1);
}

/// A frame shown, or none, from the pipe's next update - waited for, so
/// that the one before is no longer read. One the plane cannot read, or
/// scale into its place, is not kept: nothing is shown.
fn videoShow(board: *rtg.RtgBoard, layer: *rtg.RtgVideoLayer, picture: ?*const rtg.RtgYuv, src: ?*const rtg.RtgRect) callconv(.c) i32 {
    const screen = screenOf(board);
    screen.sys.ObtainSemaphore(&screen.pipe_lock);
    defer screen.sys.ReleaseSemaphore(&screen.pipe_lock);
    if (screen.film != layer) return err.RTGERR_BAD_ARG;
    const one = picture orelse {
        screen.film_frame = null;
        dropFilm(screen);
        return err.RTGERR_OK;
    };
    const part = src.?.*;
    if (!filmReads(one, part)) {
        screen.film_frame = null;
        dropFilm(screen);
        return err.RTGERR_BAD_ARG;
    }
    screen.film_frame = one.*;
    screen.film_part = part;
    const code = showFilm(screen, true);
    if (code != err.RTGERR_OK) screen.film_frame = null;
    return code;
}

/// The layer's place, on the display before any turn, the frame shown in
/// it from the pipe's next update: hidden for an empty place, one off
/// the glass, and - RTGERR_BAD_ARG - where the frame cannot be scaled
/// into it.
fn videoMove(board: *rtg.RtgBoard, layer: *rtg.RtgVideoLayer, place: *const rtg.RtgRect) callconv(.c) i32 {
    const screen = screenOf(board);
    screen.sys.ObtainSemaphore(&screen.pipe_lock);
    defer screen.sys.ReleaseSemaphore(&screen.pipe_lock);
    if (screen.film != layer) return err.RTGERR_BAD_ARG;
    screen.film_place = place.*;
    return showFilm(screen, false);
}

/// Whether the plane reads `part` of `picture`: colours it makes the
/// display's out of (`videoColours` - the picture may not be the kind
/// the layer was opened for), NV12, each plane's rows a whole number of
/// the 256 bytes a fetcher reads a linear surface's rows by and no
/// longer than it counts, the colour's samples on pairs of bytes, and the
/// part - its left and top on a pair of pixels - within the rows from
/// the 256 bytes each plane starts in.
fn filmReads(picture: *const rtg.RtgYuv, part: rtg.RtgRect) bool {
    if (!videoColours(picture.matrix, picture.transfer, picture.primaries, picture.depth)) return false;
    if (picture.layout != rtg.bitmaps.RTGYUV_NV12) return false;
    if (picture.y_pitch == 0 or picture.y_pitch % row_alignment != 0 or picture.y_pitch > largest_side + 1) return false;
    if (picture.c_pitch == 0 or picture.c_pitch % row_alignment != 0 or picture.c_pitch / 2 > largest_side + 1) return false;
    if (@intFromPtr(picture.cb) % 2 != 0) return false;
    if (@rem(part.x, 2) != 0 or @rem(part.y, 2) != 0) return false;
    const right: usize = @intCast(@as(i64, part.x) + part.width);
    if (@intFromPtr(picture.y) % row_alignment + right > picture.y_pitch) return false;
    if (@intFromPtr(picture.cb) % row_alignment + (right + 1) / 2 * 2 > picture.c_pitch) return false;
    return true;
}

/// Whether any of `place` lies on a glass `width` by `height`.
fn onGlass(place: rtg.RtgRect, width: u32, height: u32) bool {
    if (place.width <= 0 or place.height <= 0) return false;
    if (@as(i64, place.x) + place.width <= 0 or @as(i64, place.y) + place.height <= 0) return false;
    return place.x < @as(i64, width) and place.y < @as(i64, height);
}

/// Whether `read` pixels scale to `shown`, as far as a layer says it
/// does (`video_max_up`, `video_max_down`).
fn filmScales(read: i32, shown: i32) bool {
    const from: u64 = @intCast(read);
    const into: u64 = @intCast(shown);
    return into <= from * video_max_up and into * video_max_down >= from;
}

/// The film's frame kept shown in its place, as much of it as the glass
/// has: its plane lit on a free pipe where it is not, told the frame,
/// the place and the scaling where it is; taken down with no frame, an
/// empty place or none of it on the glass. RTGERR_BAD_ARG, the plane
/// taken down, where the frame cannot be scaled into its place, the
/// engine's page table cannot map its planes, no pipe is free or the hub
/// gives the plane no buffer. With `wait`, returns once the pipe has
/// taken the frame, so that the one before is no longer read. Holding
/// `pipe_lock`; nothing while the pipe is asleep, which took the plane
/// down: the frame is kept for waking.
fn showFilm(screen: *Screen, wait: bool) i32 {
    const engine = screen.dcn;
    if (screen.film == null) return err.RTGERR_OK;
    const one = screen.film_frame orelse {
        dropFilm(screen);
        return err.RTGERR_OK;
    };
    if (screen.asleep) return err.RTGERR_OK;
    const place = screen.film_place;
    const part = screen.film_part;
    if (!onGlass(place, screen.width, screen.height)) {
        dropFilm(screen);
        return err.RTGERR_OK;
    }
    const refused = err.RTGERR_BAD_ARG;
    if (!filmScales(part.width, place.width) or !filmScales(part.height, place.height)) {
        dropFilm(screen);
        return refused;
    }
    const scaling = video.scalingOf(.{
        .src_x = @intCast(part.x),
        .src_y = @intCast(part.y),
        .src_width = @intCast(part.width),
        .src_height = @intCast(part.height),
        .dst_x = place.x,
        .dst_y = place.y,
        .dst_width = @intCast(place.width),
        .dst_height = @intCast(place.height),
        .glass_width = screen.width,
        .glass_height = screen.height,
        .mirror_x = screen.turn_x,
        .mirror_y = screen.turn_y,
    }) orelse {
        dropFilm(screen);
        return refused;
    };
    const table = if (screen.gart) |*held| held else return refused;
    const rows: u32 = @intCast(part.y + part.height);
    const addresses = filmAddresses(screen, table, &one, rows) orelse {
        dropFilm(screen);
        return refused;
    };
    // Each plane's first element counted from the 256 bytes it starts in.
    const luma_x: u32 = @intCast(@intFromPtr(one.y) % row_alignment);
    const chroma_x: u32 = @intCast(@intFromPtr(one.cb) % row_alignment / 2);
    const right: u32 = @intCast(part.x + part.width);
    const across = scaling.across;
    const down = scaling.down;
    const fetch: mode.Fetch = .{
        .out_width = scaling.out_width,
        .luma = .{ .width = across.size, .surface = luma_x + right, .pitch = one.y_pitch, .bytes = 1, .h_ratio = across.ratio, .v_ratio = down.ratio, .h_taps = across.taps, .v_taps = down.taps },
        .chroma = .{ .width = across.size_c, .surface = chroma_x + (right + 1) / 2, .pitch = one.c_pitch / 2, .bytes = 2, .h_ratio = across.ratio_c, .v_ratio = down.ratio_c, .h_taps = across.taps_c, .v_taps = down.taps_c },
        .scaled = true,
        .cursor = false,
    };
    // Its pipe: the one it is lit on, else a free one.
    const index = screen.film_pipe orelse freePipe(engine) orelse {
        if (!screen.film_refused) exec.kprintf(screen.sys, "%s: no pipe is free for the film, which is not shown\n", .{MODULE_NAME});
        screen.film_refused = true;
        return refused;
    };
    // The clocks raised for what it reads before it is lit or moved, the
    // other pipes worked out anew after, the clocks lowered once taken.
    const vstartup = mode.vstartupOf(engine, engine.pipe);
    var next = screen.reading;
    next[index] = readingOf(fetch);
    const fitted = demandFor(screen, screen.timings, vstartup, &next) orelse {
        if (!screen.film_refused) exec.kprintf(screen.sys, "%s: the display's clocks cannot serve the film as well, which is not shown\n", .{MODULE_NAME});
        screen.film_refused = true;
        dropFilm(screen);
        return refused;
    };
    const held = fitted.heldOf(index) orelse {
        dropFilm(screen);
        return refused;
    };
    const schedule = mode.fetchSchedule(screen.timings, fetch, held, vstartup) orelse {
        dropFilm(screen);
        return refused;
    };
    raiseTo(screen, fitted, next);
    const film: plane.Film = .{
        .luma = addresses[0],
        .chroma = addresses[1],
        .luma_x = luma_x,
        .chroma_x = chroma_x,
        .luma_pitch = one.y_pitch,
        .chroma_pitch = one.c_pitch / 2,
        .scaling = scaling,
        .mirror_x = screen.turn_x,
        .mirror_y = screen.turn_y,
    };
    const matrix = coefficients.matrixOf(one.matrix == rtg.bitmaps.RTGYUV_BT709, one.range != rtg.bitmaps.RTGYUV_FULL);
    if (screen.film_pipe) |lit| {
        plane.moveFilm(engine, lit, engine.pipe, &schedule, &film, if (screen.film_matrix != matrix) matrix else null, &screen.film_filters);
    } else {
        gart.reach(engine, index);
        const output = mode.outputOf(engine, engine.pipe);
        if (!plane.lightFilm(engine, index, engine.pipe, output, engine.fetcher, screen.width | screen.height << 16, &schedule, &film, matrix, &screen.film_filters, screen.film_layer, &video_keyed, &screen.film_unkeyed)) {
            plane.darkenFilm(engine, index, engine.pipe, output, engine.fetcher, screen.film_layer, screen.film_unkeyed);
            if (!screen.film_refused) exec.kprintf(screen.sys, "%s: the hub gave pipe %d no buffer, so the film is not shown\n", .{ MODULE_NAME, index });
            screen.film_refused = true;
            fitWithout(screen, index, true);
            return refused;
        }
        screen.film_pipe = index;
        screen.film_refused = false;
    }
    screen.film_matrix = matrix;
    screen.film_reads = addresses;
    rewriteOthers(screen, &.{index});
    if (!wait) {
        lowerDue(screen, false);
        return err.RTGERR_OK;
    }
    // Taken at the pipe's next update, as a flip.
    pace(screen, 1);
    var looks: u32 = 0;
    while (!plane.taken(engine, index)) : (looks += 1) {
        if (looks == 2) {
            dropFilm(screen);
            return err.RTGERR_IO;
        }
        pace(screen, 1);
    }
    lowerDue(screen, true);
    return err.RTGERR_OK;
}

/// The device's addresses of a film's two planes, each from the 256
/// bytes its first row starts in to the end of its row for `rows` rows
/// of the frame, mapped in the engine's page table by the machine's
/// addresses exec names for them: one run where the colour lies close
/// past the brightness, as a decoder's frame has it, two where not. The
/// frame the film's plane reads now and the buffer the picture's fetcher
/// reads keep their pages. Null where a plane is not one run of the
/// machine's memory or the table cannot map it.
fn filmAddresses(screen: *Screen, table: *gart.Table, one: *const rtg.RtgYuv, rows: u32) ?[2]u64 {
    const step: usize = row_alignment;
    const luma_start = @intFromPtr(one.y) / step * step;
    const chroma_start = @intFromPtr(one.cb) / step * step;
    const luma_end = @intFromPtr(one.y) + @as(usize, rows) * one.y_pitch;
    const chroma_end = @intFromPtr(one.cb) + @as(usize, (rows + 1) / 2) * one.c_pitch;
    var busy = [_]u64{ screen.flip_wanted, screen.film_reads[0], screen.film_reads[1], 0 };
    const first = @min(luma_start, chroma_start);
    const last = @max(luma_end, chroma_end);
    if (last - first <= 2 * ((luma_end - luma_start) + (chroma_end - chroma_start))) {
        const start = mapSpan(screen, table, first, last - first, &busy) orelse return null;
        return .{ start + (luma_start - first), start + (chroma_start - first) };
    }
    const luma = mapSpan(screen, table, luma_start, luma_end - luma_start, &busy) orelse return null;
    busy[3] = luma;
    const chroma = mapSpan(screen, table, chroma_start, chroma_end - chroma_start, &busy) orelse return null;
    return .{ luma, chroma };
}

/// The device's address of `length` bytes of the machine's memory from
/// `start`, mapped in the engine's page table: null where they are not
/// one run of the machine's memory, as exec's CachePreDMA names them, or
/// the table cannot map them.
fn mapSpan(screen: *Screen, table: *gart.Table, start: usize, length: usize, busy: []const u64) ?u64 {
    if (length == 0 or length > 0xffff_ffff) return null;
    var bytes: u32 = @intCast(length);
    const machine = @intFromPtr(screen.sys.CachePreDMA(@ptrFromInt(start), &bytes, exec.DMAF_ReadFromRAM));
    if (bytes != length) return null;
    return gart.map(table, machine, bytes, busy);
}

/// The film's plane taken down where it is lit, the picture whole again
/// and no longer keyed, and the clocks set for what is left
/// (`fitWithout`); the frame kept. Holding `pipe_lock`.
fn dropFilm(screen: *Screen) void {
    const index = screen.film_pipe orelse return;
    const engine = screen.dcn;
    plane.darkenFilm(engine, index, engine.pipe, mode.outputOf(engine, engine.pipe), engine.fetcher, screen.film_layer, screen.film_unkeyed);
    screen.film_pipe = null;
    screen.film_filters = null;
    screen.film_matrix = null;
    screen.film_reads = .{ 0, 0 };
    fitWithout(screen, index, true);
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
/// display's clocks a state of the power manager serves for its picture,
/// `modeFit`) on an HDMI or DVI connector, at a pixel clock the link the
/// monitor takes carries.
fn checkModeOp(board: *rtg.RtgBoard, timings: *const rtg.RtgTimings) callconv(.c) i32 {
    const screen = screenOf(board);
    if (monitor.isLit(screen.dcn, timings.*)) return err.RTGERR_OK;
    if (!screen.controller.running) return err.RTGERR_BAD_MODE;
    if (screen.connector.kind != sdk.resources.amdgpu.GPUCONNECTOR_HDMI and screen.connector.kind != sdk.resources.amdgpu.GPUCONNECTOR_DVI) return err.RTGERR_BAD_MODE;
    var alone: [pipe_count]?Reading = undefined;
    _ = modeFit(screen, timings, &alone) orelse return err.RTGERR_BAD_MODE;
    const most_khz: u32 = if (takesHdmi(screen)) hdmi_most_khz else dvi_most_khz;
    if (timings.pixel_clock_hz / 1000 > most_khz) return err.RTGERR_BAD_MODE;
    return err.RTGERR_OK;
}

/// The fastest pixel clock HDMI is set at, unscrambled, and DVI on one
/// link, in kHz.
const hdmi_most_khz: u32 = 340_000;
const dvi_most_khz: u32 = 165_000;

/// The mode for `timings` and the demand its picture makes alone - as
/// the planes go down with the pipe for a set - with what its fetcher
/// reads into `alone`: null where no state of the power manager serves
/// it, or the pipe cannot make it at the clocks that do.
fn modeFit(screen: *Screen, timings: *const rtg.RtgTimings, alone: *[pipe_count]?Reading) ?struct { set: mode.Mode, fitted: Fitted } {
    const engine = screen.dcn;
    alone.* = @splat(null);
    alone[engine.fetcher] = readingOf(mode.pictureFetch(timings.h_active, framesPitch(screen)));
    const fitted = demandFor(screen, timings.*, null, alone) orelse return null;
    const held = fitted.heldOf(engine.fetcher) orelse return null;
    const set = mode.of(timings.*, screen.fb.width, screen.fb.height, held) orelse return null;
    return .{ .set = set, .fitted = fitted };
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

/// What the AVI infoframe says beyond the picture: the RGB range, where
/// it is said (`colours.outputFor`); no number for a mode that HDMI
/// 1.4's vendor infoframe names to a monitor short of HDMI 2.0.
fn aviFlags(said: *const rtg.RtgMonitorInfo, timings: *const rtg.RtgTimings, output: colours.Output) u32 {
    var flags: u32 = colours.aviFlags(output);
    const vendor_named = switch (timings.vic) {
        93, 94, 95, 98 => true,
        else => false,
    };
    if (vendor_named and said.flags & rtg.modes.RTGMON_HDMI2 == 0) flags |= rtg.RTGAVI_NO_VIC;
    return flags;
}

/// The link's colours for the mode the board shows: their range set in
/// the blender's output matrix, and on an HDMI link the AVI infoframe
/// that says it sent where it is not the one sent last (`colours.zig`).
/// A change of range is said on the log. No flip meanwhile.
fn coloursFor(screen: *Screen) void {
    const engine = screen.dcn;
    if (!colours.reached(engine)) return;
    var said: rtg.RtgMonitorInfo = .{};
    _ = screen.rtg_base.GetBoardMonitor(screen.board, &said, @sizeOf(rtg.RtgMonitorInfo));
    const output = colours.outputFor(&said, &screen.timings, screen.board.info.color_range);
    screen.sys.ObtainSemaphore(&screen.pipe_lock);
    defer screen.sys.ReleaseSemaphore(&screen.pipe_lock);
    const out = mode.outputOf(engine, engine.pipe);
    const was = colours.rangeOf(engine, out);
    colours.setRange(engine, out, output.limited);
    if (was == null or was.? != output.limited) {
        exec.kprintf(screen.sys, "%s: the colours go out in %s range%s\n", .{
            MODULE_NAME,
            if (output.limited) @as([*:0]const u8, "limited") else "full",
            if (output.said) @as([*:0]const u8, ", said in the AVI infoframe") else "",
        });
    }
    if (!pipe.litAsHdmi(engine)) return;
    const front = sound.litLink(engine) orelse return;
    var avi: [rtg.RTG_AVI_BYTES]u8 = @splat(0);
    if (drivers(screen).BuildAviInfoFrame(&screen.timings, aviFlags(&said, &screen.timings, output), &avi) != rtg.RTG_AVI_BYTES) return;
    if (screen.avi_sent) |*sent| {
        if (sameFrame(sent, &avi)) return;
    }
    pipe.sendAvi(engine, front, &avi);
    screen.avi_sent = avi;
}

fn sameFrame(a: *const [rtg.RTG_AVI_BYTES]u8, b: *const [rtg.RTG_AVI_BYTES]u8) bool {
    for (a, b) |one, other| {
        if (one != other) return false;
    }
    return true;
}

/// The link's sound set for the mode the board shows and the monitor on
/// it (`sound.soundUp`).
fn soundFor(screen: *Screen) void {
    var said: rtg.RtgMonitorInfo = .{};
    _ = screen.rtg_base.GetBoardMonitor(screen.board, &said, @sizeOf(rtg.RtgMonitorInfo));
    _ = sound.soundUp(screen.dcn, &screen.timings, &said);
}

/// The monitor sent nothing, which it sleeps at, or the stream again: the
/// pipe down and up in its mode (`pipe.sleep`, `pipe.wake`), the link's
/// sound off before and set again after. The library darkens the picture
/// before it asks for sleep and lights it once the board is awake, each
/// composed by its flips. RTGPWR_BLANK where the display controller does
/// not run, which the tables the PHY is switched by need; an error, and
/// the pipe brought up again, where a step fails. One asker at a time at
/// the controller, and no flip meanwhile.
fn powerOp(board: *rtg.RtgBoard, state: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    const sys = screen.sys;
    const asleep = state == rtg.boards.RTGPWR_ASLEEP;
    sys.ObtainSemaphore(&screen.controller_lock);
    defer sys.ReleaseSemaphore(&screen.controller_lock);
    if (!screen.controller.running) return @intCast(rtg.boards.RTGPWR_BLANK);
    sys.ObtainSemaphore(&screen.pipe_lock);
    defer sys.ReleaseSemaphore(&screen.pipe_lock);
    const code = if (asleep) sleepLink(screen, screen.pixel_clock_hz) else wakeLink(screen);
    if (code != err.RTGERR_OK) return code;
    if (!asleep) {
        soundFor(screen);
        // The infoframe written again, whatever the packet generator
        // kept while the link was down.
        screen.avi_sent = null;
        coloursFor(screen);
    }
    return @intCast(if (asleep) rtg.boards.RTGPWR_ASLEEP else rtg.boards.RTGPWR_ON);
}

/// The monitor's brightness set over DDC/CI (rtg.library's
/// GetMonitorControl and SetMonitorControl), `percent` of its largest:
/// RTGERR_IO where it does not answer, RTGERR_NOT_SUPPORTED on a
/// connector whose DDC the I2C engine does not reach. The DDC's lock
/// keeps a look at the connector off the bus meanwhile; the pipe's is
/// not taken, so the pictures go on being flipped to for the tenth of a
/// second the question and its answer take.
fn setBrightnessOp(board: *rtg.RtgBoard, percent: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    if (!monitor.readsOverI2c(screen.connector)) return err.RTGERR_NOT_SUPPORTED;
    screen.sys.ObtainSemaphore(&screen.ddc_lock);
    defer screen.sys.ReleaseSemaphore(&screen.ddc_lock);
    var hook: utility.Hook = .{ .entry = &ddcTransfer, .data = screen };
    var value: u32 = 0;
    var most: u32 = 0;
    const asked = drivers(screen).GetMonitorControl(rtg.modes.RTGVCP_BRIGHTNESS, &hook, &value, &most);
    heard(screen, asked, value, most);
    if (asked != err.RTGERR_OK) return asked;
    return drivers(screen).SetMonitorControl(rtg.modes.RTGVCP_BRIGHTNESS, (percent * most + 50) / 100, &hook);
}

/// The monitor's brightness as it answers over DDC/CI, in per cent of
/// its largest - set with its own buttons, or by `setBrightnessOp`:
/// RTGERR_IO where it does not answer. Under the DDC's lock, as
/// `setBrightnessOp`.
fn brightnessOp(board: *rtg.RtgBoard) callconv(.c) i32 {
    const screen = screenOf(board);
    if (!monitor.readsOverI2c(screen.connector)) return err.RTGERR_NOT_SUPPORTED;
    screen.sys.ObtainSemaphore(&screen.ddc_lock);
    defer screen.sys.ReleaseSemaphore(&screen.ddc_lock);
    var hook: utility.Hook = .{ .entry = &ddcTransfer, .data = screen };
    var value: u32 = 0;
    var most: u32 = 0;
    const asked = drivers(screen).GetMonitorControl(rtg.modes.RTGVCP_BRIGHTNESS, &hook, &value, &most);
    heard(screen, asked, value, most);
    if (asked != err.RTGERR_OK) return asked;
    return @intCast((@min(value, most) * 100 + most / 2) / most);
}

/// Whether the monitor answered its brightness over DDC/CI said on the
/// log the first time it is asked, and again each time that changes.
fn heard(screen: *Screen, asked: i32, value: u32, most: u32) void {
    const answers = asked == err.RTGERR_OK;
    if (screen.ddcci_heard != null and screen.ddcci_heard.? == answers) return;
    screen.ddcci_heard = answers;
    if (answers) {
        exec.kprintf(screen.sys, "%s: the monitor answers DDC/CI, its brightness at %d of %d\n", .{ MODULE_NAME, value, most });
    } else {
        exec.kprintf(screen.sys, "%s: the monitor does not answer DDC/CI: %s\n", .{ MODULE_NAME, screen.rtg_base.RtgErrorText(asked) });
    }
}

/// The hook rtg.library's DDC/CI calls hand their transfers to: each a
/// transaction of its own on the connector's DDC line, by the I2C engine
/// (`i2c.transfer`); RTGERR_IO where the monitor did not answer, or the
/// engine could not be had.
fn ddcTransfer(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const screen: *Screen = @ptrCast(@alignCast(hook.data.?));
    const move: *const rtg.RtgDdcTransfer = @ptrCast(@alignCast(message.?));
    const bytes = (move.bytes orelse return @bitCast(@as(isize, err.RTGERR_BAD_ARG)))[0..move.count];
    const messages = [_]i2c.Message{.{ .address = @intCast(move.address & 0x7F), .read = move.read != 0, .bytes = bytes }};
    const result = i2c.transfer(screen.dcn, screen.connector.ddc_line, &messages);
    return @bitCast(@as(isize, if (result == .ok) err.RTGERR_OK else err.RTGERR_IO));
}

/// The link put to sleep, the controller's and the pipe's locks held, in
/// the mode the pipe scans at `pixel_hz`: its sound off first. A step
/// that fails has the pipe brought up again.
fn sleepLink(screen: *Screen, pixel_hz: u32) i32 {
    if (screen.asleep) return err.RTGERR_OK;
    dropOverlay(screen);
    dropBands(screen);
    dropFilm(screen);
    sound.soundDown(screen.dcn);
    var stage: u32 = 0;
    const started = screen.sys.UptimeUs();
    const code = pipe.sleep(screen.dcn, &screen.controller, screen.connector, pixel_hz, &screen.sleeping, &stage);
    if (code != err.RTGERR_OK) {
        exec.kprintf(screen.sys, "%s: the monitor not put to sleep (%ld), stopped at stage %d\n", .{ MODULE_NAME, @as(i64, code), stage });
        if (stage >= rtg.tags.RTG_AMD_PIPE_MUTED) {
            var back: u32 = 0;
            _ = pipe.wake(screen.dcn, &screen.controller, &screen.sleeping, &back);
        }
        soundFor(screen);
        showOverlay(screen);
        _ = showFilm(screen, false);
        return code;
    }
    screen.asleep = true;
    exec.kprintf(screen.sys, "%s: the monitor is sent nothing after %d us, the PHY %s\n", .{
        MODULE_NAME,
        @as(u32, @intCast(@min(screen.sys.UptimeUs() - started, 0xffff_ffff))),
        @as([*:0]const u8, if (pipe.phyOn(screen.dcn, &screen.sleeping)) "still on" else "off"),
    });
    return err.RTGERR_OK;
}

/// The link woken, the controller's and the pipe's locks held: the
/// stream it was sent before. Its sound is the caller's.
fn wakeLink(screen: *Screen) i32 {
    if (!screen.asleep) return err.RTGERR_OK;
    var stage: u32 = 0;
    const started = screen.sys.UptimeUs();
    const code = pipe.wake(screen.dcn, &screen.controller, &screen.sleeping, &stage);
    if (code != err.RTGERR_OK) {
        exec.kprintf(screen.sys, "%s: the monitor not woken (%ld), stopped at stage %d\n", .{ MODULE_NAME, @as(i64, code), stage });
        return code;
    }
    screen.asleep = false;
    showOverlay(screen);
    _ = showFilm(screen, false);
    exec.kprintf(screen.sys, "%s: the monitor is sent its stream again after %d us, the PHY %s\n", .{
        MODULE_NAME,
        @as(u32, @intCast(@min(screen.sys.UptimeUs() - started, 0xffff_ffff))),
        @as([*:0]const u8, if (pipe.phyOn(screen.dcn, &screen.sleeping)) "on" else "still off"),
    });
    return err.RTGERR_OK;
}

/// The pipe set to `timings` (`pipe.set`): the display's clocks raised
/// first where the mode's picture needs them faster (`modeFit`), the
/// link HDMI or DVI as the monitor takes it, with the mode's AVI
/// infoframe on HDMI, and the clocks lowered to what the picture needs
/// once the mode runs. One asker at a time at the controller and the
/// mailbox, and no flip meanwhile. What it did is kept (RTGCTRL_AMD_MODE)
/// and said on the log; on success the engine is taken to scan the new
/// mode.
fn setMode(screen: *Screen, timings: *const rtg.RtgTimings) i32 {
    const sys = screen.sys;
    var alone: [pipe_count]?Reading = undefined;
    const made = modeFit(screen, timings, &alone) orelse return err.RTGERR_BAD_MODE;
    const new = made.set;
    const hdmi = takesHdmi(screen);
    var avi: [rtg.RTG_AVI_BYTES]u8 = @splat(0);
    var sends_avi = false;
    if (hdmi) {
        var said: rtg.RtgMonitorInfo = .{};
        _ = screen.rtg_base.GetBoardMonitor(screen.board, &said, @sizeOf(rtg.RtgMonitorInfo));
        const output = colours.outputFor(&said, timings, screen.board.info.color_range);
        sends_avi = drivers(screen).BuildAviInfoFrame(timings, aviFlags(&said, timings, output), &avi) == rtg.RTG_AVI_BYTES;
    }

    sys.ObtainSemaphore(&screen.controller_lock);
    defer sys.ReleaseSemaphore(&screen.controller_lock);
    if (!screen.controller.running) return err.RTGERR_NOT_SUPPORTED;

    sys.ObtainSemaphore(&screen.pipe_lock);
    defer sys.ReleaseSemaphore(&screen.pipe_lock);
    // A monitor asleep is woken for the set and put to sleep again after.
    const was_asleep = screen.asleep;
    if (was_asleep) {
        const woken = wakeLink(screen);
        if (woken != err.RTGERR_OK) return woken;
    }
    // At the new mode's pixel clock once it is set.
    var sleep_at = screen.pixel_clock_hz;
    defer if (was_asleep) {
        _ = sleepLink(screen, sleep_at);
    };
    // A plane goes down with the pipe; the show lights it again. The
    // clocks raised for the mode first - for its picture alone, and what
    // runs now still served - and lowered once it runs.
    screen.setting_mode = true;
    dropOverlay(screen);
    dropBands(screen);
    dropFilm(screen);
    screen.setting_mode = false;
    raiseTo(screen, made.fitted, alone);
    const code = pipe.set(screen.dcn, &screen.controller, screen.connector, &new, hdmi, if (sends_avi) &avi else null, screen.pixel_clock_hz, &screen.last_set);
    const done = &screen.last_set;
    if (code != err.RTGERR_OK) {
        // Held where they were raised to, for whatever runs.
        screen.lower_due = false;
        exec.kprintf(sys, "%s: %dx%d at %d kHz not set (%ld), stopped at stage %d\n", .{ MODULE_NAME, new.width, new.height, timings.pixel_clock_hz / 1000, @as(i64, code), done.stage });
        return code;
    }
    screen.rewrite_due = false;
    lowerDue(screen, false);
    screen.dcn.width = new.width;
    screen.dcn.height = new.height;
    screen.dcn.h_total = new.h_total;
    screen.dcn.v_total = new.v_total;
    screen.avi_sent = if (sends_avi) avi else null;
    sleep_at = timings.pixel_clock_hz;
    crc.fit(screen.dcn);
    if (screen.gart != null) gart.reach(screen.dcn, screen.dcn.fetcher);
    screen.bands_refused = false;
    exec.kprintf(sys, "%s: the display set to %dx%d at %d kHz on %s, display clock %d kHz, pipes %d kHz, down for %d us%s\n", .{
        MODULE_NAME,
        new.width,
        new.height,
        timings.pixel_clock_hz / 1000,
        if (hdmi) @as([*:0]const u8, "HDMI") else "DVI",
        screen.told.display_khz,
        screen.told.pipes_khz,
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
        // Back once the process starting the graphics block has ended.
        rtg.boards.RTGCTRL_SETTLED => {
            dma.settle(&screen.dma, screen.sys);
            return err.RTGERR_OK;
        },
        rtg.tags.RTGCTRL_AMD_FIRMWARE => {
            screen.sys.ObtainSemaphore(&screen.smu_lock);
            defer screen.sys.ReleaseSemaphore(&screen.smu_lock);
            return smu.version(screen.sys, screen.smu);
        },
        rtg.tags.RTGCTRL_AMD_CLOCKS => {
            if (value == 0) return err.RTGERR_BAD_ARG;
            const into: *rtg.tags.RtgAmdClocks = @ptrFromInt(@as(usize, @bitCast(value)));
            screen.sys.ObtainSemaphore(&screen.pipe_lock);
            const told = screen.told;
            const fitted = screen.fitted;
            const marks = screen.marks;
            screen.sys.ReleaseSemaphore(&screen.pipe_lock);
            screen.sys.ObtainSemaphore(&screen.smu_lock);
            defer screen.sys.ReleaseSemaphore(&screen.smu_lock);
            const code = smu.clocks(screen.dcn, screen.smu, into);
            clocks.readDividers(screen.dcn, into);
            if (told.started) {
                into.asked_dcf_khz = told.controller_khz;
                into.asked_deep_sleep_khz = told.deep_sleep_khz;
                into.asked_disp_khz = told.display_khz;
                into.asked_dpp_khz = told.pipes_khz;
                into.asked_pipe_khz = told.pipe_khz;
                into.answered_dcf_mhz = told.answered_controller_mhz;
                into.answered_deep_sleep_mhz = told.answered_deep_sleep_mhz;
                into.answered_disp_mhz = told.answered_display_mhz;
                into.answered_dpp_mhz = told.answered_pipes_mhz;
            }
            if (fitted) |one| {
                into.level = one.demand.level;
                into.change_in_active = @intFromBool(one.demand.change_in_active);
            }
            into.asked_marks = marks;
            hub.read(screen.dcn, &into.hub_marks);
            into.self_refresh = @intFromBool(hub.selfRefreshAllowed(screen.dcn));
            for (0..pipe_count) |index| {
                const timed = mode.fetcherControl(screen.dcn, @intCast(index)) & mode.hubp_ttu_off == 0;
                if (timed) into.timed_pipes |= @as(u32, 1) << @intCast(index);
            }
            into.fabric_now_mhz = smu.fabricNow(screen.sys, screen.smu);
            return code;
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
            if (screen.asleep) return err.RTGERR_NO_DISPLAY;
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
    .power = &powerOp,
    .set_brightness = &setBrightnessOp,
    .brightness = &brightnessOp,
    .mirror = &mirrorOp,
    .engine = &engine_ops,
};

/// FillRect, CopyRect and CopyRects by the graphics block's DMA engine,
/// for the jobs that are more than the CPU's caches hold (dma.zig).
const engine_ops = rtg.boards.RtgEngineOps{ .fill_rect = &fillRectOp, .copy_rect = &copyRectOp, .copy_rects = &copyRectsOp };

fn fillRectOp(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, colour: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    return dma.fill(&screen.dma, screen.sys, screen.rtg_base, bitmap, area, colour);
}

fn copyRectOp(board: *rtg.RtgBoard, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, one: *const rtg.RtgCopy) callconv(.c) i32 {
    const screen = screenOf(board);
    return dma.copy(&screen.dma, screen.sys, screen.rtg_base, src, dest, @as(*const [1]rtg.RtgCopy, one));
}

fn copyRectsOp(board: *rtg.RtgBoard, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copies: [*]const rtg.RtgCopy, count: u32) callconv(.c) i32 {
    const screen = screenOf(board);
    return dma.copy(&screen.dma, screen.sys, screen.rtg_base, src, dest, copies[0..count]);
}

/// The same with the pointer the pipe's cursor, the overlay a plane, a
/// video layer, or any of them together, by `opsFor`.
const op_tables = tables: {
    var tables: [8]rtg.boards.RtgBoardOps = @splat(ops);
    for (&tables, 0..) |*table, index| {
        if (index & 1 != 0) table.pointer = &pointer_ops;
        if (index & 2 != 0) table.overlay = &overlay_ops;
        if (index & 4 != 0) table.video = &video_ops;
    }
    break :tables tables;
};

fn opsFor(with_cursor: bool, with_overlay: bool, with_video: bool) *const rtg.boards.RtgBoardOps {
    return &op_tables[@as(usize, @intFromBool(with_cursor)) | @as(usize, @intFromBool(with_overlay)) << 1 | @as(usize, @intFromBool(with_video)) << 2];
}

const pointer_ops = rtg.RtgPointerOps{ .set = &setPointer, .move = &movePointer, .show = &showPointer };
const overlay_ops = rtg.RtgOverlayOps{ .set = &setOverlay, .move = &moveOverlay };
const video_ops = rtg.RtgVideoOps{ .open = &videoOpen, .close = &videoClose, .show = &videoShow, .move = &videoMove };

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

// SPDX-License-Identifier: MPL-2.0
//! An RGB panel as a display board: the chip's LCD_CAM peripheral, a
//! framebuffer, and the two DMA channels that keep the panel fed.
//!
//! A module of its own: it opens rtg.library at cold start and hands in a
//! driver called "rgb". Anything that then asks rtg.library for a board of
//! that name, with the panel's numbers in its tags, gets a panel brought
//! up and ready to be given a buffer to show. Which numbers those are -
//! this board's, or another one's - is the caller's business; this driver
//! knows the peripheral, not the machine it is soldered to.
//!
//! The module keeps nothing of its own. A ROM image is read only, so the
//! driver node, SysBase and everything else that changes are allocated at
//! init, and every entry point finds them again through the node: an op
//! has the board, the board has its driver, and the driver is a field of
//! the block. Per-board state is the `Panel` the library allocates beside
//! each handle.
//!
//! The order matters and none of it is optional. `CreateBoardTagList`
//! lets the panel out of reset, takes its memory and its DMA channels and
//! programs the peripheral; `SetBoardMode` puts the timings in; and
//! `ShowBitMap` is what starts the pixel stream. That last split is not
//! decoration: the first picture has to be drawn and written back out of
//! the cache while nothing is reading it, and a 1.2 MB write-back landing
//! on top of a running stream is enough to starve it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;
const tags = rtg.tags;
const expander = sdk.resources.expander;

const config = @import("config.zig");
const panels = @import("panel.zig");
const Panel = panels.Panel;
const lcd = @import("lcd.zig");

const MODULE_NAME = "rtg-rgb";
const DRIVER_NAME = "rgb";
const VERSION = 1;
const REVISION = 0;
const BUILD_DATE = "17.9.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// Everything this driver has that changes, allocated once by the init.
/// The driver node is a field of it, so anything holding the node is
/// holding this.
const State = struct {
    driver: rtg.RtgDriver = .{},
    sys: *ExecBase,
    rtg_base: *RtgBase,
    /// The panel while a board of it exists. There is one peripheral, so
    /// there is at most one.
    board: ?*rtg.RtgBoard = null,
};

fn stateOf(driver: *rtg.RtgDriver) *State {
    return @fieldParentPtr("driver", driver);
}

fn panelOf(board: *rtg.RtgBoard) *Panel {
    return @ptrCast(@alignCast(board.instance.?));
}

fn createBoard(made_by: *rtg.RtgDriver, board: *rtg.RtgBoard, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    const rb: *RtgBase = board.rtg_base.?;
    if (state.board != null) return err.RTGERR_IN_USE;

    const wanted = config.read(rb, tag_list) orelse return err.RTGERR_BAD_TAGS;

    const panel = panelOf(board);
    panel.* = .{ .sys = state.sys, .rtg_base = rb, .board = board, .config = wanted };

    const code = panels.bringUp(panel);
    if (code != err.RTGERR_OK) return code;

    // One mode: the panel is what it is, and a panel is not a monitor.
    const setup = &panel.config.setup;
    panel.mode = .{
        .node = .{ .name = "panel", .pri = 0 },
        .id = 1,
        .width = setup.width,
        .height = setup.height,
        .format = .rgb565,
        .pitch = setup.width * (setup.bits_per_pixel / 8),
        .pixel_clock_hz = setup.pixel_clock_hz,
        .refresh_mhz = refreshMilliHz(setup),
        .flags = rtg.boards.RTGMF_DEFAULT,
    };
    state.sys.AddTail(&board.modes, &panel.mode.node);

    // The framebuffer is the board's display memory: the library cuts the
    // buffers out of it, and the first one is the picture.
    board.region = .{
        .base = panel.frame,
        .size = panel.frame_bytes,
        .alignment = sdk.hardware.DCACHE_LINE_SIZE,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED,
    };
    board.ops = &ops;
    board.info.buffers = 1;
    board.info.pixel_clock_hz = setup.pixel_clock_hz;
    board.info.refresh_mhz = panel.mode.refresh_mhz;
    board.info.flags |= rtg.boards.RTGBF_STREAMING;
    board.info.brightness = brightness(board);
    state.board = board;
    return err.RTGERR_OK;
}

/// Frames a second, in thousandths: the pixel clock over everything a
/// frame costs, blanking and all.
fn refreshMilliHz(setup: *const lcd.Setup) u32 {
    const line = setup.hsync_pulse + setup.hsync_back_porch + setup.width + setup.hsync_front_porch;
    const lines = setup.vsync_pulse + setup.vsync_back_porch + setup.height + setup.vsync_front_porch;
    const whole: u64 = @as(u64, line) * lines;
    if (whole == 0) return 0;
    return @truncate(@as(u64, setup.pixel_clock_hz) * 1000 / whole);
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    const panel = panelOf(board);
    _ = panels.giveBack(panel, err.RTGERR_OK);
    if (board.driver) |driver| stateOf(driver).board = null;
}

/// One mode, the panel's own: putting the board in it is what programs the
/// pads, the timings and the clock.
fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode) callconv(.c) i32 {
    const panel = panelOf(board);
    if (mode.id != panel.mode.id) return err.RTGERR_BAD_MODE;
    return panels.program(panel);
}

/// Feed the panel from that buffer. This is what starts the stream, and
/// what a caller that has drawn its first picture calls to see it.
fn showBitMap(board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    // The chain is over a whole picture from its first byte: a window of a
    // larger one would need a chain per line, which this panel has no
    // bandwidth for anyway.
    if (x != 0 or y != 0) return err.RTGERR_NOT_SUPPORTED;
    const bm = bitmap orelse {
        if (panel.streaming) {
            lcd.stop();
            panel.streaming = false;
        }
        return err.RTGERR_OK;
    };
    const pixels = bm.pixels orelse return err.RTGERR_BAD_ARG;
    if (bm.width != panel.mode.width or bm.height != panel.mode.height) return err.RTGERR_NOT_DISPLAYABLE;
    if (bm.pitch != panel.mode.pitch) return err.RTGERR_NOT_DISPLAYABLE;
    if (bm.format != panel.mode.format) return err.RTGERR_BAD_FORMAT;
    return panels.start(panel, pixels);
}

/// Rows the CPU wrote, handed to the panel: it reads that memory without
/// going through the cache, so what was written has to be pushed out of
/// it first. The stream never stops, so that is the whole of it.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) callconv(.c) i32 {
    const pixels = bitmap.pixels orelse return err.RTGERR_BAD_ARG;
    var bytes: u32 = rows * bitmap.pitch;
    if (bytes == 0) return err.RTGERR_OK;
    const start: *anyopaque = @ptrFromInt(@intFromPtr(pixels) + @as(usize, y) * bitmap.pitch);
    _ = panelOf(board).sys.CachePreDMA(start, &bytes, 0);
    return err.RTGERR_OK;
}

/// The panel's display enable, which is a line on whatever the board wired
/// it to. Not the backlight.
fn display(board: *rtg.RtgBoard, on: bool) callconv(.c) i32 {
    const panel = panelOf(board);
    if (panel.config.display_pin.kind == sdk.expansion.boardpin.BPIN_NONE) return err.RTGERR_NOT_SUPPORTED;
    return if (panels.setDisplayLine(panel, on)) err.RTGERR_OK else err.RTGERR_NO_DISPLAY;
}

/// The backlight, 0 to 100, the right way round whatever the part does.
fn setBrightness(board: *rtg.RtgBoard, percent: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    const ex = openExpander(panel) orelse return err.RTGERR_NOT_SUPPORTED;
    return if (ex.SetBacklight(percent)) err.RTGERR_OK else err.RTGERR_NO_DISPLAY;
}

fn brightness(board: *rtg.RtgBoard) callconv(.c) u32 {
    const panel = panelOf(board);
    const ex = openExpander(panel) orelse return 0;
    return ex.Backlight();
}

/// This board's backlight is a part of the expander, not a pad: it has its
/// own brightness rather than a level.
fn openExpander(panel: *Panel) ?*sdk.interface.expander.ExpanderBase {
    if (panel.config.backlight_pin.kind != sdk.expansion.boardpin.BPIN_DRIVER) return null;
    const base = panel.sys.OpenResource(expander.EXPANDERNAME) orelse return null;
    return @ptrCast(@alignCast(base));
}

fn stats(board: *rtg.RtgBoard, out: *rtg.RtgBoardStats) callconv(.c) void {
    out.* = panelOf(board).stats;
}

fn control(board: *rtg.RtgBoard, what: u32, value: isize) callconv(.c) isize {
    const panel = panelOf(board);
    return switch (what) {
        tags.RTGCTRL_RGB_REALIGN => blk: {
            panels.realign(panel);
            break :blk err.RTGERR_OK;
        },
        // Move the picture along the line, at the next blanking. The shift
        // is modulo the line, so a picture that has to go left past the
        // sync pulse goes round the line instead.
        tags.RTGCTRL_RGB_SHIFT => blk: {
            const line: i32 = @intCast(lcd.lineTotal());
            if (line == 0) break :blk err.RTGERR_NO_MODE;
            const now: i32 = @intCast(lcd.active_start);
            const start = @mod(now + @as(i32, @truncate(value)), line);
            panel.want_start = @intCast(start);
            panels.realign(panel);
            break :blk @intCast(start);
        },
        tags.RTGCTRL_RGB_ACTIVE_START => @intCast(lcd.active_start),
        tags.RTGCTRL_RGB_LINE_TOTAL => @intCast(lcd.lineTotal()),
        rtg.boards.RTGCTRL_RESET_STATS => blk: {
            panels.resetStats(panel);
            break :blk err.RTGERR_OK;
        },
        else => err.RTGERR_NOT_SUPPORTED,
    };
}

/// What this board has. Every engine slot is null: this chip has nothing
/// that draws, so a caller that wants a rectangle filled fills it itself.
const ops = rtg.RtgBoardOps{
    .destroy = &destroy,
    .set_mode = &setMode,
    .show_bitmap = &showBitMap,
    .refresh = &refresh,
    .display = &display,
    .set_brightness = &setBrightness,
    .brightness = &brightness,
    .stats = &stats,
    .control = &control,
};

const driver_ops = rtg.RtgDriverOps{ .create_board = &createBoard };

/// Cold start at 22: after rtg.library (24), which it joins, and after the
/// resources a panel needs - dma.resource (70), i2c.device (35) and
/// expander.resource (30). It brings nothing up here: a board is made when
/// something asks for one.
fn init(seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*anyopaque {
    _ = seg_list;
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
        // Its refill interrupt reads the panel sixty times a frame, while
        // both DMA channels are working the memory a display streams out
        // of. Reading the panel out of that same memory costs the copy the
        // time it has to make the next bufferful ready in.
        .flags = rtg.boards.RTGDF_INTERNAL_INSTANCE,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Panel),
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
export const rtg_rgb_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rtg_rgb_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 22,
    .type = .rtg_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};

// SPDX-License-Identifier: MPL-2.0
//! A MIPI-DSI panel as a display board: the ESP32-P4's DSI host and
//! D-PHY, the bridge in front of it, and the DMA channel that keeps it
//! fed from a picture in PSRAM.
//!
//! A module of its own: it opens rtg.library at cold start and hands in a
//! driver called "dsi". A board of it is made from the panel's tags: the
//! link (lanes and lane rate), the pixel clock and timings, and the
//! panel's bring-up as DCS commands - so another panel on this host is
//! another tag list and not another driver.
//!
//! **Bringing it up** is all of create: the D-PHY's supply, the clocks,
//! the panel's reset, the PHY and its PLL, the bring-up sent in command
//! mode, then the video timings into the host and the bridge and the DMA
//! channel set up - everything but the stream. `ShowBitMap` starts the
//! stream: the channel is given the buffer, the host goes to video mode,
//! the bridge's DPI side on. So the first picture can be drawn and written
//! back out of the cache while nothing reads it.
//!
//! **The stream.** The channel sends the whole picture as one block, and
//! its transfer-done interrupt sends it again - from a new buffer, if one
//! was shown meanwhile, which is how a flip happens at a frame's end. The
//! picture is read straight out of PSRAM; the CPU's writes reach it when
//! RefreshBitMap writes them back out of the cache.
//!
//! The module keeps nothing of its own. The driver node, SysBase and the
//! rest are allocated at init, and per-board state is the `Panel` the
//! library allocates beside each handle - in internal memory, since the
//! interrupt servers read it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;
const hardware = sdk.hardware;
const gpio = hardware.gpio;
const system = hardware.system;
const systimer = hardware.systimer;
const intbits = hardware.intbits;
const boardpin = sdk.expansion.boardpin;

const config = @import("config.zig");
const host = @import("host.zig");
const bridge = @import("bridge.zig");
const dwgdma = @import("dwgdma.zig");

const MODULE_NAME = "rtg-dsi";
const DRIVER_NAME = "dsi";
const VERSION = 1;
const REVISION = 0;
const BUILD_DATE = "10.10.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The DCS commands this driver sends of its own accord.
const SWRESET = 0x01;
const DISPOFF = 0x28;
const DISPON = 0x29;

/// The 240 MHz reference clock the pixel clock is divided from, and its
/// source number.
const pixel_source_hz: u32 = 240_000_000;
const pixel_source: u32 = 1;
/// The DMA controller's channel the stream runs on.
const channel = 0;
/// How long a flip waits for the frame it lands on.
const flip_wait_us = 100_000;

/// Everything this driver has that changes, allocated once by the init.
const State = struct {
    driver: rtg.RtgDriver = .{},
    sys: *ExecBase,
    rtg_base: *RtgBase,
    /// The panel while a board of it exists. There is one host, so there
    /// is at most one.
    board: ?*rtg.RtgBoard = null,
};

/// One panel: the board's instance, allocated and cleared by the library
/// in internal memory.
const Panel = struct {
    sys: *ExecBase,
    board: *rtg.RtgBoard,
    config: config.Config = .{},
    /// The one mode this panel has.
    mode: rtg.RtgMode = .{},
    frame_bytes: u32 = 0,
    /// What the PHY's PLL and the pixel clock really run at.
    lane_kbps: u32 = 0,
    pixel_hz: u32 = 0,
    /// Room for the DMA's linked-list item, which sits on the 64-byte
    /// boundary inside it (`item`, its cached address); it is only ever
    /// written through its uncached view.
    item_room: [128]u8 = @splat(0),
    item: usize = 0,
    /// The stream runs; the buffer to send from the next frame on, which
    /// the interrupt takes (0: none waiting).
    streaming: bool = false,
    next: usize = 0,
    /// The backlight as last set, for a board that has a line for it.
    brightness: u32 = 100,
    dma_int: exec.Interrupt = .{},
    bridge_int: exec.Interrupt = .{},
    hooked: bool = false,
    stats: rtg.RtgBoardStats = .{},
};

fn stateOf(driver: *rtg.RtgDriver) *State {
    return @fieldParentPtr("driver", driver);
}

fn panelOf(board: *rtg.RtgBoard) *Panel {
    return @ptrCast(@alignCast(board.instance.?));
}

/// The linked-list item, as the CPU writes it: through the uncached view.
fn itemOf(panel: *Panel) *volatile dwgdma.Item {
    return @ptrFromInt(dwgdma.uncached(panel.item));
}

// --- the interrupts ------------------------------------------------------

/// A picture has gone: send the next one, from the buffer shown meanwhile
/// if there is one.
fn dmaServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const panel: *Panel = @ptrCast(@alignCast(is_data.?));
    const raised = dwgdma.takeInterrupts(channel);
    if (raised == 0) return 0;
    if (raised & dwgdma.int_transfer_done != 0 and panel.streaming) {
        const item = itemOf(panel);
        const next: *volatile usize = &panel.next;
        if (next.* != 0) {
            dwgdma.setSource(item, next.*);
            next.* = 0;
        }
        dwgdma.rearm(item);
        dwgdma.run(channel, panel.item);
        panel.stats.frames +%= 1;
    }
    return 1;
}

/// The bridge's FIFO ran dry: counted.
fn bridgeServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const panel: *Panel = @ptrCast(@alignCast(is_data.?));
    const raised = bridge.takeInterrupts();
    if (raised == 0) return 0;
    if (raised & bridge.int_underrun != 0) panel.stats.starved_frames +%= 1;
    return 1;
}

// --- the panel's lines ---------------------------------------------------

/// A line of the panel's driven to `level`, if it is a pad of the chip.
fn drive(pin: sdk.expansion.BoardPin, asserted: bool) bool {
    if (pin.kind != boardpin.BPIN_GPIO) return false;
    gpio.toMatrix(pin.number);
    gpio.connectOut(pin.number, gpio.out_of_gpio, true);
    gpio.setLevel(pin.number, asserted == (pin.active_low == 0));
    gpio.outputEnable(pin.number, true);
    return true;
}

// --- bringing it up ------------------------------------------------------

/// The pixel clock divider nearest the panel's clock, 1 to 256.
fn pixelDivider(pixel_hz: u32) u32 {
    const divider = (pixel_source_hz + pixel_hz / 2) / pixel_hz;
    return @min(@max(divider, 1), 256);
}

/// From nothing to a panel that has taken its bring-up and waits for a
/// picture.
fn bringUp(panel: *Panel) i32 {
    const sys = panel.sys;
    const wanted = &panel.config;

    if (wanted.phy_ldo != 0) {
        if (!hardware.ldo.set(wanted.phy_ldo, wanted.phy_millivolts)) return err.RTGERR_BAD_TAGS;
    }

    // The clocks: the D-PHY's from the 20 MHz reference clock, the pixel
    // clock from the 240 MHz one; the DMA controller's.
    const divider = pixelDivider(wanted.pixel_hz);
    panel.pixel_hz = pixel_source_hz / divider;
    sys.Disable();
    system.update(system.REF_CLK_CTRL1, system.REF_240M_CLK_EN, 0);
    system.update(system.REF_CLK_CTRL2, system.REF_20M_CLK_EN, 0);
    system.update(system.PERI_CLK_CTRL02, 0, @as(u32, 0x3) << 30);
    system.setFunctionClock(.dsi, .{ .source = pixel_source, .divider = divider });
    system.enable(.dsi);
    system.enable(.dw_gdma);
    sys.Enable();

    // The panel's reset, where the board wired one.
    if (drive(wanted.reset_pin, true)) {
        systimer.spinUs(@as(u64, wanted.reset_ms) * 1000);
        _ = drive(wanted.reset_pin, false);
        systimer.spinUs(@as(u64, wanted.settle_ms) * 1000);
    }

    panel.lane_kbps = host.startPhy(wanted.lanes, wanted.lane_mbps);
    if (panel.lane_kbps == 0) {
        sdk.exec.kprintf(sys, "%s: the D-PHY did not come up\n", .{MODULE_NAME});
        return err.RTGERR_NO_DISPLAY;
    }
    host.commandMode(wanted.lane_mbps);

    // A panel without a reset line is reset by its own command.
    if (wanted.reset_pin.kind != boardpin.BPIN_GPIO) {
        if (!host.dcsWrite(SWRESET, &.{})) return err.RTGERR_NO_DISPLAY;
        systimer.spinUs(@as(u64, wanted.settle_ms) * 1000);
    }
    if (!sendSequence(wanted.init_sequence.?[0..wanted.init_length])) {
        sdk.exec.kprintf(sys, "%s: the panel did not take its bring-up\n", .{MODULE_NAME});
        return err.RTGERR_NO_DISPLAY;
    }

    host.setVideo(.{
        .width = wanted.width,
        .height = wanted.height,
        .hsync = wanted.hsync,
        .hbp = wanted.hbp,
        .hfp = wanted.hfp,
        .vsync = wanted.vsync,
        .vbp = wanted.vbp,
        .vfp = wanted.vfp,
        .coding = host.coding_rgb565,
    }, panel.lane_kbps, panel.pixel_hz);
    bridge.setUp(.{
        .width = wanted.width,
        .height = wanted.height,
        .hsync = wanted.hsync,
        .hbp = wanted.hbp,
        .hfp = wanted.hfp,
        .vsync = wanted.vsync,
        .vbp = wanted.vbp,
        .vfp = wanted.vfp,
        .bits_per_pixel = wanted.bits_per_pixel,
        .raw_type = bridge.raw_rgb565,
    });

    if (!dwgdma.start()) return err.RTGERR_NO_DISPLAY;
    dwgdma.setUpChannel(channel);
    // The item's line out of the cache once, cleared and all: from here
    // on it is written only through its uncached view.
    panel.item = (@intFromPtr(&panel.item_room) + 63) & ~@as(usize, 63);
    var line_bytes: u32 = 64;
    _ = sys.CachePreDMA(@ptrFromInt(panel.item), &line_bytes, 0);
    sys.CachePostDMA(@ptrFromInt(panel.item), &line_bytes, 0);

    panel.dma_int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = panel,
        .code = &dmaServer,
    };
    panel.bridge_int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = MODULE_NAME },
        .data = panel,
        .code = &bridgeServer,
    };
    sys.AddIntServer(intbits.INTB_DW_GDMA, &panel.dma_int);
    sys.AddIntServer(intbits.INTB_DSI_BRIDGE, &panel.bridge_int);
    panel.hooked = true;

    if (wanted.backlight_pin.wired()) _ = drive(wanted.backlight_pin, true);
    return err.RTGERR_OK;
}

/// The panel's bring-up, step by step: false at a step that runs past the
/// end or that the host could not send.
fn sendSequence(bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        if (bytes.len - at < 3) return false;
        const command = bytes[at];
        const count = bytes[at + 1];
        const delay_ms = bytes[at + 2];
        if (bytes.len - at < 3 + @as(usize, count)) return false;
        if (!host.dcsWrite(command, bytes[at + 3 ..][0..count])) return false;
        if (!host.commandsSent()) return false;
        if (delay_ms != 0) systimer.spinUs(@as(u64, delay_ms) * 1000);
        at += 3 + @as(usize, count);
    }
    return true;
}

/// The stream started from `pixels`.
fn startStream(panel: *Panel, pixels: usize) void {
    dwgdma.fill(itemOf(panel), pixels, bridge.fifo, panel.frame_bytes);
    dwgdma.run(channel, panel.item);
    host.videoMode(true);
    bridge.dpi(true);
    bridge.underrunInterrupt(true);
    panel.streaming = true;
}

fn stopStream(panel: *Panel) void {
    panel.streaming = false;
    bridge.underrunInterrupt(false);
    bridge.dpi(false);
    host.videoMode(false);
    dwgdma.halt(channel);
}

/// Everything create took, given back.
fn giveBack(panel: *Panel) void {
    const sys = panel.sys;
    if (panel.streaming) stopStream(panel);
    if (panel.hooked) {
        sys.RemIntServer(intbits.INTB_DW_GDMA, &panel.dma_int);
        sys.RemIntServer(intbits.INTB_DSI_BRIDGE, &panel.bridge_int);
        panel.hooked = false;
    }
    bridge.stop();
    host.stop();
    if (panel.config.backlight_pin.wired()) _ = drive(panel.config.backlight_pin, false);
}

// --- the board's ops -----------------------------------------------------

fn createBoard(made_by: *rtg.RtgDriver, board: *rtg.RtgBoard, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    const rb: *RtgBase = board.rtg_base.?;
    if (state.board != null) return err.RTGERR_IN_USE;

    const wanted = config.read(rb, tag_list) orelse return err.RTGERR_BAD_TAGS;
    const panel = panelOf(board);
    panel.* = .{ .sys = state.sys, .board = board, .config = wanted };
    panel.frame_bytes = wanted.width * wanted.height * (wanted.bits_per_pixel / 8);

    const code = bringUp(panel);
    if (code != err.RTGERR_OK) {
        giveBack(panel);
        return code;
    }

    // One mode: the panel is what it is.
    panel.mode = .{
        .node = .{ .name = "panel", .pri = 0 },
        .id = 1,
        .width = wanted.width,
        .height = wanted.height,
        .format = .rgb565,
        .pitch = wanted.width * (wanted.bits_per_pixel / 8),
        .pixel_clock_hz = panel.pixel_hz,
        .refresh_mhz = refreshMilliHz(panel),
        .flags = rtg.boards.RTGMF_DEFAULT,
    };
    state.sys.AddTail(&board.modes, &panel.mode.node);

    // Its buffers are taken from system memory as they are asked for - a
    // line-aligned block each, which the DMA reads in whole lines - and no
    // more than the board says at once.
    board.region = .{
        .size = wanted.buffers * panel.frame_bytes,
        .alignment = hardware.DCACHE_LINE_SIZE,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED | rtg.boards.RTGRF_SYSTEM_MEMORY,
    };
    board.ops = &ops;
    board.info.buffers = wanted.buffers;
    board.info.pixel_clock_hz = panel.pixel_hz;
    board.info.refresh_mhz = panel.mode.refresh_mhz;
    board.info.flags |= rtg.boards.RTGBF_STREAMING;
    board.info.brightness = panel.brightness;
    state.board = board;
    return err.RTGERR_OK;
}

/// Frames a second, in thousandths: the pixel clock over everything a
/// frame costs, blanking and all.
fn refreshMilliHz(panel: *const Panel) u32 {
    const wanted = &panel.config;
    const line = wanted.hsync + wanted.hbp + wanted.width + wanted.hfp;
    const lines = wanted.vsync + wanted.vbp + wanted.height + wanted.vfp;
    const whole: u64 = @as(u64, line) * lines;
    if (whole == 0) return 0;
    return @truncate(@as(u64, panel.pixel_hz) * 1000 / whole);
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    giveBack(panelOf(board));
    if (board.driver) |driver| stateOf(driver).board = null;
}

/// One mode, the panel's own, which create already set up.
fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode) callconv(.c) i32 {
    return if (mode.id == panelOf(board).mode.id) err.RTGERR_OK else err.RTGERR_BAD_MODE;
}

/// Feed the panel from that buffer. The first time, this starts the
/// stream. With the stream running it is a flip: the buffer is sent from
/// the next frame on, whole, and this returns once the frame before it is
/// the last that reads the one it replaced.
fn showBitMap(board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    if (x != 0 or y != 0) return err.RTGERR_NOT_SUPPORTED;
    const bm = bitmap orelse {
        if (panel.streaming) stopStream(panel);
        return err.RTGERR_OK;
    };
    const pixels = bm.pixels orelse return err.RTGERR_BAD_ARG;
    if (bm.width != panel.mode.width or bm.height != panel.mode.height) return err.RTGERR_NOT_DISPLAYABLE;
    if (bm.pitch != panel.mode.pitch) return err.RTGERR_NOT_DISPLAYABLE;
    if (bm.format != panel.mode.format) return err.RTGERR_BAD_FORMAT;
    if (!panel.streaming) {
        startStream(panel, @intFromPtr(pixels));
        return err.RTGERR_OK;
    }
    const next: *volatile usize = &panel.next;
    next.* = @intFromPtr(pixels);
    const since = systimer.uptimeUs();
    while (next.* != 0) {
        if (systimer.uptimeUs() - since > flip_wait_us) return err.RTGERR_NO_DISPLAY;
    }
    return err.RTGERR_OK;
}

/// Rows the CPU wrote, handed to the panel: the DMA reads that memory
/// without going through the cache, so what was written has to be pushed
/// out of it first. The stream never stops, so that is the whole of it.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) callconv(.c) i32 {
    const pixels = bitmap.pixels orelse return err.RTGERR_BAD_ARG;
    var bytes: u32 = (if (rows == 0) bitmap.height else rows) * bitmap.pitch;
    if (bytes == 0) return err.RTGERR_OK;
    const start: *anyopaque = @ptrFromInt(@intFromPtr(pixels) + @as(usize, y) * bitmap.pitch);
    _ = panelOf(board).sys.CachePreDMA(start, &bytes, 0);
    return err.RTGERR_OK;
}

/// The panel's own display on or off, by its DCS command. Not the
/// backlight.
fn display(board: *rtg.RtgBoard, on: bool) callconv(.c) i32 {
    _ = board;
    return if (host.dcsWrite(if (on) DISPON else DISPOFF, &.{})) err.RTGERR_OK else err.RTGERR_NO_DISPLAY;
}

/// The backlight, on for anything above 0: its line is on or off.
fn setBrightness(board: *rtg.RtgBoard, percent: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    if (!drive(panel.config.backlight_pin, percent > 0)) return err.RTGERR_NOT_SUPPORTED;
    panel.brightness = if (percent > 0) 100 else 0;
    return err.RTGERR_OK;
}

fn brightness(board: *rtg.RtgBoard) callconv(.c) u32 {
    return panelOf(board).brightness;
}

fn stats(board: *rtg.RtgBoard, out: *rtg.RtgBoardStats) callconv(.c) void {
    out.* = panelOf(board).stats;
}

fn control(board: *rtg.RtgBoard, what: u32, value: isize) callconv(.c) isize {
    _ = value;
    return switch (what) {
        rtg.boards.RTGCTRL_RESET_STATS => blk: {
            panelOf(board).stats = .{};
            break :blk err.RTGERR_OK;
        },
        else => err.RTGERR_NOT_SUPPORTED,
    };
}

/// What this board has. Every engine slot is null for now: what draws on
/// this chip comes as its own step.
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

/// Cold start at 22: after rtg.library (24), which it joins. It brings
/// nothing up here: a board is made when something asks for one.
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
        // The DMA's interrupt reads the panel at every frame's end.
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
export const rtg_dsi_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rtg_dsi_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 22,
    .type = .rtg_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};

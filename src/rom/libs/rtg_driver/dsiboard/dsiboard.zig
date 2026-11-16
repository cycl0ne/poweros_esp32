// SPDX-License-Identifier: MPL-2.0
//! A MIPI-DSI panel as a display board: the ESP32-P4's DSI host and
//! D-PHY, the bridge in front of it, and the DMA channel that keeps it
//! fed from a picture in PSRAM.
//!
//! A module of its own: a description of a driver called "dsi" behind a
//! ROM tag, which rtg.library puts on its list. It takes what is on the
//! DSI host (`BUS_MIPI_DSI`): offered such a part, it makes a board from
//! the part's tags: the
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
//! **The stream.** The channel sends the picture as a chain of blocks - a
//! buffer whole, or several in bands, a block for each run of lines that
//! lies in one piece of memory (`chain.zig`) - and its transfer-done
//! interrupt sends it again: from a new chain, if one was shown
//! meanwhile, which is how a flip or a band change happens at a frame's
//! end. That interrupt is the frame's: it counts the frame begun
//! (`RtgBoardStats.blanks`) and signals `RTGEV_VBLANK`, which is what
//! WaitVBlank waits for. The picture is read straight out of PSRAM; the
//! CPU's writes reach it when RefreshBitMap writes them back out of the
//! cache.
//!
//! **HDMI.** A part that is an HDMI bridge (CHIP_LT8912B) is the same
//! board with four differences: create refuses it unless a monitor's
//! EDID answers on the bridge's bus, so the next part the board lists -
//! its panel - is tried instead; the board's mode is the largest the
//! monitor's EDID names of those this host can send (`monitor.zig`), the
//! part's own when it names none of them; the bridge is brought up over
//! I2C where a panel takes DCS commands; and the link carries RGB888,
//! which the stream reads from a copy of what is shown (`link.zig`) while
//! the screens stay RGB565.
//!
//! **The pointer** and the overlay are laid into that copy, never into the
//! screens, and rows going into the copy go around them (`pointer.zig`). A panel streams its screens straight until a
//! pointer or an overlay is first to be seen - which on a board touched
//! with a finger is never - and from then on streams a copy of its own,
//! in RGB565, kept as HDMI's is.
//!
//! The module keeps nothing of its own. The driver node, SysBase and the
//! rest are allocated at init, and per-board state is the `Panel` the
//! library allocates beside each handle - in internal memory, since the
//! interrupt servers read it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;
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
const engine_file = @import("engine.zig");
const blend_file = @import("blend.zig");
const scale_file = @import("scale.zig");
const bus = @import("bus.zig");
const chain_file = @import("chain.zig");
const Chain = chain_file.Chain;
const link_file = @import("link.zig");
const pointer_file = @import("pointer.zig");
const lt8912b = @import("lt8912b.zig");
const monitor = @import("monitor.zig");
const edid = @import("../edid.zig");
const st = sdk.expansion.systemtags;

const MODULE_NAME = "rtg-dsi";
const DRIVER_NAME = "dsi";
const VERSION = 1;
const REVISION = 14;
const BUILD_DATE = "16.11.2026";
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

/// One panel: the board's instance, allocated and cleared by the library
/// in internal memory.
const Panel = struct {
    sys: *ExecBase,
    board: *rtg.RtgBoard,
    config: config.Config = .{},
    frame_bytes: u32 = 0,
    /// The link is an HDMI bridge's: RGB888, from `link`.
    hdmi: bool = false,
    /// The stream reads `link`, the copy of what is shown, and
    /// `stream_bands` are the bands it sends over that copy: over HDMI
    /// always, on a panel once the pointer or the overlay is to be seen.
    composing: bool = false,
    link: link_file.Link = .{},
    stream_bands: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined,
    /// The bands shown, as the screens' buffers give them.
    shown: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined,
    shown_count: u32 = 0,
    /// The pointer and the overlay over the copy.
    pointer: pointer_file.Pointer = .{},
    /// A screen's row, what a line and a frame of the stream are in bytes.
    screen_pitch: u32 = 0,
    stream_pitch: u32 = 0,
    stream_frame_bytes: u32 = 0,
    /// What the PHY's PLL and the pixel clock really run at.
    lane_kbps: u32 = 0,
    pixel_hz: u32 = 0,
    /// The stream runs, from `chain`; `pending` is the one to send from
    /// the next frame on, which the interrupt takes, leaving the one it
    /// replaced in `retired` for the task to free.
    streaming: bool = false,
    chain: Chain = .{},
    pending: Chain = .{},
    retired: Chain = .{},
    /// The backlight as last set, for a board that has a line for it.
    brightness: u32 = 100,
    dma_int: exec.Interrupt = .{},
    bridge_int: exec.Interrupt = .{},
    hooked: bool = false,
    /// The DSI host's and the DMA controller's clocks are on (`bringUp`).
    clocked: bool = false,
    stats: rtg.RtgBoardStats = .{},
    /// The PPA and the 2D-DMA: FillRect and CopyRect.
    engine: engine_file.Engine = .{},
};

fn panelOf(board: *rtg.RtgBoard) *Panel {
    return @ptrCast(@alignCast(board.instance.?));
}

/// rtg.library as a driver calls it, from a board's handle.
fn driverBase(board: *rtg.RtgBoard) *RtgDriverBase {
    return @ptrCast(board.rtg_base.?);
}

// --- the interrupts ------------------------------------------------------

/// A picture has gone: send the next one, from the chain shown meanwhile
/// if there is one. The next frame has begun with it, which is counted
/// and said to whoever waits for a blanking (WaitVBlank).
fn dmaServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const panel: *Panel = @ptrCast(@alignCast(is_data.?));
    const raised = dwgdma.takeInterrupts(channel);
    if (raised == 0) return 0;
    if (raised & dwgdma.int_transfer_done != 0 and panel.streaming) {
        if (panel.pending.first != 0) {
            panel.retired = panel.chain;
            panel.chain = panel.pending;
            panel.pending = .{};
        }
        chain_file.rearm(panel.chain);
        dwgdma.run(channel, panel.chain.first);
        panel.stats.frames +%= 1;
        panel.stats.blanks +%= 1;
        engine_file.frameTick(&panel.engine);
        _ = driverBase(panel.board).SignalRtgEvent(panel.board, rtg.events.RTGEV_VBLANK);
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
/// picture. `bus_to_bridge` reaches an HDMI bridge; `lane` is the PLL's
/// setting for the lanes' rate, which everything the link is timed by
/// then follows.
fn bringUp(panel: *Panel, bus_to_bridge: ?lt8912b.I2c, lane: host.Pll) i32 {
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
    panel.clocked = true;

    // The panel's reset, where the board wired one.
    if (drive(wanted.reset_pin, true)) {
        systimer.spinUs(@as(u64, wanted.reset_ms) * 1000);
        _ = drive(wanted.reset_pin, false);
        systimer.spinUs(@as(u64, wanted.settle_ms) * 1000);
    }

    panel.lane_kbps = host.startPhy(wanted.lanes, lane);
    if (panel.lane_kbps == 0) {
        sdk.exec.kprintf(sys, "%s: the D-PHY did not come up\n", .{MODULE_NAME});
        return err.RTGERR_NO_DISPLAY;
    }
    // The rate the lanes run at, which is the one asked for wherever the
    // PLL makes it.
    const lane_mbps = panel.lane_kbps / 1000;
    host.commandMode(lane_mbps);

    if (bus_to_bridge) |bridge_bus| {
        // An HDMI bridge: brought up over I2C for the mode the link carries.
        const mode: lt8912b.Mode = .{
            .width = wanted.width,
            .height = wanted.height,
            .hsync = wanted.hsync,
            .hbp = wanted.hbp,
            .hfp = wanted.hfp,
            .vsync = wanted.vsync,
            .vbp = wanted.vbp,
            .vfp = wanted.vfp,
            .hsync_high = wanted.hsync_high,
            .vsync_high = wanted.vsync_high,
            .pixel_hz = panel.pixel_hz,
        };
        if (!lt8912b.setUp(bridge_bus, wanted.i2c_address, wanted.lanes, lane_mbps, mode)) {
            sdk.exec.kprintf(sys, "%s: the HDMI bridge did not take its bring-up\n", .{MODULE_NAME});
            return err.RTGERR_NO_DISPLAY;
        }
    } else {
        // A panel without a reset line is reset by its own command.
        if (wanted.reset_pin.kind != boardpin.BPIN_GPIO) {
            if (!host.dcsWrite(SWRESET, &.{})) return err.RTGERR_NO_DISPLAY;
            systimer.spinUs(@as(u64, wanted.settle_ms) * 1000);
        }
        if (!sendSequence(wanted.init_sequence.?[0..wanted.init_length])) {
            sdk.exec.kprintf(sys, "%s: the panel did not take its bring-up\n", .{MODULE_NAME});
            return err.RTGERR_NO_DISPLAY;
        }
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
        .coding = if (panel.hdmi) host.coding_rgb888 else host.coding_rgb565,
        .low_power = !panel.hdmi,
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
        .bits_per_pixel = if (panel.hdmi) 24 else wanted.bits_per_pixel,
        .raw_type = if (panel.hdmi) bridge.raw_rgb888 else bridge.raw_rgb565,
    });

    if (!dwgdma.start()) return err.RTGERR_NO_DISPLAY;
    const psram_mhz = psramMhz(panel.board.driver.?);
    bus.share(streamBytes(panel), psram_mhz);
    dwgdma.setUpChannel(channel);

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

    engine_file.setUp(&panel.engine, sys, psram_mhz);
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

/// The stream started from `chain`.
fn startStream(panel: *Panel, chain: Chain) void {
    panel.chain = chain;
    dwgdma.run(channel, chain.first);
    host.videoMode(true);
    bridge.dpi(true);
    bridge.underrunInterrupt(true);
    panel.streaming = true;
}

/// The HDMI bridge set to follow the stream that has just started; said
/// on the raw port if it could not be reached.
fn settleBridge(panel: *Panel) void {
    const wanted = &panel.config;
    const bus_to_bridge = lt8912b.I2c.open(panel.sys, wanted.i2c_unit) orelse return;
    defer bus_to_bridge.close();
    if (!lt8912b.follow(bus_to_bridge, wanted.i2c_address, panel.pixel_hz)) {
        sdk.exec.kprintf(panel.sys, "%s: the HDMI bridge did not take the stream\n", .{MODULE_NAME});
    }
}

/// The stream stopped, and every chain freed.
fn stopStream(panel: *Panel) void {
    const sys = panel.sys;
    sys.Disable();
    panel.streaming = false;
    sys.Enable();
    bridge.underrunInterrupt(false);
    bridge.dpi(false);
    host.videoMode(false);
    dwgdma.halt(channel);
    for ([_]*Chain{ &panel.chain, &panel.pending, &panel.retired }) |one| {
        chain_file.free(sys, one.*);
        one.* = .{};
    }
}

/// Show `bands` from the next frame on, whole; the first time, this starts
/// the stream. Returns once the chain they make is the one being sent, and
/// the one before it is no longer read. The library's two shows come here
/// one at a time, under the board's lock, so the chain handed over is
/// taken up before the next is made; `compose` comes under the pointer's
/// lock instead.
fn show(panel: *Panel, bands: []const rtg.RtgBand) i32 {
    const sys = panel.sys;
    const band_count: u32 = @intCast(@min(bands.len, rtg.RTG_MAX_BANDS));
    for (bands[0..band_count], 0..) |band, index| panel.shown[index] = band;
    panel.shown_count = band_count;
    var sent = bands;
    if (panel.composing) {
        sys.ObtainSemaphore(&panel.pointer.lock);
        const kept = pointer_file.keepOut(&panel.pointer, &panel.link);
        const count = link_file.show(&panel.link, &panel.engine, sys, bands, panel.streaming, kept, &panel.stream_bands);
        pointer_file.mend(&panel.pointer, &panel.link, sys, kept);
        sys.ReleaseSemaphore(&panel.pointer.lock);
        sent = panel.stream_bands[0..count];
    }
    const made = chain_file.build(sys, sent, panel.config.height, panel.stream_pitch) orelse return err.RTGERR_NO_MEMORY;
    if (!panel.streaming) {
        startStream(panel, made);
        if (panel.hdmi) settleBridge(panel);
        return err.RTGERR_OK;
    }
    sys.Disable();
    panel.pending = made;
    sys.Enable();
    const waiting: *volatile usize = &panel.pending.first;
    const since = systimer.uptimeUs();
    while (waiting.* != 0) {
        if (systimer.uptimeUs() - since > flip_wait_us) break;
    }
    sys.Disable();
    const timed_out = panel.pending.first == made.first;
    if (timed_out) panel.pending = .{};
    const retired = panel.retired;
    panel.retired = .{};
    sys.Enable();
    chain_file.free(sys, retired);
    if (timed_out) {
        chain_file.free(sys, made);
        return err.RTGERR_NO_DISPLAY;
    }
    return err.RTGERR_OK;
}

/// A panel's stream onto a copy of its own, for the pointer to be laid
/// into: the copy made, and what is shown shown again through it. False
/// without memory for it.
fn compose(panel: *Panel) bool {
    if (panel.composing) return true;
    const sys = panel.sys;
    if (!link_file.allocate(&panel.link, sys, panel.config.width, panel.config.height, .rgb565)) return false;
    panel.composing = true;
    if (panel.streaming and panel.shown_count > 0) _ = show(panel, panel.shown[0..panel.shown_count]);
    return true;
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
    engine_file.takeDown(&panel.engine);
    link_file.free(&panel.link, sys);
    // The bridge's and the host's registers answer only with their clock
    // on: a bring-up that failed before that has nothing to stop.
    if (panel.clocked) {
        bridge.stop();
        host.stop();
    }
    if (panel.config.backlight_pin.wired()) _ = drive(panel.config.backlight_pin, false);
}

// --- the board's ops -----------------------------------------------------

/// What is on the DSI host is offered - a panel, or an HDMI bridge: it is
/// brought up, and a board made of it. A board that lists both is offered
/// them in the list's order; the bridge is declined without a monitor
/// behind it, and whichever has the host, the other is declined.
fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const sys = driver.sys_base;
    const rb = driver.rtg_base;
    // There is one host: what else is on it is declined.
    if (driver.boards != 0) return err.RTGERR_IN_USE;

    var wanted = config.read(rb, tag_list) orelse return err.RTGERR_BAD_TAGS;

    // An HDMI bridge only with a monitor behind it, in the largest mode it
    // takes.
    var bridge_bus: ?lt8912b.I2c = null;
    defer if (bridge_bus) |bus_to_bridge| bus_to_bridge.close();
    if (wanted.chip == st.CHIP_LT8912B) bridge_bus = monitorFor(sys, &wanted) orelse return err.RTGERR_NO_DISPLAY;
    // The PLL's setting for the rate that will run - over HDMI the one
    // the monitor's mode came with - found before anything is taken. The
    // tags' own rate was asked of it as they were read.
    const lane = host.pllFor(wanted.lane_mbps) orelse return err.RTGERR_BAD_TAGS;

    const board = rb.CreateBoard(driver, device, &.{
        .ops = &ops,
        .instance_size = @sizeOf(Panel),
        .flags = rtg.boards.RTGBF_STREAMING,
    }) orelse return err.RTGERR_NO_MEMORY;
    const panel = panelOf(board);
    panel.* = .{ .sys = sys, .board = board, .config = wanted };
    sys.InitSemaphore(&panel.pointer.lock);
    // A screen's rows: the stream reads a panel's straight, so they are
    // exactly its width; over HDMI it reads the copy instead, and the
    // screens' rows are whole cache lines as AllocBitMap makes them, for a
    // width that is not.
    const row = wanted.width * (wanted.bits_per_pixel / 8);
    const line = hardware.DCACHE_LINE_SIZE;
    panel.screen_pitch = if (bridge_bus != null) (row + line - 1) / line * line else row;
    panel.frame_bytes = panel.screen_pitch * wanted.height;
    panel.stream_pitch = row;
    panel.stream_frame_bytes = panel.frame_bytes;
    if (bridge_bus != null) {
        panel.hdmi = true;
        panel.composing = true;
        if (!link_file.allocate(&panel.link, sys, wanted.width, wanted.height, .bgr24)) {
            rb.DeleteBoard(board);
            return err.RTGERR_NO_MEMORY;
        }
        panel.stream_pitch = panel.link.pitch;
        panel.stream_frame_bytes = panel.link.pitch * wanted.height;
    }

    const code = bringUp(panel, bridge_bus, lane);
    if (code != err.RTGERR_OK) {
        giveBack(panel);
        rb.DeleteBoard(board);
        return code;
    }

    // One mode: the panel is what it is, and a monitor gets the one
    // picked for it - at the pixel clock the chip makes of the one asked.
    const timings: rtg.RtgTimings = .{
        .pixel_clock_hz = panel.pixel_hz,
        .h_active = wanted.width,
        .h_front = wanted.hfp,
        .h_sync = wanted.hsync,
        .h_back = wanted.hbp,
        .v_active = wanted.height,
        .v_front = wanted.vfp,
        .v_sync = wanted.vsync,
        .v_back = wanted.vbp,
        .flags = (if (wanted.hsync_high) rtg.modes.RTGTM_HSYNC_HIGH else 0) |
            (if (wanted.vsync_high) rtg.modes.RTGTM_VSYNC_HIGH else 0),
    };
    if (rb.AddBoardMode(board, &timings, @intFromEnum(rtg.PixelFormat.rgb565), rtg.modes.RTGMF_DEFAULT) == 0) {
        giveBack(panel);
        rb.DeleteBoard(board);
        return err.RTGERR_NO_MEMORY;
    }

    // Its buffers are taken from system memory as they are asked for - a
    // line-aligned block each, which the DMA reads in whole lines - and no
    // more than the board says at once.
    board.region = .{
        .size = wanted.buffers * panel.frame_bytes,
        .alignment = hardware.DCACHE_LINE_SIZE,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED | rtg.boards.RTGRF_SYSTEM_MEMORY,
    };
    board.info.buffers = wanted.buffers;
    board.info.brightness = panel.brightness;
    return err.RTGERR_OK;
}

/// The bridge's I2C bus, when a monitor's EDID answers on it, and
/// `wanted` set to the largest mode the EDID names (`monitor.zig`) - left
/// the part's own when it names none of them; the monitor's name and the
/// mode said on the raw port. Null, and nothing kept, when there is no
/// monitor - or no bus.
fn monitorFor(sys: *ExecBase, wanted: *config.Config) ?lt8912b.I2c {
    const bus_to_bridge = lt8912b.I2c.open(sys, wanted.i2c_unit) orelse return null;
    if (!lt8912b.monitorThere(bus_to_bridge)) {
        bus_to_bridge.close();
        return null;
    }
    var first: lt8912b.Edid = undefined;
    var extension: lt8912b.Edid = undefined;
    var name: [14]u8 = undefined;
    name[0] = 0;
    if (lt8912b.readEdid(bus_to_bridge, &first)) {
        edid.name(&first, &name);
        const cea: ?*const lt8912b.Edid = if (lt8912b.readExtension(bus_to_bridge, &first, &extension)) &extension else null;
        if (monitor.best(&first, cea)) |mode| take(wanted, mode);
    }
    const shown: [*:0]const u8 = if (name[0] != 0) @ptrCast(&name) else "a monitor";
    sdk.exec.kprintf(sys, "%s: HDMI to %s, %dx%d\n", .{ MODULE_NAME, shown, wanted.width, wanted.height });
    return bus_to_bridge;
}

/// `mode` in place of the part's own: the picture, its timings, the
/// pixel clock and the link's rate on two lanes.
fn take(wanted: *config.Config, mode: *const monitor.Mode) void {
    wanted.width = mode.width;
    wanted.height = mode.height;
    wanted.pixel_hz = mode.pixel_hz;
    wanted.hsync = mode.hsync;
    wanted.hbp = mode.hbp;
    wanted.hfp = mode.hfp;
    wanted.vsync = mode.vsync;
    wanted.vbp = mode.vbp;
    wanted.vfp = mode.vfp;
    wanted.hsync_high = mode.hsync_high;
    wanted.vsync_high = mode.vsync_high;
    wanted.lane_mbps = mode.lane_mbps;
    wanted.lanes = 2;
}

/// The PSRAM's bus clock in MHz, as the board's list gives it (80 if it
/// does not).
fn psramMhz(driver: *rtg.RtgDriver) u32 {
    const default_mhz = 80;
    const eb = driver.expansion_base orelse return default_mhz;
    return @truncate(driver.rtg_base.GetRtgTagData(sdk.expansion.systemtags.SYSTAG_PsramSpeed, default_mhz, eb.SystemTags()));
}

/// What the stream reads a second, on average: a frame's bytes, as often
/// as the pixel clock sends frames.
fn streamBytes(panel: *const Panel) u64 {
    const wanted = &panel.config;
    const line = wanted.hsync + wanted.hbp + wanted.width + wanted.hfp;
    const lines = wanted.vsync + wanted.vbp + wanted.height + wanted.vfp;
    const whole: u64 = @as(u64, line) * lines;
    if (whole == 0) return 0;
    return @as(u64, panel.stream_frame_bytes) * panel.pixel_hz / whole;
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    giveBack(panelOf(board));
}

/// One mode, the panel's own or the monitor's, which create already set
/// up.
fn setMode(_: *rtg.RtgBoard, _: *const rtg.RtgMode, _: *const rtg.RtgTimings) callconv(.c) i32 {
    return err.RTGERR_OK;
}

/// Feed the panel from that buffer: a chain of one band. The first time,
/// this starts the stream. With the stream running it is a flip: the
/// buffer is sent from the next frame on, whole, and this returns once
/// the frame before it is the last that reads the one it replaced.
fn showBitMap(board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    if (x != 0 or y != 0) return err.RTGERR_NOT_SUPPORTED;
    const bm = bitmap orelse {
        if (panel.streaming) stopStream(panel);
        return err.RTGERR_OK;
    };
    if (bm.pixels == null) return err.RTGERR_BAD_ARG;
    if (bm.width != panel.config.width or bm.height != panel.config.height) return err.RTGERR_NOT_DISPLAYABLE;
    if (bm.pitch != panel.screen_pitch) return err.RTGERR_NOT_DISPLAYABLE;
    if (bm.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    const whole = [_]rtg.RtgBand{.{ .bitmap = bm }};
    return show(panel, &whole);
}

/// Several buffers at once, in bands: each band a run of display lines
/// from one buffer, whose rows are a line each. Shown from the next frame
/// on, as a flip is.
fn showBands(board: *rtg.RtgBoard, bands: [*]const rtg.RtgBand, count: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    for (bands[0..count]) |band| {
        const bm = band.bitmap;
        if (bm.pixels == null) return err.RTGERR_BAD_ARG;
        if (bm.pitch != panel.screen_pitch) return err.RTGERR_NOT_DISPLAYABLE;
        if (bm.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    }
    return show(panel, bands[0..count]);
}

/// Rows the CPU wrote, handed to the panel: the DMA reads that memory
/// without going through the cache, so what was written has to be pushed
/// out of it first. The stream never stops, so that is the whole of it -
/// unless it reads the copy, which takes the rows and the pointer again.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) callconv(.c) i32 {
    const pixels = bitmap.pixels orelse return err.RTGERR_BAD_ARG;
    const count = if (rows == 0) bitmap.height - y else rows;
    var bytes: u32 = count * bitmap.pitch;
    if (bytes == 0) return err.RTGERR_OK;
    const start: *anyopaque = @ptrFromInt(@intFromPtr(pixels) + @as(usize, y) * bitmap.pitch);
    const panel = panelOf(board);
    _ = panel.sys.CachePreDMA(start, &bytes, 0);
    if (panel.composing) {
        const sys = panel.sys;
        sys.ObtainSemaphore(&panel.pointer.lock);
        const kept = pointer_file.keepOut(&panel.pointer, &panel.link);
        link_file.refresh(&panel.link, &panel.engine, sys, bitmap, y, count, panel.streaming, kept);
        pointer_file.mend(&panel.pointer, &panel.link, sys, kept);
        sys.ReleaseSemaphore(&panel.pointer.lock);
    }
    return err.RTGERR_OK;
}

// --- the pointer and the overlay (pointer.zig) ---------------------------

fn setPointer(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    const panel = panelOf(board);
    if (image) |one| {
        if (one.format != .rgb565) return err.RTGERR_BAD_FORMAT;
        if (panel.pointer.shown and !compose(panel)) return err.RTGERR_NO_MEMORY;
    }
    pointer_file.change(&panel.pointer, &panel.link, panel.sys, .{ .image = image });
    return err.RTGERR_OK;
}

fn movePointer(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const panel = panelOf(board);
    pointer_file.change(&panel.pointer, &panel.link, panel.sys, .{ .place = .{ left, top } });
}

/// Seen from now on: the first time on a panel, its stream goes over to
/// the copy, a flip's wait.
fn showPointer(board: *rtg.RtgBoard, shown: bool) callconv(.c) i32 {
    const panel = panelOf(board);
    if (shown and panel.pointer.image != null and !compose(panel)) return err.RTGERR_NO_MEMORY;
    pointer_file.change(&panel.pointer, &panel.link, panel.sys, .{ .shown = shown });
    return err.RTGERR_OK;
}

fn setOverlay(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    const panel = panelOf(board);
    if (image) |one| {
        if (one.format != .rgb565) return err.RTGERR_BAD_FORMAT;
        if (!compose(panel)) return err.RTGERR_NO_MEMORY;
    }
    pointer_file.change(&panel.pointer, &panel.link, panel.sys, .{ .overlay = image });
    return err.RTGERR_OK;
}

fn moveOverlay(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const panel = panelOf(board);
    pointer_file.change(&panel.pointer, &panel.link, panel.sys, .{ .overlay_place = .{ left, top } });
}

/// The panel's own display on or off, by its DCS command. Not the
/// backlight.
fn display(board: *rtg.RtgBoard, on: bool) callconv(.c) i32 {
    if (panelOf(board).hdmi) return err.RTGERR_NOT_SUPPORTED;
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

/// A rectangle filled by the PPA, its ragged ends by the CPU
/// (`engine.zig`); RTGERR_NOT_SUPPORTED for one the engine does not take.
fn fillRect(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    return engine_file.fill(&panel.engine, panel.sys, bitmap, area, color, panel.streaming);
}

/// A rectangle copied by the 2D-DMA, its ragged ends by the CPU.
fn copyRect(board: *rtg.RtgBoard, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, what: *const rtg.RtgCopy) callconv(.c) i32 {
    const panel = panelOf(board);
    return engine_file.copy(&panel.engine, panel.sys, src, dest, what, panel.streaming);
}

/// Pixels laid over a rectangle by the PPA's blend unit, its ragged ends
/// by the CPU (`blend.zig`).
fn blendPixels(board: *rtg.RtgBoard, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, alpha: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    return blend_file.blendPixels(&panel.engine, panel.sys, dest, area, pixels, alpha, panel.streaming);
}

/// A colour laid over a rectangle the same way.
fn blendRect(board: *rtg.RtgBoard, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    return blend_file.blendRect(&panel.engine, panel.sys, dest, area, color, panel.streaming);
}

/// A picture scaled by the PPA's scaler and then laid over the rectangle
/// (`scale.zig`), for ratios its steps reach exactly.
fn scalePixels(board: *rtg.RtgBoard, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, width: u32, height: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    return scale_file.scalePixels(&panel.engine, panel.sys, dest, area, pixels, width, height, panel.streaming);
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

/// What this board has: of the engine, fills, copies, blends and scales;
/// a pointer and an overlay.
const ops = rtg.RtgBoardOps{
    .destroy = &destroy,
    .set_mode = &setMode,
    .show_bitmap = &showBitMap,
    .show_bands = &showBands,
    .refresh = &refresh,
    .display = &display,
    .set_brightness = &setBrightness,
    .brightness = &brightness,
    .stats = &stats,
    .control = &control,
    .fill_rect = &fillRect,
    .copy_rect = &copyRect,
    .blend_pixels = &blendPixels,
    .blend_rect = &blendRect,
    .scale_pixels = &scalePixels,
    .set_pointer = &setPointer,
    .move_pointer = &movePointer,
    .show_pointer = &showPointer,
    .set_overlay = &setOverlay,
    .move_overlay = &moveOverlay,
};

const driver_ops = rtg.RtgDriverOps{ .attach = &attach };

/// What it takes: a panel or a bridge on the DSI host.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_BUS, .bus = st.BUS_MIPI_DSI },
    .{},
};

/// The driver's tag: a description and no init. rtg.library reads it at
/// its own init and puts the driver on its list; nothing of this module
/// runs until a board is asked for.
export const rtg_dsi_tag: rtg.ResidentRtgDriver linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&rtg_dsi_tag),
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
        // The DMA's interrupt reads the panel at every frame's end.
        .flags = rtg.drivers.RTGDF_INTERNAL_INSTANCE,
        .matches = &matches,
        .ops = &driver_ops,
    },
};

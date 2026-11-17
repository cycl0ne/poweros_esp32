// SPDX-License-Identifier: MPL-2.0
//! A MIPI-DSI panel as a display board: the ESP32-P4's DSI host and
//! D-PHY, the bridge in front of it, and the DMA channel that keeps it
//! fed from a picture in PSRAM - one of the DW-GDMA's, which dma.resource
//! hands out.
//!
//! A module of its own: a description of a driver called "dsi" behind a
//! ROM tag, which rtg.library puts on its list. It takes what is on the
//! DSI host (`BUS_MIPI_DSI`): offered such a part, it makes a board from
//! the part's tags: the link (lanes and lane rate), the pixel clock and
//! timings, and the panel's bring-up as DCS commands - so another panel
//! on this host is another tag list and not another driver.
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
//! end. That interrupt is the frame's: it says the frame ended
//! (`FrameDone`), which the library counts (`RtgBoardStats.blanks`) and
//! WaitVBlank waits for. The picture is read straight out of PSRAM; the
//! CPU's writes reach it when RefreshRect writes them back out of the
//! cache.
//!
//! **HDMI.** A part that is an HDMI bridge (CHIP_LT8912B) is the same
//! board with these differences. The part is declined unless a monitor's
//! EDID answers on the bridge's bus, so the next part the board lists -
//! its panel - is offered instead. The board has a connector: it says
//! what is on it (`detect`, the monitor's EDID read over the bridge's
//! bus) and which timings it can make (`checkMode`: the sizes of
//! `sends.zig` and the part's own, at 60 Hz), and rtg.library makes its
//! modes of what the monitor names. The link is brought up when the board
//! is put in a mode (`setMode`), in this host's timing for the mode's
//! size - and again in the mode it is in when another monitor came, what
//! was shown shown again. The bridge is brought up over I2C where a panel
//! takes DCS commands; and the link carries RGB888, which the stream
//! reads from a copy of what is shown (`link.zig`) while the screens stay
//! RGB565. The bridge's hot-plug line raises no interrupt here: the
//! frame's interrupt has the library look at the connector every two
//! seconds (`MonitorChanged`), which changes nothing while the same
//! monitor is there.
//!
//! **The copy** is the board's own picture, which rtg.library composes:
//! the bands of the screens' buffers, the overlay and the pointer over
//! them. The board is told which rectangle of it changed (`update`) and
//! fetches that from the library into the copy (`link.zig`). A bridge's
//! board reads no screen itself and always streams its copy. A panel
//! streams its screens straight for as long as nothing lies over the
//! picture - which on a board touched with a finger is nearly always -
//! and a copy of its own, in RGB565, while a pointer or an overlay is to
//! be seen; the copy is made the first time and kept.
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
const utility = sdk.utility;
const TagItem = utility.TagItem;
const err = rtg.errors;
const hardware = sdk.hardware;
const system = hardware.system;
const systimer = hardware.systimer;
const intbits = hardware.intbits;
const boardpin = sdk.expansion.boardpin;
const BoardPin = sdk.expansion.BoardPin;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const dwdma = hardware.dwdma;
const dmares = sdk.resources.dma;

const config = @import("config.zig");
const host = @import("host.zig");
const bridge = @import("bridge.zig");
const engine_file = @import("engine.zig");
const blend_file = @import("blend.zig");
const scale_file = @import("scale.zig");
const bus = @import("bus.zig");
const chain_file = @import("chain.zig");
const Chain = chain_file.Chain;
const link_file = @import("link.zig");
const lt8912b = @import("lt8912b.zig");
const sends = @import("sends.zig");
const st = sdk.expansion.systemtags;

const MODULE_NAME = "rtg-dsi";
const DRIVER_NAME = "dsi";
const VERSION = 1;
const REVISION = 27;
const BUILD_DATE = "17.11.2026";
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
const pixel_source_hz = system.REF_240M_HZ;
const pixel_source = system.DSI_CLK_SRC_REF_240M;
/// How the stream's channel feeds the bridge: on the bridge's handshake,
/// at priority 1, with five reads and two writes outstanding at most.
const stream_route: dwdma.Route = .{ .handshake = bridge.dma_handshake, .priority = 1, .reads = 5, .writes = 2 };
/// How long a flip waits for the frame it lands on.
const flip_wait_us = 100_000;
/// How many frames go by between two looks at the bridge's connector,
/// which the library takes (`look_frames`): a second of them, so a
/// monitor pulled or plugged has settled within two.
const look_frames = 60;

/// One panel: the board's instance, allocated and cleared by the library
/// in internal memory.
const Panel = struct {
    sys: *ExecBase,
    board: *rtg.RtgBoard,
    config: config.Config = .{},
    frame_bytes: u32 = 0,
    /// The link is an HDMI bridge's: RGB888, from `link`.
    hdmi: bool = false,
    /// Over HDMI: the part's own mode, as its tags give it - what a
    /// monitor that names none of the host's gets; whether the link is
    /// brought up, and the number of the mode it is brought up in.
    own: config.Config = .{},
    up: bool = false,
    mode_id: u32 = 0,
    /// The copy of what is shown, which rtg.library composes: over HDMI
    /// from the mode set on, on a panel from the first time it shows its
    /// own picture. `from_copy`: the stream reads it now.
    link: link_file.Link = .{},
    from_copy: bool = false,
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
    /// The stream's channel, from dma.resource for as long as the link is
    /// up (`takeChannel`): the controller's registers, the channel's
    /// number on it, and its interrupt.
    dma: ?*dmares.DmaBase = null,
    dma_base: usize = 0,
    dma_channel: u32 = 0,
    dma_irq: u32 = 0,
    dma_int: exec.Interrupt = .{},
    bridge_int: exec.Interrupt = .{},
    hooked: bool = false,
    /// The DSI host's clock is on (`bringUp`).
    clocked: bool = false,
    /// The part's reset and backlight, taken through expansion.library for
    /// as long as the board is (`takeLines`).
    expansion_base: ?*ExpansionBase = null,
    lines_held: bool = false,
    stats: rtg.RtgBoardStats = .{},
    /// The PPA and the 2D-DMA: the board's fill, copy, blend and scale
    /// (`engine_ops`).
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
/// and said to whoever waits for a blanking (WaitVBlank). A block the
/// bus would not carry stops the channel: counted as a failed send, and
/// the next picture sent the same way. The controller's other channels
/// share the interrupt, so the server answers for its own alone.
fn dmaServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const panel: *Panel = @ptrCast(@alignCast(is_data.?));
    const raised = dwdma.takeInterrupts(panel.dma_base, panel.dma_channel);
    if (raised == 0) return 0;
    if (raised & (dwdma.INT_DONE | dwdma.INT_ERRORS) != 0 and panel.streaming) {
        if (raised & dwdma.INT_ERRORS != 0) {
            panel.stats.failed_sends +%= 1;
            _ = dwdma.halt(panel.dma_base, panel.dma_channel);
        }
        if (panel.pending.first != 0) {
            panel.retired = panel.chain;
            panel.chain = panel.pending;
            panel.pending = .{};
        }
        chain_file.rearm(panel.chain);
        dwdma.go(panel.dma_base, panel.dma_channel, panel.chain.first);
        panel.stats.frames +%= 1;
        engine_file.frameTick(&panel.engine);
        // Over HDMI, every `look_frames` of them the library looks at
        // the bridge's connector.
        driverBase(panel.board).FrameDone(panel.board);
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

/// The part's reset and backlight taken through expansion.library,
/// whatever kind each is. False, said on the raw port, if another driver
/// holds one; a machine without the library takes nothing.
fn takeLines(panel: *Panel) bool {
    const eb = panel.expansion_base orelse return true;
    const reset = panel.config.reset_pin.data();
    if (eb.ClaimBoardPin(reset, MODULE_NAME)) |holder| {
        exec.kprintf(panel.sys, "%s: its panel's reset line is %s's\n", .{ MODULE_NAME, holder });
        return false;
    }
    if (eb.ClaimBoardPin(panel.config.backlight_pin.data(), MODULE_NAME)) |holder| {
        eb.ReleaseBoardPin(reset);
        exec.kprintf(panel.sys, "%s: its panel's backlight is %s's\n", .{ MODULE_NAME, holder });
        return false;
    }
    panel.lines_held = true;
    return true;
}

/// The two lines given back, the backlight off first.
fn releaseLines(panel: *Panel) void {
    if (!panel.lines_held) return;
    _ = drive(panel, panel.config.backlight_pin, false);
    const eb = panel.expansion_base.?;
    eb.ReleaseBoardPin(panel.config.reset_pin.data());
    eb.ReleaseBoardPin(panel.config.backlight_pin.data());
    panel.lines_held = false;
}

/// A line of the panel's driven asserted or not. False where it is not
/// one expansion.library drives - not wired, or the part's own.
fn drive(panel: *Panel, pin: BoardPin, asserted: bool) bool {
    const eb = panel.expansion_base orelse return false;
    return eb.SetBoardPin(pin.data(), asserted);
}

/// Whether a line is one this driver can switch: a pad of the chip or a
/// pin of the expander.
fn switched(pin: BoardPin) bool {
    return pin.kind == boardpin.BPIN_GPIO or pin.kind == boardpin.BPIN_EXPANDER;
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
    // clock from the 240 MHz one.
    const divider = pixelDivider(wanted.timing.pixel_hz);
    panel.pixel_hz = pixel_source_hz / divider;
    sys.Disable();
    system.update(system.REF_CLK_CTRL1, system.REF_240M_CLK_EN, 0);
    system.update(system.REF_CLK_CTRL2, system.REF_20M_CLK_EN, 0);
    system.update(system.PERI_CLK_CTRL02, 0, system.MIPI_DSI_DPHY_CLK_SRC_SEL);
    system.setFunctionClock(.dsi, .{ .source = pixel_source, .divider = divider });
    system.enable(.dsi);
    sys.Enable();
    panel.clocked = true;

    // The panel's reset, where the board wired one.
    const rb = driverBase(panel.board);
    const reset_by_line = drive(panel, wanted.reset_pin, true);
    if (reset_by_line) {
        rb.RtgDelay(wanted.reset_ms * 1000);
        _ = drive(panel, wanted.reset_pin, false);
        rb.RtgDelay(wanted.settle_ms * 1000);
    }

    panel.lane_kbps = host.startPhy(panel.sys, wanted.lanes, lane);
    if (panel.lane_kbps == 0) {
        exec.kprintf(sys, "%s: the D-PHY did not come up\n", .{MODULE_NAME});
        return err.RTGERR_NO_DISPLAY;
    }
    // The rate the lanes run at, which is the one asked for wherever the
    // PLL makes it.
    const lane_mbps = panel.lane_kbps / 1000;
    host.commandMode(lane_mbps);

    if (bus_to_bridge) |bridge_bus| {
        // An HDMI bridge: brought up over I2C for the mode the link carries.
        // At the pixel clock the divider makes.
        var mode: lt8912b.Mode = wanted.timing;
        mode.pixel_hz = panel.pixel_hz;
        // The mode's AVI infoframe: a computer's picture in the whole
        // range, with no number, since the clocks here are not CEA's.
        var avi: [rtg.RTG_AVI_BYTES]u8 = undefined;
        const shown: rtg.RtgTimings = .{ .h_active = wanted.timing.width, .v_active = wanted.timing.height };
        _ = driverBase(panel.board).BuildAviInfoFrame(&shown, rtg.RTGAVI_IT | rtg.RTGAVI_RANGE_FULL | rtg.RTGAVI_NO_VIC, &avi);
        // HDMI, unless the monitor's EDID says it is a DVI one.
        var monitor: rtg.RtgMonitorInfo = .{};
        _ = panel.board.rtg_base.?.GetBoardMonitor(panel.board, &monitor, @sizeOf(rtg.RtgMonitorInfo));
        const dvi = monitor.flags & rtg.modes.RTGMON_EDID != 0 and monitor.flags & rtg.modes.RTGMON_HDMI == 0;
        if (!lt8912b.setUp(bridge_bus, wanted.i2c_address, wanted.lanes, lane_mbps, mode, &avi, dvi)) {
            exec.kprintf(sys, "%s: the HDMI bridge did not take its bring-up\n", .{MODULE_NAME});
            return err.RTGERR_NO_DISPLAY;
        }
    } else {
        // A panel without a reset line is reset by its own command.
        if (!reset_by_line) {
            if (!host.dcsWrite(panel.sys, SWRESET, &.{})) return err.RTGERR_NO_DISPLAY;
            rb.RtgDelay(wanted.settle_ms * 1000);
        }
        var hook: utility.Hook = .{ .entry = &sendStep, .data = panel };
        const code = rb.RunPanelSequence(wanted.init_sequence.?, wanted.init_length, &hook);
        if (code != err.RTGERR_OK) {
            exec.kprintf(sys, "%s: the panel did not take its bring-up\n", .{MODULE_NAME});
            return code;
        }
    }

    host.setVideo(.{
        .timing = wanted.timing,
        .coding = if (panel.hdmi) host.coding_rgb888 else host.coding_rgb565,
        .low_power = !panel.hdmi,
    }, panel.lane_kbps, panel.pixel_hz);
    bridge.setUp(.{
        .timing = wanted.timing,
        .bits_per_pixel = if (panel.hdmi) 24 else wanted.bits_per_pixel,
        .raw_type = if (panel.hdmi) bridge.raw_rgb888 else bridge.raw_rgb565,
    });

    const taken = takeChannel(panel);
    if (taken != err.RTGERR_OK) return taken;
    const psram_mhz = psramMhz(panel.board.driver.?);
    bus.share(panel.sys, streamBytes(panel), psram_mhz);

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
    sys.AddIntServer(panel.dma_irq, &panel.dma_int);
    sys.AddIntServer(intbits.INTB_DSI_BRIDGE, &panel.bridge_int);
    panel.hooked = true;

    _ = drive(panel, wanted.backlight_pin, true);
    return err.RTGERR_OK;
}

/// The stream's channel: the first of the DW-GDMA's that dma.resource
/// hands over, set to feed the bridge. RTGERR_IN_USE, said on the raw
/// port, when every one is another's; RTGERR_NO_DISPLAY without
/// dma.resource.
fn takeChannel(panel: *Panel) i32 {
    const sys = panel.sys;
    const db: *dmares.DmaBase = @ptrCast(@alignCast(sys.OpenResource(dmares.DMANAME) orelse return err.RTGERR_NO_DISPLAY));
    const controller = dwdma.find() orelse return err.RTGERR_NO_DISPLAY;
    var number: u32 = 0;
    while (number < dmares.DWDMA_CHANNELS) : (number += 1) {
        const holder = db.AllocDMAChannel(dmares.DWDMA_CHANNEL0 + number, MODULE_NAME) orelse break;
        if (number + 1 == dmares.DWDMA_CHANNELS) {
            exec.kprintf(sys, "%s: no DMA channel for the stream, the last is %s's\n", .{ MODULE_NAME, holder });
            return err.RTGERR_IN_USE;
        }
    }
    panel.dma = db;
    panel.dma_base = controller.base;
    panel.dma_channel = number;
    panel.dma_irq = dmares.dmaIntNumber(dmares.DWDMA_CHANNEL0 + number, dmares.DMA_OUT);
    dwdma.toPeripheral(controller.base, number, stream_route);
    return err.RTGERR_OK;
}

/// One step of the panel's bring-up, sent by the host as a DCS command:
/// `RunPanelSequence`'s hook, whose data is the panel. RTGERR_NO_DISPLAY
/// where the host could not send it.
fn sendStep(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const panel: *Panel = @ptrCast(@alignCast(hook.data.?));
    const step: *const rtg.RtgPanelStep = @ptrCast(@alignCast(message.?));
    const params: []const u8 = if (step.params) |bytes| bytes[0..step.count] else &.{};
    const sent = host.dcsWrite(panel.sys, @intCast(step.command), params) and host.commandsSent(panel.sys);
    return @bitCast(@as(isize, if (sent) err.RTGERR_OK else err.RTGERR_NO_DISPLAY));
}

/// The stream started from `chain`.
fn startStream(panel: *Panel, chain: Chain) void {
    panel.chain = chain;
    // Before the channel runs: its first end is a frame's like any other.
    panel.streaming = true;
    dwdma.go(panel.dma_base, panel.dma_channel, chain.first);
    host.videoMode(true);
    bridge.dpi(true);
    bridge.underrunInterrupt(true);
}

/// The HDMI bridge set to follow the stream that has just started. False,
/// and said on the raw port, when it could not be reached or did not take
/// the stream.
fn settleBridge(panel: *Panel) bool {
    const wanted = &panel.config;
    const bus_to_bridge = lt8912b.I2c.open(panel.sys, wanted.i2c_unit) orelse return false;
    defer bus_to_bridge.close();
    if (lt8912b.follow(bus_to_bridge, wanted.i2c_address, panel.pixel_hz)) return true;
    exec.kprintf(panel.sys, "%s: the HDMI bridge did not take the stream\n", .{MODULE_NAME});
    return false;
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
    // The chains are freed only once the channel has stopped reading
    // them; one that did not stop keeps them, and they are not freed.
    const stopped = dwdma.halt(panel.dma_base, panel.dma_channel);
    if (!stopped) exec.kprintf(sys, "%s: the stream's channel did not stop; its chains are kept\n", .{MODULE_NAME});
    for ([_]*Chain{ &panel.chain, &panel.pending, &panel.retired }) |one| {
        if (stopped) chain_file.free(sys, one.*);
        one.* = .{};
    }
}

/// Send `bands` from the next frame on, whole; the first time, this
/// starts the stream. Returns once the chain they make is the one being
/// sent, and the one before it is no longer read. A show comes here one at
/// a time, under the board's lock, so the chain handed over is taken up
/// before the next is made.
fn stream(panel: *Panel, bands: []const rtg.RtgBand) i32 {
    const sys = panel.sys;
    const made = chain_file.build(sys, bands, panel.config.timing.height, panel.stream_pitch) orelse return err.RTGERR_NO_MEMORY;
    if (!panel.streaming) {
        startStream(panel, made);
        // A bridge that does not take the stream shows nothing: the
        // stream is stopped again, and nothing is shown.
        if (panel.hdmi and !settleBridge(panel)) {
            stopStream(panel);
            return err.RTGERR_NO_DISPLAY;
        }
        return err.RTGERR_OK;
    }
    sys.Disable();
    panel.pending = made;
    sys.Enable();
    const waiting: *volatile usize = &panel.pending.first;
    const since = panel.sys.UptimeUs();
    while (waiting.* != 0) {
        if (panel.sys.UptimeUs() - since > flip_wait_us) break;
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

/// Everything create took, given back.
fn giveBack(panel: *Panel) void {
    const sys = panel.sys;
    if (panel.streaming) stopStream(panel);
    panel.from_copy = false;
    if (panel.hooked) {
        sys.RemIntServer(panel.dma_irq, &panel.dma_int);
        sys.RemIntServer(intbits.INTB_DSI_BRIDGE, &panel.bridge_int);
        panel.hooked = false;
    }
    if (panel.dma) |db| {
        db.FreeDMAChannel(dmares.DWDMA_CHANNEL0 + panel.dma_channel);
        panel.dma = null;
    }
    link_file.free(&panel.link, sys);
    // The bridge's and the host's registers answer only with their clock
    // on: a bring-up that failed before that has nothing to stop.
    if (panel.clocked) {
        bridge.stop();
        host.stop();
    }
    _ = drive(panel, panel.config.backlight_pin, false);
}

// --- the board's ops -----------------------------------------------------

/// What is on the DSI host is offered - a panel, or an HDMI bridge - and
/// a board made of it. A panel is brought up here, in its one mode. A
/// bridge is taken only with a monitor behind it, and brought up when
/// the board is put in a mode the monitor names (`setMode`). A board that
/// lists both is offered them in the list's order; the bridge is declined
/// without a monitor behind it, and whichever has the host, the other is
/// declined.
fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const sys = driver.sys_base;
    const rb = driver.rtg_base;
    // There is one host: what else is on it is declined.
    if (driver.boards != 0) return err.RTGERR_IN_USE;

    const wanted = config.read(rb, tag_list) orelse return err.RTGERR_BAD_TAGS;
    const hdmi = wanted.chip == st.CHIP_LT8912B;
    if (hdmi and !monitorBehind(sys, &wanted)) return err.RTGERR_NO_DISPLAY;
    // The PLL's setting for the rate the tags ask, which was asked of it
    // as they were read.
    const lane = host.pllFor(wanted.lane_mbps) orelse return err.RTGERR_BAD_TAGS;

    const board = rb.CreateBoard(driver, device, &.{
        .ops = if (hdmi) &bridge_ops else &ops,
        .instance_size = @sizeOf(Panel),
        .flags = rtg.boards.RTGBF_STREAMING,
        // A monitor's modes are made in the format the screens are in.
        .format = .rgb565,
        // A panel's stream reads every band of a show itself. A bridge's
        // reads none: its link carries RGB888, which only the copy is.
        .direct_bands = if (hdmi) 0 else rtg.RTG_MAX_BANDS,
        // The bridge's connector raises no interrupt.
        .look_frames = if (hdmi) look_frames else 0,
    }) orelse return err.RTGERR_NO_MEMORY;
    const panel = panelOf(board);
    panel.* = .{ .sys = sys, .board = board, .config = wanted, .own = wanted, .hdmi = hdmi, .expansion_base = driver.expansion_base };
    if (!takeLines(panel)) {
        rb.DeleteBoard(board);
        return err.RTGERR_IN_USE;
    }
    sizeRows(panel);
    // The engine is the board's for as long as the board is, whatever
    // becomes of the link: its channels claimed now, and the board
    // without the engine's ops where they were not to be had.
    engine_file.setUp(&panel.engine, sys, psramMhz(driver));
    if (!panel.engine.ready) board.ops = if (hdmi) &bridge_ops_no_engine else &ops_no_engine;

    // Its buffers are taken from system memory as they are asked for - a
    // line-aligned block each, which the DMA reads in whole lines - and no
    // more than the board says at once. A panel's stream reads them past
    // the cache - for any buffer, shown or not, and also while it reads
    // the copy, since it reads the buffers again once nothing lies over
    // the picture - so the library writes back what the CPU wrote. A
    // bridge's stream reads the copy alone, and nothing but the CPU reads
    // the screens' buffers.
    board.region = .{
        .size = wanted.buffers * panel.frame_bytes,
        .alignment = hardware.DCACHE_LINE_SIZE,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED | rtg.boards.RTGRF_SYSTEM_MEMORY |
            (if (hdmi) 0 else rtg.boards.RTGRF_WRITE_BACK),
    };
    board.info.buffers = wanted.buffers;
    // A backlight on a pad or on the expander is on or off; a board with
    // none wired, and one behind the bridge, has none to set.
    board.info.brightness_steps = if (!hdmi and switched(panel.config.backlight_pin)) 2 else 0;
    // A bridge's modes are the library's to make, and its link comes up
    // with the first of them.
    if (hdmi) return err.RTGERR_OK;

    const code = bringUp(panel, null, lane);
    if (code != err.RTGERR_OK) {
        giveBack(panel);
        engine_file.takeDown(&panel.engine);
        releaseLines(panel);
        rb.DeleteBoard(board);
        return code;
    }
    panel.up = true;

    // One mode: the panel is what it is - at the pixel clock the chip
    // makes of the one asked.
    const timings: rtg.RtgTimings = .{
        .pixel_clock_hz = panel.pixel_hz,
        .h_active = wanted.timing.width,
        .h_front = wanted.timing.hfp,
        .h_sync = wanted.timing.hsync,
        .h_back = wanted.timing.hbp,
        .v_active = wanted.timing.height,
        .v_front = wanted.timing.vfp,
        .v_sync = wanted.timing.vsync,
        .v_back = wanted.timing.vbp,
        .flags = (if (wanted.timing.hsync_high) rtg.modes.RTGTM_HSYNC_HIGH else 0) |
            (if (wanted.timing.vsync_high) rtg.modes.RTGTM_VSYNC_HIGH else 0),
    };
    if (rb.AddBoardMode(board, &timings, @intFromEnum(rtg.PixelFormat.rgb565), rtg.modes.RTGMF_DEFAULT) == 0) {
        giveBack(panel);
        engine_file.takeDown(&panel.engine);
        releaseLines(panel);
        rb.DeleteBoard(board);
        return err.RTGERR_NO_MEMORY;
    }
    return err.RTGERR_OK;
}

/// A screen's rows and a frame's bytes, for the mode in `panel.config`:
/// the stream reads a panel's screens straight, so their rows are exactly
/// its width; over HDMI it reads the copy instead, and the screens' rows
/// are whole cache lines as AllocBitMap makes them, for a width that is
/// not. What the stream reads is set from the copy once that is taken.
fn sizeRows(panel: *Panel) void {
    const wanted = &panel.config;
    const row = wanted.timing.width * (wanted.bits_per_pixel / 8);
    const line = hardware.DCACHE_LINE_SIZE;
    panel.screen_pitch = if (panel.hdmi) (row + line - 1) / line * line else row;
    panel.frame_bytes = panel.screen_pitch * wanted.timing.height;
    panel.stream_pitch = row;
    panel.stream_frame_bytes = panel.frame_bytes;
}

/// Whether a monitor's EDID answers on the bridge's bus.
fn monitorBehind(sys: *ExecBase, wanted: *const config.Config) bool {
    const bus_to_bridge = lt8912b.I2c.open(sys, wanted.i2c_unit) orelse return false;
    defer bus_to_bridge.close();
    return lt8912b.monitorThere(bus_to_bridge);
}

/// What is on the bridge's connector, for the library: whether a
/// monitor's EDID answers on the bridge's bus, and its blocks, as many
/// as there is room for. A monitor whose EDID the last look kept is
/// taken to be the one still there, and not read again (`edid_known`).
fn detect(board: *rtg.RtgBoard, asked: *rtg.RtgDetect) callconv(.c) i32 {
    const panel = panelOf(board);
    const bus_to_bridge = lt8912b.I2c.open(panel.sys, panel.own.i2c_unit) orelse return err.RTGERR_IO;
    defer bus_to_bridge.close();
    if (!lt8912b.monitorThere(bus_to_bridge)) return err.RTGERR_OK;
    asked.present = 1;
    if (asked.edid_known != 0) {
        asked.edid_size = asked.edid_known;
        return err.RTGERR_OK;
    }
    const block = rtg.modes.RTG_EDID_BLOCK;
    if (asked.edid_max < block) return err.RTGERR_OK;
    const first: *lt8912b.Edid = asked.edid[0..block];
    if (!lt8912b.readEdid(bus_to_bridge, 0, first)) return err.RTGERR_OK;
    asked.edid_size = block;
    const room_for_two = asked.edid_max >= 2 * block;
    if (first[126] != 0 and room_for_two and lt8912b.readEdid(bus_to_bridge, 1, asked.edid[block..][0..block])) asked.edid_size = 2 * block;
    return err.RTGERR_OK;
}

/// Whether the host sends `timings` to a monitor: a progressive picture
/// at 60 a second, of a size `sends.zig` has a timing for or of the
/// part's own.
fn checkMode(board: *rtg.RtgBoard, timings: *const rtg.RtgTimings) callconv(.c) i32 {
    const panel = panelOf(board);
    if (timings.flags & rtg.modes.RTGTM_INTERLACED != 0) return err.RTGERR_BAD_MODE;
    const line: u64 = @as(u64, timings.h_active) + timings.h_front + timings.h_sync + timings.h_back;
    const lines: u64 = @as(u64, timings.v_active) + timings.v_front + timings.v_sync + timings.v_back;
    if (line * lines == 0) return err.RTGERR_BAD_MODE;
    const millihertz = @as(u64, timings.pixel_clock_hz) * 1000 / (line * lines);
    if (millihertz < 59_500 or millihertz > 60_500) return err.RTGERR_BAD_MODE;
    // The table's rates are for its lanes: a part wired on fewer has its
    // own mode alone.
    if (sends.forSize(timings.h_active, timings.v_active) != null and panel.own.lanes == sends.lanes) return err.RTGERR_OK;
    const own = timings.h_active == panel.own.timing.width and timings.v_active == panel.own.timing.height;
    return if (own) err.RTGERR_OK else err.RTGERR_BAD_MODE;
}

/// `mode` in place of the part's own: the picture, its timings, the
/// pixel clock and the lanes' rate. The lanes stay the part's, which
/// `checkMode` has held to the ones the table's rates are for.
fn take(wanted: *config.Config, mode: *const sends.Mode) void {
    wanted.timing = mode.timing;
    wanted.lane_mbps = mode.lane_mbps;
}

/// The PSRAM's bus clock in MHz, as the board's list gives it (80 if it
/// does not).
fn psramMhz(driver: *rtg.RtgDriver) u32 {
    const default_mhz = 80;
    const eb = driver.expansion_base orelse return default_mhz;
    return @truncate(driver.rtg_base.GetRtgTagData(st.SYSTAG_PsramSpeed, default_mhz, eb.SystemTags()));
}

/// What the stream reads a second, on average: a frame's bytes, as often
/// as the pixel clock sends frames.
fn streamBytes(panel: *const Panel) u64 {
    const wanted = &panel.config;
    const line = wanted.timing.hsync + wanted.timing.hbp + wanted.timing.width + wanted.timing.hfp;
    const lines = wanted.timing.vsync + wanted.timing.vbp + wanted.timing.height + wanted.timing.vfp;
    const whole: u64 = @as(u64, line) * lines;
    if (whole == 0) return 0;
    return @as(u64, panel.stream_frame_bytes) * panel.pixel_hz / whole;
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    const panel = panelOf(board);
    giveBack(panel);
    engine_file.takeDown(&panel.engine);
    releaseLines(panel);
}

/// A panel has one mode, which `attach` brought up. Over HDMI the link is
/// brought up here, in this host's timing for the mode's size
/// (`sends.zig`), or the part's own: the bridge's copy taken, the PHY, the
/// bridge and the host set for it. A link that is up is taken down first
/// - for another mode, or for the mode it is in when another monitor
/// came - and shows nothing until the bands the library hands over with
/// the mode are shown.
fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode, _: *const rtg.RtgTimings) i32 {
    const panel = panelOf(board);
    if (!panel.hdmi) return err.RTGERR_OK;
    const sys = panel.sys;
    var wanted = panel.own;
    if (sends.forSize(mode.width, mode.height)) |sent| {
        take(&wanted, sent);
    } else if (mode.width != panel.own.timing.width or mode.height != panel.own.timing.height) {
        return err.RTGERR_BAD_MODE;
    }
    const lane = host.pllFor(wanted.lane_mbps) orelse return err.RTGERR_BAD_MODE;
    const bus_to_bridge = lt8912b.I2c.open(sys, wanted.i2c_unit) orelse return err.RTGERR_NO_DISPLAY;
    defer bus_to_bridge.close();

    // The copy goes and comes back another. Nothing is put into it
    // meanwhile: a show holds the board's compose lock.
    if (panel.up) giveBack(panel);
    panel.up = false;

    panel.config = wanted;
    sizeRows(panel);
    var code: i32 = err.RTGERR_NO_MEMORY;
    if (link_file.allocate(&panel.link, sys, wanted.timing.width, wanted.timing.height, .bgr24)) {
        panel.stream_pitch = panel.link.pitch;
        panel.stream_frame_bytes = panel.link.pitch * wanted.timing.height;
        code = bringUp(panel, bus_to_bridge, lane);
        if (code != err.RTGERR_OK) giveBack(panel);
    }
    panel.up = code == err.RTGERR_OK;
    if (code != err.RTGERR_OK) return code;
    panel.mode_id = mode.id;
    board.region.size = wanted.buffers * panel.frame_bytes;
    return err.RTGERR_OK;
}

/// The board's one op for what is on the glass (`RtgShow`): put in the
/// mode where the library says it is to be, then shown - the bands of the
/// screens' buffers streamed straight, the board's copy with the
/// library's picture in it, or nothing. With the mode set anew a show
/// that fails leaves the board showing nothing.
fn showOp(board: *rtg.RtgBoard, what: *const rtg.RtgShow) callconv(.c) i32 {
    const panel = panelOf(board);
    const anew = what.flags & rtg.boards.RTGSHOW_MODE_CHANGED != 0;
    if (anew) {
        const code = setMode(board, what.mode, what.timings);
        if (code != err.RTGERR_OK) return code;
    }
    const code = showThese(panel, what);
    if (code != err.RTGERR_OK and anew and panel.streaming) stopStream(panel);
    return code;
}

/// What a show asks for, in the mode the board is in. The first picture
/// starts the stream; with the stream running a show is a flip, sent from
/// the next frame on, whole, and this returns once the frame before it is
/// the last that reads what it replaced.
fn showThese(panel: *Panel, what: *const rtg.RtgShow) i32 {
    const sys = panel.sys;
    // A bridge's link comes up with the board's mode.
    if (!panel.up) return err.RTGERR_NO_MODE;
    const bands = what.bands orelse &[0]rtg.RtgBand{};
    if (what.count == 0) {
        if (panel.streaming) stopStream(panel);
        panel.from_copy = false;
        return err.RTGERR_OK;
    }
    if (what.flags & rtg.boards.RTGSHOW_DIRECT != 0) {
        // The screens' buffers, each band a run of display lines whose
        // rows are a line each: the library has checked them.
        const code = stream(panel, bands[0..what.count]);
        if (code == err.RTGERR_OK) panel.from_copy = false;
        return code;
    }
    // The board's own picture: the copy, which a panel makes the first
    // time it is asked for, filled whole with what the library composes.
    if (panel.link.pixels == 0) {
        if (!link_file.allocate(&panel.link, sys, panel.config.timing.width, panel.config.timing.height, .rgb565)) return err.RTGERR_NO_MEMORY;
    }
    const whole = rtg.RtgRect{ .width = @intCast(panel.config.timing.width), .height = @intCast(panel.config.timing.height) };
    const filled = link_file.fill(&panel.link, &panel.engine, sys, panel.board, &whole, panel.streaming);
    if (filled != err.RTGERR_OK) return filled;
    // A stream that reads the copy already sends what was just put into
    // it: its chain stays, and there is no frame to wait for.
    if (panel.streaming and panel.from_copy) return err.RTGERR_OK;
    const copy = [_]rtg.RtgBand{.{ .bitmap = &panel.link.whole }};
    const code = stream(panel, &copy);
    if (code == err.RTGERR_OK) panel.from_copy = true;
    return code;
}

/// A rectangle of the display changed while the stream reads the copy:
/// fetched from the library into it.
fn update(board: *rtg.RtgBoard, area: *const rtg.RtgRect) callconv(.c) i32 {
    const panel = panelOf(board);
    if (!panel.up) return err.RTGERR_NO_MODE;
    return link_file.fill(&panel.link, &panel.engine, panel.sys, board, area, panel.streaming);
}

/// A panel asleep, or awake again: its own display off, by its DCS
/// command, and the backlight off; the display on and the backlight as
/// the library keeps it. The stream runs on, and the picture is black
/// meanwhile, which is the library's.
fn power(board: *rtg.RtgBoard, state: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    const asleep = state == rtg.boards.RTGPWR_ASLEEP;
    if (asleep) _ = drive(panel, panel.config.backlight_pin, false);
    if (!host.dcsWrite(panel.sys, if (asleep) DISPOFF else DISPON, &.{})) return err.RTGERR_NO_DISPLAY;
    if (!asleep) _ = drive(panel, panel.config.backlight_pin, board.info.brightness != 0);
    return @intCast(if (asleep) rtg.boards.RTGPWR_ASLEEP else rtg.boards.RTGPWR_ON);
}

/// The backlight, on for anything above 0: its line is on or off.
fn setBrightness(board: *rtg.RtgBoard, percent: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    if (!switched(panel.config.backlight_pin)) return err.RTGERR_NOT_SUPPORTED;
    return if (drive(panel, panel.config.backlight_pin, percent > 0)) err.RTGERR_OK else err.RTGERR_IO;
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

/// Of the engine: fills, copies, blends and scales (`engine.zig`).
const engine_ops = rtg.RtgEngineOps{
    .fill_rect = &fillRect,
    .copy_rect = &copyRect,
    .blend_pixels = &blendPixels,
    .blend_rect = &blendRect,
    .scale_pixels = &scalePixels,
};

/// What a panel's board has. Its stream reads the screens itself, and a
/// copy the library composes while something lies over the picture: the
/// bands in it, the overlay and the pointer are the library's.
const ops = rtg.RtgBoardOps{
    .destroy = &destroy,
    .show = &showOp,
    .update = &update,
    .power = &power,
    .set_brightness = &setBrightness,
    .stats = &stats,
    .control = &control,
    .engine = &engine_ops,
};

/// A bridge's board has a connector, and its stream reads the copy
/// alone. The monitor behind it is not put to
/// sleep from here and has no backlight of the board's: a board asleep
/// is blank there.
const bridge_ops = made: {
    var more = ops;
    more.power = null;
    more.set_brightness = null;
    more.detect = &detect;
    more.check_mode = &checkMode;
    break :made more;
};

/// The same two for a board whose engine's channels were not to be had.
const ops_no_engine = made: {
    var less = ops;
    less.engine = null;
    break :made less;
};

const bridge_ops_no_engine = made: {
    var less = bridge_ops;
    less.engine = null;
    break :made less;
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

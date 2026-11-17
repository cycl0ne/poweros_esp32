// SPDX-License-Identifier: MPL-2.0
//! A display controller that keeps its own picture and speaks MIPI DCS -
//! CASET, RASET, RAMWR, MADCTL - over a command bus, as a display board.
//!
//! A module of its own: a description of a driver called "dcs" behind a
//! ROM tag, which rtg.library puts on its list. It takes a panel on a
//! command bus (`BUS_SPI`): offered one, it opens the bus the panel sits
//! on (`OpenTransport`, which a transport driver makes from the same
//! tags) and makes its board on it. Everything that makes one controller
//! differ from the next arrives as tags: the bring-up the panel's maker
//! gives, the MADCTL values that set it upright and on its side, and the
//! alignment its windows keep. So another controller of this kind is
//! another tag list and not another driver.
//!
//! The picture lives in PSRAM, as display memory the library cuts buffers
//! out of, and the controller holds a picture of its own, which nothing
//! reaches but what is sent. So the board is one whose picture
//! rtg.library composes: it is told which rectangle of the display
//! changed (`update`) - something drawn, a pointer moved, a screen pulled
//! down - and sends it. The rectangle is widened to the controller's
//! alignment, each way, and goes over the bus in bands, each band given
//! its own window and a RAMWR. A band's pixels are fetched from the
//! library (`ComposeLines`) - the bands of the picture, the overlay and
//! the pointer over them - straight into a buffer in internal memory,
//! which is where the DMA behind the bus reads from, and turned round in
//! it: the bus sends each pixel high byte first, which is not how memory
//! holds RGB565.
//!
//! Nothing is sent that nobody asked for: there is no stream, so the board
//! reports no RTGBF_STREAMING, and what is written into a buffer no band
//! shows is not sent at all until it is shown.
//!
//! A picture on its side, on a controller that cannot exchange its own
//! axes, is turned on its way: the panel's window for the rectangle is
//! worked out, each band of it fetched as the rectangle of the picture it
//! shows, and that turned into the band.
//!
//! The picture mirrored (MirrorBoard) is the controller's own scan
//! direction: MADCTL's two address-order bits, set over the value the
//! mode has - the columns' bit for the picture's left and right while it
//! lies upright, the rows' bit while it lies on its side, and the other
//! for top and bottom. The controller then takes every window mirrored,
//! so the whole picture is sent again, which the library asks for.
//!
//! Asleep (SetBoardPower) is the controller's display off and the
//! backlight off; the picture it holds stays, and waking is the display
//! on again and the backlight as the library keeps it. A blank picture
//! is the library's: black, sent like any other.
//!
//! What the bus asks of a band: it lies in internal memory, where the
//! bus's DMA reads without the cache between, and it is no longer than
//! the bus carries in one transaction (the QSPI bus: 32 KiB). A band here
//! is `band_bytes`, half of that, so two of them are never one run.

const std = @import("std");
const sdk = @import("sdk");
const BoardPin = sdk.expansion.BoardPin;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const err = rtg.errors;
const tags = rtg.tags;

const sequence = @import("sequence.zig");
const st = sdk.expansion.systemtags;
const gpio = sdk.hardware.gpio;

const MODULE_NAME = "rtg-dcs";
const DRIVER_NAME = "dcs";
const VERSION = 1;
const REVISION = 13;
const BUILD_DATE = "17.11.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

// The DCS commands this driver sends of its own accord.
const SWRESET = 0x01;
const DISPOFF = 0x28;
const DISPON = 0x29;
const CASET = 0x2A;
const RASET = 0x2B;
const RAMWR = 0x2C;
const MADCTL = 0x36;

/// MADCTL's address-order bits: the rows', and the columns'.
const MADCTL_MY: u8 = 0x80;
const MADCTL_MX: u8 = 0x40;

/// The buffer a band is fetched into and sent from, in internal memory.
const band_bytes = 16 * 1024;

/// What an absent tag reads as, where 0 is a real value.
const absent = std.math.maxInt(usize);

/// What one board keeps.
const Panel = struct {
    sys: *ExecBase,
    rtg_base: *RtgDriverBase,
    io: *rtg.RtgTransport,
    /// The bus, for a band's window and its pixels and for a command on
    /// its own: one task at a time (`sendBand`). A semaphore - a band is
    /// about a millisecond, and a transport on a bus device waits for it.
    bus_lock: exec.SignalSemaphore = .{},
    /// Upright, and on its side when the controller can be turned: the
    /// MADCTL value of each, and whether the board has the second.
    madctl: [2]u8 = .{ 0, 0 },
    turns: bool = false,
    /// Whether the mode it is in is the one on its side, and how the
    /// picture is mirrored: what MADCTL is made of (`madctlNow`).
    on_its_side: bool = false,
    mirror_x: bool = false,
    mirror_y: bool = false,
    /// The size of the mode it is in, which is what a window is cut from,
    /// and the panel's own, which is what the controller scans.
    width: u32 = 0,
    height: u32 = 0,
    native_width: u32 = 0,
    native_height: u32 = 0,
    /// How the picture is laid on the panel: turned, for a mode whose
    /// size is the panel's the other way round on a controller that
    /// cannot exchange its own axes.
    turn: sequence.Turn = .none,
    /// The turn that mode asks for, .none when the controller does it
    /// itself with MADCTL.
    swapped_turn: sequence.Turn = .none,
    alignment: u32 = 1,
    backlight: BoardPin = .{},
    /// The panel's lines that are pads of the chip - its reset and its
    /// backlight - taken from gpio.resource while the board exists.
    gpio_base: ?*GpioBase = null,
    held_pads: [2]u8 = .{ 0, 0 },
    held_count: u8 = 0,
    band: ?[*]align(4) u8 = null,
    /// How many bytes the band holds.
    band_size: u32 = band_bytes,
    /// Where a rectangle of a picture on its side is fetched, before it
    /// is turned into the band: as large as the band, in any memory -
    /// only the CPU reads it. Null on a panel that turns nothing.
    upright: ?[*]u8 = null,
    stats: rtg.RtgBoardStats = .{},

    /// A bit per picture row, set when a rectangle with that row in it is
    /// sent. It is what tells a row nobody handed on from a row that was
    /// handed on and sent with the wrong pixels in it: the two look the
    /// same on the glass and have nothing else to tell them apart.
    asked: [rows_marked / 8]u8 = @splat(0),
};

/// The rows the marks cover, which is more than any mode this board has.
const rows_marked = 512;

fn panelOf(board: *rtg.RtgBoard) *Panel {
    return @ptrCast(@alignCast(board.instance.?));
}

/// A panel on a command bus is offered: its bus opened, the controller
/// brought up, and a board made of it. Whatever fails, the bus and the
/// board are given back.
fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const rb = driver.rtg_base;
    // What has to be there, looked at before anything is taken.
    const size = sizeOf(rb, tag_list);
    if (sequenceOf(rb, tag_list) == null) return err.RTGERR_BAD_TAGS;
    if (size.width == 0 or size.height == 0) return err.RTGERR_BAD_TAGS;
    // The controller is sent RGB565 and nothing else.
    const format = rb.GetRtgTagData(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.rgb565), tag_list);
    if (format != @intFromEnum(rtg.PixelFormat.rgb565)) return err.RTGERR_BAD_FORMAT;

    // The bus the controller sits on, made from the same tags.
    const io = rb.OpenTransport(driver, device) orelse return err.RTGERR_NO_DISPLAY;
    // The controller reads no buffer itself: its picture is sent, and
    // the library composes it.
    const board = rb.CreateBoard(driver, device, &.{
        .ops = &ops,
        .instance_size = @sizeOf(Panel),
        // The controller's scan direction turns either axis.
        .caps = rtg.boards.RTGBC_MIRROR_X | rtg.boards.RTGBC_MIRROR_Y,
    }) orelse {
        rb.CloseTransport(io);
        return err.RTGERR_NO_MEMORY;
    };
    const code = bringUpBoard(driver, board, io, tag_list);
    if (code != err.RTGERR_OK) {
        rb.DeleteBoard(board);
        rb.CloseTransport(io);
    }
    return code;
}

/// The panel's size, as its tags give it; 0 where they give none.
fn sizeOf(rb: *RtgDriverBase, tag_list: ?[*]const TagItem) struct { width: u32, height: u32 } {
    return .{
        .width = @truncate(rb.GetRtgTagData(tags.RTGA_Width, 0, tag_list)),
        .height = @truncate(rb.GetRtgTagData(tags.RTGA_Height, 0, tag_list)),
    };
}

/// The controller's bring-up, as its tags give it; null where they give
/// none.
fn sequenceOf(rb: *RtgDriverBase, tag_list: ?[*]const TagItem) ?[]const u8 {
    const init_at = rb.GetRtgTagData(tags.RTGA_InitSequence, 0, tag_list);
    const init_length = rb.GetRtgTagData(tags.RTGA_InitLength, 0, tag_list);
    if (init_at == 0) return null;
    return @as([*]const u8, @ptrFromInt(init_at))[0..init_length];
}

/// The board's panel filled in from the tags, which `attach` has looked
/// at, and brought up on its bus. On any answer but RTGERR_OK it has
/// given back what it took, the bus and the board excepted, which are the
/// caller's to give back.
fn bringUpBoard(driver: *rtg.RtgDriver, board: *rtg.RtgBoard, io: *rtg.RtgTransport, tag_list: ?[*]const TagItem) i32 {
    const sys = driver.sys_base;
    const rb = driver.rtg_base;
    const size = sizeOf(rb, tag_list);
    const width = size.width;
    const height = size.height;
    const bring_up = sequenceOf(rb, tag_list) orelse return err.RTGERR_BAD_TAGS;
    const panel = panelOf(board);
    panel.* = .{
        .sys = sys,
        .rtg_base = rb,
        .io = io,
        .width = width,
        .height = height,
        .native_width = width,
        .native_height = height,
    };
    sys.InitSemaphore(&panel.bus_lock);
    panel.alignment = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_DCS_Align, 1, tag_list))), 1);
    if (width % panel.alignment != 0 or height % panel.alignment != 0) return err.RTGERR_BAD_TAGS;
    panel.madctl[0] = @truncate(rb.GetRtgTagData(tags.RTGA_DCS_Madctl, 0, tag_list));
    const swapped = rb.GetRtgTagData(tags.RTGA_DCS_SwappedMadctl, absent, tag_list);
    // A controller that cannot exchange its own axes still has the mode,
    // if the driver turns every band on its way out: which quarter turn
    // says which way round.
    panel.swapped_turn = switch (rb.GetRtgTagData(tags.RTGA_DCS_SwappedTurn, 0, tag_list)) {
        0 => .none,
        90 => .clockwise,
        270 => .counter_clockwise,
        else => return err.RTGERR_BAD_TAGS,
    };
    if (swapped != absent and panel.swapped_turn != .none) return err.RTGERR_BAD_TAGS;
    // The part's own lines, from its PART_Pin* tags; absent: not wired.
    panel.backlight = BoardPin.of(rb.GetRtgTagData(st.PART_PinBacklight, 0, tag_list));
    // A backlight on a pad is on or off; any other is not this driver's
    // to set, and the board says it has none.
    board.info.brightness_steps = if (panel.backlight.kind == sdk.expansion.boardpin.BPIN_GPIO) 2 else 0;
    const reset_pin = BoardPin.of(rb.GetRtgTagData(st.PART_PinReset, 0, tag_list));
    const reset_ms: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_ResetMillis, 10, tag_list));
    const settle_ms: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_SettleMillis, 120, tag_list));
    if (!takePads(panel, reset_pin)) return err.RTGERR_IN_USE;

    // The memory first: a panel brought up with nowhere to draw is no use.
    // The band is what the bus's DMA reads: internal memory.
    const side = @max(width, height);
    const band = sys.AllocVec(band_bytes, exec.MEMF_INTERNAL | exec.MEMF_DMA) orelse {
        giveBack(panel);
        return err.RTGERR_NO_MEMORY;
    };
    panel.band = @ptrCast(@alignCast(band));
    // One alignment of rows of the longer side is the least a band is.
    if (sequence.bandRows(band_bytes, side * 2, panel.alignment) * side * 2 > band_bytes) {
        giveBack(panel);
        return err.RTGERR_BAD_TAGS;
    }
    // A picture the driver turns is fetched upright first, which the CPU
    // alone reads: any memory will do.
    if (panel.swapped_turn != .none) {
        panel.upright = @ptrCast(sys.AllocVec(band_bytes, exec.MEMF_ANY) orelse {
            giveBack(panel);
            return err.RTGERR_NO_MEMORY;
        });
    }
    const frame_bytes = @as(usize, width) * height * 2;
    // As many pictures as the board asks for (`RTGA_Buffers`) at once, each
    // taken by the library as it is asked for.
    const frames = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list))), 1);

    // Dark until there is a picture, then out of reset and through the
    // maker's bring-up.
    setBacklight(panel, false);
    const code = bringUp(panel, reset_pin, reset_ms, settle_ms, bring_up);
    if (code != err.RTGERR_OK) {
        giveBack(panel);
        return code;
    }

    // Upright, which it comes up in, and on its side where the
    // controller or the driver turns the picture. A controller behind a
    // bus has no clock: a mode is its size.
    const rgb565 = @intFromEnum(rtg.PixelFormat.rgb565);
    const upright: rtg.RtgTimings = .{ .h_active = width, .v_active = height };
    var added = rb.AddBoardMode(board, &upright, rgb565, rtg.modes.RTGMF_DEFAULT) != 0;
    if (swapped != absent or panel.swapped_turn != .none) {
        panel.madctl[1] = if (swapped != absent) @truncate(swapped) else panel.madctl[0];
        panel.turns = true;
        const on_its_side: rtg.RtgTimings = .{ .h_active = height, .v_active = width };
        added = added and rb.AddBoardMode(board, &on_its_side, rgb565, rtg.modes.RTGMF_TURNED) != 0;
    }
    if (!added) {
        giveBack(panel);
        return err.RTGERR_NO_MEMORY;
    }

    board.region = .{
        .size = frames * frame_bytes,
        .alignment = sdk.hardware.DCACHE_LINE_SIZE,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED | rtg.boards.RTGRF_SYSTEM_MEMORY,
    };
    board.info.buffers = frames;
    return err.RTGERR_OK;
}

/// The controller out of reset - its own line if it has one, the command
/// if not - and every step of the bring-up, each with its wait. The
/// waits give the CPU away (`RtgDelay`): some 250 ms on the 3.5" board.
fn bringUp(panel: *Panel, reset_pin: BoardPin, reset_ms: u32, settle_ms: u32, bring_up: []const u8) i32 {
    const rb = panel.rtg_base;
    if (reset_pin.kind == sdk.expansion.boardpin.BPIN_GPIO) {
        const asserted = reset_pin.active_low == 0;
        gpio.toMatrix(reset_pin.number);
        gpio.connectOut(reset_pin.number, gpio.out_of_gpio, true);
        gpio.outputEnable(reset_pin.number, true);
        gpio.setLevel(reset_pin.number, asserted);
        rb.RtgDelay(reset_ms * 1000);
        gpio.setLevel(reset_pin.number, !asserted);
    } else {
        const code = rb.TxParam(panel.io, SWRESET, null, 0);
        if (code != err.RTGERR_OK) return code;
    }
    rb.RtgDelay(settle_ms * 1000);

    var hook: utility.Hook = .{ .entry = &sendStep, .data = panel };
    return rb.RunPanelSequence(bring_up.ptr, @intCast(bring_up.len), &hook);
}

/// One step of the bring-up, sent on the panel's bus: `RunPanelSequence`'s
/// hook, whose data is the panel.
fn sendStep(hook: *utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const panel: *Panel = @ptrCast(@alignCast(hook.data.?));
    const step: *const rtg.RtgPanelStep = @ptrCast(@alignCast(message.?));
    const code = panel.rtg_base.TxParam(panel.io, @intCast(step.command), step.params, step.count);
    return @bitCast(@as(isize, code));
}

/// The panel's lines that are pads of the chip, taken from gpio.resource.
/// False if another driver holds one; a machine without the resource
/// takes nothing.
fn takePads(panel: *Panel, reset_pin: BoardPin) bool {
    const sys = panel.sys;
    const gb: *GpioBase = @ptrCast(@alignCast(sys.OpenResource(gpio_resource.GPIONAME) orelse return true));
    var count: u8 = 0;
    for ([_]BoardPin{ reset_pin, panel.backlight }) |line| {
        if (line.kind != sdk.expansion.boardpin.BPIN_GPIO) continue;
        panel.held_pads[count] = line.number;
        count += 1;
    }
    if (gpio_resource.allocPads(gb, panel.held_pads[0..count], MODULE_NAME)) |refused| {
        exec.kprintf(sys, "%s: GPIO%d is %s's\n", .{ MODULE_NAME, refused.pad, refused.holder });
        return false;
    }
    panel.gpio_base = gb;
    panel.held_count = count;
    return true;
}

fn giveBack(panel: *Panel) void {
    if (panel.gpio_base) |gb| gpio_resource.freePads(gb, panel.held_pads[0..panel.held_count]);
    panel.gpio_base = null;
    panel.held_count = 0;
    if (panel.band) |band| panel.sys.FreeVec(band);
    panel.band = null;
    if (panel.upright) |upright| panel.sys.FreeVec(upright);
    panel.upright = null;
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    const panel = panelOf(board);
    setBacklight(panel, false);
    giveBack(panel);
    // The bus it opened goes with the board.
    panel.rtg_base.CloseTransport(panel.io);
}

/// The mode is a way up: MADCTL says which, and the windows are cut from
/// its size from here on.
fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode, _: *const rtg.RtgTimings) i32 {
    const panel = panelOf(board);
    const turned = mode.flags & rtg.modes.RTGMF_TURNED != 0;
    if (turned and !panel.turns) return err.RTGERR_BAD_MODE;
    const value = madctlFor(panel, turned, panel.mirror_x, panel.mirror_y);
    const code = command(panel, MADCTL, &value, 1);
    if (code != err.RTGERR_OK) return code;
    panel.on_its_side = turned;
    panel.width = mode.width;
    panel.height = mode.height;
    panel.turn = if (turned) panel.swapped_turn else .none;
    return err.RTGERR_OK;
}

/// MADCTL for a mode and a mirror: the mode's own value, with an
/// address order turned for each axis mirrored. Upright, the picture's
/// columns are the controller's; on its side - by the controller's own
/// exchange or by this driver's turn - they are its rows.
fn madctlFor(panel: *const Panel, on_its_side: bool, mirror_x: bool, mirror_y: bool) u8 {
    var value = panel.madctl[@intFromBool(on_its_side)];
    const across: u8 = if (on_its_side) MADCTL_MY else MADCTL_MX;
    const down: u8 = if (on_its_side) MADCTL_MX else MADCTL_MY;
    if (mirror_x) value ^= across;
    if (mirror_y) value ^= down;
    return value;
}

/// The picture mirrored about each axis by the controller's scan
/// direction. The picture it holds was written the other way round: the
/// library has the whole of it sent again once this has answered.
fn mirror(board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) callconv(.c) i32 {
    const panel = panelOf(board);
    const value = madctlFor(panel, panel.on_its_side, mirror_x, mirror_y);
    const code = command(panel, MADCTL, &value, 1);
    if (code != err.RTGERR_OK) return code;
    panel.mirror_x = mirror_x;
    panel.mirror_y = mirror_y;
    return err.RTGERR_OK;
}

/// The board's one op for what is on the glass (`RtgShow`): put in the
/// mode where the library says it is to be, then sent the whole picture,
/// which the library composes of the show's bands - they are in place
/// while it is sent. The controller has no second picture to flip to, so
/// a show is a whole picture sent; nothing shown sends nothing, and the
/// controller keeps the picture it has. A send the bus refuses is the
/// show's answer: what it leaves on the glass is part old and part new
/// (`failed_sends`), and stays so until those rows are sent again.
fn showOp(board: *rtg.RtgBoard, what: *const rtg.RtgShow) callconv(.c) i32 {
    const panel = panelOf(board);
    if (what.flags & rtg.boards.RTGSHOW_MODE_CHANGED != 0) {
        const code = setMode(board, what.mode, what.timings);
        if (code != err.RTGERR_OK) return code;
    }
    if (what.count == 0) return err.RTGERR_OK;
    return send(board, .{ .left = 0, .top = 0, .right = panel.width, .end = panel.height });
}

/// A rectangle of the display changed: sent. It goes where this stands,
/// on the caller's own task, so the picture that reaches the panel is the
/// one the caller had when it asked. A send of its own, on a task of its
/// own, would read the buffer while the caller was still writing it and
/// put a half-written row on the glass - which is what a caller gathering
/// its drawing into one hand-on (graphics.library's BeginDraw) is taking
/// trouble to avoid.
fn update(board: *rtg.RtgBoard, area: *const rtg.RtgRect) callconv(.c) i32 {
    const panel = panelOf(board);
    const box = sequence.Box{
        .left = @intCast(area.x),
        .top = @intCast(area.y),
        .right = @intCast(area.x + area.width),
        .end = @intCast(area.y + area.height),
    };
    panel.stats.refreshes +%= 1;
    panel.stats.rows_refreshed +%= box.rows();
    markAsked(panel, box.top, box.end);
    return send(board, box);
}

/// Rows `top` to `end` marked as asked for.
fn markAsked(panel: *Panel, top: u32, end: u32) void {
    var row = top;
    while (row < end and row < rows_marked) : (row += 1) {
        panel.asked[row / 8] |= @as(u8, 1) << @intCast(row % 8);
    }
}

/// A rectangle of the picture to the panel, upright or turned: the
/// panel's window that holds it, in bands of whole alignments, each with
/// its window. A count of the sends that did not get there.
fn send(board: *rtg.RtgBoard, box: sequence.Box) i32 {
    const panel = panelOf(board);
    // Where the rectangle lies on the panel, as a window the controller
    // takes.
    const on_panel = sequence.onPanel(panel.turn, box, panel.width, panel.height);
    const window = sequence.aligned(on_panel, panel.native_width, panel.native_height, panel.alignment);
    const row_bytes = window.columns() * 2;
    const per_band = sequence.bandRows(panel.band_size, row_bytes, panel.alignment);
    var row = window.top;
    while (row < window.end) {
        const count = @min(per_band, window.end - row);
        const code = sendBand(board, .{ .left = window.left, .top = row, .right = window.right, .end = row + count });
        if (!goesOn(code)) {
            // A send that stopped part way has told the panel a window
            // and then not filled it, so what is on the glass is part
            // old and part new.
            panel.stats.failed_sends +%= 1;
            return code;
        }
        row += count;
    }
    panel.stats.frames +%= 1;
    return err.RTGERR_OK;
}

/// One band of the panel fetched and sent, one task at a time on the
/// bus: the rectangle of the picture it shows as the library composes
/// it, turned the way the bus carries it - and the way the panel lies,
/// for a picture on its side - then its window and its pixels.
///
/// The band is the board's only one. The library has one task at a time
/// in here - a show, a hand-on and a pointer's move each hold the board's
/// compose lock - so it is filled and sent whole. The bus's own lock
/// keeps a command sent on its own (`command`) from landing between the
/// band's window and its pixels: a transaction set up on the bus and
/// then set aside would have its registers written over.
///
/// The window is set per band rather than once per send: each band says
/// where it goes.
fn sendBand(board: *rtg.RtgBoard, band_box: sequence.Box) i32 {
    const panel = panelOf(board);
    const rb = panel.rtg_base;
    const band = panel.band orelse return err.RTGERR_NO_MEMORY;
    const bytes = band_box.columns() * band_box.rows() * 2;
    const columns = windowBytes(band_box.left, band_box.right - 1);
    const lines = windowBytes(band_box.top, band_box.end - 1);

    panel.sys.ObtainSemaphore(&panel.bus_lock);
    defer panel.sys.ReleaseSemaphore(&panel.bus_lock);
    if (panel.turn == .none) {
        // Straight into the band, and turned round where it lies.
        const code = rb.ComposeLines(board, &rectOf(band_box), band, band_box.columns() * 2);
        if (code != err.RTGERR_OK) return code;
        sequence.swapPixels(band[0..bytes], band[0..bytes]);
    } else {
        // The picture's rectangle this band shows, upright, then turned
        // into the band.
        const upright = panel.upright orelse return err.RTGERR_NO_MEMORY;
        const from = sequence.ofPicture(panel.turn, band_box, panel.width, panel.height);
        const code = rb.ComposeLines(board, &rectOf(from), upright, from.columns() * 2);
        if (code != err.RTGERR_OK) return code;
        sequence.turnInto(band[0..bytes], upright[0..bytes], from.columns(), from.rows(), panel.turn);
    }
    return writeBand(panel, rb, &columns, &lines, band, bytes);
}

/// A rectangle as the library takes one.
fn rectOf(box: sequence.Box) rtg.RtgRect {
    return .{ .x = @intCast(box.left), .y = @intCast(box.top), .width = @intCast(box.columns()), .height = @intCast(box.rows()) };
}

/// How often a band whose transfer ran dry is sent again before its rows
/// are left wrong on the glass.
const underrun_tries = 3;

/// A filled band to the controller: its window, then its pixels. A
/// transfer the DMA fell behind in is counted and sent again - the band
/// is still in its buffer and says where it goes, so a second go lands
/// on the same pixels. The caller holds the bus's lock.
fn writeBand(
    panel: *Panel,
    rb: *RtgDriverBase,
    columns: *const [4]u8,
    lines: *const [4]u8,
    band: [*]align(4) const u8,
    bytes: u32,
) i32 {
    var tries: u32 = 0;
    while (true) {
        const set_columns = rb.TxParam(panel.io, CASET, columns, columns.len);
        if (set_columns != err.RTGERR_OK) return set_columns;
        const set_rows = rb.TxParam(panel.io, RASET, lines, lines.len);
        if (set_rows != err.RTGERR_OK) return set_rows;
        const code = rb.TxColor(panel.io, RAMWR, band, bytes);
        if (code != err.RTGERR_UNDERRUN) return code;
        panel.stats.underruns += 1;
        tries += 1;
        if (tries == underrun_tries) return code;
    }
}

/// Whether a band's send lets the rest go on: it got there, or every
/// try of it ran dry. That band's rows are wrong on the glass, but its
/// window was filled, so the bands after it land where they belong.
fn goesOn(code: i32) bool {
    return code == err.RTGERR_OK or code == err.RTGERR_UNDERRUN;
}

/// A CASET or RASET's parameters: the first and the last, high byte first.
fn windowBytes(first: u32, last: u32) [4]u8 {
    return .{ @truncate(first >> 8), @truncate(first), @truncate(last >> 8), @truncate(last) };
}

/// Asleep, or awake again: the controller's display off and the
/// backlight off; the display on and the backlight as the library keeps
/// it. The picture the controller holds stays through it.
fn power(board: *rtg.RtgBoard, state: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    const asleep = state == rtg.boards.RTGPWR_ASLEEP;
    if (asleep) setBacklight(panel, false);
    const code = command(panel, if (asleep) DISPOFF else DISPON, null, 0);
    if (code != err.RTGERR_OK) return if (code < 0) code else err.RTGERR_IO;
    if (!asleep) setBacklight(panel, board.info.brightness != 0);
    return @intCast(if (asleep) rtg.boards.RTGPWR_ASLEEP else rtg.boards.RTGPWR_ON);
}

/// A command on its own, under the bus's lock as a band is: a transaction
/// set up on the bus and then set aside would have its registers written
/// over by another task's band before it started.
fn command(panel: *Panel, cmd: i32, params: ?*const anyopaque, size: u32) i32 {
    panel.sys.ObtainSemaphore(&panel.bus_lock);
    defer panel.sys.ReleaseSemaphore(&panel.bus_lock);
    return panel.rtg_base.TxParam(panel.io, cmd, params, size);
}

/// The backlight: a pad that lights it or not. Any brightness above 0 is
/// on.
fn setBrightness(board: *rtg.RtgBoard, percent: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    if (panel.backlight.kind != sdk.expansion.boardpin.BPIN_GPIO) return err.RTGERR_NOT_SUPPORTED;
    setBacklight(panel, percent != 0);
    return err.RTGERR_OK;
}

fn setBacklight(panel: *Panel, on: bool) void {
    const pin = panel.backlight;
    if (pin.kind != sdk.expansion.boardpin.BPIN_GPIO) return;
    gpio.toMatrix(pin.number);
    gpio.connectOut(pin.number, gpio.out_of_gpio, true);
    gpio.outputEnable(pin.number, true);
    gpio.setLevel(pin.number, on != (pin.active_low != 0));
}

fn stats(board: *rtg.RtgBoard, out: *rtg.RtgBoardStats) callconv(.c) void {
    out.* = panelOf(board).stats;
}

fn control(board: *rtg.RtgBoard, what: u32, value: isize) callconv(.c) isize {
    const panel = panelOf(board);
    return switch (what) {
        rtg.boards.RTGCTRL_RESET_STATS => blk: {
            panel.stats = .{};
            break :blk err.RTGERR_OK;
        },
        tags.RTGCTRL_DCS_ROW_ASKED => blk: {
            if (value < 0 or value >= rows_marked) break :blk 0;
            const row: usize = @intCast(value);
            break :blk if (panel.asked[row / 8] & (@as(u8, 1) << @intCast(row % 8)) != 0) 1 else 0;
        },
        tags.RTGCTRL_DCS_FORGET_ROWS => blk: {
            panel.asked = @splat(0);
            break :blk err.RTGERR_OK;
        },
        else => err.RTGERR_NOT_SUPPORTED,
    };
}

/// What this board has. Its picture is sent: `update` is how it hears of
/// what changed, and the bands, the overlay and the pointer are the
/// library's. No engine: the controller draws nothing, so a caller that
/// wants a rectangle filled fills it in the buffer itself. A quarter turn
/// is a mode; mirrored is the controller's scan direction.
const ops = rtg.RtgBoardOps{
    .destroy = &destroy,
    .show = &showOp,
    .update = &update,
    .power = &power,
    .set_brightness = &setBrightness,
    .mirror = &mirror,
    .stats = &stats,
    .control = &control,
};

const driver_ops = rtg.RtgDriverOps{ .attach = &attach };

/// What it takes: a panel reached over a command bus on SPI.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_BUS, .bus = sdk.expansion.systemtags.BUS_SPI },
    .{},
};

/// The driver's tag: a description and no init. rtg.library reads it at
/// its own init and puts the driver on its list; nothing of this module
/// runs until a board is asked for.
export const rtg_dcs_tag: rtg.ResidentRtgDriver linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&rtg_dcs_tag),
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

// --- tests (host: ./zig build test) -----------------------------------------
//
// A board of this driver cannot be made by its own attach on the host:
// that drives pads and waits on the chip's timer. So the tests have a
// driver of their own offered a device - it makes a board with this
// driver's ops and fills its panel in as the bring-up leaves it - and a
// bus of their own behind it, which keeps what a controller would: the
// window it was last told and the pixels sent into it. The tests then
// call the library as a program does, and read the glass.

const testing = std.testing;
const kexec = @import("../../exec/exec.zig");
const kutility = @import("../../utility/utility.zig");
const krtg = @import("../../rtg/rtg.zig");

/// The tests' panel: 8 by 8, or 8 wide and 4 high on a panel 4 wide and
/// 8 tall, and the controller's memory for it.
const Glass = struct {
    const side = 8;
    /// The controller's picture, as the bus sent it: high byte first.
    pixels: [side * side * 2]u8 = @splat(0),
    /// The window it was last told.
    columns: [2]u32 = .{ 0, 0 },
    lines: [2]u32 = .{ 0, 0 },
    /// Runs of pixels asked for, and which of them - counted from 1 - is
    /// refused; 0 refuses none.
    runs: u32 = 0,
    refuse_at: u32 = 0,
    /// The windows of the last runs, as (left, top, right, end).
    windows: [8]sequence.Box = undefined,
    /// How the next board is made: its panel's size, its turn, its
    /// alignment.
    native_width: u32 = side,
    native_height: u32 = side,
    turn: sequence.Turn = .none,
    alignment: u32 = 1,
    board: ?*rtg.RtgBoard = null,

    var glass: Glass = .{};

    /// The pixel the panel shows at its column and row, as memory holds
    /// RGB565.
    fn at(column: u32, row: u32) u16 {
        const pixel = glass.pixels[(row * glass.native_width + column) * 2 ..];
        return @as(u16, pixel[0]) << 8 | pixel[1];
    }

    fn txParam(_: *rtg.RtgTransport, cmd: i32, param: ?*const anyopaque, size: u32) callconv(.c) i32 {
        if (cmd != CASET and cmd != RASET) return err.RTGERR_OK;
        if (size != 4) return err.RTGERR_BAD_ARG;
        const bytes: [*]const u8 = @ptrCast(param.?);
        const range = [2]u32{ @as(u32, bytes[0]) << 8 | bytes[1], @as(u32, bytes[2]) << 8 | bytes[3] };
        if (cmd == CASET) glass.columns = range else glass.lines = range;
        return err.RTGERR_OK;
    }

    fn txColor(_: *rtg.RtgTransport, cmd: i32, color: ?*const anyopaque, size: u32) callconv(.c) i32 {
        if (cmd != RAMWR) return err.RTGERR_BAD_ARG;
        glass.windows[glass.runs % glass.windows.len] = .{ .left = glass.columns[0], .top = glass.lines[0], .right = glass.columns[1] + 1, .end = glass.lines[1] + 1 };
        glass.runs += 1;
        if (glass.runs == glass.refuse_at) return err.RTGERR_IO;
        // The window's pixels, row after row.
        const bytes: [*]const u8 = @ptrCast(color.?);
        const wide = glass.columns[1] + 1 - glass.columns[0];
        if (size != wide * (glass.lines[1] + 1 - glass.lines[0]) * 2) return err.RTGERR_BAD_ARG;
        var row = glass.lines[0];
        var from: usize = 0;
        while (row <= glass.lines[1]) : (row += 1) {
            const into = glass.pixels[(row * glass.native_width + glass.columns[0]) * 2 ..];
            @memcpy(into[0 .. wide * 2], bytes[from..][0 .. wide * 2]);
            from += wide * 2;
        }
        return err.RTGERR_OK;
    }

    fn createTransport(_: *rtg.RtgDriver, io: *rtg.RtgTransport, _: ?[*]const TagItem) callconv(.c) i32 {
        io.ops = &bus_ops;
        return err.RTGERR_OK;
    }

    const bus_ops = rtg.RtgTransportOps{ .tx_param = &txParam, .tx_color = &txColor };
    const bus_driver_ops = rtg.RtgDriverOps{ .create_transport = &createTransport };
    const test_bus: u32 = 0x7E57_0D05;
    const test_chip: u32 = 0x7E57_0D06;
    const bus_matches = [_]rtg.RtgMatch{ .{ .fields = rtg.drivers.RTGMATCH_BUS, .bus = test_bus }, .{} };
    const bus_spec = rtg.RtgDriverSpec{
        .name = "testbus",
        .id_string = "dcs test bus",
        .version = 1,
        .kind = rtg.drivers.RTGDT_TRANSPORT,
        .matches = &bus_matches,
        .ops = &bus_driver_ops,
    };

    /// The tests' attach: a board with the driver's own ops, its panel
    /// as the bring-up leaves it, on the tests' bus.
    fn attachTest(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, _: ?[*]const TagItem) callconv(.c) i32 {
        const sys = driver.sys_base;
        const rb = driver.rtg_base;
        const io = rb.OpenTransport(driver, device) orelse return err.RTGERR_NO_DISPLAY;
        const board = rb.CreateBoard(driver, device, &.{ .ops = &ops, .instance_size = @sizeOf(Panel) }) orelse return err.RTGERR_NO_MEMORY;
        const panel = panelOf(board);
        panel.* = .{
            .sys = sys,
            .rtg_base = rb,
            .io = io,
            .width = glass.native_width,
            .height = glass.native_height,
            .native_width = glass.native_width,
            .native_height = glass.native_height,
            .alignment = glass.alignment,
            .swapped_turn = glass.turn,
            .turns = glass.turn != .none,
        };
        sys.InitSemaphore(&panel.bus_lock);
        // A band of 64 bytes: four rows of the 8 wide panel.
        panel.band_size = 64;
        panel.band = @ptrCast(@alignCast(sys.AllocVec(64, exec.MEMF_ANY).?));
        if (glass.turn != .none) panel.upright = @ptrCast(sys.AllocVec(64, exec.MEMF_ANY).?);
        const rgb565 = @intFromEnum(rtg.PixelFormat.rgb565);
        const upright: rtg.RtgTimings = .{ .h_active = glass.native_width, .v_active = glass.native_height };
        const on_its_side: rtg.RtgTimings = .{ .h_active = glass.native_height, .v_active = glass.native_width };
        _ = rb.AddBoardMode(board, &upright, rgb565, if (glass.turn == .none) rtg.modes.RTGMF_DEFAULT else 0);
        if (glass.turn != .none) _ = rb.AddBoardMode(board, &on_its_side, rgb565, rtg.modes.RTGMF_TURNED | rtg.modes.RTGMF_DEFAULT);
        board.region = .{ .size = 4096, .alignment = 4, .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_SYSTEM_MEMORY };
        glass.board = board;
        return err.RTGERR_OK;
    }

    const board_driver_ops = rtg.RtgDriverOps{ .attach = &attachTest };
    const board_matches = [_]rtg.RtgMatch{ .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = test_chip }, .{} };
    const board_spec = rtg.RtgDriverSpec{
        .name = "dcstest",
        .id_string = "dcs test board",
        .version = 1,
        .kind = rtg.drivers.RTGDT_BOARD,
        .matches = &board_matches,
        .ops = &board_driver_ops,
    };
    const device_tags = [_]sdk.utility.FixedTagItem{
        .value(st.PART_Chip, test_chip),
        .pointer(st.PART_ChipName, "dcs test panel"),
        .value(st.PART_Bus, test_bus),
        .done,
    };
};

/// What a test has: the library, its two drivers and the device it was
/// offered.
const Bench = struct {
    rb: *krtg.RtgBase,
    board: *rtg.RtgBoard,
    bus_driver: *rtg.RtgDriver,
    board_driver: *rtg.RtgDriver,
    device: *rtg.RtgDevice,

    fn programs(bench: Bench) *sdk.interface.rtg.RtgBase {
        return @ptrCast(bench.rb);
    }
};

/// exec, utility.library and rtg.library from their tags, the tests' two
/// drivers on its list, and a board made of the tests' device: a panel 8
/// by 8, or one 4 wide and 8 tall whose picture lies on its side.
fn testBench(turn: sequence.Turn, alignment: u32) !Bench {
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    const made = kexec.InitResident(kexec.SysBase, &krtg.rtg_library_tag, null) orelse return error.NoRtg;
    const rb: *krtg.RtgBase = @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
    const drivers: *RtgDriverBase = @ptrCast(rb);
    Glass.glass = .{ .turn = turn, .alignment = alignment, .native_width = if (turn == .none) 8 else 4 };
    const bus_driver = drivers.AddRtgDriver(&Glass.bus_spec, null) orelse return error.NoDriver;
    const board_driver = drivers.AddRtgDriver(&Glass.board_spec, null) orelse return error.NoDriver;
    const device = drivers.AddRtgDevice(@ptrCast(&Glass.device_tags)) orelse return error.NoDevice;
    const board = Glass.glass.board orelse return error.NoBoard;
    return .{ .rb = rb, .board = board, .bus_driver = bus_driver, .board_driver = board_driver, .device = device };
}

/// The board, the device and the drivers given back, both libraries
/// taken off and freed, and nothing left.
fn dropBench(bench: Bench) !void {
    const rb = bench.rb;
    const drivers: *RtgDriverBase = @ptrCast(rb);
    drivers.DeleteBoard(bench.board);
    drivers.RemRtgDevice(bench.device);
    try testing.expect(drivers.RemRtgDriver(bench.board_driver));
    try testing.expect(drivers.RemRtgDriver(bench.bus_driver));
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(rb.utility_base));
    _ = kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    if (rb.timer_io.node.device != null) kexec.CloseDevice(kexec.SysBase, &rb.timer_io.node);
    kexec.Remove(kexec.SysBase, &rb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &rb.lib);
    kutility.freeForTests(ub);
    try kexec.expectNoLeaks();
}

/// A buffer of the board with every pixel saying where it is: `mark` in
/// its top bits, then its row and its column.
fn paintedBuffer(bench: Bench, width: u32, height: u32, mark: u16) !*rtg.RtgBitMap {
    const bitmap = bench.programs().AllocBitMap(bench.board, width, height, @intFromEnum(rtg.PixelFormat.rgb565), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse return error.NoBitMap;
    for (0..height) |y| {
        const row: [*]u16 = @ptrCast(@alignCast(bitmap.pixels.? + y * bitmap.pitch));
        for (0..width) |x| row[x] = pixelOf(mark, @intCast(x), @intCast(y));
    }
    return bitmap;
}

fn pixelOf(mark: u16, x: u32, y: u32) u16 {
    return mark << 12 | @as(u16, @intCast(y)) << 6 | @as(u16, @intCast(x));
}

test "dcs: a picture shown is sent whole, in bands; a rectangle drawn is its own window" {
    const bench = try testBench(.none, 1);
    defer kexec.deinit();
    const rb = bench.programs();
    const glass = &Glass.glass;
    const first = try paintedBuffer(bench, 8, 8, 1);

    // The whole picture, four rows to a band, each with its window.
    try testing.expectEqual(err.RTGERR_OK, rb.ShowBitMap(bench.board, first));
    try testing.expectEqual(@as(u32, 2), glass.runs);
    try testing.expectEqual(sequence.Box{ .left = 0, .top = 4, .right = 8, .end = 8 }, glass.windows[1]);
    try testing.expectEqual(pixelOf(1, 0, 0), Glass.at(0, 0));
    try testing.expectEqual(pixelOf(1, 7, 7), Glass.at(7, 7));
    try testing.expectEqual(@as(u32, 1), panelOf(bench.board).stats.frames);

    // A rectangle drawn: its columns and rows, and no more of either.
    glass.runs = 0;
    const row: [*]u16 = @ptrCast(@alignCast(first.pixels.? + 5 * first.pitch));
    row[3] = 0xFFFF;
    row[6] = 0xFFFF;
    try testing.expectEqual(err.RTGERR_OK, rb.RefreshRect(first, &.{ .x = 3, .y = 5, .width = 2, .height = 1 }));
    try testing.expectEqual(@as(u32, 1), glass.runs);
    try testing.expectEqual(sequence.Box{ .left = 3, .top = 5, .right = 5, .end = 6 }, glass.windows[0]);
    try testing.expectEqual(@as(u16, 0xFFFF), Glass.at(3, 5));
    try testing.expectEqual(pixelOf(1, 6, 5), Glass.at(6, 5));
    // The row was asked for, and its neighbour not.
    try testing.expectEqual(@as(isize, 1), rb.BoardControl(bench.board, tags.RTGCTRL_DCS_ROW_ASKED, 5));
    try testing.expectEqual(@as(isize, 0), rb.BoardControl(bench.board, tags.RTGCTRL_DCS_ROW_ASKED, 4));

    // A buffer that is not shown goes nowhere.
    const other = try paintedBuffer(bench, 8, 8, 2);
    glass.runs = 0;
    try testing.expectEqual(err.RTGERR_OK, rb.RefreshRect(other, null));
    try testing.expectEqual(@as(u32, 0), glass.runs);

    // Two buffers in bands: each line of the glass from the band that
    // covers it.
    const two = [_]rtg.RtgBand{ .{ .bitmap = first }, .{ .bitmap = other, .line = 4, .origin = 4 } };
    try testing.expectEqual(err.RTGERR_OK, rb.ShowBoard(bench.board, 0, &two, two.len));
    try testing.expectEqual(pixelOf(1, 2, 3), Glass.at(2, 3));
    try testing.expectEqual(pixelOf(2, 2, 0), Glass.at(2, 4));
    try testing.expectEqual(pixelOf(2, 7, 3), Glass.at(7, 7));

    // The pointer is the library's, and reaches the glass as its own
    // rectangle: one pixel, one window of one pixel.
    var dot = [_]u32{@byteSwap(@as(u32, 0xFF0000FF))};
    const pointer = rtg.Surface{ .pixels = @ptrCast(&dot), .width = 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(err.RTGERR_OK, rb.SetBoardPointer(bench.board, &pointer, 0, 0));
    rb.MoveBoardPointer(bench.board, 6, 2);
    glass.runs = 0;
    try testing.expectEqual(err.RTGERR_OK, rb.ShowBoardPointer(bench.board, true));
    try testing.expectEqual(@as(u32, 1), glass.runs);
    try testing.expectEqual(sequence.Box{ .left = 6, .top = 2, .right = 7, .end = 3 }, glass.windows[0]);
    try testing.expectEqual(@as(u16, 0xF800), Glass.at(6, 2));
    rb.MoveBoardPointer(bench.board, 1, 6);
    try testing.expectEqual(pixelOf(1, 6, 2), Glass.at(6, 2));
    try testing.expectEqual(@as(u16, 0xF800), Glass.at(1, 6));
    try testing.expectEqual(err.RTGERR_OK, rb.SetBoardPointer(bench.board, null, 0, 0));
    try testing.expectEqual(pixelOf(2, 1, 2), Glass.at(1, 6));

    try testing.expectEqual(err.RTGERR_OK, rb.ShowBitMap(bench.board, null));
    rb.FreeBitMap(other);
    rb.FreeBitMap(first);
    try dropBench(bench);
}

test "dcs: a window is whole alignments, each way" {
    const bench = try testBench(.none, 4);
    defer kexec.deinit();
    const rb = bench.programs();
    const glass = &Glass.glass;
    const picture = try paintedBuffer(bench, 8, 8, 1);
    try testing.expectEqual(err.RTGERR_OK, rb.ShowBitMap(bench.board, picture));

    // One pixel drawn: the four by four around it.
    glass.runs = 0;
    try testing.expectEqual(err.RTGERR_OK, rb.RefreshRect(picture, &.{ .x = 5, .y = 2, .width = 1, .height = 1 }));
    try testing.expectEqual(@as(u32, 1), glass.runs);
    try testing.expectEqual(sequence.Box{ .left = 4, .top = 0, .right = 8, .end = 4 }, glass.windows[0]);
    // The whole picture: bands of four rows, the alignment's.
    glass.runs = 0;
    try testing.expectEqual(err.RTGERR_OK, rb.RefreshRect(picture, null));
    try testing.expectEqual(@as(u32, 2), glass.runs);
    try testing.expectEqual(sequence.Box{ .left = 0, .top = 4, .right = 8, .end = 8 }, glass.windows[1]);

    try testing.expectEqual(err.RTGERR_OK, rb.ShowBitMap(bench.board, null));
    rb.FreeBitMap(picture);
    try dropBench(bench);
}

test "dcs: a show the bus refuses changes nothing; what was shown is sent again from the same buffer" {
    const bench = try testBench(.none, 1);
    defer kexec.deinit();
    const rb = bench.programs();
    const glass = &Glass.glass;
    const panel = panelOf(bench.board);
    const first = try paintedBuffer(bench, 8, 8, 1);
    const second = try paintedBuffer(bench, 8, 8, 2);

    // The very first show refused: the board shows nothing, as before it.
    glass.refuse_at = 1;
    try testing.expectEqual(err.RTGERR_IO, rb.ShowBitMap(bench.board, first));
    try testing.expect(rb.BoardDisplayBitMap(bench.board) == null);
    try testing.expectEqual(@as(u32, 1), panel.stats.failed_sends);
    try testing.expectEqual(@as(u32, 0), panel.stats.frames);

    // Shown: two bands of four rows.
    glass.runs = 0;
    glass.refuse_at = 0;
    try testing.expectEqual(err.RTGERR_OK, rb.ShowBitMap(bench.board, first));
    try testing.expectEqual(@as(u32, 2), glass.runs);

    // Another buffer, refused at its second band: part of it reached the
    // glass, and the library still holds the first as what is shown.
    glass.runs = 0;
    glass.refuse_at = 2;
    try testing.expectEqual(err.RTGERR_IO, rb.ShowBitMap(bench.board, second));
    try testing.expectEqual(pixelOf(2, 0, 0), Glass.at(0, 0));
    try testing.expectEqual(pixelOf(1, 0, 7), Glass.at(0, 7));
    try testing.expectEqual(first, rb.BoardDisplayBitMap(bench.board).?);
    try testing.expect(second.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);
    try testing.expectEqual(@as(u32, 2), panel.stats.failed_sends);

    // So handing the one shown on again puts the glass right, and the
    // buffer refused goes nowhere.
    glass.runs = 0;
    glass.refuse_at = 0;
    try testing.expectEqual(err.RTGERR_OK, rb.RefreshRect(second, null));
    try testing.expectEqual(@as(u32, 0), glass.runs);
    try testing.expectEqual(err.RTGERR_OK, rb.RefreshRect(first, null));
    try testing.expectEqual(pixelOf(1, 0, 0), Glass.at(0, 0));

    // Bands refused over one buffer, and one buffer refused over bands:
    // what the library holds is what was shown each time.
    const two = [_]rtg.RtgBand{ .{ .bitmap = first }, .{ .bitmap = second, .line = 4, .origin = 4 } };
    glass.runs = 0;
    glass.refuse_at = 1;
    try testing.expectEqual(err.RTGERR_IO, rb.ShowBoard(bench.board, 0, &two, two.len));
    try testing.expectEqual(first, rb.BoardDisplayBitMap(bench.board).?);
    glass.refuse_at = 0;
    try testing.expectEqual(err.RTGERR_OK, rb.ShowBoard(bench.board, 0, &two, two.len));
    try testing.expectEqual(second, rb.BoardDisplayBitMap(bench.board).?);
    glass.runs = 0;
    glass.refuse_at = 2;
    try testing.expectEqual(err.RTGERR_IO, rb.ShowBitMap(bench.board, first));
    try testing.expect(second.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    glass.refuse_at = 0;
    try testing.expectEqual(err.RTGERR_OK, rb.RefreshRect(second, null));
    try testing.expectEqual(pixelOf(2, 3, 0), Glass.at(3, 4));

    try testing.expectEqual(err.RTGERR_OK, rb.ShowBitMap(bench.board, null));
    rb.FreeBitMap(second);
    rb.FreeBitMap(first);
    try dropBench(bench);
}

test "dcs: a picture on its side is turned onto the panel, a rectangle of it as the panel's window" {
    // 8 wide and 4 high, on a panel 4 wide and 8 tall.
    for ([_]sequence.Turn{ .clockwise, .counter_clockwise }) |turn| {
        const bench = try testBench(turn, 1);
        defer kexec.deinit();
        const rb = bench.programs();
        const glass = &Glass.glass;
        const picture = try paintedBuffer(bench, 8, 4, 1);

        // The board comes up in the mode on its side: the whole picture,
        // every pixel where the panel has it.
        try testing.expectEqual(err.RTGERR_OK, rb.ShowBitMap(bench.board, picture));
        try testing.expectEqual(turn, panelOf(bench.board).turn);
        for (0..4) |y| for (0..8) |x| {
            const box = sequence.Box{ .left = @intCast(x), .top = @intCast(y), .right = @intCast(x + 1), .end = @intCast(y + 1) };
            const where = sequence.onPanel(turn, box, 8, 4);
            try testing.expectEqual(pixelOf(1, @intCast(x), @intCast(y)), Glass.at(where.left, where.top));
        };

        // Two pixels of one row drawn: the panel's window is two rows of
        // one column, and nothing else is sent.
        const row: [*]u16 = @ptrCast(@alignCast(picture.pixels.? + 1 * picture.pitch));
        row[5] = 0xFFFF;
        row[6] = 0xF800;
        glass.runs = 0;
        try testing.expectEqual(err.RTGERR_OK, rb.RefreshRect(picture, &.{ .x = 5, .y = 1, .width = 2, .height = 1 }));
        try testing.expectEqual(@as(u32, 1), glass.runs);
        const window = sequence.onPanel(turn, .{ .left = 5, .top = 1, .right = 7, .end = 2 }, 8, 4);
        try testing.expectEqual(window, glass.windows[0]);
        try testing.expectEqual(@as(u32, 1), window.columns());
        try testing.expectEqual(@as(u32, 2), window.rows());
        const white = sequence.onPanel(turn, .{ .left = 5, .top = 1, .right = 6, .end = 2 }, 8, 4);
        const red = sequence.onPanel(turn, .{ .left = 6, .top = 1, .right = 7, .end = 2 }, 8, 4);
        try testing.expectEqual(@as(u16, 0xFFFF), Glass.at(white.left, white.top));
        try testing.expectEqual(@as(u16, 0xF800), Glass.at(red.left, red.top));

        // Refused: the picture shown stays the library's.
        const other = try paintedBuffer(bench, 8, 4, 2);
        glass.runs = 0;
        glass.refuse_at = 1;
        try testing.expectEqual(err.RTGERR_IO, rb.ShowBitMap(bench.board, other));
        try testing.expectEqual(picture, rb.BoardDisplayBitMap(bench.board).?);
        glass.refuse_at = 0;

        try testing.expectEqual(err.RTGERR_OK, rb.ShowBitMap(bench.board, null));
        rb.FreeBitMap(other);
        rb.FreeBitMap(picture);
        try dropBench(bench);
    }
}

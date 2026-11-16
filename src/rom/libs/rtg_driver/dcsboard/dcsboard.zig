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
//! out of, and the controller holds a copy of its own. RefreshBitMap is
//! what brings the copy up to date: the rows asked for, widened to the
//! controller's alignment, go over the bus in bands, each band given its
//! own window and a RAMWR. The bus sends each pixel high byte first, which
//! is not how memory holds RGB565, so a band is turned round into a
//! buffer in internal memory on its way - which is also where the DMA
//! behind the bus reads from without help.
//!
//! Nothing is sent that nobody asked for: there is no stream, so the board
//! reports no RTGBF_STREAMING, and a buffer that is not being shown is
//! not sent at all until it is.
//!
//! A picture may be several buffers at once, in bands of lines
//! (ShowBoard): every line is read from the band that covers it,
//! and a buffer's refresh sends the lines it shows there.
//!
//! The pointer is laid into each band after it is turned round and before
//! it goes, so the picture in PSRAM never holds it. Moving it sends the
//! rows it left and the rows it came to, which the picture supplies again
//! with the pointer in its new place. The overlay - a dragged icon - is
//! laid and moved the same way, under the pointer.

const std = @import("std");
const sdk = @import("sdk");
const BoardPin = sdk.expansion.BoardPin;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;
const tags = rtg.tags;

const sequence = @import("sequence.zig");
const gpio = @import("sdk").hardware.gpio;
const systimer = sdk.hardware.systimer;

const MODULE_NAME = "rtg-dcs";
const DRIVER_NAME = "dcs";
const VERSION = 1;
const REVISION = 9;
const BUILD_DATE = "16.11.2026";
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

/// The buffer a band is turned round in, in internal memory.
const band_bytes = 16 * 1024;

/// What an absent tag reads as, where 0 is a real value.
const absent = std.math.maxInt(usize);

/// What one board keeps.
const Panel = struct {
    sys: *ExecBase,
    rtg_base: *RtgDriverBase,
    io: *rtg.RtgTransport,
    /// The band and the bus between its fill and its transfer, and a
    /// command's transaction: one task at a time (`oneBand`). A semaphore -
    /// a band is about a millisecond, and a transport on a bus device
    /// waits for it.
    band_lock: exec.SignalSemaphore = .{},
    /// Upright, and on its side when the controller can be turned: the
    /// MADCTL value of each, and whether the board has the second.
    madctl: [2]u8 = .{ 0, 0 },
    turns: bool = false,
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
    lit: u32 = 0,
    /// The panel's lines that are pads of the chip - its reset and its
    /// backlight - taken from gpio.resource while the board exists.
    gpio_base: ?*GpioBase = null,
    held_pads: [2]u8 = .{ 0, 0 },
    held_count: u8 = 0,
    band: ?[*]align(4) u8 = null,
    band_rows: u32 = 0,
    stats: rtg.RtgBoardStats = .{},

    /// A bit per picture row, set when a refresh asks for that row. It
    /// is what tells a row nobody handed on from a row that was handed
    /// on and sent with the wrong pixels in it: the two look the same on
    /// the glass and have nothing else to tell them apart.
    asked: [rows_marked / 8]u8 = @splat(0),

    /// The pointer: the image the library made, where its top left is on
    /// the picture, and whether it is laid into what is sent.
    pointer: ?*const rtg.RtgPointerImage = null,
    pointer_left: i32 = 0,
    pointer_top: i32 = 0,
    pointer_shown: bool = false,
    /// The overlay (a dragged icon): its image, laid under the pointer
    /// whenever there is one, and where its top left is.
    overlay: ?*const rtg.RtgPointerImage = null,
    overlay_left: i32 = 0,
    overlay_top: i32 = 0,

    /// What the controller is sent from: the bands of the picture shown,
    /// one for a single buffer, none before the first. While a show's
    /// picture is being sent they are that picture's; a show the bus
    /// refuses puts back the ones before (`showPicture`).
    bands: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined,
    band_count: u32 = 0,
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
    const bring_up = sequenceOf(rb, tag_list) orelse return err.RTGERR_BAD_TAGS;
    if (size.width == 0 or size.height == 0) return err.RTGERR_BAD_TAGS;
    if (!sequence.valid(bring_up)) return err.RTGERR_BAD_TAGS;
    // The controller is sent RGB565 and nothing else.
    const format = rb.GetRtgTagData(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.rgb565), tag_list);
    if (format != @intFromEnum(rtg.PixelFormat.rgb565)) return err.RTGERR_BAD_FORMAT;

    // The bus the controller sits on, made from the same tags.
    const io = rb.OpenTransport(driver, device) orelse return err.RTGERR_NO_DISPLAY;
    const board = rb.CreateBoard(driver, device, &.{ .ops = &ops, .instance_size = @sizeOf(Panel), .direct_bands = rtg.RTG_MAX_BANDS }) orelse {
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
    const init_at = rb.GetRtgTagData(tags.RTGA_DCS_InitSequence, 0, tag_list);
    const init_length = rb.GetRtgTagData(tags.RTGA_DCS_InitLength, 0, tag_list);
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
    sys.InitSemaphore(&panel.band_lock);
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
    const st = sdk.expansion.systemtags;
    panel.backlight = BoardPin.of(rb.GetRtgTagData(st.PART_PinBacklight, 0, tag_list));
    const reset_pin = BoardPin.of(rb.GetRtgTagData(st.PART_PinReset, 0, tag_list));
    const reset_ms: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_ResetMillis, 120, tag_list));
    if (!takePads(panel, reset_pin)) return err.RTGERR_IN_USE;

    // The memory first: a panel brought up with nowhere to draw is no use.
    const side = @max(width, height);
    const band = sys.AllocVec(band_bytes, exec.MEMF_INTERNAL | exec.MEMF_DMA) orelse {
        giveBack(panel);
        return err.RTGERR_NO_MEMORY;
    };
    panel.band = @ptrCast(@alignCast(band));
    panel.band_rows = sequence.bandRows(band_bytes, side * 2, panel.alignment);
    if (panel.band_rows * side * 2 > band_bytes) {
        giveBack(panel);
        return err.RTGERR_BAD_TAGS;
    }
    const frame_bytes = @as(usize, width) * height * 2;
    // As many pictures as the board asks for (`RTGA_Buffers`) at once, each
    // taken by the library as it is asked for.
    const frames = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list))), 1);

    // Dark until there is a picture, then out of reset and through the
    // maker's bring-up.
    setBacklight(panel, false);
    const code = bringUp(panel, reset_pin, reset_ms, bring_up);
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
    board.info.brightness = 0;
    return err.RTGERR_OK;
}

/// The controller out of reset - its own line if it has one, the command
/// if not - and every step of the bring-up, each with its wait.
fn bringUp(panel: *Panel, reset_pin: BoardPin, reset_ms: u32, bring_up: []const u8) i32 {
    const rb = panel.rtg_base;
    if (reset_pin.kind == sdk.expansion.boardpin.BPIN_GPIO) {
        const asserted = reset_pin.active_low == 0;
        gpio.toMatrix(reset_pin.number);
        gpio.connectOut(reset_pin.number, gpio.out_of_gpio, true);
        gpio.outputEnable(reset_pin.number, true);
        gpio.setLevel(reset_pin.number, asserted);
        systimer.spinUs(10_000);
        gpio.setLevel(reset_pin.number, !asserted);
    } else {
        const code = rb.TxParam(panel.io, SWRESET, null, 0);
        if (code != err.RTGERR_OK) return code;
    }
    systimer.spinUs(@as(u64, reset_ms) * 1000);

    var steps: sequence.Steps = .{ .bytes = bring_up };
    while (steps.next()) |one| {
        const params: ?*const anyopaque = if (one.params.len != 0) one.params.ptr else null;
        const code = rb.TxParam(panel.io, one.cmd, params, @intCast(one.params.len));
        if (code != err.RTGERR_OK) return code;
        if (one.delay_ms != 0) systimer.spinUs(@as(u64, one.delay_ms) * 1000);
    }
    return err.RTGERR_OK;
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
    const which: usize = @intFromBool(turned);
    const code = command(panel, MADCTL, &panel.madctl[which], 1);
    if (code != err.RTGERR_OK) return code;
    panel.width = mode.width;
    panel.height = mode.height;
    panel.turn = if (turned) panel.swapped_turn else .none;
    return err.RTGERR_OK;
}

/// Show that buffer: all of it goes over the bus, and it is what a refresh
/// sends from then on. The controller has no second picture to flip to,
/// so a new buffer shown is a whole picture sent. A send the bus refuses
/// leaves the picture shown before as what a refresh sends.
fn showBitMap(board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap) i32 {
    const panel = panelOf(board);
    const bm = bitmap orelse {
        panel.band_count = 0;
        return err.RTGERR_OK;
    };
    if (bm.pixels == null) return err.RTGERR_BAD_ARG;
    if (bm.width != panel.width or bm.height != panel.height) return err.RTGERR_NOT_DISPLAYABLE;
    if (bm.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    const whole = [_]rtg.RtgBand{.{ .bitmap = bm }};
    return showPicture(panel, &whole);
}

/// Several buffers at once, in bands: the whole picture sent, each line
/// from the band that covers it, and a refresh of any of them sends the
/// lines it shows from then on. A send the bus refuses leaves the picture
/// shown before as what a refresh sends.
fn showBands(board: *rtg.RtgBoard, bands: [*]const rtg.RtgBand, count: u32) i32 {
    const panel = panelOf(board);
    for (bands[0..count]) |band| {
        if (band.bitmap.pixels == null) return err.RTGERR_BAD_ARG;
        if (band.bitmap.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    }
    return showPicture(panel, bands[0..count]);
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
    const code = showThese(board, what);
    if (code != err.RTGERR_OK and anew) _ = showBitMap(board, null);
    return code;
}

/// The bands of a show, in the mode the board is in.
fn showThese(board: *rtg.RtgBoard, what: *const rtg.RtgShow) i32 {
    const bands = what.bands orelse return showBitMap(board, null);
    if (what.count == 0) return showBitMap(board, null);
    const first = bands[0];
    if (what.count == 1 and first.origin == 0 and first.flags == 0) return showBitMap(board, first.bitmap);
    return showBands(board, bands, what.count);
}

/// The whole picture sent from `picture`'s bands, which are what the panel
/// is sent from afterwards. They are in place while the send runs: it
/// reads them, and rows another task refreshes meanwhile, and the
/// pointer's, then come from the picture being sent. A send the bus
/// refuses puts the bands shown before back: the library marks nothing of
/// a show that failed, so the buffers this driver reads stay the ones
/// that cannot be freed. What such a send leaves on the glass is part old
/// and part new (`failed_sends`), and stays so until those rows are sent
/// again from the bands put back.
///
/// INPUTS:
/// - `panel` - the board's instance.
/// - `picture` - the bands to show, as the library checked them: one to
///   `RTG_MAX_BANDS`.
///
/// RESULT:
/// `RTGERR_OK` - also where a band ran dry on every try (`goesOn`) - or
/// the error that stopped the send.
fn showPicture(panel: *Panel, picture: []const rtg.RtgBand) i32 {
    var before: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined;
    const count_before = panel.band_count;
    @memcpy(before[0..count_before], panel.bands[0..count_before]);
    @memcpy(panel.bands[0..picture.len], picture);
    panel.band_count = @intCast(picture.len);
    const code = send(panel, 0, panel.height);
    if (code != err.RTGERR_OK) {
        // The count is never above the bands that are in place: lowered
        // before they are written, raised after.
        panel.band_count = @min(panel.band_count, count_before);
        @memcpy(panel.bands[0..count_before], before[0..count_before]);
        panel.band_count = count_before;
    }
    return code;
}

/// Rows the CPU wrote. Only the buffer being shown goes anywhere: the
/// controller holds one picture, and that is it.
///
/// They go where this stands, on the caller's own task, so the picture
/// that reaches the panel is the one the caller had when it asked. A
/// send of its own, on a task of its own, would read the buffer while
/// the caller was still writing it and put a half-written row on the
/// glass - which is what a caller gathering its drawing into one refresh
/// (graphics.library's BeginDraw) is taking trouble to avoid.
///
/// A buffer shown in a band sends the lines of its rows that the band
/// shows, and only those.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect) callconv(.c) i32 {
    const panel = panelOf(board);
    const top: u32 = @intCast(area.y);
    const end: u32 = top + @as(u32, @intCast(area.height));
    panel.stats.refreshes += 1;
    panel.stats.rows_refreshed +%= end - top;
    const shown = panel.bands[0..panel.band_count];
    var code: i32 = err.RTGERR_OK;
    var sent = false;
    for (shown, 0..) |band, i| {
        if (band.bitmap != bitmap) continue;
        // The band's lines, and those of them the rows asked for are on.
        const band_end = if (i + 1 < shown.len) shown[i + 1].line else panel.height;
        const lines = band.linesOf(top, end, band_end);
        if (lines.first >= lines.end) continue;
        sent = true;
        markAsked(panel, lines.first, lines.end);
        code = send(panel, lines.first, lines.end - lines.first);
        if (code != err.RTGERR_OK) return code;
    }
    if (!sent) panel.stats.refreshes_dropped += 1;
    return code;
}

/// Rows `top` to `end` marked as asked for.
fn markAsked(panel: *Panel, top: u32, end: u32) void {
    var row = top;
    while (row < end and row < rows_marked) : (row += 1) {
        panel.asked[row / 8] |= @as(u8, 1) << @intCast(row % 8);
    }
}

/// Lines `y` to `y + rows` of the picture shown (0: all of them) to the
/// panel, upright or turned, and a count of the sends that did not get
/// there.
fn send(panel: *Panel, y: u32, rows: u32) i32 {
    if (panel.band_count == 0) return err.RTGERR_OK;
    const code = if (panel.turn != .none) sendTurned(panel, y, rows) else sendUpright(panel, y, rows);
    // A send that stopped part way has told the panel a window and then
    // not filled it, so what is on the glass is part old and part new.
    if (code != err.RTGERR_OK) panel.stats.failed_sends += 1;
    return code;
}

/// Lines `y` to `y + rows` (0: all of them) to the controller, in bands
/// of whole alignments, each with its window.
fn sendUpright(panel: *Panel, y: u32, rows: u32) i32 {
    const rb = panel.rtg_base;
    const shown = panel.bands[0..panel.band_count];
    const band = panel.band orelse return err.RTGERR_NO_MEMORY;
    const area = sequence.window(y, rows, panel.height, panel.alignment);
    const row_bytes = panel.width * 2;
    const columns = windowBytes(0, panel.width - 1);

    var code: i32 = err.RTGERR_OK;
    var row = area.top;
    while (row < area.end) {
        const count = @min(panel.band_rows, area.end - row);
        const lines = windowBytes(row, row + count - 1);
        // Filled and sent by one task at a time, for the reason `oneBand`
        // gives: the band is the board's only one.
        code = band_done: {
            panel.sys.ObtainSemaphore(&panel.band_lock);
            defer panel.sys.ReleaseSemaphore(&panel.band_lock);
            for (0..count) |i| {
                // Rows start on the region's alignment, a whole cache line.
                const from: [*]align(4) const u8 = @alignCast(sequence.bandRow(shown, row + @as(u32, @intCast(i))));
                const into: [*]align(4) u8 = @alignCast(band + i * row_bytes);
                sequence.swapPixels(into[0..row_bytes], from[0..row_bytes]);
            }
            layPointer(panel, band[0 .. count * row_bytes], .{
                .first_row = row,
                .rows = count,
                .first_column = 0,
                .columns = panel.width,
                .picture_width = panel.width,
                .picture_height = panel.height,
                .turn = .none,
            });
            break :band_done writeBand(panel, rb, &columns, &lines, band, count * row_bytes);
        };
        if (!goesOn(code)) return code;
        row += count;
    }
    panel.stats.frames += 1;
    return err.RTGERR_OK;
}

/// The same for a picture the panel cannot turn itself: rows of the
/// picture are a strip of the panel's columns, and every panel row in that
/// strip is read down a column of the picture as it is copied.
fn sendTurned(panel: *Panel, y: u32, rows: u32) i32 {
    const rb = panel.rtg_base;
    const shown = panel.bands[0..panel.band_count];
    const bm = shown[0].bitmap;
    const pixels = bm.pixels orelse return err.RTGERR_BAD_ARG;
    const band = panel.band orelse return err.RTGERR_NO_MEMORY;
    const strip = sequence.turnedColumns(panel.turn, y, rows, panel.native_width, panel.alignment);
    if (strip.top >= strip.end) return err.RTGERR_OK;

    const count_columns = strip.end - strip.top;
    const row_bytes = count_columns * 2;
    const columns = windowBytes(strip.top, strip.end - 1);

    const picture: sequence.Turned = .{
        .pixels = pixels,
        .pitch = bm.pitch,
        .panel_width = panel.native_width,
        .panel_height = panel.native_height,
        .turn = panel.turn,
        .bands = shown,
    };
    const per_band = sequence.bandRows(band_bytes, row_bytes, panel.alignment);
    var code: i32 = err.RTGERR_OK;
    var row: u32 = 0;
    while (row < panel.native_height) {
        const count = @min(per_band, panel.native_height - row);
        const lines = windowBytes(row, row + count - 1);
        code = oneBand(panel, rb, band, &columns, &lines, picture, row, count, strip.top, count_columns, row_bytes);
        if (!goesOn(code)) return code;
        row += count;
    }
    panel.stats.frames += 1;
    return err.RTGERR_OK;
}

/// One band filled and sent, one task at a time.
///
/// **The band is the board's only one, and filling it is not the bus's
/// business.** A transfer holds the bus - the next one waits for it -
/// but the *filling* happens here, before the bus is asked for anything
/// at all, and the wait for a transfer to end is a poll on whichever
/// task drew. That task can be put aside mid-poll, and another one
/// drawing would then fill this band while the first one's transfer is
/// still reading it out. What reached the glass would be the two
/// mixed: a band of pixels belonging to neither picture.
///
/// So the fill and the transfer are one thing, under the band's lock
/// (`band_lock`): another task that draws - on either core - waits for
/// it. A transfer is polled on the SPI transports, about a millisecond; a
/// transport on a bus device waits for its request, which is why the lock
/// is a semaphore.
///
/// The window is set per band rather than once per send, which is what
/// lets the pause be one band instead of a whole picture: each band
/// says where it goes, so another task's send in between cannot leave
/// this one writing into its window.
fn oneBand(
    panel: *Panel,
    rb: *RtgDriverBase,
    band: [*]align(4) u8,
    columns: *const [4]u8,
    lines: *const [4]u8,
    picture: sequence.Turned,
    row: u32,
    count: u32,
    first_column: u32,
    count_columns: u32,
    row_bytes: u32,
) i32 {
    panel.sys.ObtainSemaphore(&panel.band_lock);
    defer panel.sys.ReleaseSemaphore(&panel.band_lock);
    sequence.turnedBand(band[0 .. count * row_bytes], picture, row, count, first_column, count_columns);
    // A turned picture's width is the panel's height.
    layPointer(panel, band[0 .. count * row_bytes], .{
        .first_row = row,
        .rows = count,
        .first_column = first_column,
        .columns = count_columns,
        .picture_width = picture.panel_height,
        .picture_height = picture.panel_width,
        .turn = picture.turn,
    });
    return writeBand(panel, rb, columns, lines, band, count * row_bytes);
}

/// The overlay over a band, if there is one, and the pointer over that,
/// if one is shown.
fn layPointer(panel: *Panel, into: []u8, band: sequence.Band) void {
    if (panel.overlay) |overlay| sequence.layPointer(into, band, overlay, panel.overlay_left, panel.overlay_top);
    if (!panel.pointer_shown) return;
    const image = panel.pointer orelse return;
    sequence.layPointer(into, band, image, panel.pointer_left, panel.pointer_top);
}

/// The picture rows the pointer covers at (`top`), with `image`, sent
/// again: what is on the glass there follows the pointer.
fn sendPointerRows(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage, top: i32) void {
    const panel = panelOf(board);
    const one = image orelse return;
    const first = @max(top, 0);
    const end = @min(top + @as(i32, @intCast(one.height)), @as(i32, @intCast(panel.height)));
    if (first >= end) return;
    _ = send(panel, @intCast(first), @intCast(end - first));
}

fn setPointer(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    const panel = panelOf(board);
    if (image) |one| {
        if (one.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    }
    const old = panel.pointer;
    panel.pointer = image;
    if (panel.pointer_shown) {
        sendPointerRows(board, old, panel.pointer_top);
        sendPointerRows(board, image, panel.pointer_top);
    }
    return err.RTGERR_OK;
}

/// The rows it left and the rows it came to; one send when they overlap.
fn movePointer(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const panel = panelOf(board);
    const old_top = panel.pointer_top;
    panel.pointer_left = left;
    panel.pointer_top = top;
    if (!panel.pointer_shown) return;
    const image = panel.pointer orelse return;
    const height: i32 = @intCast(image.height);
    if (top < old_top + height and old_top < top + height) {
        const first = @max(@min(top, old_top), 0);
        const end = @min(@max(top, old_top) + height, @as(i32, @intCast(panel.height)));
        if (first < end) _ = send(panel, @intCast(first), @intCast(end - first));
        return;
    }
    sendPointerRows(board, image, old_top);
    sendPointerRows(board, image, top);
}

fn showPointer(board: *rtg.RtgBoard, show: bool) callconv(.c) i32 {
    const panel = panelOf(board);
    panel.pointer_shown = show;
    sendPointerRows(board, panel.pointer, panel.pointer_top);
    return err.RTGERR_OK;
}

fn setOverlay(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    const panel = panelOf(board);
    if (image) |one| {
        if (one.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    }
    const old = panel.overlay;
    panel.overlay = image;
    sendPointerRows(board, old, panel.overlay_top);
    sendPointerRows(board, image, panel.overlay_top);
    return err.RTGERR_OK;
}

/// The rows it left and the rows it came to, as the pointer's.
fn moveOverlay(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const panel = panelOf(board);
    const old_top = panel.overlay_top;
    panel.overlay_left = left;
    panel.overlay_top = top;
    const image = panel.overlay orelse return;
    const height: i32 = @intCast(image.height);
    if (top < old_top + height and old_top < top + height) {
        const first = @max(@min(top, old_top), 0);
        const end = @min(@max(top, old_top) + height, @as(i32, @intCast(panel.height)));
        if (first < end) _ = send(panel, @intCast(first), @intCast(end - first));
        return;
    }
    sendPointerRows(board, image, old_top);
    sendPointerRows(board, image, top);
}

/// How often a band whose transfer ran dry is sent again before its rows
/// are left wrong on the glass.
const underrun_tries = 3;

/// A filled band to the controller: its window, then its pixels. A
/// transfer the DMA fell behind in is counted and sent again - the band
/// is still in its buffer and says where it goes, so a second go lands
/// on the same pixels. The caller holds the band's lock, as filling it
/// needs.
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

/// The picture on or off. Not the backlight.
fn display(board: *rtg.RtgBoard, on: bool) callconv(.c) i32 {
    const panel = panelOf(board);
    return command(panel, if (on) DISPON else DISPOFF, null, 0);
}

/// A command on its own, under the band's lock as a band is: a transaction
/// set up on the bus and then set aside would have its registers written
/// over by another task's band before it started.
fn command(panel: *Panel, cmd: i32, params: ?*const anyopaque, size: u32) i32 {
    panel.sys.ObtainSemaphore(&panel.band_lock);
    defer panel.sys.ReleaseSemaphore(&panel.band_lock);
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

fn brightness(board: *rtg.RtgBoard) callconv(.c) u32 {
    return panelOf(board).lit;
}

fn setBacklight(panel: *Panel, on: bool) void {
    const pin = panel.backlight;
    if (pin.kind != sdk.expansion.boardpin.BPIN_GPIO) return;
    gpio.toMatrix(pin.number);
    gpio.connectOut(pin.number, gpio.out_of_gpio, true);
    gpio.outputEnable(pin.number, true);
    gpio.setLevel(pin.number, on != (pin.active_low != 0));
    panel.lit = if (on) 100 else 0;
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

/// What this board has. No engine: the controller draws nothing, so a
/// caller that wants a rectangle filled fills it in the buffer itself.
/// The picture is turned by choosing a mode, not by the turning ops.
const ops = rtg.RtgBoardOps{
    .destroy = &destroy,
    .show = &showOp,
    .refresh = &refresh,
    .display = &display,
    .set_brightness = &setBrightness,
    .brightness = &brightness,
    .stats = &stats,
    .control = &control,
    .pointer = &pointer_ops,
    .overlay = &overlay_ops,
};

const pointer_ops = rtg.RtgPointerOps{ .set = &setPointer, .move = &movePointer, .show = &showPointer };
const overlay_ops = rtg.RtgOverlayOps{ .set = &setOverlay, .move = &moveOverlay };

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
// A board of this driver cannot be made on the host: its create drives
// pads and waits on the chip's timer. So the tests make a panel by hand -
// what create fills in, as far as a show reads it - on a bus of their
// own, and call the ops as the library does. What they hold is the one
// path no board can be asked for: a send the bus refuses.

const testing = std.testing;
const kexec = @import("../../exec/exec.zig");
const kutility = @import("../../utility/utility.zig");
const krtg = @import("../../rtg/rtg.zig");

/// The bus of the tests: it takes every window, counts the runs of
/// pixels, and refuses the run a test names.
const TestBus = struct {
    /// Runs of pixels asked for, and which of them - counted from 1 - is
    /// refused; 0 refuses none.
    runs: u32 = 0,
    refuse_at: u32 = 0,
    /// The panel, and the first band's buffer it named at the last run:
    /// what that send was composed from.
    panel: ?*Panel = null,
    during: ?*rtg.RtgBitMap = null,

    fn of(io: *rtg.RtgTransport) *TestBus {
        return @ptrCast(@alignCast(io.user_data.?));
    }
    fn txParam(_: *rtg.RtgTransport, _: i32, _: ?*const anyopaque, _: u32) callconv(.c) i32 {
        return err.RTGERR_OK;
    }
    fn txColor(io: *rtg.RtgTransport, _: i32, _: ?*const anyopaque, _: u32) callconv(.c) i32 {
        const bus = of(io);
        bus.runs += 1;
        if (bus.panel) |panel| bus.during = panel.bands[0].bitmap;
        return if (bus.runs == bus.refuse_at) err.RTGERR_IO else err.RTGERR_OK;
    }
    const ops = rtg.RtgTransportOps{ .tx_param = &txParam, .tx_color = &txColor };
};

/// A picture of the tests: 8 pixels wide, `rows` high, RGB565, its rows
/// on four bytes as the senders ask.
fn TestPicture(comptime rows: u32) type {
    return struct {
        pixels: [8 * 2 * rows]u8 align(4) = @splat(0),
        bitmap: rtg.RtgBitMap = .{},

        fn set(picture: *@This()) *rtg.RtgBitMap {
            picture.bitmap = .{ .pixels = &picture.pixels, .width = 8, .height = rows, .pitch = 16, .size_bytes = picture.pixels.len, .format = .rgb565 };
            return &picture.bitmap;
        }
    };
}

/// exec, utility.library and rtg.library from their tags, for the bus
/// calls a send makes through the library's table.
fn testLibrary() !*krtg.RtgBase {
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    const made = kexec.InitResident(kexec.SysBase, &krtg.rtg_library_tag, null) orelse return error.NoRtg;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

/// Both libraries taken off and freed, and nothing left.
fn dropLibrary(rb: *krtg.RtgBase) !void {
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(rb.utility_base));
    _ = kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &rb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &rb.lib);
    kutility.freeForTests(ub);
    try kexec.expectNoLeaks();
}

/// A panel as create leaves it, 8 pixels wide: upright with `height` rows
/// sent two to a band, or turned clockwise onto a panel 8 rows tall.
fn testPanel(rb: *krtg.RtgBase, io: *rtg.RtgTransport, band: *align(4) [64]u8, height: u32, turn: sequence.Turn) Panel {
    var panel = Panel{ .sys = rb.sys_base, .rtg_base = @ptrCast(rb), .io = io };
    panel.width = 8;
    panel.height = height;
    panel.native_width = if (turn == .none) 8 else height;
    panel.native_height = if (turn == .none) height else 8;
    panel.turn = turn;
    panel.band = band;
    panel.band_rows = 2;
    return panel;
}

test "dcs: a show the bus refuses puts back the picture that was shown" {
    const rb = try testLibrary();
    defer kexec.deinit();
    var bus = TestBus{};
    var io = rtg.RtgTransport{ .ops = &TestBus.ops, .user_data = &bus };
    var band: [64]u8 align(4) = undefined;
    var panel = testPanel(rb, &io, &band, 8, .none);
    rb.sys_base.InitSemaphore(&panel.band_lock);
    bus.panel = &panel;
    var board = rtg.RtgBoard{ .instance = &panel };
    var one = TestPicture(8){};
    var other = TestPicture(8){};
    const first = one.set();
    const second = other.set();

    // The very first show refused: the board shows nothing, as before it.
    bus.refuse_at = 1;
    try testing.expectEqual(err.RTGERR_IO, showBitMap(&board, first));
    try testing.expectEqual(@as(u32, 0), panel.band_count);
    try testing.expectEqual(@as(u32, 1), panel.stats.failed_sends);
    try testing.expectEqual(err.RTGERR_OK, refresh(&board, first, &.{ .width = 8, .height = 8 }));
    try testing.expectEqual(@as(u32, 1), panel.stats.refreshes_dropped);

    // Shown: four bands of two rows, and it is what the panel is sent from.
    bus.runs = 0;
    bus.refuse_at = 0;
    try testing.expectEqual(err.RTGERR_OK, showBitMap(&board, first));
    try testing.expectEqual(@as(u32, 4), bus.runs);
    try testing.expectEqual(@as(u32, 1), panel.band_count);
    try testing.expectEqual(first, panel.bands[0].bitmap);
    try testing.expectEqual(@as(u32, 1), panel.stats.frames);

    // Another buffer, refused at its second band: while it was sent the
    // panel named it, and afterwards the first again.
    bus.runs = 0;
    bus.refuse_at = 2;
    try testing.expectEqual(err.RTGERR_IO, showBitMap(&board, second));
    try testing.expectEqual(second, bus.during.?);
    try testing.expectEqual(@as(u32, 1), panel.band_count);
    try testing.expectEqual(first, panel.bands[0].bitmap);
    try testing.expectEqual(@as(u32, 2), panel.stats.failed_sends);
    try testing.expectEqual(@as(u32, 1), panel.stats.frames);

    // So a refresh of the one shown is sent, and one of the buffer
    // refused goes nowhere.
    bus.runs = 0;
    bus.refuse_at = 0;
    try testing.expectEqual(err.RTGERR_OK, refresh(&board, first, &.{ .width = 8, .height = 2 }));
    try testing.expectEqual(@as(u32, 1), bus.runs);
    try testing.expectEqual(err.RTGERR_OK, refresh(&board, second, &.{ .width = 8, .height = 2 }));
    try testing.expectEqual(@as(u32, 1), bus.runs);
    try testing.expectEqual(@as(u32, 2), panel.stats.refreshes_dropped);

    try dropLibrary(rb);
}

test "dcs: bands the bus refuses, and one buffer refused over bands" {
    const rb = try testLibrary();
    defer kexec.deinit();
    var bus = TestBus{};
    var io = rtg.RtgTransport{ .ops = &TestBus.ops, .user_data = &bus };
    var band: [64]u8 align(4) = undefined;
    var panel = testPanel(rb, &io, &band, 8, .none);
    rb.sys_base.InitSemaphore(&panel.band_lock);
    bus.panel = &panel;
    var board = rtg.RtgBoard{ .instance = &panel };
    var one = TestPicture(8){};
    var other = TestPicture(8){};
    var another = TestPicture(8){};
    const first = one.set();
    const second = other.set();
    const third = another.set();
    const two = [_]rtg.RtgBand{ .{ .bitmap = first }, .{ .bitmap = second, .line = 4, .origin = 4 } };

    // One buffer up, then bands refused at their first band: one band
    // again, the buffer from the top.
    try testing.expectEqual(err.RTGERR_OK, showBitMap(&board, first));
    bus.runs = 0;
    bus.refuse_at = 1;
    try testing.expectEqual(err.RTGERR_IO, showBands(&board, &two, two.len));
    try testing.expectEqual(@as(u32, 1), panel.band_count);
    try testing.expectEqual(first, panel.bands[0].bitmap);
    try testing.expectEqual(@as(u32, 0), panel.bands[0].line);

    // The bus willing: both bands are what the panel is sent from.
    bus.refuse_at = 0;
    try testing.expectEqual(err.RTGERR_OK, showBands(&board, &two, two.len));
    try testing.expectEqual(@as(u32, 2), panel.band_count);
    try testing.expectEqual(second, panel.bands[1].bitmap);
    try testing.expectEqual(@as(u32, 4), panel.bands[1].line);

    // One buffer refused over them: both bands are back, the second too,
    // which the one buffer had no place for.
    bus.runs = 0;
    bus.refuse_at = 3;
    try testing.expectEqual(err.RTGERR_IO, showBitMap(&board, third));
    try testing.expectEqual(third, bus.during.?);
    try testing.expectEqual(@as(u32, 2), panel.band_count);
    try testing.expectEqual(first, panel.bands[0].bitmap);
    try testing.expectEqual(second, panel.bands[1].bitmap);
    try testing.expectEqual(@as(u32, 4), panel.bands[1].origin);

    try dropLibrary(rb);
}

test "dcs: a picture sent turned, refused, leaves the one that was shown" {
    const rb = try testLibrary();
    defer kexec.deinit();
    var bus = TestBus{};
    var io = rtg.RtgTransport{ .ops = &TestBus.ops, .user_data = &bus };
    var band: [64]u8 align(4) = undefined;
    // 8 wide and 4 high, on a panel 4 wide and 8 tall: one band of the
    // panel's 8 rows, 4 pixels each.
    var panel = testPanel(rb, &io, &band, 4, .clockwise);
    rb.sys_base.InitSemaphore(&panel.band_lock);
    bus.panel = &panel;
    var board = rtg.RtgBoard{ .instance = &panel };
    var one = TestPicture(4){};
    var other = TestPicture(4){};
    const first = one.set();
    const second = other.set();

    try testing.expectEqual(err.RTGERR_OK, showBitMap(&board, first));
    try testing.expectEqual(@as(u32, 1), bus.runs);
    bus.runs = 0;
    bus.refuse_at = 1;
    try testing.expectEqual(err.RTGERR_IO, showBitMap(&board, second));
    try testing.expectEqual(second, bus.during.?);
    try testing.expectEqual(@as(u32, 1), panel.band_count);
    try testing.expectEqual(first, panel.bands[0].bitmap);
    try testing.expectEqual(@as(u32, 1), panel.stats.failed_sends);

    try dropLibrary(rb);
}

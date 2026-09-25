// SPDX-License-Identifier: MPL-2.0
//! A display controller that keeps its own picture and speaks MIPI DCS -
//! CASET, RASET, RAMWR, MADCTL - over a command bus, as a display board.
//!
//! A module of its own: it opens rtg.library at cold start and hands in a
//! driver called "dcs". A board of it is made on a bus a transport driver
//! made first (`RTGA_Transport`), and everything that makes one controller
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

const std = @import("std");
const sdk = @import("sdk");
const BoardPin = sdk.expansion.BoardPin;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgBase = sdk.interface.rtg.RtgBase;
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
const REVISION = 0;
const BUILD_DATE = "22.9.2026";
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

/// Everything this driver has that changes, allocated once by the init.
const State = struct {
    driver: rtg.RtgDriver = .{},
    sys: *ExecBase,
};

fn stateOf(driver: *rtg.RtgDriver) *State {
    return @fieldParentPtr("driver", driver);
}

/// What one board keeps.
const Panel = struct {
    sys: *ExecBase,
    rtg_base: *RtgBase,
    io: *rtg.RtgTransport,
    /// Upright, and on its side when the controller can be turned.
    modes: [2]rtg.RtgMode = @splat(.{}),
    madctl: [2]u8 = .{ 0, 0 },
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
    /// The picture, on a cache line - every buffer the library cuts from
    /// it starts on one - and the allocation it sits in.
    frame: ?[*]u8 = null,
    frame_memory: ?*anyopaque = null,
    frame_bytes: usize = 0,
    /// How many pictures the display memory holds: several when there was
    /// room, so one can be drawn while another is on the glass.
    frames: u32 = 0,
    band: ?[*]align(4) u8 = null,
    band_rows: u32 = 0,
    stats: rtg.RtgBoardStats = .{},

    /// A bit per picture row, set when a refresh asks for that row. It
    /// is what tells a row nobody handed on from a row that was handed
    /// on and sent with the wrong pixels in it: the two look the same on
    /// the glass and have nothing else to tell them apart.
    asked: [rows_marked / 8]u8 = @splat(0),
};

/// The rows the marks cover, which is more than any mode this board has.
const rows_marked = 512;

fn panelOf(board: *rtg.RtgBoard) *Panel {
    return @ptrCast(@alignCast(board.instance.?));
}

fn createBoard(made_by: *rtg.RtgDriver, board: *rtg.RtgBoard, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const sys = stateOf(made_by).sys;
    const rb: *RtgBase = board.rtg_base.?;
    const io = board.transport orelse return err.RTGERR_BAD_TAGS;

    const width: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Width, 0, tag_list));
    const height: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Height, 0, tag_list));
    const init_at = rb.GetRtgTagData(tags.RTGA_DCS_InitSequence, 0, tag_list);
    const init_length = rb.GetRtgTagData(tags.RTGA_DCS_InitLength, 0, tag_list);
    if (width == 0 or height == 0 or init_at == 0) return err.RTGERR_BAD_TAGS;
    const bring_up = @as([*]const u8, @ptrFromInt(init_at))[0..init_length];
    if (!sequence.valid(bring_up)) return err.RTGERR_BAD_TAGS;

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
    panel.frame_bytes = @as(usize, width) * height * 2;
    const line = sdk.hardware.DCACHE_LINE_SIZE;
    // As many pictures as the board asks for (`RTGA_Buffers`), or as many
    // fewer as there is room for; one may live anywhere.
    panel.frames = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list))), 1);
    const frame = while (true) : (panel.frames -= 1) {
        const asked: u32 = @intCast(panel.frames * panel.frame_bytes + line);
        if (sys.AllocVec(asked, exec.MEMF_EXTERNAL | exec.MEMF_CLEAR)) |memory| break memory;
        if (panel.frames > 1) continue;
        break sys.AllocVec(asked, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
            giveBack(panel);
            return err.RTGERR_NO_MEMORY;
        };
    };
    panel.frame_memory = frame;
    panel.frame = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(frame), line));

    // Dark until there is a picture, then out of reset and through the
    // maker's bring-up.
    setBacklight(panel, false);
    const code = bringUp(panel, reset_pin, reset_ms, bring_up);
    if (code != err.RTGERR_OK) {
        giveBack(panel);
        return code;
    }

    panel.modes[0] = .{
        .node = .{ .name = "upright", .pri = 1 },
        .id = 1,
        .width = width,
        .height = height,
        .format = .rgb565,
        .pitch = width * 2,
        .flags = rtg.boards.RTGMF_DEFAULT,
    };
    sys.AddTail(&board.modes, &panel.modes[0].node);
    if (swapped != absent or panel.swapped_turn != .none) {
        panel.madctl[1] = if (swapped != absent) @truncate(swapped) else panel.madctl[0];
        panel.modes[1] = .{
            .node = .{ .name = "on its side", .pri = 0 },
            .id = 2,
            .width = height,
            .height = width,
            .format = .rgb565,
            .pitch = height * 2,
        };
        sys.AddTail(&board.modes, &panel.modes[1].node);
    }

    board.region = .{
        .base = panel.frame,
        .size = panel.frames * panel.frame_bytes,
        .alignment = sdk.hardware.DCACHE_LINE_SIZE,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED,
    };
    board.ops = &ops;
    board.info.buffers = panel.frames;
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
    if (panel.frame_memory) |frame| panel.sys.FreeVec(frame);
    panel.band = null;
    panel.frame = null;
    panel.frame_memory = null;
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    const panel = panelOf(board);
    setBacklight(panel, false);
    giveBack(panel);
}

/// The mode is a way up: MADCTL says which, and the windows are cut from
/// its size from here on.
fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode) callconv(.c) i32 {
    const panel = panelOf(board);
    const which: usize = switch (mode.id) {
        1 => 0,
        2 => if (panel.modes[1].id == 2) 1 else return err.RTGERR_BAD_MODE,
        else => return err.RTGERR_BAD_MODE,
    };
    const code = command(panel, MADCTL, &panel.madctl[which], 1);
    if (code != err.RTGERR_OK) return code;
    panel.width = panel.modes[which].width;
    panel.height = panel.modes[which].height;
    panel.turn = if (which == 1) panel.swapped_turn else .none;
    return err.RTGERR_OK;
}

/// Show that buffer: all of it goes over the bus, and it is what a refresh
/// sends from then on. The controller has no second picture to flip to,
/// so a new buffer shown is a whole picture sent.
fn showBitMap(board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    if (x != 0 or y != 0) return err.RTGERR_NOT_SUPPORTED;
    const bm = bitmap orelse return err.RTGERR_OK;
    if (bm.pixels == null) return err.RTGERR_BAD_ARG;
    if (bm.width != panel.width or bm.height != panel.height) return err.RTGERR_NOT_DISPLAYABLE;
    if (bm.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    panel.stats.buffer_swaps += 1;
    return send(panel, bm, 0, bm.height);
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
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    panel.stats.refreshes += 1;
    panel.stats.rows_refreshed +%= if (rows == 0) bitmap.height else rows;
    if (board.showing != bitmap) {
        panel.stats.refreshes_dropped += 1;
        return err.RTGERR_OK;
    }
    const top = @min(y, bitmap.height);
    const end = if (rows == 0) bitmap.height else @min(y +| rows, bitmap.height);
    markAsked(panel, top, end);
    return send(panel, bitmap, y, rows);
}

/// Rows `top` to `end` marked as asked for.
fn markAsked(panel: *Panel, top: u32, end: u32) void {
    var row = top;
    while (row < end and row < rows_marked) : (row += 1) {
        panel.asked[row / 8] |= @as(u8, 1) << @intCast(row % 8);
    }
}

/// Rows `y` to `y + rows` of `bm` (0: all of them) to the panel, upright
/// or turned, and a count of the sends that did not get there.
fn send(panel: *Panel, bm: *rtg.RtgBitMap, y: u32, rows: u32) i32 {
    const code = if (panel.turn != .none) sendTurned(panel, bm, y, rows) else sendUpright(panel, bm, y, rows);
    // A send that stopped part way has told the panel a window and then
    // not filled it, so what is on the glass is part old and part new.
    if (code != err.RTGERR_OK) panel.stats.failed_sends += 1;
    return code;
}

/// Rows `y` to `y + rows` of `bm` (0: all of them) to the controller, in
/// bands of whole alignments, each with its window.
fn sendUpright(panel: *Panel, bm: *rtg.RtgBitMap, y: u32, rows: u32) i32 {
    const rb = panel.rtg_base;
    const pixels = bm.pixels orelse return err.RTGERR_BAD_ARG;
    const band = panel.band orelse return err.RTGERR_NO_MEMORY;
    const area = sequence.window(y, rows, bm.height, panel.alignment);
    const row_bytes = bm.width * 2;
    const columns = windowBytes(0, bm.width - 1);

    var code: i32 = err.RTGERR_OK;
    var row = area.top;
    while (row < area.end) {
        const count = @min(panel.band_rows, area.end - row);
        const lines = windowBytes(row, row + count - 1);
        // Filled and sent with nothing else running, for the reason
        // `oneBand` gives: the band is the board's only one.
        code = band_done: {
            panel.sys.Forbid();
            defer panel.sys.Permit();
            for (0..count) |i| {
                // Rows start on the region's alignment, a whole cache line.
                const from: [*]align(4) const u8 = @alignCast(pixels + (row + i) * bm.pitch);
                const into: [*]align(4) u8 = @alignCast(band + i * row_bytes);
                sequence.swapPixels(into[0..row_bytes], from[0..row_bytes]);
            }
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
fn sendTurned(panel: *Panel, bm: *rtg.RtgBitMap, y: u32, rows: u32) i32 {
    const rb = panel.rtg_base;
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

/// One band filled and sent, with nothing else running.
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
/// So the fill and the transfer are one thing, and nothing else runs
/// while they happen. Nothing in here waits - a transfer is polled, not
/// slept on - so this is a pause of about a millisecond and never a
/// stall.
///
/// The window is set per band rather than once per send, which is what
/// lets the pause be one band instead of a whole picture: each band
/// says where it goes, so another task's send in between cannot leave
/// this one writing into its window.
fn oneBand(
    panel: *Panel,
    rb: *RtgBase,
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
    panel.sys.Forbid();
    defer panel.sys.Permit();
    sequence.turnedBand(band[0 .. count * row_bytes], picture, row, count, first_column, count_columns);
    return writeBand(panel, rb, columns, lines, band, count * row_bytes);
}

/// How often a band whose transfer ran dry is sent again before its rows
/// are left wrong on the glass.
const underrun_tries = 3;

/// A filled band to the controller: its window, then its pixels. A
/// transfer the DMA fell behind in is counted and sent again - the band
/// is still in its buffer and says where it goes, so a second go lands
/// on the same pixels. The caller holds Forbid, as filling it needs.
fn writeBand(
    panel: *Panel,
    rb: *RtgBase,
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

/// A command on its own, sent with nothing else running, as a band is: a
/// transaction set up on the bus and then set aside would have its
/// registers written over by another task's band before it started.
fn command(panel: *Panel, cmd: i32, params: ?*const anyopaque, size: u32) i32 {
    panel.sys.Forbid();
    defer panel.sys.Permit();
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
/// nothing up here: a board is made when something asks for one, on a bus
/// that was made first.
fn init(seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*anyopaque {
    _ = seg_list;
    const library = sys.OpenLibrary(rtg.RTGNAME, VERSION) orelse return @ptrCast(sys);
    const rb: *RtgBase = @ptrCast(library);

    const memory = sys.AllocVec(@sizeOf(State), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    };
    const state: *State = @ptrCast(@alignCast(memory));
    state.* = .{ .sys = sys };
    state.driver = .{
        .node = .{ .name = DRIVER_NAME, .pri = 0 },
        .version = VERSION,
        .revision = REVISION,
        .id_string = VERSION_STRING[1..],
        .type = rtg.boards.RTGDT_BOARD,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Panel),
    };
    if (!rb.AddRtgDriver(&state.driver)) {
        sys.FreeVec(memory);
        sys.CloseLibrary(library);
        return @ptrCast(sys);
    }
    return @ptrCast(sys);
}

/// No library and no vectors: the tag's init is the whole of it.
export const rtg_dcs_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rtg_dcs_tag,
    .flags = exec.RTF_COLDSTART,
    .version = VERSION,
    .pri = 22,
    .type = .rtg_driver,
    .name = MODULE_NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&init)),
};

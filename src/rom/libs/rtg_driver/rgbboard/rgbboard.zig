// SPDX-License-Identifier: MPL-2.0
//! An RGB panel as a display board: the chip's LCD_CAM peripheral, a
//! framebuffer, and the two DMA channels that keep the panel fed.
//!
//! A module of its own: a description of a driver called "rgb" behind a
//! ROM tag, which rtg.library puts on its list. It takes a panel on
//! LCD_CAM (`BUS_LCD`): rtg.library offers it such a part of the board's
//! list with the panel's numbers in its tags, and the driver brings the
//! panel up and makes its board, ready to be given a buffer to show.
//! Which numbers those are - this board's, or another one's - is the
//! list's business; this driver knows the peripheral, not the machine it
//! is soldered to.
//!
//! The module keeps nothing of its own. A ROM image is read only, so what
//! changes is the library's to allocate, and every entry point finds it
//! again through what it is handed: an op has the board, the board has
//! its driver's node, and the node has exec and rtg.library. Per-board
//! state is the `Panel` the library allocates beside each handle.
//!
//! A picture may also be several buffers at once, in bands of lines
//! (ShowBoard): the copy's chains then take each line from the band
//! that covers it, a descriptor a line, so a band starts on any line.
//!
//! The order matters and none of it is optional. The driver's `attach`
//! lets the panel out of reset, takes its memory and its DMA channels and
//! programs the peripheral; the first show (`show`, with the mode set
//! anew) puts the timings in, and its picture is what starts the pixel
//! stream. That the stream waits for a picture is not decoration: the
//! first picture has to be drawn and written back out of the cache while
//! nothing is reading it, and a 1.2 MB write-back landing on top of a
//! running stream is enough to starve it.

const std = @import("std");
const sdk = @import("sdk");
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;
const tags = rtg.tags;
const expander = sdk.resources.expander;

const config = @import("config.zig");
const panels = @import("panel.zig");
const Panel = panels.Panel;
const lcd = @import("lcd.zig");
const pointer = @import("pointer.zig");

const DRIVER_NAME = "rgb";
/// The panel shows RGB565 and nothing else: two bytes a pixel.
const bytes_per_pixel = 2;
const VERSION = 1;
const REVISION = 14;
const BUILD_DATE = "17.11.2026";
const VERSION_STRING =
    "\x00$VER: " ++ panels.MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn panelOf(board: *rtg.RtgBoard) *Panel {
    return @ptrCast(@alignCast(board.instance.?));
}

/// A panel on LCD_CAM is offered: brought up, and a board made of it.
fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const sys = driver.sys_base;
    const rb = driver.rtg_base;
    // There is one peripheral: a second panel on it is declined.
    if (driver.boards != 0) return err.RTGERR_IN_USE;

    const wanted = config.read(rb, tag_list) orelse return err.RTGERR_BAD_TAGS;

    const board = rb.CreateBoard(driver, device, &.{
        .ops = &ops,
        .instance_size = @sizeOf(Panel),
        .flags = rtg.boards.RTGBF_STREAMING,
        // The stream's copy reads every band of a show itself.
        .direct_bands = rtg.RTG_MAX_BANDS,
        // It sends its lines last first, and cannot turn one round.
        .caps = rtg.boards.RTGBC_MIRROR_Y,
    }) orelse return err.RTGERR_NO_MEMORY;
    const panel = panelOf(board);
    panel.* = .{ .sys = sys, .rtg_base = rb, .board = board, .config = wanted };
    // A panel with no display line has nothing to go dark by but its
    // pictures, which is the library's.
    if (wanted.display_pin.kind == sdk.expansion.boardpin.BPIN_NONE) board.ops = &ops_no_line;
    // The backlight: a part with a brightness of its own, a line that
    // is on or off, or none.
    board.info.brightness_steps = switch (wanted.backlight_pin.kind) {
        sdk.expansion.boardpin.BPIN_NONE => 0,
        sdk.expansion.boardpin.BPIN_DRIVER => 101,
        else => 2,
    };

    const code = panels.bringUp(panel);
    if (code != err.RTGERR_OK) {
        rb.DeleteBoard(board);
        return code;
    }

    // One mode: the panel is what it is, and a panel is not a monitor.
    const setup = &panel.config.setup;
    panel.pitch = setup.width * (setup.bits_per_pixel / 8);
    if (rb.AddBoardMode(board, &panel.config.timings, @intFromEnum(rtg.PixelFormat.rgb565), rtg.modes.RTGMF_DEFAULT) == 0) {
        _ = panels.giveBack(panel, err.RTGERR_NO_MEMORY);
        rb.DeleteBoard(board);
        return err.RTGERR_NO_MEMORY;
    }

    // The panel shows a picture wherever it is, so its buffers are taken
    // from system memory as they are asked for - a line-aligned block
    // each, since the DMA reaches PSRAM a cache line at a time - and no
    // more than `frames` of them at once.
    board.region = .{
        .size = panel.frames * panel.frame_bytes,
        .alignment = sdk.hardware.DCACHE_LINE_SIZE,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED | rtg.boards.RTGRF_SYSTEM_MEMORY,
    };
    board.info.buffers = panel.frames;
    return err.RTGERR_OK;
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    const panel = panelOf(board);
    _ = panels.giveBack(panel, err.RTGERR_OK);
}

/// One mode, the panel's own: putting the board in it is what programs the
/// pads, the timings and the clock.
fn setMode(board: *rtg.RtgBoard, _: *const rtg.RtgMode, _: *const rtg.RtgTimings) i32 {
    return panels.program(panelOf(board));
}

/// Feed the panel from that buffer. The first time, this is what starts the
/// stream, and what a caller that has drawn its first picture calls to see
/// it. With the stream running it is a flip: the buffer is shown from the
/// next frame on, whole, and this returns when it is - the one it replaced
/// is no longer read.
fn showBitMap(board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap) i32 {
    const panel = panelOf(board);
    const bm = bitmap orelse {
        if (panel.streaming) {
            lcd.stop();
            panel.streaming = false;
        }
        return err.RTGERR_OK;
    };
    const pixels = bm.pixels orelse return err.RTGERR_BAD_ARG;
    const setup = &panel.config.setup;
    if (bm.width != setup.width or bm.height != setup.height) return err.RTGERR_NOT_DISPLAYABLE;
    if (bm.pitch != panel.pitch) return err.RTGERR_NOT_DISPLAYABLE;
    if (bm.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    // Sent last line first, a picture is a chain a line, as bands are.
    if (panel.mirror_y) return panels.showBands(panel, &.{.{ .bitmap = bm }});
    if (panel.streaming and panel.aligned) return panels.flip(panel, pixels);
    return panels.start(panel, pixels);
}

/// Several buffers at once, in bands: the copy reads each display line
/// from the row of the band that covers it, so a band may start on any
/// line. Shown from the next frame on, as a flip is.
fn showBands(board: *rtg.RtgBoard, bands: [*]const rtg.RtgBand, count: u32) i32 {
    const panel = panelOf(board);
    for (bands[0..count]) |band| {
        const bm = band.bitmap;
        if (bm.pixels == null) return err.RTGERR_BAD_ARG;
        if (bm.pitch != panel.pitch) return err.RTGERR_NOT_DISPLAYABLE;
        if (bm.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    }
    return panels.showBands(panel, bands[0..count]);
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

/// A rectangle the CPU wrote, handed to the panel: it reads that memory
/// without going through the cache, so what was written has to be pushed
/// out of it first. The stream never stops, so that is the whole of it.
///
/// A rectangle at least half a row wide goes as its rows, in one stretch;
/// a narrower one a row at a time, its own bytes alone, so the side of a
/// window's frame does not write back the rows it runs down.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect) callconv(.c) i32 {
    const sys = panelOf(board).sys;
    const pixels = bitmap.pixels orelse return err.RTGERR_BAD_ARG;
    const top: usize = @intCast(area.y);
    const rows: u32 = @intCast(area.height);
    const wide: u32 = @as(u32, @intCast(area.width)) * bytes_per_pixel;
    const first = @intFromPtr(pixels) + top * bitmap.pitch;
    if (wide * 2 >= bitmap.pitch) {
        var bytes: u32 = rows * bitmap.pitch;
        _ = sys.CachePreDMA(@ptrFromInt(first), &bytes, 0);
        return err.RTGERR_OK;
    }
    const left: usize = @as(usize, @intCast(area.x)) * bytes_per_pixel;
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var bytes: u32 = wide;
        _ = sys.CachePreDMA(@ptrFromInt(first + @as(usize, row) * bitmap.pitch + left), &bytes, 0);
    }
    return err.RTGERR_OK;
}

/// The board's power state, by the panel's display enable - a line on
/// whatever the board wired it to: off while the board is blank or
/// asleep, the stream running on, and asleep the backlight off too.
/// Awake, the line is on again and the backlight as the library keeps
/// it.
fn power(board: *rtg.RtgBoard, state: u32) callconv(.c) i32 {
    const panel = panelOf(board);
    const on = state == rtg.boards.RTGPWR_ON;
    if (state == rtg.boards.RTGPWR_ASLEEP) _ = light(panel, 0);
    if (!panels.setDisplayLine(panel, on)) return err.RTGERR_NO_DISPLAY;
    if (on) _ = light(panel, board.info.brightness);
    return @intCast(state);
}

/// The backlight, 0 to 100, the right way round whatever the part does.
fn setBrightness(board: *rtg.RtgBoard, percent: u32) callconv(.c) i32 {
    return if (light(panelOf(board), percent)) err.RTGERR_OK else err.RTGERR_NO_DISPLAY;
}

/// The backlight driven: a part of the expander with a brightness of its
/// own, or a line that is on for anything above 0. False for one that
/// did not take it, and where none is wired.
fn light(panel: *Panel, percent: u32) bool {
    const pin = panel.config.backlight_pin;
    return switch (pin.kind) {
        sdk.expansion.boardpin.BPIN_NONE => false,
        sdk.expansion.boardpin.BPIN_DRIVER => blk: {
            const ex = panels.openExpander(panel) orelse break :blk false;
            break :blk ex.SetBacklight(percent);
        },
        else => panels.setLine(panel, pin, percent != 0),
    };
}

/// The picture sent last line first, or as it lies: mirrored top to
/// bottom by the order of its lines. A line is never turned round. The
/// library has what is shown shown again, which makes the copy's chains
/// in the new order.
fn mirror(board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) callconv(.c) i32 {
    if (mirror_x) return err.RTGERR_NOT_SUPPORTED;
    panelOf(board).mirror_y = mirror_y;
    return err.RTGERR_OK;
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

fn setPointer(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    return pointer.setPointer(panelOf(board), image);
}

fn movePointer(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    pointer.movePointer(panelOf(board), left, top);
}

fn showPointer(board: *rtg.RtgBoard, show: bool) callconv(.c) i32 {
    return pointer.showPointer(panelOf(board), show);
}

fn setOverlay(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    return pointer.setOverlay(panelOf(board), image);
}

fn moveOverlay(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    pointer.moveOverlay(panelOf(board), left, top);
}

/// The pointer and the overlay are the stream's own: laid into its copy
/// on the way to the glass, in the interrupt that fills it.
const pointer_ops = rtg.RtgPointerOps{ .set = &setPointer, .move = &movePointer, .show = &showPointer };
const overlay_ops = rtg.RtgOverlayOps{ .set = &setOverlay, .move = &moveOverlay };

/// What this board has. No engine: this chip has nothing that draws, so
/// a caller that wants a rectangle filled fills it itself.
const ops = rtg.RtgBoardOps{
    .destroy = &destroy,
    .show = &showOp,
    .refresh = &refresh,
    .power = &power,
    .set_brightness = &setBrightness,
    .mirror = &mirror,
    .stats = &stats,
    .control = &control,
    .pointer = &pointer_ops,
    .overlay = &overlay_ops,
};

/// The same for a panel with no display line wired.
const ops_no_line = made: {
    var less = ops;
    less.power = null;
    break :made less;
};

const driver_ops = rtg.RtgDriverOps{ .attach = &attach };

/// What it takes: a panel on LCD_CAM.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_BUS, .bus = sdk.expansion.systemtags.BUS_LCD },
    .{},
};

/// The driver's tag: a description and no init. rtg.library reads it at
/// its own init and puts the driver on its list; nothing is brought up
/// until a board is asked for.
export const rtg_rgb_tag: rtg.ResidentRtgDriver linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&rtg_rgb_tag),
        .version = VERSION,
        .type = .rtg_driver,
        .name = panels.MODULE_NAME,
        .id_string = VERSION_STRING[1..], // past the NUL: a C string
    },
    .spec = .{
        .name = DRIVER_NAME,
        .id_string = VERSION_STRING[1..],
        .version = VERSION,
        .revision = REVISION,
        .kind = rtg.drivers.RTGDT_BOARD,
        // Its refill interrupt reads the panel sixty times a frame, while
        // both DMA channels are working the memory a display streams out
        // of. Reading the panel out of that same memory costs the copy the
        // time it has to make the next bufferful ready in.
        .flags = rtg.drivers.RTGDF_INTERNAL_INSTANCE,
        .matches = &matches,
        .ops = &driver_ops,
    },
};

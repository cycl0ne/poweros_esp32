// SPDX-License-Identifier: MPL-2.0
//! The emulator's virtual display as a display board.
//!
//! A module of its own, on the same footing as the panel driver: a
//! description of a driver called "qemu" behind a ROM tag, which
//! rtg.library puts on its list. It takes the emulator's display
//! (`CHIP_QEMU_DISPLAY`), and makes a board of it when the board's list
//! has that part.
//!
//! What it drives is a frame of memory and a doorbell. The device owns the
//! pixels - they are its own VRAM, not the machine's - and a register says
//! "this rectangle changed, put it on the window". There is no stream to
//! keep fed, no DMA, no blanking and no timing: the picture is whatever is
//! in VRAM the last time the doorbell was rung. Nothing here is a
//! simplified version of the panel's driver - the two have almost nothing
//! in common below the board interface, which is the point of having the
//! interface.
//!
//! The window reads one whole buffer by itself: a board's buffers are cut
//! out of the VRAM, so showing one is the doorbell rung with its address,
//! and nothing is copied. That is how the board is shown for as long as
//! nothing lies over the picture.
//!
//! Anything more - a pointer, a dragged icon, a screen pulled down over
//! the one behind - is one picture only in a frame it is composed in. The
//! doorbell copies at the window's next refresh, not when it is rung, so
//! a pointer cannot be put into the shown buffer, rung and taken out
//! again. The board has a frame of its own for that, in the VRAM past its
//! buffers, and rtg.library composes the picture in it: the board is told
//! which rectangle of its display changed (`update`), fetches those
//! pixels from the library straight into the frame (`ComposeLines`), and
//! rings the doorbell with the frame's address. A pointer's move is then
//! the image's rectangle and not the picture.
//!
//! It exists so that the layers above it can be looked at before anything
//! is flashed. A board here means rtg.library lists a display,
//! graphics.library finds a View, and what is drawn can be seen - in the
//! emulator's window, or captured from its monitor without one.
//!
//! The module keeps nothing of its own: a ROM image is read only, so what
//! changes is the library's to allocate - a `Screen` beside each board -
//! and found again through what an op is handed.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;

const qemu_rgb = sdk.hardware.qemu_rgb;
const tags = rtg.tags;
const RtgBase = sdk.interface.rtg.RtgBase;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;

const MODULE_NAME = "rtg-qemu";
const DRIVER_NAME = "qemu";
const VERSION = 1;
const REVISION = 10;
const BUILD_DATE = "16.11.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const bytes_per_pixel = 2;

/// Everything one board of this driver has. The library allocates it
/// beside the handle.
const Screen = struct {
    sys: *ExecBase,
    /// What the device is asked to show: RTGA_Width and RTGA_Height, the
    /// screen of the board the image was built for, so a board here is
    /// the same shape as the real one and what is seen in the window is
    /// what the glass would show.
    width: u32 = 0,
    height: u32 = 0,
    /// Whether the window is fed a picture.
    shown: bool = false,
    /// The buffer the window reads by itself, while the board is shown
    /// direct; null while it is fed from the composed frame, and while
    /// nothing is shown.
    direct: ?*rtg.RtgBitMap = null,
    /// How many times the picture has been handed to the window. There is
    /// no blanking to count, so this is the only number worth having.
    updates: u32 = 0,
    /// The frame the library's picture is composed in, past the board's
    /// buffers in VRAM; null when there was no room, and the board then
    /// shows one whole buffer and no more.
    composed: ?[*]u8 = null,
};

/// A frame of the display waited out, after a flip: the window has no
/// frames of its own, so the library waits by the clock, and a program
/// that flips runs here at the speed it runs on the glass.
fn pace(board: *rtg.RtgBoard) void {
    const rb: *RtgBase = @ptrCast(board.rtg_base.?);
    _ = rb.WaitVBlank(board, 1);
}

fn screenOf(board: *rtg.RtgBoard) *Screen {
    return @ptrCast(@alignCast(board.instance.?));
}

/// Hand the window everything in a frame of the VRAM.
///
/// INPUTS:
/// - `screen` - the board's own state, whose `updates` this counts.
/// - `from` - the frame: a shown buffer's pixels, or the composed frame.
///
/// BEHAVIOR:
/// The device copies from the address it is given at its own pace, so a
/// caller never waits. The whole frame goes every time: the device takes a
/// rectangle, but the window is small enough that working out the union of
/// what changed would cost more than sending it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. Four register writes and nothing else.
/// - Locks: none needed.
/// - Process: a Task will do.
fn present(screen: *Screen, from: [*]const u8) void {
    qemu_rgb.update(@intFromPtr(from), @intCast(screen.width), @intCast(screen.height));
    screen.updates +%= 1;
}

/// The emulator's display is offered: a board made of it, in the size
/// its tags give.
fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const sys = driver.sys_base;
    const rb = driver.rtg_base;
    // There is one virtual display: a second part of it is declined.
    if (driver.boards != 0) return err.RTGERR_IN_USE;

    const width: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Width, 0, tag_list));
    const height: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Height, 0, tag_list));
    // The window shows RGB565 and nothing else.
    const format = rb.GetRtgTagData(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.rgb565), tag_list);
    if (format != @intFromEnum(rtg.PixelFormat.rgb565)) return err.RTGERR_BAD_FORMAT;
    // The device takes each side as 16 bits.
    if (width == 0 or height == 0) return err.RTGERR_BAD_TAGS;
    if (width > 0xFFFF or height > 0xFFFF) return err.RTGERR_BAD_TAGS;
    // A picture's bytes, in 64 bits: two sides of 16 bits and two bytes a
    // pixel do not fit in 32.
    const frame: u64 = @as(u64, width) * height * bytes_per_pixel;
    // As many pictures as the board asks for and the VRAM holds are as
    // many buffers as can be shown in turn, each by naming its address.
    const room: u32 = @intCast(qemu_rgb.vramSize() / frame);
    if (room == 0) return err.RTGERR_BAD_TAGS;
    const asked: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list));
    const frames = @min(@max(asked, 1), room);
    // A frame more, if there is one, for the picture the library
    // composes: a board without it has no pointer and no bands.
    const composed: ?[*]u8 = if (frames < room) @ptrFromInt(qemu_rgb.vram + frames * @as(usize, @intCast(frame))) else null;

    // The device's own VRAM is the board's display memory, so a buffer cut
    // out of it is already where the device reads from and a refresh is a
    // doorbell rather than a copy. It is not cached: these are device
    // bytes, and nothing has to be written back before they are read.
    const board = rb.CreateBoard(driver, device, &.{
        // A pointer, an overlay and bands are one picture only in the
        // frame they are composed in.
        .ops = if (composed != null) &composing_ops else &ops,
        .instance_size = @sizeOf(Screen),
        // The window reads one whole buffer of the VRAM by itself.
        .direct_bands = 1,
        .region = .{
            .base = @ptrFromInt(qemu_rgb.vram),
            .size = frames * @as(usize, @intCast(frame)),
            .alignment = bytes_per_pixel,
            .flags = rtg.boards.RTGRF_DISPLAYABLE,
        },
    }) orelse return err.RTGERR_NO_MEMORY;
    const screen = screenOf(board);
    screen.* = .{ .sys = sys, .width = width, .height = height, .composed = composed };

    // One mode. A virtual display is not a monitor either: it is the shape
    // the emulator was built for, and has no clock of its own.
    const window: rtg.RtgTimings = .{ .h_active = width, .v_active = height };
    if (rb.AddBoardMode(board, &window, @intFromEnum(rtg.PixelFormat.rgb565), rtg.modes.RTGMF_DEFAULT) == 0) {
        rb.DeleteBoard(board);
        return err.RTGERR_NO_MEMORY;
    }
    board.info.buffers = frames;
    return err.RTGERR_OK;
}

/// One mode, so this only ever sizes the window to it.
fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode, _: *const rtg.RtgTimings) i32 {
    const screen = screenOf(board);
    if (mode.width != screen.width or mode.height != screen.height) return err.RTGERR_BAD_MODE;
    if (!qemu_rgb.init(@intCast(screen.width), @intCast(screen.height))) {
        // A stock Espressif QEMU stops its window at 800 pixels.
        exec.kprintf(screen.sys, "%s: the window will not take %dx%d; build QEMU with scripts/build-qemu.sh\n", .{ MODULE_NAME, screen.width, screen.height });
        return err.RTGERR_BAD_MODE;
    }
    return err.RTGERR_OK;
}

/// The board's one op for what is on the glass (`RtgShow`): put in the
/// mode where the library says it is to be, then shown - one whole buffer
/// the window reads by itself, the library's picture in the composed
/// frame, or nothing. The window takes the whole picture at its next
/// refresh, so it never shows half of one and half of another. With the
/// mode set anew a show that fails leaves the board showing nothing.
fn showOp(board: *rtg.RtgBoard, what: *const rtg.RtgShow) callconv(.c) i32 {
    const screen = screenOf(board);
    const anew = what.flags & rtg.boards.RTGSHOW_MODE_CHANGED != 0;
    if (anew) {
        const code = setMode(board, what.mode, what.timings);
        if (code != err.RTGERR_OK) return code;
    }
    const code = showThese(board, what);
    if (code != err.RTGERR_OK and anew) {
        screen.shown = false;
        screen.direct = null;
    }
    return code;
}

/// What a show asks for, in the mode the board is in.
fn showThese(board: *rtg.RtgBoard, what: *const rtg.RtgShow) i32 {
    const screen = screenOf(board);
    const bands = what.bands orelse &[0]rtg.RtgBand{};
    if (what.count == 0) {
        // Nothing to feed the window from: it keeps what it last took.
        screen.shown = false;
        screen.direct = null;
        return err.RTGERR_OK;
    }
    // A flip from one picture to another takes a frame, as on the glass.
    // The first picture shown is not waited for: it comes up at cold
    // start.
    const flip = screen.shown;
    if (what.flags & rtg.boards.RTGSHOW_DIRECT != 0) {
        // The device reads packed rows out of its VRAM: a buffer cut
        // from the region, the mode's size and pitch, which the library
        // has checked.
        const bitmap = bands[0].bitmap;
        const pixels = bitmap.pixels orelse return err.RTGERR_BAD_ARG;
        screen.direct = bitmap;
        screen.shown = true;
        present(screen, pixels);
    } else {
        const code = compose(board, &.{ .width = @intCast(screen.width), .height = @intCast(screen.height) });
        if (code != err.RTGERR_OK) return code;
        screen.direct = null;
        screen.shown = true;
        present(screen, screen.composed.?);
    }
    if (flip) pace(board);
    return err.RTGERR_OK;
}

/// A rectangle of the library's picture fetched into the composed frame.
fn compose(board: *rtg.RtgBoard, area: *const rtg.RtgRect) i32 {
    const screen = screenOf(board);
    const composed = screen.composed orelse return err.RTGERR_NOT_SUPPORTED;
    const rb: *RtgDriverBase = @ptrCast(board.rtg_base.?);
    const pitch = screen.width * bytes_per_pixel;
    const at = composed + @as(usize, @intCast(area.y)) * pitch + @as(usize, @intCast(area.x)) * bytes_per_pixel;
    return rb.ComposeLines(board, area, at, pitch);
}

/// A rectangle of the display changed while the window is fed from the
/// composed frame: fetched into it, and the doorbell rung.
fn update(board: *rtg.RtgBoard, area: *const rtg.RtgRect) callconv(.c) i32 {
    const screen = screenOf(board);
    const code = compose(board, area);
    if (code != err.RTGERR_OK) return code;
    present(screen, screen.composed.?);
    return err.RTGERR_OK;
}

/// A rectangle of a buffer was written by the CPU. It is already in the
/// device's memory, so where the window reads that buffer this is the
/// doorbell and nothing more. Any other buffer is a program drawing
/// ahead, or one the composed frame shows: nothing to hand to the window
/// here.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, _: *const rtg.RtgRect) callconv(.c) i32 {
    const screen = screenOf(board);
    if (screen.direct != bitmap) return err.RTGERR_OK;
    present(screen, bitmap.pixels.?);
    return err.RTGERR_OK;
}

fn stats(board: *rtg.RtgBoard, into: *rtg.RtgBoardStats) callconv(.c) void {
    const screen = screenOf(board);
    into.frames = screen.updates;
}

/// A board with no frame to compose in: one whole buffer, read by the
/// window itself.
const ops = rtg.boards.RtgBoardOps{
    .show = &showOp,
    .refresh = &refresh,
    .stats = &stats,
    .control = &control,
};

/// A board with a frame for the library's picture: the same, and told
/// which rectangle of its display changed.
const composing_ops = rtg.boards.RtgBoardOps{
    .show = &showOp,
    .refresh = &refresh,
    .update = &update,
    .stats = &stats,
    .control = &control,
};

/// The board's own controls: its counter of pictures handed to the
/// window is put back to none with the others.
fn control(board: *rtg.RtgBoard, what: u32, value: isize) callconv(.c) isize {
    _ = value;
    if (what != rtg.boards.RTGCTRL_RESET_STATS) return err.RTGERR_NOT_SUPPORTED;
    screenOf(board).updates = 0;
    return err.RTGERR_OK;
}

const driver_ops = rtg.RtgDriverOps{ .attach = &attach };

/// What it takes: the emulator's display.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = sdk.expansion.systemtags.CHIP_QEMU_DISPLAY },
    .{},
};

/// The driver's tag: a description and no init. rtg.library reads it at
/// its own init and puts the driver on its list; nothing of this module
/// runs until a board is asked for.
export const rtg_qemu_tag: rtg.ResidentRtgDriver linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&rtg_qemu_tag),
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

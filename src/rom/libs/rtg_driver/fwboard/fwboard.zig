// SPDX-License-Identifier: MPL-2.0
//! A display that reads one picture out of the machine's RAM and has
//! nothing else to be told, as a display board: the framebuffer a UEFI
//! firmware has already lit (`uefi.zig`), which reads the one buffer it
//! was given, and QEMU's ramfb (`ramfb.zig`), which reads wherever it is
//! told.
//!
//! A module of its own, on the same footing as the other drivers: a
//! description of a driver called "fw" behind a ROM tag, which
//! rtg.library puts on its list. It takes a panel part of one of the two
//! and makes a board of each it is offered.
//!
//! Each has one mode, the size its part names. Neither is flipped: the
//! picture is rtg.library's to compose where the display reads it. With
//! nothing over the picture the ramfb reads the shown buffer itself, and
//! nothing is copied (`direct_bands`). While a pointer or the overlay is
//! shown, or the picture is several in bands, it reads a frame of the
//! driver's own instead: the board is told which rectangle of the display
//! changed (`update`) and fetches it from the library into that frame
//! (`ComposeLines`), no wider than what was written, so a pointer's move
//! costs the pointer's size and not the picture's. The firmware's
//! framebuffer is such a frame already, the only thing the display
//! reads: the library's picture is fetched straight into it, at the
//! firmware's own row length. The ramfb's frame is taken when it is first
//! needed, and stays. Black, as the display comes up or when nothing is
//! shown, is that frame cleared.
//!
//! The buffers are the machine's RAM below 4 GiB (MEMF_DMA): the library
//! takes each when it is allocated and gives it back when it is freed
//! (RTGRF_SYSTEM_MEMORY, RTGRF_DMA_MEMORY), at most as many pictures of
//! the mode as the board asks for (RTGA_Buffers). They are reached
//! through the caches (`RTGRF_CPU_CACHED`), so a refresh hands the rows
//! on with exec's CacheClearE, and whether that writes them back is the
//! machine's to say. The firmware's framebuffer is reached
//! write-combining and nothing is written back for it.
//!
//! Neither has an interrupt at a frame: the library waits as long as a
//! frame takes. Neither can be stopped: the firmware's display reads its
//! buffer for as long as nothing else drives it, and the ramfb the last
//! address it was told.
//!
//! The module keeps nothing of its own: a ROM image is read only, so what
//! changes is the library's to allocate - a `Screen` beside each board -
//! and found again through what an op is handed.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;
const st = sdk.expansion.systemtags;
const tags = rtg.tags;

const ramfb = @import("ramfb.zig");
const uefi = @import("uefi.zig");

const MODULE_NAME = "rtg-fw";
const DRIVER_NAME = "fw";
const VERSION = 1;
const REVISION = 1;
const BUILD_DATE = "16.11.2026";
const VERSION_STRING =
    "\x00$VER: " ++ MODULE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ VERSION, REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// What every row and every buffer starts on: whole cache lines, so a
/// refresh writes back exactly the rows it names.
const row_alignment = 128;
/// Where the frame of the driver's own starts.
const page = 4096;
/// The most pixels a side of the picture has: what fourteen bits hold,
/// which every size here is kept in.
const largest_side = 0x3FFF;

/// Which display, and what it was found to be.
const Display = union(enum) {
    ramfb: ramfb.Ramfb,
    uefi: uefi.Framebuffer,
};

/// Everything one board of this driver has. The library allocates it
/// beside the handle.
const Screen = struct {
    sys: *ExecBase,
    /// rtg.library, as the driver calls it.
    rtg_base: *RtgBase,
    display: Display,
    /// The picture: RTGA_Width by RTGA_Height in RTGA_PixelFormat, rows
    /// `pitch` bytes apart, `bytes` a pixel.
    width: u32 = 0,
    height: u32 = 0,
    format: rtg.PixelFormat = .bgra32,
    bytes: u32 = 4,
    pitch: u32 = 0,
    /// The board, and how many pictures it may have at once.
    board: *rtg.RtgBoard,
    buffers: u32 = 1,
    /// The number of the mode the display is in; 0 before the first.
    mode_id: u32 = 0,
    /// What a row of a buffer is rounded up to: the board's display
    /// memory's alignment, which the library rounds a mode's rows by.
    alignment: u32 = row_alignment,
    /// A picture of the largest mode it has been in, which the frame of
    /// the driver's own takes.
    frame_bytes: usize = 0,
    /// Where the display reads from; 0 before it has been told.
    scanning: usize = 0,
    /// The buffer at the display's bottom, as last shown, and whether a
    /// picture is shown at all.
    showing: ?*rtg.RtgBitMap = null,
    shown: bool = false,
    /// How many times the display has been handed a picture.
    updates: u32 = 0,
    /// On the ramfb: the frame of the driver's own that the library's
    /// picture is fetched into and black is shown from, as AllocMem gave
    /// it and where it starts. Null until it is needed (`ownFrame`).
    composed_memory: ?*anyopaque = null,
    composed: ?[*]u8 = null,
};

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

/// A rectangle of a picture: columns `left` up to `right`, rows `top` up
/// to `end`.
const Box = struct {
    left: u32,
    top: u32,
    right: u32,
    end: u32,
};

/// The whole display.
fn whole(screen: *const Screen) Box {
    return .{ .left = 0, .top = 0, .right = screen.width, .end = screen.height };
}

/// A picture of the display's size and rows at `pixels`: the frame of
/// the driver's own.
fn pictureAt(screen: *const Screen, pixels: ?[*]u8) rtg.RtgBitMap {
    return .{
        .pixels = pixels,
        .width = screen.width,
        .height = screen.height,
        .pitch = screen.pitch,
        .format = screen.format,
    };
}

/// `box` of a picture the CPU has written, where the ramfb reads it:
/// written back out of the caches - a run a row, one run over the rows
/// where the box is as wide as the picture. Nothing for the firmware's
/// framebuffer: the display reads only what is reached write-combining
/// there, and the buffers drawn in are read by the cores.
fn handOn(screen: *Screen, picture: *const rtg.RtgBitMap, box: Box) void {
    if (screen.display == .uefi) return;
    if (box.left >= box.right or box.top >= box.end) return;
    const pixels = picture.pixels orelse return;
    const pitch = picture.pitch;
    const sys = screen.sys;
    if (box.left == 0 and box.right >= picture.width) {
        sys.CacheClearE(pixels + box.top * pitch, (box.end - box.top) * pitch, exec.CACRF_ClearD);
        return;
    }
    const bytes = screen.rtg_base.RtgFormatBits(@intFromEnum(picture.format)) / 8;
    const left = box.left * bytes;
    const run = (box.right - box.left) * bytes;
    var y = box.top;
    while (y < box.end) : (y += 1) sys.CacheClearE(pixels + y * pitch + left, run, exec.CACRF_ClearD);
}

/// The display told to read `picture` from its next frame on: a buffer
/// of the mode it is in, as the library describes one. Whether it does:
/// a ramfb that refuses goes on reading where it read. The firmware's
/// framebuffer is told nothing: it reads the one buffer the firmware gave
/// it, which the picture is fetched into.
fn scanFrom(screen: *Screen, picture: *const rtg.RtgBitMap) bool {
    const address = @intFromPtr(picture.pixels orelse return false);
    if (address == screen.scanning) return true;
    const shown = switch (screen.display) {
        .ramfb => |device| ramfb.show(device, picture),
        .uefi => true,
    };
    if (shown) screen.scanning = address;
    return shown;
}

/// The frame of the driver's own that the library's picture is fetched
/// into, and black is shown from, taken when there is none yet: from a
/// page on, where the ramfb reads, the system's and not the task's that
/// happened to ask. Null without memory. Not cleared: it is written whole
/// before the display reads it.
fn ownFrame(screen: *Screen) ?[*]u8 {
    if (screen.composed) |frame| return frame;
    const memory = screen.sys.AllocMem(screen.frame_bytes + page, exec.MEMF_DMA | exec.MEMF_SYSTEM) orelse return null;
    screen.composed_memory = memory;
    screen.composed = @ptrFromInt((@intFromPtr(memory) + page - 1) & ~@as(usize, page - 1));
    return screen.composed;
}

// --- the board -------------------------------------------------------------------

/// The display the part is, if it is there.
fn findDisplay(driver: *rtg.RtgDriver, chip: u32, format: rtg.PixelFormat, tag_list: ?[*]const TagItem) ?Display {
    const rb = driver.rtg_base;
    const address = rb.GetRtgTagData(st.PART_Address, 0, tag_list);
    return switch (chip) {
        st.CHIP_QEMU_RAMFB => .{ .ramfb = ramfb.find(address) orelse return null },
        // Nothing to probe: the firmware set this one up, and the board
        // says what it set up.
        st.CHIP_UEFI_FB => .{ .uefi = uefi.find(
            address,
            @truncate(rb.GetRtgTagData(tags.RTGA_Pitch, 0, tag_list)),
            @truncate(rb.GetRtgTagData(tags.RTGA_Width, 0, tag_list)),
            @truncate(rb.GetRtgTagData(tags.RTGA_Height, 0, tag_list)),
            programs(rb).RtgFormatBits(@intFromEnum(format)) / 8,
        ) orelse return null },
        else => null,
    };
}

/// A display this drives is offered: found, and a board made of it with
/// its one mode.
fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const rb = driver.rtg_base;

    // What the tags have to say, looked at before anything is taken.
    const format: rtg.PixelFormat = @enumFromInt(@as(u8, @truncate(rb.GetRtgTagData(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32), tag_list))));
    if (format != .bgra32 and format != .rgb565) return err.RTGERR_BAD_FORMAT;
    const width: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Width, 0, tag_list));
    const height: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Height, 0, tag_list));
    if (width == 0 or height == 0) return err.RTGERR_BAD_TAGS;
    if (width > largest_side or height > largest_side) return err.RTGERR_BAD_TAGS;

    const display = findDisplay(driver, device.chip, format, tag_list) orelse return err.RTGERR_NO_DISPLAY;
    const board = rb.CreateBoard(driver, device, &.{
        .ops = &ops,
        .instance_size = @sizeOf(Screen),
        .format = format,
    }) orelse return err.RTGERR_NO_MEMORY;
    const screen = screenOf(board);
    screen.* = .{
        .sys = driver.sys_base,
        .rtg_base = programs(rb),
        .display = display,
        .width = width,
        .height = height,
        .format = format,
        .bytes = if (format == .bgra32) 4 else 2,
        .board = board,
    };
    // The board's buffers start, and their rows are rounded, as its tags
    // say; whole cache lines where they say nothing.
    const asked_alignment: u32 = @truncate(rb.GetRtgTagData(tags.RTGA_Alignment, 0, tag_list));
    if (asked_alignment != 0) screen.alignment = asked_alignment;
    // One mode of its own: the picture the board was built for, on a
    // display with no clock.
    const own: rtg.RtgTimings = .{ .h_active = width, .v_active = height };
    if (rb.AddBoardMode(board, &own, @intFromEnum(format), rtg.modes.RTGMF_DEFAULT) == 0) {
        rb.DeleteBoard(board);
        return err.RTGERR_NO_MEMORY;
    }
    screen.pitch = rowBytes(screen, width);

    // At most as many pictures of the mode as the board asks for, each
    // taken by the library as it is allocated, from memory the display
    // reaches. Not cleared: each is cleared before it is first shown. The
    // ramfb's own frame is taken as it is needed.
    const frame: usize = @as(usize, screen.pitch) * height;
    screen.frame_bytes = frame;
    screen.buffers = @max(@as(u32, @truncate(rb.GetRtgTagData(tags.RTGA_Buffers, 1, tag_list))), 1);
    // The ramfb reads one whole buffer by itself, the firmware's
    // framebuffer none.
    board.direct_bands = if (display == .ramfb) 1 else 0;
    board.region = .{
        .size = screen.buffers * frame,
        .alignment = screen.alignment,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED |
            rtg.boards.RTGRF_SYSTEM_MEMORY | rtg.boards.RTGRF_DMA_MEMORY,
    };
    board.info.buffers = screen.buffers;
    return err.RTGERR_OK;
}

fn destroy(board: *rtg.RtgBoard) callconv(.c) void {
    const screen = screenOf(board);
    if (screen.composed_memory) |memory| screen.sys.FreeMem(memory, screen.frame_bytes + page);
    screen.composed_memory = null;
    screen.composed = null;
}

/// Bytes a row of a buffer `width` pixels wide has: the pixels, rounded
/// up to the board's alignment, as the library rounds a mode's.
fn rowBytes(screen: *const Screen, width: u32) u32 {
    const row = width * screen.bytes;
    const step = screen.alignment;
    return (row + step - 1) / step * step;
}

/// The display brought up in `mode`, or changed to it: it comes up
/// black.
fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode) i32 {
    const screen = screenOf(board);
    // A row as the library makes one of a buffer: what this driver sizes
    // its frame by.
    if (mode.format != screen.format or mode.pitch != rowBytes(screen, mode.width)) return err.RTGERR_BAD_MODE;
    const changed = mode.id != screen.mode_id;
    screen.mode_id = mode.id;
    screen.width = mode.width;
    screen.height = mode.height;
    screen.pitch = mode.pitch;
    // Room for the mode: the board's display memory let hold as many
    // pictures of it as the board may have, and the frame of the driver's
    // own given back where a picture of the mode is larger than it is, to
    // be taken anew when it is next needed. A show holds the board's
    // compose lock: nothing is fetched into the frame meanwhile.
    const picture = @as(usize, screen.pitch) * screen.height;
    if (picture > screen.frame_bytes) {
        if (screen.composed_memory) |old| screen.sys.FreeMem(old, screen.frame_bytes + page);
        if (screen.composed) |gone| {
            if (screen.scanning == @intFromPtr(gone)) screen.scanning = 0;
        }
        screen.composed_memory = null;
        screen.composed = null;
        screen.frame_bytes = picture;
    }
    board.region.size = @as(usize, screen.buffers) * picture;
    if (screen.scanning == 0 or changed) {
        // What it read until now says nothing about the new mode.
        screen.scanning = 0;
        screen.shown = false;
        if (!showBlack(screen)) return err.RTGERR_NO_DISPLAY;
    }
    return err.RTGERR_OK;
}

/// The display showing black: the firmware's framebuffer cleared, or the
/// frame of the driver's own cleared and the ramfb reading it. False
/// without memory for that frame, and where the ramfb does not take it.
fn showBlack(screen: *Screen) bool {
    switch (screen.display) {
        .uefi => |fb| {
            var y: u32 = 0;
            while (y < @min(screen.height, fb.height)) : (y += 1) @memset(fb.row(y)[0 .. screen.width * screen.bytes], 0);
            screen.scanning = fb.pixels;
            return true;
        },
        .ramfb => {
            const black = ownFrame(screen) orelse return false;
            const bytes = @as(usize, screen.pitch) * screen.height;
            @memset(black[0..bytes], 0);
            const picture = pictureAt(screen, black);
            handOn(screen, &picture, whole(screen));
            return scanFrom(screen, &picture);
        },
    }
}

/// What the display shows from now on. No band is black. One whole
/// buffer the display is to read itself (`RTGSHOW_DIRECT`: the ramfb) is
/// read where it lies. Anything else is the picture the library composes
/// - bands, an overlay, a pointer - fetched whole into the firmware's
/// framebuffer, or into the frame of the driver's own, which the ramfb
/// then reads. A picture that takes the place of another is waited out
/// for a frame, as a flip is.
///
/// Nothing is changed where it fails: with no memory for that frame
/// (RTGERR_NO_MEMORY), and where the device does not take the address
/// (RTGERR_IO), the display reads what it read.
fn showPlain(screen: *Screen, what: *const rtg.RtgShow) i32 {
    const bands: []const rtg.RtgBand = if (what.bands) |list| list[0..what.count] else &.{};
    if (bands.len == 0) {
        if (!showBlack(screen)) return err.RTGERR_NO_MEMORY;
        screen.shown = false;
        return err.RTGERR_OK;
    }
    const last = bands[bands.len - 1].bitmap;
    // The same buffer shown the other way - the pointer come or gone -
    // is no other picture, and is not waited for.
    const flip = screen.shown and !(bands.len == 1 and screen.showing == last);
    if (what.flags & rtg.boards.RTGSHOW_DIRECT != 0) {
        if (!scanFrom(screen, last)) return err.RTGERR_IO;
    } else {
        const code = fetch(screen, &.{ .width = @intCast(screen.width), .height = @intCast(screen.height) });
        if (code != err.RTGERR_OK) return code;
        if (screen.composed) |frame| {
            if (!scanFrom(screen, &pictureAt(screen, frame))) return err.RTGERR_IO;
        }
    }
    screen.showing = last;
    screen.shown = true;
    screen.updates +%= 1;
    // Waited out inside the show: the library holds the board's compose
    // lock, and a pointer's move waits that frame.
    if (flip) _ = screen.rtg_base.WaitVBlank(screen.board, 1);
    return err.RTGERR_OK;
}

/// A rectangle of the library's picture fetched to where the display
/// reads it: straight into the firmware's framebuffer, whose rows are as
/// far apart as the firmware set them - the memory is write-combining, so
/// the rows are gathered into bursts as they are written and nothing is
/// written back afterwards - or into the frame of the driver's own, which
/// is then handed on.
fn fetch(screen: *Screen, area: *const rtg.RtgRect) i32 {
    const x: u32 = @intCast(area.x);
    const y: u32 = @intCast(area.y);
    switch (screen.display) {
        .uefi => |fb| {
            if (y + @as(u32, @intCast(area.height)) > fb.height) return err.RTGERR_BAD_ARG;
            return drivers(screen).ComposeLines(screen.board, area, fb.row(y) + x * screen.bytes, fb.pitch);
        },
        .ramfb => {
            const frame = ownFrame(screen) orelse return err.RTGERR_NO_MEMORY;
            const code = drivers(screen).ComposeLines(screen.board, area, frame + y * screen.pitch + x * screen.bytes, screen.pitch);
            if (code != err.RTGERR_OK) return code;
            handOn(screen, &pictureAt(screen, frame), .{
                .left = x,
                .top = y,
                .right = x + @as(u32, @intCast(area.width)),
                .end = y + @as(u32, @intCast(area.height)),
            });
            return err.RTGERR_OK;
        },
    }
}

/// A rectangle of the display's own picture changed: fetched from the
/// library to where the display reads it.
fn update(board: *rtg.RtgBoard, area: *const rtg.RtgRect) callconv(.c) i32 {
    return fetch(screenOf(board), area);
}

/// The board's one op for what is on the glass (`RtgShow`): put in the
/// mode where the library says it is to be, then shown the bands - one
/// whole buffer, the library's picture, or nothing; with the mode set
/// anew a show that fails leaves it showing nothing.
fn showOp(board: *rtg.RtgBoard, what: *const rtg.RtgShow) callconv(.c) i32 {
    const anew = what.flags & rtg.boards.RTGSHOW_MODE_CHANGED != 0;
    if (anew) {
        const code = setMode(board, what.mode);
        if (code != err.RTGERR_OK) return code;
    }
    const screen = screenOf(board);
    const code = showPlain(screen, what);
    if (code != err.RTGERR_OK and anew) _ = showPlain(screen, &.{ .mode = what.mode, .timings = what.timings });
    return code;
}

/// A rectangle of a buffer the ramfb reads, or may be shown to read, was
/// written by the CPU: its pixels alone handed on.
fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect) callconv(.c) i32 {
    const screen = screenOf(board);
    const x: u32 = @intCast(area.x);
    const first: u32 = @intCast(area.y);
    handOn(screen, bitmap, .{ .left = x, .top = first, .right = x + @as(u32, @intCast(area.width)), .end = first + @as(u32, @intCast(area.height)) });
    return err.RTGERR_OK;
}

fn stats(board: *rtg.RtgBoard, into: *rtg.RtgBoardStats) callconv(.c) void {
    into.frames = screenOf(board).updates;
}

/// The picture the library composes fetched to where the display reads
/// it: the bands, the overlay and the pointer are the library's.
const ops = rtg.boards.RtgBoardOps{
    .destroy = &destroy,
    .show = &showOp,
    .refresh = &refresh,
    .update = &update,
    .stats = &stats,
};

const driver_ops = rtg.RtgDriverOps{ .attach = &attach };

/// What it takes: a panel part that is the firmware's framebuffer or the
/// emulator's ramfb.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = st.CHIP_QEMU_RAMFB },
    .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = st.CHIP_UEFI_FB },
    .{},
};

/// The driver's tag: a description and no init. rtg.library reads it at
/// its own init and puts the driver on its list; nothing of this module
/// runs until a board is asked for.
export const rtg_fw_tag: rtg.ResidentRtgDriver linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&rtg_fw_tag),
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

// SPDX-License-Identifier: MPL-2.0
//! A board that exists only for the host tests.
//!
//! It is written the way a real driver is written, because it is what
//! anyone writing one will read: nothing is kept in the module's own
//! image. `create` allocates one block holding the driver node, the
//! display memory and everything that changes, and every entry point finds
//! that block again through the node - an op has the board, the board has
//! its driver, and the driver is a field of the block. What belongs to one
//! board and not to the driver - its modes - is in the instance the
//! library allocates beside each handle, so two boards of this driver
//! never share a list.
//!
//! Its engine really does fill, copy and invert, so a test can compare
//! bytes and see both that the work happened and that the rectangle it was
//! given had already been cut down to the buffer. Everything it is asked
//! is recorded, so a test can also see what it was *not* asked.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;
const tags = rtg.tags;

pub const DRIVER_NAME = "fake";

/// The display memory it reports. Small on purpose: the host tests run
/// exec on 64 KiB of test RAM and everything else has to fit beside it.
pub const region_bytes: usize = 16 * 1024;
/// How much of it a display that was already running is using, when the
/// board is made to come up that way.
pub const claimed_bytes: usize = 4096;
/// What the driver writes into its instance, so a test can see that the
/// library gave it its own memory and handed the same pointer back.
pub const instance_pattern: u32 = 0x5A5A_1234;

/// What the board was asked to do.
pub const Log = struct {
    created: u32 = 0,
    destroyed: u32 = 0,
    set_mode: u32 = 0,
    shown: u32 = 0,
    refreshed: u32 = 0,
    display_calls: u32 = 0,
    brightness_calls: u32 = 0,
    control_calls: u32 = 0,
    fills: u32 = 0,
    copies: u32 = 0,
    inverts: u32 = 0,
    mirrors: u32 = 0,
    swaps: u32 = 0,
    gaps: u32 = 0,
    /// The rectangle of the last fill or invert, as the driver got it.
    last_rect: rtg.RtgRect = .{},
    last_copy: rtg.RtgCopy = .{},
    last_show_x: u32 = 0,
    last_show_y: u32 = 0,
    last_refresh_y: u32 = 0,
    last_refresh_rows: u32 = 0,
    last_control: u32 = 0,
    last_mirror_x: bool = false,
    last_mirror_y: bool = false,
    last_swap: bool = false,
    last_gap_x: u32 = 0,
    last_gap_y: u32 = 0,
    display_on: bool = false,
    brightness: u32 = 0,
};

/// Everything this driver has that changes, allocated by `create`.
pub const State = struct {
    driver: rtg.RtgDriver = .{},
    sys: *ExecBase,
    /// The display memory its boards are cut out of.
    region: [*]u8,
    log: Log = .{},

    // What a test makes the board do.

    /// Make the next create fail with this, or RTGERR_OK to let it work.
    create_answer: i32 = err.RTGERR_OK,
    /// Leave the engine's slots empty, as a board with no engine has them.
    without_engine: bool = false,
    /// Refuse to turn the picture, as a board whose pixels go out in the
    /// order they are written does.
    cannot_turn: bool = false,
    /// Come up with a display already running out of the front of the
    /// region, the way a driver that took over a running one does.
    claims_display: bool = false,
};

/// What belongs to one board: the library allocates it beside the handle.
pub const Instance = struct {
    pattern: u32 = 0,
    calls: u32 = 0,
    /// This board's own modes. A driver that kept one list in its image
    /// would hand the same nodes to two boards and corrupt both.
    modes: [mode_table.len]rtg.RtgMode = mode_table,
};

pub fn stateOf(driver: *rtg.RtgDriver) *State {
    return @fieldParentPtr("driver", driver);
}

fn stateOfBoard(board: *rtg.RtgBoard) *State {
    return stateOf(board.driver.?);
}

fn instanceOf(board: *rtg.RtgBoard) *Instance {
    return @ptrCast(@alignCast(board.instance.?));
}

/// The driver, ready to be handed to AddRtgDriver. Null without memory.
pub fn create(sys: *ExecBase) ?*State {
    const memory = sys.AllocVec(@sizeOf(State), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const region = sys.AllocMem(region_bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.FreeVec(memory);
        return null;
    };
    const state: *State = @ptrCast(@alignCast(memory));
    state.* = .{ .sys = sys, .region = @ptrCast(region) };
    state.driver = .{
        .node = .{ .name = DRIVER_NAME, .pri = 0 },
        .version = 1,
        .id_string = "fake board 1.0",
        .type = rtg.boards.RTGDT_BOARD,
        .ops = &driver_ops,
        .instance_size = @sizeOf(Instance),
    };
    return state;
}

/// Give back what create took. The driver must be off the list first.
pub fn destroy(state: *State) void {
    const sys = state.sys;
    sys.FreeMem(@ptrCast(state.region), region_bytes);
    sys.FreeVec(state);
}

const mode_table = [_]rtg.RtgMode{
    .{
        .node = .{ .name = "320x200", .pri = 10 },
        .id = 1,
        .width = 320,
        .height = 200,
        .format = .rgb565,
        .refresh_mhz = 60_000,
        .flags = rtg.boards.RTGMF_DEFAULT,
    },
    .{
        .node = .{ .name = "640x480", .pri = 5 },
        .id = 2,
        .width = 640,
        .height = 480,
        .format = .rgb565,
        .refresh_mhz = 60_000,
    },
    .{
        .node = .{ .name = "64x64 mono", .pri = 0 },
        .id = 3,
        .width = 64,
        .height = 64,
        .format = .mono1,
    },
};

// --- the ops ----------------------------------------------------------------

fn destroyBoard(board: *rtg.RtgBoard) callconv(.c) void {
    instanceOf(board).calls += 1;
    stateOfBoard(board).log.destroyed += 1;
}

fn setMode(board: *rtg.RtgBoard, mode: *const rtg.RtgMode) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    stateOfBoard(board).log.set_mode += 1;
    board.info.width = mode.width;
    board.info.height = mode.height;
    board.info.format = mode.format;
    return err.RTGERR_OK;
}

fn showBitMap(board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap, x: u32, y: u32) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    _ = bitmap;
    const log = &stateOfBoard(board).log;
    log.shown += 1;
    log.last_show_x = x;
    log.last_show_y = y;
    return err.RTGERR_OK;
}

fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    _ = bitmap;
    const log = &stateOfBoard(board).log;
    log.refreshed += 1;
    log.last_refresh_y = y;
    log.last_refresh_rows = rows;
    return err.RTGERR_OK;
}

fn display(board: *rtg.RtgBoard, on: bool) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.display_calls += 1;
    log.display_on = on;
    return err.RTGERR_OK;
}

fn setBrightness(board: *rtg.RtgBoard, percent: u32) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.brightness_calls += 1;
    log.brightness = percent;
    return err.RTGERR_OK;
}

fn brightness(board: *rtg.RtgBoard) callconv(.c) u32 {
    return stateOfBoard(board).log.brightness;
}

fn stats(board: *rtg.RtgBoard, out: *rtg.RtgBoardStats) callconv(.c) void {
    _ = board;
    out.* = .{ .frames = 42, .starved_frames = 1, .worst_gap_us = 7 };
}

fn control(board: *rtg.RtgBoard, what: u32, value: isize) callconv(.c) isize {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.control_calls += 1;
    log.last_control = what;
    return value + 1;
}

fn mirror(board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.mirrors += 1;
    log.last_mirror_x = mirror_x;
    log.last_mirror_y = mirror_y;
    return err.RTGERR_OK;
}

fn swapXy(board: *rtg.RtgBoard, swap: bool) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.swaps += 1;
    log.last_swap = swap;
    return err.RTGERR_OK;
}

fn setGap(board: *rtg.RtgBoard, gap_x: u32, gap_y: u32) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.gaps += 1;
    log.last_gap_x = gap_x;
    log.last_gap_y = gap_y;
    return err.RTGERR_OK;
}

/// rgb565 only: what a board's engine would do, done by hand so the tests
/// can compare bytes.
fn rows16(bitmap: *rtg.RtgBitMap, y: u32) []u16 {
    const start = bitmap.rowPtr(y);
    return @as([*]u16, @ptrCast(@alignCast(start)))[0..bitmap.width];
}

fn fillRect(board: *rtg.RtgBoard, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.fills += 1;
    log.last_rect = area.*;
    if (dest.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    var y: u32 = @intCast(area.y);
    const end: u32 = @intCast(area.y + area.height);
    while (y < end) : (y += 1) {
        const row = rows16(dest, y);
        var x: u32 = @intCast(area.x);
        const right: u32 = @intCast(area.x + area.width);
        while (x < right) : (x += 1) row[x] = @truncate(color);
    }
    return err.RTGERR_OK;
}

fn invertRect(board: *rtg.RtgBoard, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.inverts += 1;
    log.last_rect = area.*;
    if (dest.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    var y: u32 = @intCast(area.y);
    const end: u32 = @intCast(area.y + area.height);
    while (y < end) : (y += 1) {
        const row = rows16(dest, y);
        var x: u32 = @intCast(area.x);
        const right: u32 = @intCast(area.x + area.width);
        while (x < right) : (x += 1) row[x] = ~row[x];
    }
    return err.RTGERR_OK;
}

fn copyRect(board: *rtg.RtgBoard, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copy: *const rtg.RtgCopy) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.copies += 1;
    log.last_copy = copy.*;
    if (src.format != .rgb565 or dest.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    const height: u32 = @intCast(copy.height);
    const width: u32 = @intCast(copy.width);
    // Rows the way round that lets a buffer be copied onto itself.
    const downwards = copy.dest_y <= copy.src_y;
    var step: u32 = 0;
    while (step < height) : (step += 1) {
        const line = if (downwards) step else height - 1 - step;
        const from = rows16(src, @as(u32, @intCast(copy.src_y)) + line);
        const to = rows16(dest, @as(u32, @intCast(copy.dest_y)) + line);
        const src_x: u32 = @intCast(copy.src_x);
        const dest_x: u32 = @intCast(copy.dest_x);
        if (copy.dest_x <= copy.src_x) {
            var x: u32 = 0;
            while (x < width) : (x += 1) to[dest_x + x] = from[src_x + x];
        } else {
            var x: u32 = width;
            while (x > 0) {
                x -= 1;
                to[dest_x + x] = from[src_x + x];
            }
        }
    }
    return err.RTGERR_OK;
}

fn waitBlit(board: *rtg.RtgBoard) callconv(.c) void {
    instanceOf(board).calls += 1;
}

/// Everything a board can be asked.
const full_ops = rtg.RtgBoardOps{
    .destroy = &destroyBoard,
    .set_mode = &setMode,
    .show_bitmap = &showBitMap,
    .refresh = &refresh,
    .display = &display,
    .set_brightness = &setBrightness,
    .brightness = &brightness,
    .stats = &stats,
    .control = &control,
    .fill_rect = &fillRect,
    .copy_rect = &copyRect,
    .invert_rect = &invertRect,
    .wait_blit = &waitBlit,
    .mirror = &mirror,
    .swap_xy = &swapXy,
    .set_gap = &setGap,
};

/// A board with no engine: it can be shown and refreshed and no more.
const plain_ops = rtg.RtgBoardOps{
    .destroy = &destroyBoard,
    .set_mode = &setMode,
    .show_bitmap = &showBitMap,
    .refresh = &refresh,
};

/// A board whose pixels go out in the order they are written, so it cannot
/// be turned.
const fixed_ops = rtg.RtgBoardOps{
    .destroy = &destroyBoard,
    .set_mode = &setMode,
    .show_bitmap = &showBitMap,
    .refresh = &refresh,
    .stats = &stats,
};

fn createBoard(made_by: *rtg.RtgDriver, board: *rtg.RtgBoard, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(made_by);
    if (state.create_answer != err.RTGERR_OK) return state.create_answer;
    state.log.created += 1;

    const rb = board.rtg_base.?;
    const instance = instanceOf(board);
    instance.* = .{ .pattern = instance_pattern };

    board.ops = if (state.cannot_turn)
        &fixed_ops
    else if (state.without_engine)
        &plain_ops
    else
        &full_ops;

    // This board's own modes, out of its own instance.
    for (&instance.modes) |*mode| state.sys.AddTail(&board.modes, &mode.node);

    board.region = .{
        .base = state.region,
        .size = rb.GetRtgTagData(tags.RTGA_DisplayMemorySize, region_bytes, tag_list),
        .alignment = 64,
        .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED,
    };
    board.info.flags |= rtg.boards.RTGBF_STREAMING;
    board.info.buffers = 2;

    if (state.claims_display) {
        var described = rtg.RtgBitMap{
            .pixels = state.region,
            .width = 64,
            .height = 32,
            .pitch = 128,
            .size_bytes = claimed_bytes,
            .format = .rgb565,
            .flags = rtg.bitmaps.RTGBMF_DISPLAYABLE,
        };
        board.showing = rb.AttachBitMap(board, &described);
    }
    return err.RTGERR_OK;
}

const driver_ops = rtg.RtgDriverOps{ .create_board = &createBoard };

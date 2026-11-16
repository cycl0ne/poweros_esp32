// SPDX-License-Identifier: MPL-2.0
//! A board's monitor, and the modes made of what it names.
//!
//! A board with a connector fills `detect`: whether a monitor is on it,
//! and the blocks of its EDID. The library asks it as the board joins the
//! list (`firstLook`), in the task that binds the drivers, and again whenever
//! the driver says `MonitorChanged` - from its hot-plug interrupt, or
//! from a task of its own that looks at the port. That call only marks
//! the board and wakes the library's monitor task, which does the rest
//! (`service`): no driver keeps a task for its monitor. A look that finds
//! what the last one found - the same monitor, or none still - changes
//! nothing, so a driver whose connector has no interrupt may have it
//! looked at now and then.
//!
//! **What a look does** (`look`), with the board's lock held: `detect`
//! is called with the library's buffer, the EDID's first block is held to
//! its header and its sum, and what the monitor says of itself is kept
//! for `GetBoardMonitor`. Then the list of modes is made again
//! (`remake`): the modes made of the monitor before are set aside, and
//! every timing the new one names - its detailed timings as they are, a
//! size or a number with the standard's timing - is offered to the
//! board's `check_mode`, up to the fastest clock the monitor takes. The
//! ones taken are the board's modes: each of the figures of a mode the
//! board had before has that mode's number. A picture named twice at one
//! refresh is one mode, in the timing it was named with first - the
//! monitor's own before the standard's. The default is the mode the
//! monitor prefers, its first detailed timing; else 1920 by 1080 at 60 a
//! second where it names that; else the largest.
//!
//! **A monitor that names nothing** the board can make - none there, an
//! EDID that does not read, timings all refused - leaves the board with
//! the modes its driver added itself; where it added none, with the size
//! its device's tags give (`RTGA_Width`, `RTGA_Height`) at 60 a second in
//! the standard's timing, so the output comes up for the monitor that is
//! plugged in later.
//!
//! **A board that shows** when its monitor changes: where the mode it is
//! in is in the new list, its driver is handed that mode and what was
//! shown again (`show`, with `RTGSHOW_MODE_CHANGED`), with the timings
//! the monitor now there gives it, and brings the link up for it. Where
//! it is not, the board shows nothing and is in no mode until it is
//! shown in one. Either way its `changes` are
//! raised and the tasks that asked are told.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rtg = sdk.rtg;
const tags = rtg.tags;
const err = rtg.errors;
const monitors = rtg.modes;

const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const modes = @import("../mode/_mode.zig");
const devices = @import("../device/_device.zig");
const edid = @import("_edid.zig");
const shows = @import("../display/_display.zig");

/// What the library keeps of the monitor of a board with a connector: a
/// block of its own behind the board, made as the board joins the list.
pub const State = struct {
    /// What is on the connector, as `GetBoardMonitor` copies it out.
    info: rtg.RtgMonitorInfo = .{},
    /// The EDID as it was last read, `info.edid_size` bytes of it: room
    /// for `RTG_EDID_MAX`, behind this record in its block.
    edid: [*]u8,
    /// The modes the board does not offer now, kept with their numbers: a
    /// monitor's that went, the driver's own while a monitor names some.
    modes_aside: exec.List = .{},
    /// Present, the EDID's length and a sum over its bytes, as the last
    /// look found them: a look that finds the same changes nothing.
    stamp: u64 = 0,
    /// Whether the board's modes are the ones the monitor names. While
    /// they are, the driver's own are set aside.
    names_modes: bool = false,
    /// The driver said something happened at the connector, and the
    /// monitor task has not looked yet. Written from interrupts.
    changed: bool = false,
};

/// The monitor task's name and priority: above the programs that draw,
/// below the tasks that move what is drawn.
const task_name = "rtg monitors";
const task_priority = 5;

/// Whether a board has a connector: its driver filled in `detect`.
///
/// INPUTS:
/// - `board` - the board.
fn hasConnector(board: *const rtg.RtgBoard) bool {
    const ops = board.ops orelse return false;
    return ops.detect != null;
}

/// A timing of the EDID's as the library keeps a mode's.
///
/// INPUTS:
/// - `timing` - the timing, as the reader has it.
pub fn timingsOf(timing: *const edid.Timing) rtg.RtgTimings {
    return .{
        .pixel_clock_hz = timing.pixel_khz * 1000,
        .h_active = timing.width,
        .h_front = timing.h_front,
        .h_sync = timing.h_sync,
        .h_back = timing.h_back,
        .v_active = timing.height,
        .v_front = timing.v_front,
        .v_sync = timing.v_sync,
        .v_back = timing.v_back,
        .flags = (if (timing.hsync_high) monitors.RTGTM_HSYNC_HIGH else 0) |
            (if (timing.vsync_high) monitors.RTGTM_VSYNC_HIGH else 0),
        .vic = timing.vic,
    };
}

/// Whether the board can make a timing: what its `check_mode` says, yes
/// where it has none.
fn makes(board: *rtg.RtgBoard, timings: *const rtg.RtgTimings) bool {
    const check = board.ops.?.check_mode orelse return true;
    return check(board, timings) == err.RTGERR_OK;
}

/// The EDID's first block and its extension, where the bytes held are
/// whole blocks that read as an EDID does.
const Blocks = struct { first: *const edid.Block, extension: ?*const edid.Block };

fn blocksOf(state: *const State) ?Blocks {
    const bytes = state.edid;
    if (state.info.edid_size < monitors.RTG_EDID_BLOCK) return null;
    const first: *const edid.Block = @ptrCast(bytes);
    if (!edid.isFirst(first) or !edid.valid(first)) return null;
    var extension: ?*const edid.Block = null;
    if (first[126] != 0 and state.info.edid_size >= 2 * monitors.RTG_EDID_BLOCK) {
        const second: *const edid.Block = @ptrCast(bytes + monitors.RTG_EDID_BLOCK);
        if (edid.valid(second)) extension = second;
    }
    return .{ .first = first, .extension = extension };
}

/// What is on a board's connector, as it was last seen: a connector's
/// monitor as the last look found it; a panel's always there, called
/// what its part is called.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock is held.
/// - `into` - where the answer goes.
pub fn infoOf(rb: *RtgBase, board: *rtg.RtgBoard, into: *rtg.RtgMonitorInfo) void {
    if (boards.privateOf(board).monitor) |state| {
        into.* = state.info;
        return;
    }
    into.* = .{ .flags = monitors.RTGMON_PRESENT | monitors.RTGMON_PANEL };
    const device = board.device orelse return;
    const chip_name = devices.privateOf(device).chip_name orelse return;
    _ = rb.utility_base.Strlcpy(&into.name, into.name.len, chip_name);
}

/// What tells two looks apart: whether a monitor was there, how long its
/// EDID is, and a sum over its bytes.
fn stampOf(present: bool, bytes: []const u8) u64 {
    var sum: u32 = 2166136261;
    for (bytes) |byte| sum = (sum ^ byte) *% 16777619;
    return @as(u64, @intFromBool(present)) << 63 | @as(u64, bytes.len) << 32 | sum;
}

/// What the monitor says of itself, from the blocks just read.
fn describe(state: *State, present: bool, size: u32) void {
    state.info = .{ .edid_size = size };
    if (present) state.info.flags |= monitors.RTGMON_PRESENT;
    const blocks = blocksOf(state) orelse {
        // Bytes that are no EDID are not kept as one.
        state.info.edid_size = 0;
        return;
    };
    state.info.flags |= monitors.RTGMON_EDID;
    const who = edid.identity(blocks.first);
    state.info.maker = who.maker;
    state.info.product = who.product;
    state.info.serial = who.serial;
    state.info.week = who.week;
    state.info.year = who.year;
    state.info.width_mm = who.width_mm;
    state.info.height_mm = who.height_mm;
    var name: [14]u8 = undefined;
    edid.name(blocks.first, &name);
    @memcpy(state.info.name[0..name.len], &name);
    const sink = edid.sinkOf(blocks.extension);
    if (sink.hdmi) state.info.flags |= monitors.RTGMON_HDMI;
    if (sink.audio) state.info.flags |= monitors.RTGMON_AUDIO;
    if (sink.quant_selectable) state.info.flags |= monitors.RTGMON_RANGE_SELECTABLE;
    if (sink.scdc) state.info.flags |= monitors.RTGMON_SCDC;
    if (sink.forum) state.info.flags |= monitors.RTGMON_HDMI2;
    state.info.max_tmds_khz = sink.max_tmds_khz;
}

/// Whether the board has a mode of the monitor's of that picture at that
/// refresh, to the nearest Hertz: a timing named a second time - in full
/// and by a number, or in both blocks - is the mode it was named as
/// first.
fn named(board: *rtg.RtgBoard, timing: *const edid.Timing) bool {
    var node = boards.privateOf(board).modes.first();
    while (node) |n| : (node = n.next()) {
        const record = modes.recordOf(n);
        if (record.origin != .monitor) continue;
        if (record.mode.width != timing.width or record.mode.height != timing.height) continue;
        if ((record.mode.refresh_mhz + 500) / 1000 == timing.hz()) return true;
    }
    return false;
}

/// A timing the monitor names made a mode of the board's, where the
/// board can make it, the monitor's fastest clock allows it, and it was
/// not named before. The mode's record, or null.
fn offer(rb: *RtgBase, board: *rtg.RtgBoard, timing: *const edid.Timing, most_khz: u32, format: u32) ?*modes.Record {
    if (timing.pixel_khz > most_khz) return null;
    if (named(board, timing)) return null;
    const timings = timingsOf(timing);
    if (!makes(board, &timings)) return null;
    return modes.add(rb, board, &timings, format, 0, .monitor);
}

/// The board's list of modes made again from what its monitor names.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, with `detect`; its lock is held, or it is on no
///   list yet.
fn remake(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const private = boards.privateOf(board);
    const state = private.monitor.?;
    const format: u32 = @intFromEnum(private.monitor_format);
    modes.withdraw(rb, board, .monitor);

    var preferred: ?*modes.Record = null;
    var full_hd: ?*modes.Record = null;
    var taken: u32 = 0;
    if (blocksOf(state)) |blocks| {
        const most_khz = edid.sinkOf(blocks.extension).mostKhz();
        var timings: [10]edid.Timing = undefined;
        const found = edid.detailedTimings(blocks.first, blocks.extension, &timings);
        for (timings[0..found], 0..) |*timing, i| {
            timing.vic = edid.vicOf(timing);
            const record = offer(rb, board, timing, most_khz, format) orelse continue;
            taken += 1;
            // The first block's first descriptor, where it is a timing,
            // is the mode the monitor prefers.
            if (i == 0 and edid.detailed(blocks.first, 54) != null) preferred = record;
        }
        for (&edid.known) |*mode| {
            if (!edid.takes(blocks.first, blocks.extension, .{ .width = mode.width, .height = mode.height, .refresh_hz = mode.hz(), .vic = mode.vic })) continue;
            const record = offer(rb, board, mode, most_khz, format) orelse continue;
            taken += 1;
            if (mode.width == 1920 and mode.height == 1080 and mode.hz() == 60) full_hd = record;
        }
    }
    if (taken != 0) {
        // The monitor's modes are the board's: the driver's own stand by.
        state.names_modes = true;
        modes.withdraw(rb, board, .driver);
        const usual = preferred orelse full_hd orelse modes.recordOf(private.modes.first().?);
        modes.setDefault(board, usual);
        return;
    }
    // Nothing named that the board can make: its own modes, and where it
    // has none the size its device's tags give, at 60 a second.
    state.names_modes = false;
    if (modes.restore(rb, board) != 0) return;
    const device = board.device orelse return;
    const ub = rb.utility_base;
    const width: u32 = @truncate(ub.GetTagData(tags.RTGA_Width, 0, device.tags));
    const height: u32 = @truncate(ub.GetTagData(tags.RTGA_Height, 0, device.tags));
    const own = edid.knownMode(width, height, 60) orelse return;
    const timings = timingsOf(&own);
    if (!makes(board, &timings)) return;
    _ = modes.add(rb, board, &timings, format, monitors.RTGMF_DEFAULT, .monitor);
}

/// A board's connector looked at: `detect` asked, what the monitor says
/// of itself kept, and the modes made again of what it names. Whether
/// anything is other than the last look found it: where it is not,
/// nothing is touched.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, with `detect` and its monitor's state; its lock
///   is held, or it is on no list yet.
fn look(rb: *RtgBase, board: *rtg.RtgBoard) bool {
    const state = boards.privateOf(board).monitor.?;
    const detect = board.ops.?.detect.?;
    var present = false;
    var size: u32 = 0;
    var asked: rtg.RtgDetect = .{ .edid = state.edid, .edid_max = monitors.RTG_EDID_MAX };
    if (detect(board, &asked) == err.RTGERR_OK) {
        present = asked.present != 0;
        // Whole blocks, and no more than there was room for; none of a
        // monitor that is not there.
        if (present) size = @min(asked.edid_size, monitors.RTG_EDID_MAX) / monitors.RTG_EDID_BLOCK * monitors.RTG_EDID_BLOCK;
    }
    const stamp = stampOf(present, state.edid[0..size]);
    if (stamp == state.stamp) return false;
    state.stamp = stamp;
    describe(state, present, size);
    if (present) {
        board.info.flags &= ~rtg.boards.RTGBF_NO_DISPLAY;
    } else {
        board.info.flags |= rtg.boards.RTGBF_NO_DISPLAY;
    }
    remake(rb, board);
    return true;
}

/// A board's monitor read for the first time, as the board joins the
/// library's list: a panel's said to be there, a connector's looked at
/// and its modes made. The monitor task is made with the first board
/// that has a connector.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, its display memory known; not yet on the list.
///
/// CONTEXT:
/// Called in the task that binds the drivers. `detect` may wait.
pub fn firstLook(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const sys = rb.sys_base;
    if (!hasConnector(board)) return;
    // The monitor's state and the room for its EDID, one block: without
    // memory the board is a panel's, with the modes its driver added.
    const memory = sys.AllocVec(@sizeOf(State) + monitors.RTG_EDID_MAX, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return;
    const state: *State = @ptrCast(@alignCast(memory));
    state.* = .{ .edid = @as([*]u8, @ptrCast(memory)) + @sizeOf(State) };
    sys.NewList(&state.modes_aside);
    boards.privateOf(board).monitor = state;
    board.info.flags |= rtg.boards.RTGBF_CONNECTOR;
    _ = look(rb, board);
    start(rb);
}

/// What a board keeps for its monitor given back, as the board goes.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board.
pub fn free(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const private = boards.privateOf(board);
    if (private.monitor) |state| rb.sys_base.FreeVec(state);
    private.monitor = null;
}

/// A board marked for the monitor task to look at, and the task woken.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board whose connector something happened at.
///
/// CONTEXT:
/// From an interrupt or a task: a flag written and a task signalled.
pub fn mark(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const state = boards.privateOf(board).monitor orelse return;
    @atomicStore(bool, &state.changed, true, .release);
    if (@atomicLoad(?*exec.Task, &rb.monitor_task, .acquire)) |task| rb.sys_base.Signal(task, exec.SIGF_SINGLE);
}

/// One board whose driver said its monitor changed, looked at: its
/// connector asked, its modes made again, and where it shows, its driver
/// handed the mode it is in again - or, where the monitor now there has
/// not got that mode, the board put in none, showing nothing. Whether
/// the look found anything other than the last.
fn serve(rb: *RtgBase, board: *rtg.RtgBoard) bool {
    const private = boards.privateOf(board);
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    // A board whose device went meanwhile has no connector to ask.
    if (boards.dark(board) or private.monitor == null) return false;
    if (!look(rb, board)) return false;
    const current = private.mode orelse return true;
    if (current.offered) {
        // The link again, for the monitor now there, and what was shown
        // shown again.
        shows.again(rb, board);
        return true;
    }
    // The monitor has not got the mode the board is in.
    _ = shows.clear(rb, board);
    return true;
}

/// Every board whose driver said its monitor changed is looked at, and
/// the tasks that asked are told of each. What the monitor task does
/// each time it is woken.
///
/// INPUTS:
/// - `rb` - the library.
///
/// CONTEXT:
/// In a task; `detect` and `show` may wait. It takes the board list's
/// lock for its walk and each board's lock in turn, never both.
pub fn service(rb: *RtgBase) void {
    const sys = rb.sys_base;
    while (true) {
        // The next board that was marked, found with the list held still.
        var marked: ?*rtg.RtgBoard = null;
        sys.ObtainSemaphore(&rb.board_lock);
        var node = rb.boards.first();
        while (node) |n| : (node = n.next()) {
            const board: *rtg.RtgBoard = @fieldParentPtr("node", n);
            const state = boards.privateOf(board).monitor orelse continue;
            if (@atomicRmw(bool, &state.changed, .Xchg, false, .acq_rel)) {
                marked = board;
                break;
            }
        }
        sys.ReleaseSemaphore(&rb.board_lock);
        const board = marked orelse return;
        if (serve(rb, board)) boards.changed(rb, board);
    }
}

/// The monitor task: every board marked is looked at, then it waits to be
/// woken again.
fn taskCode(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    while (@atomicLoad(?*anyopaque, &me.user_data, .acquire) == null) _ = sys.Wait(exec.SIGF_SINGLE);
    const rb: *RtgBase = @ptrCast(@alignCast(me.user_data.?));
    while (true) {
        service(rb);
        _ = sys.Wait(exec.SIGF_SINGLE);
    }
}

/// The monitor task made, where there is none yet: the system's, not the
/// task's that happened to bind the drivers. Without memory there is
/// none, and a monitor that changes is not looked at.
///
/// INPUTS:
/// - `rb` - the library.
fn start(rb: *RtgBase) void {
    const sys = rb.sys_base;
    if (rb.monitor_task != null) return;
    sys.BeginSystemMemory();
    const task = sys.CreateTask(task_name, task_priority, &taskCode, 0);
    sys.EndSystemMemory();
    const made = task orelse return;
    @atomicStore(?*anyopaque, &made.user_data, rb, .release);
    @atomicStore(?*exec.Task, &rb.monitor_task, made, .release);
    sys.Signal(made, exec.SIGF_SINGLE);
}

/// The monitor task taken away again: for a test, which leaves nothing
/// behind. On a machine it lives as long as the library.
///
/// INPUTS:
/// - `rb` - the library.
pub fn stop(rb: *RtgBase) void {
    const task = rb.monitor_task orelse return;
    @atomicStore(?*exec.Task, &rb.monitor_task, null, .release);
    rb.sys_base.RemTask(task);
}

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
//! looked at now and then - by its frames, where it says how many go by
//! between two looks (`RtgBoardSpec.look_frames`, asked for by
//! FrameDone).
//!
//! **A connector looked at by its frames**, on a board that shows, has
//! its looks settle: a monitor come or gone is taken to have once two
//! looks in a row have found it - which a plug that bounces as it goes
//! in, or a monitor that raises its hot-plug line before its EDID reads,
//! takes - and what was there stands until then. The EDID of a monitor
//! that gave none is asked for at three looks, not at every one: each
//! try holds the connector for as long as its DDC takes to give up. A
//! board that does not show takes every look as it is.
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
//! it is not, what it showed is shown in the mode the new monitor
//! prefers, scaled - by the library where it composes the board's
//! picture, or by planes that scale (`RTGBC_SCALE_BANDS`) - so that a
//! monitor that is there is not left dark; a board that cannot scale
//! shows nothing and is in no mode until it is shown in one. Either way
//! its `changes` are raised and the tasks that asked are told.

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
const settings = @import("../settings/_settings.zig");

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
    /// On a connector looked at by its frames: the looks in a row that
    /// found other than what stands, and the looks in a row at which a
    /// monitor there gave no EDID.
    settling: u32 = 0,
    misses: u32 = 0,
};

/// How many looks in a row a monitor come or gone on a connector looked
/// at by its frames must be found at before it is taken to have.
const settle_looks = 2;
/// At how many looks in a row the EDID of a monitor that gave none is
/// asked for while its board shows.
const edid_tries = 3;

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
    state.info.audio_channels = sink.lpcm_channels;
    state.info.audio_rates = sink.lpcm_rates;
    state.info.audio_stereo_rates = sink.lpcm_stereo_rates;
    state.info.audio_sizes = sink.lpcm_sizes;
    state.info.speakers = sink.speakers;
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
        // The mode the monitor prefers is the default of its own; the
        // board's line may name another.
        const usual = preferred orelse full_hd orelse modes.recordOf(private.modes.first().?);
        usual.marked_default = true;
        settings.chooseDefault(rb, board);
        return;
    }
    // Nothing named that the board can make: the timings its line gives
    // by hand, with its own modes; without a line its own modes, and
    // where it has none the size its device's tags give, at 60 a second.
    state.names_modes = false;
    const own_modes = modes.restore(rb, board);
    var line: rtg.RtgSettings = .{};
    _ = settings.lineOf(rb, board, &line);
    if (line.flags & rtg.RTGSET_TIMINGS != 0 and makes(board, &line.timings)) {
        _ = modes.add(rb, board, &line.timings, format, monitors.RTGMF_DEFAULT, .monitor);
    } else if (own_modes == 0) {
        if (board.device) |device| {
            const ub = rb.utility_base;
            const width: u32 = @truncate(ub.GetTagData(tags.RTGA_Width, 0, device.tags));
            const height: u32 = @truncate(ub.GetTagData(tags.RTGA_Height, 0, device.tags));
            if (edid.knownMode(width, height, 60)) |own| {
                const timings = timingsOf(&own);
                if (makes(board, &timings)) _ = modes.add(rb, board, &timings, format, monitors.RTGMF_DEFAULT, .monitor);
            }
        }
    }
    settings.chooseDefault(rb, board);
}

/// A board's modes made again of what its monitor named at the last look
/// and what the settings say now - the default its line names, the
/// timings it gives by hand - with nothing asked of the connector. A
/// board left in a mode it no longer offers shows what it showed in its
/// default mode, scaled, or nothing where it cannot.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock is held.
pub fn renew(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const private = boards.privateOf(board);
    if (private.monitor == null) {
        // A panel's modes never go: only which is the default changes.
        settings.chooseDefault(rb, board);
        return;
    }
    remake(rb, board);
    const current = private.mode orelse return;
    if (current.offered) return;
    if (!shows.elsewhere(rb, board)) _ = shows.clear(rb, board);
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
    const private = boards.privateOf(board);
    const state = private.monitor.?;
    const detect = board.ops.?.detect.?;
    // A connector looked at by its frames, on a board that shows: its
    // looks settle, and its EDID is asked for at a few looks only.
    const polled = private.look_frames != 0 and private.mode != null;
    const was_present = state.info.flags & monitors.RTGMON_PRESENT != 0;
    const room: u32 = if (polled and state.misses >= edid_tries) 0 else monitors.RTG_EDID_MAX;
    var present = false;
    var size: u32 = 0;
    var asked: rtg.RtgDetect = .{ .edid = state.edid, .edid_max = room, .edid_known = state.info.edid_size };
    if (detect(board, &asked) == err.RTGERR_OK) {
        present = asked.present != 0;
        // Whole blocks, and no more than there was room for; none of a
        // monitor that is not there.
        if (present) size = @min(asked.edid_size, room) / monitors.RTG_EDID_BLOCK * monitors.RTG_EDID_BLOCK;
    }
    if (polled and present != was_present) {
        state.settling += 1;
        // What stands is answered until the change has settled. A
        // monitor that came has been read into the buffer meanwhile,
        // where the one before it had left nothing to keep.
        if (state.settling < settle_looks) return false;
    }
    state.settling = 0;
    const stamp = stampOf(present, state.edid[0..size]);
    if (stamp == state.stamp) {
        if (present and state.info.edid_size == 0) state.misses +|= 1;
        return false;
    }
    state.stamp = stamp;
    describe(state, present, size);
    state.misses = if (present and state.info.edid_size == 0) 1 else 0;
    if (was_present and !present and private.mode != null) {
        exec.kprintf(rb.sys_base, "rtg.library: the monitor was taken off %s\n", .{board.node.name orelse "a board"});
    }
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
/// not got that mode, what it showed shown in the mode that monitor
/// prefers, scaled, and on a board that cannot scale the board put in
/// none, showing nothing. Whether the look found anything other than
/// the last.
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
    // The monitor has not got the mode the board is in: what it showed
    // in the mode this one prefers, scaled - or nothing.
    if (!shows.elsewhere(rb, board)) _ = shows.clear(rb, board);
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
        if (serve(rb, board)) {
            // Another monitor may have a line of its own: its mirror, its
            // brightness, its range, its place.
            settings.applyRest(rb, board);
            boards.changed(rb, board);
        }
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

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const std = fixture.std;
const utility = fixture.utility;
const TagItem = fixture.TagItem;
const testing = fixture.testing;

test "a monitor's modes: made of its EDID as the board joins the list, the one it prefers the default" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeConnector(rb, fixture.portable_bytes, fixture.fake.mode_table.len);

    // The connector was asked once, in the task that made the board, and
    // the task that looks again is there.
    try testing.expectEqual(@as(u32, 1), fk.log.detects);
    try testing.expect(rb.monitor_task != null);
    var info = fixture.infoOf(rb, board);
    try testing.expect(info.flags & rtg.boards.RTGBF_CONNECTOR != 0);
    try testing.expect(info.caps & rtg.boards.RTGBC_MONITOR != 0);
    try testing.expectEqual(@as(u32, 0), info.flags & rtg.boards.RTGBF_NO_DISPLAY);

    // What it names that the standards time, the larger picture first:
    // its own 1080p in full, then sizes by a bit, a size or a number.
    const expected = [_][2]u32{
        .{ 1920, 1080 }, .{ 1280, 1024 }, .{ 1440, 900 }, .{ 1280, 960 }, .{ 1280, 720 },
        .{ 1024, 768 },  .{ 800, 600 },   .{ 720, 480 },  .{ 640, 480 },
    };
    var found: [16]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, expected.len), fixture.base(rb).GetBoardModes(board, &found, found.len));
    try testing.expectEqual(@as(u32, expected.len), info.modes);
    for (expected, found[0..expected.len]) |want, *got| {
        try testing.expectEqual(want[0], got.width);
        try testing.expectEqual(want[1], got.height);
        // In the format the board said a monitor's modes are made in.
        try testing.expectEqual(rtg.PixelFormat.rgb565, got.format);
        try testing.expect(got.refresh_mhz > 59_000 and got.refresh_mhz < 61_000);
    }
    // The driver's own three stand by: none of them is listed.
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).FindBoardMode(board, 320, 200, rtg.RTG_ANY, rtg.RTG_ANY));
    // The mode it prefers is the default, with the timing it gave - the
    // sync a line early - and CEA's number for it.
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[0].flags);
    try testing.expectEqualStrings("1920x1080", std.mem.sliceTo(&found[0].name, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, 0));
    try testing.expectEqual(found[0].id, fk.log.last_mode.id);
    try testing.expectEqual(@as(u32, 148_500_000), fk.log.last_timings.pixel_clock_hz);
    try testing.expectEqual(@as(u32, 3), fk.log.last_timings.v_front);
    try testing.expectEqual(@as(u8, 16), fk.log.last_timings.vic);
    try testing.expectEqual(rtg.modes.RTGTM_HSYNC_HIGH | rtg.modes.RTGTM_VSYNC_HIGH, fk.log.last_timings.flags);
    // A mode named by a number has the standard's timing and that number.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, found[7].id));
    try testing.expectEqual(@as(u8, 3), fk.log.last_timings.vic);
    try testing.expectEqual(@as(u32, 27_000_000), fk.log.last_timings.pixel_clock_hz);

    // What the monitor says of itself, and its EDID as it was read.
    const said = fixture.monitorOf(rb, board);
    const m = rtg.modes;
    try testing.expectEqual(m.RTGMON_PRESENT | m.RTGMON_EDID | m.RTGMON_HDMI | m.RTGMON_AUDIO | m.RTGMON_RANGE_SELECTABLE, said.flags);
    try testing.expectEqualStrings("BOE", std.mem.sliceTo(&said.maker, 0));
    try testing.expectEqualStrings("Display", std.mem.sliceTo(&said.name, 0));
    try testing.expectEqual(@as(u32, 0x2556), said.product);
    try testing.expectEqual(@as(u32, 350), said.width_mm);
    try testing.expectEqual(@as(u16, 2024), said.year);
    try testing.expectEqual(@as(u32, 300_000), said.max_tmds_khz);
    try testing.expectEqual(@as(u8, 2), said.audio_channels);
    try testing.expectEqual(@as(u8, 0x7F), said.audio_rates);
    try testing.expectEqual(@as(u8, 0x07), said.audio_sizes);
    try testing.expectEqual(m.RTGSPEAKER_FRONT, said.speakers);
    try testing.expectEqual(@as(u32, 256), said.edid_size);
    try testing.expectEqual(@as(u32, 256), fixture.base(rb).ReadBoardEDID(board, null, 0));
    var bytes: [rtg.modes.RTG_EDID_MAX]u8 = @splat(0xEE);
    try testing.expectEqual(@as(u32, 256), fixture.base(rb).ReadBoardEDID(board, &bytes, 130));
    try testing.expectEqualSlices(u8, fixture.portable_bytes[0..130], bytes[0..130]);
    try testing.expectEqual(@as(u8, 0xEE), bytes[130]);

    info = fixture.infoOf(rb, board);
    try testing.expectEqual(found[7].id, info.mode_id);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "a monitor that prefers what the board cannot make gets 1080p at 60; one mode in full is its one mode" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    // A board that makes no clock past 300 MHz, as an HDMI 1.4 port.
    fk.fastest_hz = 300_000_000;
    const board = try fixture.makeConnector(rb, fixture.uhd_bytes, 0);
    var found: [16]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 2), fixture.base(rb).GetBoardModes(board, &found, found.len));
    try testing.expectEqual(@as(u32, 3840), found[0].width);
    try testing.expectEqual(@as(u32, 30_000), found[0].refresh_mhz);
    try testing.expectEqual(@as(u32, 0), found[0].flags);
    try testing.expectEqual(@as(u32, 1080), found[1].height);
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[1].flags);
    // The board was asked of the two the monitor's own clock allows: it
    // says no faster one than HDMI 1.4's, so 4K at 60 is not its to take.
    try testing.expectEqual(@as(u32, 2), fk.log.checks);
    fixture.driverBase(rb).DeleteBoard(board);

    // One detailed timing and no more: that mode, as the monitor times it.
    fk.fastest_hz = 0xFFFF_FFFF;
    const other = try fixture.makeConnector(rb, fixture.qhd_bytes, 0);
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).GetBoardModes(other, &found, found.len));
    try testing.expectEqual(@as(u32, 2560), found[0].width);
    try testing.expectEqual(@as(u32, 241_500_000), found[0].pixel_clock_hz);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, other, 0));
    try testing.expectEqual(rtg.modes.RTGTM_HSYNC_HIGH, fk.log.last_timings.flags);
    try testing.expectEqual(@as(u8, 0), fk.log.last_timings.vic);
    // A monitor without an extension is a DVI monitor, of no sound.
    const said = fixture.monitorOf(rb, other);
    try testing.expectEqual(rtg.modes.RTGMON_PRESENT | rtg.modes.RTGMON_EDID, said.flags);
    fixture.driverBase(rb).DeleteBoard(other);
    try fixture.tearDown(rb);
}

test "a monitor that names nothing: the board's own modes, or its device's size at 60 a second" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);

    // No monitor on the connector: the driver's own modes stand, and the
    // board says it has no display - and is shown on all the same.
    const board = try fixture.makeConnector(rb, null, fixture.fake.mode_table.len);
    var found: [16]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 3), fixture.base(rb).GetBoardModes(board, &found, found.len));
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).FindBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY));
    try testing.expect(fixture.infoOf(rb, board).flags & rtg.boards.RTGBF_NO_DISPLAY != 0);
    try testing.expectEqual(@as(u32, 0), fixture.monitorOf(rb, board).flags);
    // In its mode of one bit a pixel, whose picture the tests' display
    // memory holds.
    const bm = fixture.base(rb).AllocBitMap(board, 64, 64, @intFromEnum(rtg.PixelFormat.mono1), rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const in_mono = [_]rtg.RtgBand{.{ .bitmap = bm }};
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoard(board, 3, &in_mono, in_mono.len));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(bm);
    fixture.driverBase(rb).DeleteBoard(board);

    // A monitor whose EDID does not read, on a board that added no mode:
    // the size its device's tags give, in the standard's timing.
    const sized = [_]TagItem{
        .{ .tag = rtg.tags.RTGA_Width, .data = 1280 },
        .{ .tag = rtg.tags.RTGA_Height, .data = 720 },
        .{ .tag = utility.TAG_MORE, .data = @intFromPtr(fixture.fake.deviceTags()) },
    };
    fk.connector = true;
    fk.modes = 0;
    fk.monitor_there = true;
    fk.monitor_edid = null;
    const bare = fixture.fake.makeBoardFrom(fk, &sized) orelse return error.NoBoard;
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).GetBoardModes(bare, &found, found.len));
    try testing.expectEqualStrings("1280x720", std.mem.sliceTo(&found[0].name, 0));
    try testing.expectEqual(@as(u32, 74_250_000), found[0].pixel_clock_hz);
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[0].flags);
    try testing.expectEqual(rtg.modes.RTGMON_PRESENT, fixture.monitorOf(rb, bare).flags);
    try testing.expectEqual(@as(u32, 0), fixture.infoOf(rb, bare).flags & rtg.boards.RTGBF_NO_DISPLAY);
    fixture.driverBase(rb).DeleteBoard(bare);

    // Bytes that do not sum to zero are no EDID: not kept, and the same
    // one mode.
    var broken: [256]u8 = undefined;
    @memcpy(&broken, fixture.portable_bytes);
    broken[20] ^= 0xFF;
    fk.monitor_edid = &broken;
    const doubtful = fixture.fake.makeBoardFrom(fk, &sized) orelse return error.NoBoard;
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).GetBoardModes(doubtful, null, 0));
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).ReadBoardEDID(doubtful, null, 0));
    try testing.expectEqual(rtg.modes.RTGMON_PRESENT, fixture.monitorOf(rb, doubtful).flags);
    // A driver that cannot say what is on its connector has none there.
    fk.detect_answer = rtg.errors.RTGERR_IO;
    fixture.driverBase(rb).MonitorChanged(doubtful);
    fixture.monitors.service(rb);
    try testing.expectEqual(@as(u32, 0), fixture.monitorOf(rb, doubtful).flags);
    try testing.expect(fixture.infoOf(rb, doubtful).flags & rtg.boards.RTGBF_NO_DISPLAY != 0);
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).GetBoardModes(doubtful, null, 0));
    fixture.driverBase(rb).DeleteBoard(doubtful);
    try fixture.tearDown(rb);
}

test "two monitors in turn: the list made again, a mode's number kept, the task told" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const sys = rb.sys_base;
    const board = try fixture.makeConnector(rb, fixture.portable_bytes, fixture.fake.mode_table.len);
    var first: [16]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 9), fixture.base(rb).GetBoardModes(board, &first, first.len));
    // The driver's own took the first three numbers, the monitor's the
    // next nine.
    try testing.expectEqual(@as(u32, 4), first[0].id);

    // A task that asked is told.
    const bit = sys.AllocSignal(-1);
    try testing.expect(bit >= 0);
    const mask = @as(u32, 1) << @intCast(bit);
    const notify = fixture.base(rb).AddRtgNotify(sys.FindTask(null).?, mask).?;
    try testing.expectEqual(@as(?*rtg.RtgNotify, null), fixture.base(rb).AddRtgNotify(sys.FindTask(null).?, 0));
    const changes = fixture.infoOf(rb, board).changes;

    // A look that finds the monitor it found changes nothing, and tells
    // nobody.
    fixture.driverBase(rb).MonitorChanged(board);
    fixture.driverBase(rb).MonitorChanged(board);
    fixture.monitors.service(rb);
    try testing.expectEqual(@as(u32, 2), fk.log.detects);
    try testing.expectEqual(changes, fixture.infoOf(rb, board).changes);
    try testing.expectEqual(@as(u32, 0), sys.SetSignal(0, mask) & mask);

    // Another monitor: its one mode is the list, with a number of its own.
    fk.monitor_edid = fixture.qhd_bytes;
    fixture.driverBase(rb).MonitorChanged(board);
    fixture.monitors.service(rb);
    var second: [16]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).GetBoardModes(board, &second, second.len));
    try testing.expectEqual(@as(u32, 2560), second[0].width);
    try testing.expectEqual(@as(u32, 13), second[0].id);
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, second[0].flags);
    try testing.expectEqual(changes + 1, fixture.infoOf(rb, board).changes);
    try testing.expect(sys.SetSignal(0, mask) & mask != 0);
    try testing.expectEqualStrings("", std.mem.sliceTo(&fixture.monitorOf(rb, board).name, 0));

    // The monitor taken off: the driver's own modes again, as they were.
    fk.monitor_there = false;
    fixture.driverBase(rb).MonitorChanged(board);
    fixture.monitors.service(rb);
    try testing.expectEqual(@as(u32, 3), fixture.base(rb).GetBoardModes(board, &second, second.len));
    try testing.expectEqual(@as(u32, 2), second[0].id);
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).FindBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY));
    try testing.expect(fixture.infoOf(rb, board).flags & rtg.boards.RTGBF_NO_DISPLAY != 0);
    try testing.expect(sys.SetSignal(0, mask) & mask != 0);

    // The first monitor again: every mode has the number it had.
    fk.monitor_there = true;
    fk.monitor_edid = fixture.portable_bytes;
    fixture.driverBase(rb).MonitorChanged(board);
    fixture.monitors.service(rb);
    try testing.expectEqual(@as(u32, 9), fixture.base(rb).GetBoardModes(board, &second, second.len));
    for (first[0..9], second[0..9]) |before, after| {
        try testing.expectEqual(before.id, after.id);
        try testing.expectEqual(before.width, after.width);
        try testing.expectEqual(before.flags, after.flags);
    }

    // A notification given back tells no more.
    _ = sys.SetSignal(0, mask);
    fixture.base(rb).RemRtgNotify(notify);
    fixture.base(rb).RemRtgNotify(null);
    fk.monitor_edid = fixture.uhd_bytes;
    fixture.driverBase(rb).MonitorChanged(board);
    fixture.monitors.service(rb);
    try testing.expectEqual(@as(u32, 0), sys.SetSignal(0, mask) & mask);
    try testing.expectEqual(@as(u32, 2), fixture.base(rb).GetBoardModes(board, null, 0));

    sys.FreeSignal(bit);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "a board that shows when its monitor changes: the mode again where the new one has it, none where it has not" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    // Three monitors of pictures small enough for the tests' display
    // memory: one of 64 by 32; one that prefers 32 by 32 and has 64 by 32
    // too, with another front porch; one of 32 by 32 alone.
    const wide_only = fixture.smallMonitor(fixture.smallTiming(64, 32, 8), null);
    const both = fixture.smallMonitor(fixture.smallTiming(32, 32, 8), fixture.smallTiming(64, 32, 12));
    const square_only = fixture.smallMonitor(fixture.smallTiming(32, 32, 8), null);
    const board = try fixture.makeConnector(rb, std.mem.sliceAsBytes(&wide_only), 0);
    const wide = fixture.base(rb).FindBoardMode(board, 64, 32, rtg.RTG_ANY, rtg.RTG_ANY);
    try testing.expect(wide != 0);
    const bm = fixture.base(rb).AllocBitMap(board, 64, 32, @intFromEnum(rtg.PixelFormat.rgb565), rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, bm));
    try testing.expectEqual(@as(u32, 1), fk.log.set_mode);
    try testing.expectEqual(@as(u32, 8), fk.log.last_timings.h_front);

    // A monitor that has the mode too: the board stays in it, its driver
    // handed the mode again with the timing this monitor gives it, and
    // what was shown with it - it stays shown.
    fk.monitor_edid = std.mem.sliceAsBytes(&both);
    fixture.driverBase(rb).MonitorChanged(board);
    fixture.monitors.service(rb);
    try testing.expectEqual(@as(u32, 2), fk.log.set_mode);
    try testing.expectEqual(rtg.boards.RTGSHOW_MODE_CHANGED | rtg.boards.RTGSHOW_DIRECT, fk.log.last_flags);
    try testing.expectEqual(wide, fk.log.last_mode.id);
    try testing.expectEqual(@as(u32, 12), fk.log.last_timings.h_front);
    try testing.expectEqual(@as(u32, 1), fk.log.band_count);
    try testing.expectEqual(bm, fk.log.bands[0].bitmap);
    try testing.expectEqual(bm, fixture.base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(bm.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    var info = fixture.infoOf(rb, board);
    try testing.expectEqual(wide, info.mode_id);
    try testing.expect(info.flags & rtg.boards.RTGBF_MODE_SET != 0);
    // The new monitor's list: the mode the board is in, and the one this
    // monitor prefers, which is the default.
    var found: [16]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 2), fixture.base(rb).GetBoardModes(board, &found, found.len));
    try testing.expectEqual(@as(u32, 64), found[0].width);
    try testing.expectEqual(rtg.modes.RTGMF_CURRENT, found[0].flags);
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[1].flags);

    // A monitor that has not got the mode: the board shows nothing and is
    // in none, and the buffer can go.
    fk.monitor_edid = std.mem.sliceAsBytes(&square_only);
    fixture.driverBase(rb).MonitorChanged(board);
    fixture.monitors.service(rb);
    try testing.expectEqual(@as(u32, 2), fk.log.set_mode);
    try testing.expectEqual(@as(u32, 0), fk.log.band_count);
    try testing.expect(fixture.base(rb).BoardDisplayBitMap(board) == null);
    try testing.expect(bm.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);
    info = fixture.infoOf(rb, board);
    try testing.expectEqual(@as(u32, 0), info.mode_id);
    try testing.expectEqual(@as(u32, 0), info.flags & rtg.boards.RTGBF_MODE_SET);
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).GetBoardModes(board, &found, found.len));
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[0].flags);
    // The mode it was in is not the board's to be put in until a monitor
    // has it, nor its buffer one to show in the mode that is.
    try testing.expectEqual(rtg.errors.RTGERR_BAD_MODE, fixture.setMode(rb, board, wide));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, fixture.base(rb).ShowBitMap(board, bm));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, 0));
    try testing.expectEqual(@as(u32, 32), fixture.infoOf(rb, board).width);

    // The driver that cannot bring the link up again for a monitor that
    // came leaves the board in no mode, showing nothing.
    const square = fixture.base(rb).AllocBitMap(board, 32, 32, @intFromEnum(rtg.PixelFormat.rgb565), rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, square));
    fk.monitor_edid = std.mem.sliceAsBytes(&both);
    fk.show_answer = rtg.errors.RTGERR_NO_DISPLAY;
    fixture.driverBase(rb).MonitorChanged(board);
    fixture.monitors.service(rb);
    try testing.expectEqual(@as(u32, 0), fixture.infoOf(rb, board).mode_id);
    try testing.expect(fixture.base(rb).BoardDisplayBitMap(board) == null);
    try testing.expectEqual(@as(u32, 0), fixture.fake.instanceOf(board).showing_count);

    fixture.base(rb).FreeBitMap(square);
    fixture.base(rb).FreeBitMap(bm);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

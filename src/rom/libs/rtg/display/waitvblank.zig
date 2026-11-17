// SPDX-License-Identifier: MPL-2.0
//! WaitVBlank: Wait for `frames` frames of the display to end; 0 is the
//! next one.
//!
//! A board whose driver says its frames (FrameDone) is waited for by
//! them: a waiter on the waiting task's stack is counted down by each
//! frame, and a request to timer.device - a copy of the library's,
//! answered to a port on the same stack - ends the wait when they do not
//! come. Both wake the task on one signal, so one Wait hears whichever is
//! first. A board that says none is waited for by the same request
//! alone, for the frames' time.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const timer = sdk.devices.timer;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const frames_file = @import("../frame/_frame.zig");
const err = rtg.errors;

/// A frame's time, in microseconds, on a board that does not say how
/// often it refreshes: a panel's 60 a second.
const default_frame_us: u64 = 16_667;

/// A frame's time on `board`, in microseconds: by its refresh rate, a
/// sixtieth of a second on a board that names none.
///
/// INPUTS:
/// - `board` - the board, for its refresh rate.
fn frameMicros(board: *const rtg.RtgBoard) u64 {
    const refresh_mhz = board.info.refresh_mhz;
    return if (refresh_mhz == 0) default_frame_us else 1_000_000_000 / @as(u64, refresh_mhz);
}

/// Waits for frames of the display to end.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitVBlank(rb: *RtgBase, board: *rtg.RtgBoard, frames: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `board` - the board.
/// - `frames` - how many frames to wait for; 0 is the next one.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_TIMEOUT` when the board's driver says its frames
/// and they did not come within two frames' time for each;
/// `RTGERR_NOT_SUPPORTED` where there is no timer.device to wait by;
/// `RTGERR_NO_MEMORY` without a free signal.
///
/// BEHAVIOR:
/// On a board whose driver says when a frame ends (`FrameDone`,
/// `RTGBC_VBLANK`) the task waits until that many have ended, or for the
/// time limit, whichever is first: two frames of the board's refresh rate
/// for each frame asked for, a frame taken as a sixtieth of a second on
/// a board that names no rate. A wait the frames did not come for
/// answers `RTGERR_TIMEOUT`, and the board is held to say none until its
/// driver says the next.
///
/// On a board that says no frames - one with no frame interrupt, one
/// whose stream has not begun or has stopped, one that is dark - and on
/// one that is asleep (`SetBoardPower`) the
/// task waits by the clock, a frame's time for each frame asked for, and
/// the answer is `RTGERR_OK`: a program that paces itself by the display
/// runs at the speed it would on one that says its frames.
///
/// So the call comes back on every board.
///
/// CONTEXT:
/// - Waits: yes.
/// - Interrupts: no. It waits.
/// - Locks: no spinlock may be held. The board's lock is not taken: a
///   driver calls it from its `show`, which holds it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A signal is taken for the wait and given back. Nothing is allocated:
/// the waiter, the request and its reply port are on the caller's stack;
/// the waiter is off the board's list and the request back from
/// timer.device when this returns.
///
/// NOTES:
/// `RTGERR_TIMEOUT` says nothing was waited for in step with the display:
/// a caller that paces itself by this call has been held for the limit
/// and no longer.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FrameDone`, `GetBoardStats`
///
/// EXAMPLES:
/// ```zig
/// if (rb.WaitVBlank(board, 0) == rtg.errors.RTGERR_TIMEOUT) {
///     // the board sends no frames just now
/// }
/// ```
pub fn WaitVBlank(rb: *RtgBase, board: *rtg.RtgBoard, frames: u32) i32 {
    const sys = rb.sys_base;
    const wanted = if (frames == 0) 1 else frames;
    const state = &boards.privateOf(board).frames;
    // A wait nothing could end is not begun.
    if (rb.timer_io.node.device == null) return err.RTGERR_NOT_SUPPORTED;

    // AllocSignal hands the bit out cleared, so neither an old frame nor
    // an old reply is heard.
    const signal_bit = sys.AllocSignal(-1);
    if (signal_bit < 0) return err.RTGERR_NO_MEMORY;
    defer sys.FreeSignal(signal_bit);
    const mask = @as(u32, 1) << @intCast(signal_bit);
    const task = sys.FindTask(null).?;

    // The clock: a copy of the library's request, answered to this task
    // on the signal the frames come on.
    var port: exec.MsgPort = .{ .sig_bit = @intCast(signal_bit), .sig_task = task };
    port.msg_list.init(.message);
    var clock = rb.timer_io;
    clock.node.message.reply_port = &port;
    clock.node.command = timer.TR_ADDREQUEST;

    if (!frames_file.come(state) or board.info.power == rtg.boards.RTGPWR_ASLEEP) {
        // No frames are said, or the display sleeps: the frames' time,
        // by the clock.
        clock.time = timer.TimeVal.fromMicros(frameMicros(board) * wanted);
        sys.SendIO(&clock.node);
        _ = sys.WaitIO(&clock.node);
        return err.RTGERR_OK;
    }

    var waiter: frames_file.Waiter = .{ .task = task, .mask = mask, .left = wanted };
    // The count is the interrupt's to write: read again at every look.
    const left: *volatile u32 = &waiter.left;
    // The limit: twice the frames' time. A board that says its frames
    // says one every frame, so twice that is one that will not come.
    clock.time = timer.TimeVal.fromMicros(2 * frameMicros(board) * wanted);

    frames_file.add(sys, state, &waiter);
    sys.SendIO(&clock.node);
    while (left.* != 0 and sys.CheckIO(&clock.node) == null) _ = sys.Wait(mask);
    const missing = frames_file.remove(sys, state, &waiter);
    // The request is back before its port goes with this call: taken back
    // where its time has not come, and its reply taken off the port.
    if (sys.CheckIO(&clock.node) == null) _ = sys.AbortIO(&clock.node);
    _ = sys.WaitIO(&clock.node);
    return if (missing == 0) err.RTGERR_OK else err.RTGERR_TIMEOUT;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "WaitVBlank: woken by the board's frames, the limit's request taken back" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeBoard(rb);
    const frames = &fixture.boards.privateOf(board).frames;
    // The library's own request, which every wait copies and none sends.
    const opened = rb.timer_io;
    try testing.expectEqual(fixture.timer.UNIT_MICROHZ, fixture.FakeTimer.opened_unit);
    fixture.frames_board = board;
    fixture.Sleep.install(&fixture.endOneFrame);
    defer fixture.Sleep.uninstall();
    // The board's driver says its frames: one was said.
    fixture.fake.endFrame(board);

    // The next frame: the task sleeps once, and the frame that ends
    // meanwhile wakes it. The limit never came, and is taken back; the
    // wait's waiter is off the board.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).WaitVBlank(board, 0));
    try testing.expect(frames.waiters == null);
    try testing.expectEqual(@as(u32, 1), fixture.Sleep.sleeps);
    try testing.expectEqual(@as(u32, 2), fk.log.frames_ended);
    try testing.expectEqual(@as(u32, 1), fixture.FakeTimer.sent);
    try testing.expectEqual(@as(u32, 1), fixture.FakeTimer.aborted);
    try testing.expect(fixture.FakeTimer.waiting == null);
    try testing.expect(fixture.FakeTimer.last.? != &rb.timer_io.node);
    try testing.expectEqual(opened, rb.timer_io);
    // Two frames' time for the one asked, a frame a sixtieth of a second
    // on a board that names no rate.
    try testing.expectEqual(@as(u64, 2 * 16_667), fixture.FakeTimer.last_micros);

    // Three of them: one sleep through all three, woken by the third,
    // and the limit three times as long - by the board's own rate, 50 a
    // second here.
    board.info.refresh_mhz = 50_000;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).WaitVBlank(board, 3));
    try testing.expect(frames.waiters == null);
    try testing.expectEqual(@as(u32, 2), fixture.Sleep.sleeps);
    try testing.expectEqual(@as(u32, 4), fixture.Sleep.interrupts);
    try testing.expectEqual(@as(u32, 5), fk.log.frames_ended);
    try testing.expectEqual(@as(u64, 3 * 2 * 20_000), fixture.FakeTimer.last_micros);
    try testing.expectEqual(@as(u32, 2), fixture.FakeTimer.aborted);
    try testing.expectEqual(opened, rb.timer_io);

    // An abort answered before its reply is made: the wait goes on until
    // the reply has landed - a sleep more - so none is left to land on a
    // port that has gone with the call.
    fixture.FakeTimer.abort_replies_later = true;
    fixture.Sleep.meanwhile = &fixture.frameOrLanding;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).WaitVBlank(board, 1));
    try testing.expect(fixture.FakeTimer.leaving == null);
    try testing.expect(frames.waiters == null);
    try testing.expectEqual(@as(u32, 4), fixture.Sleep.sleeps);
    try testing.expectEqual(@as(u32, 6), fixture.Sleep.interrupts);
    try testing.expectEqual(@as(u32, 6), fk.log.frames_ended);
    try testing.expectEqual(@as(u32, 3), fixture.FakeTimer.aborted);
    try testing.expectEqual(opened, rb.timer_io);
    fixture.FakeTimer.abort_replies_later = false;
    // The frames the waits saw are the frames counted, and the board
    // still says them.
    try testing.expectEqual(@as(u32, 6), fixture.blanksOf(rb, board));
    try testing.expect(fixture.saysFrames(rb, board));

    fixture.driverBase(rb).DeleteBoard(board);
    try testing.expect(fixture.base(rb).NextBoard(null) == null);
    try fixture.tearDown(rb);
}

test "WaitVBlank: frames that stop are waited for no longer than the limit, and by the clock from then on" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeBoard(rb);
    const frames = &fixture.boards.privateOf(board).frames;
    fixture.Sleep.install(&fixture.FakeTimer.expire);
    defer fixture.Sleep.uninstall();

    // A board that has said no frame is waited for by the clock: the
    // frames' time, no waiter on the board, and nothing taken back.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).WaitVBlank(board, 0));
    try testing.expectEqual(@as(u32, 1), fixture.Sleep.sleeps);
    try testing.expectEqual(@as(u32, 1), fixture.FakeTimer.sent);
    try testing.expectEqual(@as(u64, 16_667), fixture.FakeTimer.last_micros);
    try testing.expectEqual(@as(u32, 0), fixture.FakeTimer.aborted);
    try testing.expect(fixture.FakeTimer.waiting == null);
    try testing.expect(frames.waiters == null);
    // By the board's own rate, for each frame asked for.
    board.info.refresh_mhz = 50_000;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).WaitVBlank(board, 3));
    try testing.expectEqual(@as(u64, 3 * 20_000), fixture.FakeTimer.last_micros);
    board.info.refresh_mhz = 0;

    // It says a frame, and then no more: the limit's time passes while
    // the task sleeps, the waiter is off the board all the same, and the
    // board is held to say none.
    fixture.fake.endFrame(board);
    try testing.expect(fixture.saysFrames(rb, board));
    try testing.expectEqual(rtg.errors.RTGERR_TIMEOUT, fixture.base(rb).WaitVBlank(board, 2));
    try testing.expect(frames.waiters == null);
    try testing.expectEqual(@as(u32, 3), fixture.Sleep.sleeps);
    try testing.expectEqual(@as(u32, 1), fk.log.frames_ended);
    try testing.expectEqual(@as(u64, 2 * 2 * 16_667), fixture.FakeTimer.last_micros);
    try testing.expectEqual(@as(u32, 0), fixture.FakeTimer.aborted);
    try testing.expect(fixture.FakeTimer.waiting == null);
    try testing.expect(!fixture.saysFrames(rb, board));

    // From then on by the clock, and answered as a wait that was kept.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).WaitVBlank(board, 2));
    try testing.expectEqual(@as(u64, 2 * 16_667), fixture.FakeTimer.last_micros);
    try testing.expectEqual(@as(u32, 4), fixture.FakeTimer.sent);

    // The frames come again, one of the two asked for, and then no more:
    // the frame wakes nobody, and the limit ends the wait all the same.
    fixture.fake.endFrame(board);
    fixture.frames_board = board;
    fixture.frames_then_time = 0;
    fixture.Sleep.meanwhile = &fixture.oneFrameThenTime;
    const interrupts = fixture.Sleep.interrupts;
    try testing.expectEqual(rtg.errors.RTGERR_TIMEOUT, fixture.base(rb).WaitVBlank(board, 2));
    try testing.expect(frames.waiters == null);
    try testing.expectEqual(@as(u32, 3), fk.log.frames_ended);
    try testing.expectEqual(@as(u32, 5), fixture.Sleep.sleeps);
    try testing.expectEqual(interrupts + 2, fixture.Sleep.interrupts);
    try testing.expectEqual(@as(u32, 3), fixture.blanksOf(rb, board));
    try testing.expect(!fixture.saysFrames(rb, board));

    // With no clock to wait by nothing is waited for, on a board that
    // says its frames or not.
    const device = rb.timer_io.node.device;
    rb.timer_io.node.device = null;
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.base(rb).WaitVBlank(board, 1));
    fixture.fake.endFrame(board);
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.base(rb).WaitVBlank(board, 1));
    rb.timer_io.node.device = device;
    try testing.expectEqual(@as(u32, 5), fixture.FakeTimer.sent);

    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "WaitVBlank on a board asleep is by the clock, though its frames were said" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const board = try fixture.makeBoard(rb);
    fixture.Sleep.install(&fixture.FakeTimer.expire);
    defer fixture.Sleep.uninstall();
    // Its driver says its frames.
    fixture.fake.endFrame(board);
    try testing.expect(fixture.saysFrames(rb, board));
    try testing.expectEqual(@as(i32, @intCast(rtg.boards.RTGPWR_ASLEEP)), fixture.base(rb).SetBoardPower(board, rtg.boards.RTGPWR_ASLEEP));
    // A frame's time, and no waiter on the board's list meanwhile.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).WaitVBlank(board, 0));
    try testing.expectEqual(@as(u64, 16_667), fixture.FakeTimer.last_micros);
    try testing.expectEqual(@as(u32, 0), fixture.FakeTimer.aborted);
    try testing.expect(fixture.boards.privateOf(board).frames.waiters == null);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

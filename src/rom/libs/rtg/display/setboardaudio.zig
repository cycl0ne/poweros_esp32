// SPDX-License-Identifier: MPL-2.0
//! SetBoardAudio: Have a board's link carry a sound, or none.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const err = rtg.errors;

/// Has a board's link carry a sound from now on, or none.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardAudio(rb: *RtgBase, board: *rtg.RtgBoard, format: ?*const rtg.RtgAudio) i32
/// ```
///
/// SINCE: 1.33. LVO -76.
///
/// INPUTS:
/// - `board` - the board whose link is to carry the sound.
/// - `format` - the sound: its sample rate, channels and bits a sample.
///   Null for none.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_NOT_SUPPORTED` for a board whose link carries no
/// sound (no `RTGBC_AUDIO`), or what its driver answered:
/// `RTGERR_NO_MODE` while the link is not up, `RTGERR_NOT_SUPPORTED` for
/// a format the link does not carry or a monitor that is sent no
/// packets. Null on a board without `RTGBC_AUDIO` is `RTGERR_OK`.
///
/// BEHAVIOR:
/// A display's link - an HDMI port - carries sound beside the picture,
/// and the sound's driver is another module than the display's. This is
/// what the two share: the sound's driver feeds the samples its own way
/// and tells the board the format, and the display's driver does the
/// link's side (`audio`) - the numbers the monitor rebuilds the sample
/// clock from, the audio infoframe, the sample packets on. Null takes
/// all of that off again.
///
/// The driver keeps the format, and sets the link's side up again when
/// the mode changes while the sound plays, since the numbers follow the
/// pixel clock. Whether the monitor on the link plays sound at all is
/// the monitor's to say: `GetBoardMonitor`, `RTGMON_AUDIO`.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the board's lock, and if the
///   driver does.
/// - Interrupts: no. The driver may wait on its link.
/// - Locks: takes the board's lock. No spinlock may be held: a driver
///   may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The format stays the caller's and is copied
/// where the driver keeps it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBoardMonitor`, `GetBoardInfo`
///
/// EXAMPLES:
/// ```zig
/// if (rb.SetBoardAudio(board, &.{ .sample_rate = 48_000, .channels = 2, .bits = 16 }) != rtg.errors.RTGERR_OK) return;
/// defer _ = rb.SetBoardAudio(board, null);
/// ```
pub fn SetBoardAudio(rb: *RtgBase, board: *rtg.RtgBoard, format: ?*const rtg.RtgAudio) i32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const audio = ops.audio orelse return if (format == null) err.RTGERR_OK else err.RTGERR_NOT_SUPPORTED;
    return audio(board, format);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "SetBoardAudio: the link's driver told the sound, and none; a board whose link carries none" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeBoard(rb);
    try testing.expect(fixture.infoOf(rb, board).caps & rtg.boards.RTGBC_AUDIO != 0);

    const stereo = rtg.RtgAudio{ .sample_rate = 48_000, .channels = 2, .bits = 16 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardAudio(board, &stereo));
    try testing.expectEqual(@as(u32, 1), fk.log.audio_calls);
    try testing.expectEqual(@as(u32, 48_000), fk.log.last_audio.?.sample_rate);
    try testing.expectEqual(@as(u32, 2), fk.log.last_audio.?.channels);
    // What the driver answers is the answer.
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.base(rb).SetBoardAudio(board, &.{ .sample_rate = 44_100 }));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardAudio(board, null));
    try testing.expectEqual(@as(u32, 3), fk.log.audio_calls);
    try testing.expect(fk.log.last_audio == null);

    // A board whose driver has no such op: no sound, and none to take off.
    fk.without_engine = true;
    const plain = try fixture.makeBoard(rb);
    fk.without_engine = false;
    try testing.expectEqual(@as(u32, 0), fixture.infoOf(rb, plain).caps & rtg.boards.RTGBC_AUDIO);
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.base(rb).SetBoardAudio(plain, &stereo));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardAudio(plain, null));
    try testing.expectEqual(@as(u32, 3), fk.log.audio_calls);
    try fixture.tearDown(rb);
}

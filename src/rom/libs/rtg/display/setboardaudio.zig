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

// SPDX-License-Identifier: MIT
//! ReleaseVideoFrame: a frame given back.

const sdk = @import("sdk");
const vc = sdk.videocodec;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _stream = @import("_stream.zig");
const _codec = @import("../codec/_codec.zig");
const _ahead = @import("../ahead/_ahead.zig");

/// Gives a frame DecodeVideoFrame handed out back to the decoder.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseVideoFrame(base: *VideoCodecBase, stream: *vc.VideoStream, frame: *vc.VideoFrame) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `stream`: what OpenVideoStream made.
/// - `frame`: a frame it handed out and not yet taken back.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The frame's buffer goes back to the decoder, which decodes into it
/// again, and `frame` is cleared. A frame that is not one the stream has
/// lent - given back already, or cleared - is passed by. Decoded ahead
/// (SINCE 1.14), the process hands the buffer to the decoder before it
/// decodes its next frame.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// The planes are the decoder's again after the call; the frame may not
/// be shown after. Frames may be given back in any order, by the task
/// that decodes the pictures.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DecodeVideoFrame`
///
/// EXAMPLES:
/// ```zig
/// vcb.ReleaseVideoFrame(film, &frame);
/// ```
pub fn ReleaseVideoFrame(_: *VideoCodecBase, stream: *vc.VideoStream, frame: *vc.VideoFrame) void {
    const s = _stream.of(stream);
    const slot = _stream.slotOf(s, frame) orelse return;
    s.held[slot] = false;
    if (s.ahead) |ahead| _ahead.giveBack(ahead, slot) else _codec.release(s, slot);
    frame.* = .{};
}

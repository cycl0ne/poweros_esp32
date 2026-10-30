// SPDX-License-Identifier: MIT
//! DecodeVideoFrame: the next frame to be shown.

const sdk = @import("sdk");
const vc = sdk.videocodec;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _stream = @import("_stream.zig");
const chip = @import("../chip/_chip.zig");
const mjpeg = @import("../mjpeg/_mjpeg.zig");

/// Hands out the next frame in the order frames are shown.
///
/// SYNOPSIS:
/// ```zig
/// fn DecodeVideoFrame(base: *VideoCodecBase, stream: *vc.VideoStream, frame: *vc.VideoFrame) i32
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `stream`: what OpenVideoStream made.
/// - `frame`: where the frame goes.
///
/// RESULT:
/// VCERR_OK and the frame in `frame`; VCERR_END when every frame has been
/// handed out; VCERR_BUSY with VIDEO_HELD_FRAMES frames held; VCERR_CORRUPT
/// for a picture the decoder stopped on - called again, it goes on with
/// the next; VCERR_UNSUPPORTED, VCERR_READ, VCERR_NOMEMORY.
///
/// BEHAVIOR:
/// The picture track's packets are decoded until the next frame comes
/// out: the chip's decoder fed them a picture at a time - turned into the
/// form it takes, the parameter sets in front of each key picture - and
/// asked for its frames, which it hands out in the order they are shown;
/// a Motion JPEG picture unpacked into its planes. A frame due before
/// what the film presents, or before the key frame a seek landed on, is
/// passed over. At the end of the track the chip's decoder hands out the
/// frames it still holds back, and then VCERR_END. The frame's `time` is
/// when it is due, and `number` counts the frames handed out since the
/// stream was opened or moved.
///
/// CONTEXT:
/// - Waits: yes, on the file and the chip.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process for a file; a task will do with VCA_ReadFunc.
///
/// OWNERSHIP:
/// The frame's planes are the decoder's, lent until ReleaseVideoFrame
/// gives them back; they do not change while lent. The pictures are
/// decoded by one task at a time, which may be another than the one that
/// decodes the sound.
///
/// NOTES:
/// The chip decodes 1080p H.264 at about 150 frames a second. Motion JPEG
/// is decoded on the calling task, about a second for a 1080p picture on
/// the VisionFive 2: for small pictures.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseVideoFrame`, `SeekVideo`, graphics' `WriteYUVPixelArray`
///
/// EXAMPLES:
/// ```zig
/// var frame: vc.VideoFrame = .{};
/// while (vcb.DecodeVideoFrame(film, &frame) == vc.VCERR_OK) {
///     waitUntil(frame.time);
///     _ = gfx.WriteYUVPixelArray(rp, &frame.picture, 0, 0, &.{ .x = 0, .y = 0, .w = frame.width, .h = frame.height });
///     vcb.ReleaseVideoFrame(film, &frame);
/// }
/// ```
pub fn DecodeVideoFrame(_: *VideoCodecBase, stream: *vc.VideoStream, frame: *vc.VideoFrame) i32 {
    const s = _stream.of(stream);
    const slot = _stream.freeSlot(s) orelse return vc.VCERR_BUSY;
    const result = switch (s.engine) {
        .chip => chip.decode(s, frame, slot),
        .mjpeg => mjpeg.decode(s, frame, slot),
    };
    if (result != vc.VCERR_OK) return result;
    s.held[slot] = true;
    frame.number = s.number;
    frame.private = .{ slot + 1, _stream.frame_mark, 0 };
    s.number += 1;
    return vc.VCERR_OK;
}

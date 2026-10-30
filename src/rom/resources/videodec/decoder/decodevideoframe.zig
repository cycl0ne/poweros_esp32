// SPDX-License-Identifier: MPL-2.0
//! DecodeVideoFrame: the next frame in the order frames are shown.

const sdk = @import("sdk");
const types = sdk.resources.videodec;
const VideoDecBase = @import("../videodec_base.zig").VideoDecBase;
const Decoder = @import("_decoder.zig").Decoder;

/// Hands out a decoder's next frame, decoding as many pictures as that
/// takes.
///
/// SYNOPSIS:
/// ```zig
/// fn DecodeVideoFrame(vb: *VideoDecBase, decoder: *VideoDecoder,
///     frame: *VideoDecFrame) u32
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `decoder` - the decoder.
/// - `frame` - filled in.
///
/// RESULT:
/// VDERR_OK, and `frame` holds the next frame to be shown (see
/// VideoDecFrame), lent until ReleaseVideoFrame. Otherwise `frame` is
/// left as it was, and: VDERR_NEED_DATA when every picture fed is decoded
/// and none is due yet - feed more; VDERR_END when the stream was ended
/// and its last frame handed out; VDERR_FULL when every frame buffer is
/// lent - give some back; VDERR_UNSUPPORTED for a stream the chip does
/// not take (10-bit H.264, too large, changing its size); VDERR_NO_MEMORY for
/// its frames; VDERR_CORRUPT when the chip stopped on the stream or did
/// not answer in half a second, after which the decoder does nothing
/// more.
///
/// BEHAVIOR:
/// The first call reads the stream's sequence from what was fed - its
/// parameter sets and first picture; what comes before them is passed
/// over - and makes the decoder's frames. Each call then has the chip
/// decode the next picture fed, until one is due to be shown: with B
/// frames the chip holds pictures back, so a frame may come out only
/// after the next ones are fed. After VDFEED_END the ones held back come
/// out, one a call, then VDERR_END. The caller's task waits for the chip
/// meanwhile, the CPU free.
///
/// The frame's bytes are dropped from the caches before it is handed
/// out; they are the chip's, written by it - read them, do not write.
///
/// CONTEXT:
/// - Waits: yes, for the chip. - Interrupts: no.
/// - Locks: the resource's, around the chip: decoders on other tasks wait
///   meanwhile. - Process: a Task will do.
///
/// OWNERSHIP:
/// The frame's planes are the decoder's, lent to the caller until
/// ReleaseVideoFrame or CloseVideoDecoder; the decoder does not write
/// them until then.
///
/// NOTES:
/// A frame's time is the time of the picture it shows as it was fed: of
/// the pictures decoded and not yet shown, the earliest.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FeedVideoDecoder`, `ReleaseVideoFrame`, `GetVideoDecoderInfo`
///
/// EXAMPLES:
/// ```zig
/// var frame: videodec.VideoDecFrame = .{};
/// if (vb.DecodeVideoFrame(decoder, &frame) == videodec.VDERR_OK) {
///     defer vb.ReleaseVideoFrame(decoder, &frame);
///     show(frame.y.?, frame.cbcr.?, frame.pitch, frame.width, frame.height);
/// }
/// ```
pub fn DecodeVideoFrame(vb: *VideoDecBase, decoder: *types.VideoDecoder, frame: *types.VideoDecFrame) u32 {
    const sys = vb.sys_base;
    sys.ObtainSemaphore(&vb.lock);
    defer sys.ReleaseSemaphore(&vb.lock);
    return Decoder.of(decoder).nextFrame(frame);
}

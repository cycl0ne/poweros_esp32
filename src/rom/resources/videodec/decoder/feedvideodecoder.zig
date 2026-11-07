// SPDX-License-Identifier: MPL-2.0
//! FeedVideoDecoder: one picture's data into a decoder's stream.

const sdk = @import("sdk");
const types = sdk.resources.videodec;
const VideoDecBase = @import("../videodec_base.zig").VideoDecBase;
const Decoder = @import("_decoder.zig").Decoder;
const Session = @import("_session.zig").Session;
const engine = @import("../videodec_init.zig").engine;

/// Feeds a decoder one picture of its stream.
///
/// SYNOPSIS:
/// ```zig
/// fn FeedVideoDecoder(vb: *VideoDecBase, decoder: *VideoDecoder,
///     data: ?[*]const u8, length: u32, time: u64, flags: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -16.
///
/// INPUTS:
/// - `decoder` - the decoder.
/// - `data` - the picture's units in Annex B form, each after a start
///   code; the parameter sets in front of the first picture.
/// - `length` - how many bytes; 0 with VDFEED_END alone.
/// - `time` - when the picture is shown, in the caller's units
///   (microseconds, say); handed back with its frame.
/// - `flags` - VDFEED_END with the stream's last picture, or after it.
///
/// RESULT:
/// VDERR_OK; VDERR_FULL when the stream's ring has no room for it yet, or
/// 64 pictures wait to be decoded - DecodeVideoFrame makes room, then the
/// picture is fed again; VDERR_END after the stream was ended, until
/// FlushVideoDecoder; VDERR_CORRUPT when the decoder stopped on the
/// stream before, or the chip did not take the data.
///
/// BEHAVIOR:
/// The bytes are copied into the ring the chip reads, written back out
/// of the caches, and the chip told where they end. Nothing is decoded
/// here: DecodeVideoFrame does it.
///
/// On an AMD graphics device the bytes are copied and read at once
/// (videoparse.library): the sequence makes the stream on the device,
/// and each picture the call completes is decoded there and read back
/// into a frame of the system's memory, the caller's task waiting for
/// the device meanwhile. Pictures go on being read until the stream
/// needs a frame back that is still to be handed out or lent: then the
/// rest of the call's bytes are read by the next DecodeVideoFrame or
/// FeedVideoDecoder, and a call that comes while they are not answers
/// VDERR_FULL. A stream the device does not take answers
/// VDERR_UNSUPPORTED: H.264 other than 8-bit 4:2:0, the extended
/// profile, lossless pictures, slice groups, larger than 4096 each way;
/// H.265 other than Main, Main 10 and Main Still Picture, larger than
/// 8192 x 4352.
///
/// CONTEXT:
/// - Waits: yes, for the chip to take the command. - Interrupts: no.
/// - Locks: the resource's, around the chip. - Process: a Task will do.
///
/// OWNERSHIP:
/// `data` is copied: the caller's again when the call returns.
///
/// NOTES:
/// One picture per call keeps each frame's time right; a call with the
/// parameter sets alone counts as a picture of its own.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DecodeVideoFrame`, `FlushVideoDecoder`
///
/// EXAMPLES:
/// ```zig
/// while (vb.FeedVideoDecoder(decoder, unit.ptr, @intCast(unit.len), pts, 0) == videodec.VDERR_FULL) {
///     if (vb.DecodeVideoFrame(decoder, &frame) == videodec.VDERR_OK) show(&frame);
/// }
/// ```
pub fn FeedVideoDecoder(vb: *VideoDecBase, decoder: *types.VideoDecoder, data: ?[*]const u8, length: u32, time: u64, flags: u32) u32 {
    const sys = vb.sys_base;
    sys.ObtainSemaphore(&vb.lock);
    defer sys.ReleaseSemaphore(&vb.lock);
    if (comptime engine == .vcn) return Session.of(decoder).feed(data, length, time, flags);
    return Decoder.of(decoder).feed(data, length, time, flags);
}

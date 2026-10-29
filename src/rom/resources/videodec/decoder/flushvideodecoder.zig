// SPDX-License-Identifier: MPL-2.0
//! FlushVideoDecoder: what a decoder was fed and has not shown dropped.

const sdk = @import("sdk");
const types = sdk.resources.videodec;
const VideoDecBase = @import("../videodec_base.zig").VideoDecBase;
const Decoder = @import("_decoder.zig").Decoder;

/// Drops what a decoder was fed and has not shown yet, for a seek.
///
/// SYNOPSIS:
/// ```zig
/// fn FlushVideoDecoder(vb: *VideoDecBase, decoder: *VideoDecoder) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `decoder` - the decoder.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A picture the chip is decoding is waited for, then everything queued
/// for the decoder dropped: the pictures fed and not decoded, the frames
/// decoded and not shown. The stream is no longer ended (VDFEED_END), so
/// it can be fed again - from a key frame, as after a seek. The sequence
/// and the frames stay: a stream fed after it is one of the same size.
///
/// CONTEXT:
/// - Waits: yes, for the chip. - Interrupts: no.
/// - Locks: the resource's, around the chip. - Process: a Task will do.
///
/// OWNERSHIP:
/// The frames handed out stay the caller's, to give back as before.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FeedVideoDecoder`, `DecodeVideoFrame`
///
/// EXAMPLES:
/// ```zig
/// vb.FlushVideoDecoder(decoder);
/// feedFrom(keyFrameBefore(target));
/// ```
pub fn FlushVideoDecoder(vb: *VideoDecBase, decoder: *types.VideoDecoder) void {
    const sys = vb.sys_base;
    sys.ObtainSemaphore(&vb.lock);
    defer sys.ReleaseSemaphore(&vb.lock);
    Decoder.of(decoder).flush();
}

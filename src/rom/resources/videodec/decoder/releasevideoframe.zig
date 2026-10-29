// SPDX-License-Identifier: MPL-2.0
//! ReleaseVideoFrame: a frame handed back to its decoder.

const sdk = @import("sdk");
const types = sdk.resources.videodec;
const VideoDecBase = @import("../videodec_base.zig").VideoDecBase;
const Decoder = @import("_decoder.zig").Decoder;

/// Gives a frame DecodeVideoFrame handed out back to the decoder.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseVideoFrame(vb: *VideoDecBase, decoder: *VideoDecoder,
///     frame: *VideoDecFrame) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `decoder` - the decoder it came from.
/// - `frame` - as DecodeVideoFrame filled it in.
///
/// RESULT:
/// Nothing. `frame` is all zero afterwards.
///
/// BEHAVIOR:
/// The chip may decode into the frame's buffer again. A frame not handed
/// out - all zero - or given back already is left alone.
///
/// CONTEXT:
/// - Waits: yes, for the chip to take the command. - Interrupts: no.
/// - Locks: the resource's, around the chip. - Process: a Task will do.
///
/// OWNERSHIP:
/// The planes are the decoder's again: nothing may read them afterwards.
///
/// NOTES:
/// Frames may be given back in any order.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DecodeVideoFrame`
///
/// EXAMPLES:
/// ```zig
/// defer vb.ReleaseVideoFrame(decoder, &frame);
/// ```
pub fn ReleaseVideoFrame(vb: *VideoDecBase, decoder: *types.VideoDecoder, frame: *types.VideoDecFrame) void {
    const sys = vb.sys_base;
    sys.ObtainSemaphore(&vb.lock);
    defer sys.ReleaseSemaphore(&vb.lock);
    Decoder.of(decoder).release(frame);
}

// SPDX-License-Identifier: MPL-2.0
//! GetVideoDecoderInfo: what a decoder's stream is.

const sdk = @import("sdk");
const types = sdk.resources.videodec;
const VideoDecBase = @import("../videodec_base.zig").VideoDecBase;
const Decoder = @import("_decoder.zig").Decoder;
const wave511 = @import("../codec/_wave511.zig");

/// Says what a decoder's stream is, once its sequence is read.
///
/// SYNOPSIS:
/// ```zig
/// fn GetVideoDecoderInfo(vb: *VideoDecBase, decoder: *VideoDecoder,
///     info: *VideoDecInfo) u32
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `decoder` - the decoder.
/// - `info` - filled in.
///
/// RESULT:
/// VDERR_OK, and `info` holds the stream's size as shown and as coded,
/// its bit depth, profile and frame rate (see VideoDecInfo), and how many
/// frames the decoder made. VDERR_NEED_DATA, and `info` all zero, while
/// what was fed holds no sequence yet; otherwise what DecodeVideoFrame
/// would answer for the stream (VDERR_UNSUPPORTED, VDERR_NO_MEMORY,
/// VDERR_CORRUPT).
///
/// BEHAVIOR:
/// A decoder whose sequence is not read yet has the chip read it from
/// what was fed, and makes its frames, as the first DecodeVideoFrame
/// would; no picture is decoded.
///
/// CONTEXT:
/// - Waits: yes, for the chip. - Interrupts: no.
/// - Locks: the resource's, around the chip. - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is kept.
///
/// NOTES:
/// H.264's frame rate is its timing's half rate (fields): `rate_den` is
/// twice the stream's num_units_in_tick.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FeedVideoDecoder`, `DecodeVideoFrame`
///
/// EXAMPLES:
/// ```zig
/// var info: videodec.VideoDecInfo = .{};
/// if (vb.GetVideoDecoderInfo(decoder, &info) == videodec.VDERR_OK) open(info.width, info.height);
/// ```
pub fn GetVideoDecoderInfo(vb: *VideoDecBase, decoder: *types.VideoDecoder, info: *types.VideoDecInfo) u32 {
    const sys = vb.sys_base;
    info.* = .{};
    sys.ObtainSemaphore(&vb.lock);
    defer sys.ReleaseSemaphore(&vb.lock);
    const d = Decoder.of(decoder);
    const started = d.startSequence();
    if (started != types.VDERR_OK) return started;
    const s = d.seq;
    const rated = s.rate_num != 0 and s.rate_den != 0;
    info.* = .{
        .width = s.width - s.left - s.right,
        .height = s.height - s.top - s.bottom,
        .coded_width = s.width,
        .coded_height = s.height,
        .left = s.left,
        .top = s.top,
        .bit_depth = s.luma_depth,
        .profile = s.profile,
        .rate_num = if (rated) s.rate_num else 0,
        .rate_den = if (!rated) 0 else if (d.instance.std == wave511.STD_AVC) s.rate_den * 2 else s.rate_den,
        .frames = d.linear_count,
    };
    return types.VDERR_OK;
}

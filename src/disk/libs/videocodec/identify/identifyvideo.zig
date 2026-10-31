// SPDX-License-Identifier: MIT
//! IdentifyVideo: what codec a film's pictures are in, by its first
//! bytes.

const sdk = @import("sdk");
const vc = sdk.videocodec;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _identify = @import("_identify.zig");

/// Says what codec the pictures of a film are in, by the first bytes of
/// its file.
///
/// SYNOPSIS:
/// ```zig
/// fn IdentifyVideo(base: *VideoCodecBase, bytes: [*]const u8, length: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `bytes`, `length`: the file's first bytes - VIDEO_IDENTIFY_BYTES
///   are best.
///
/// RESULT:
/// The codec of its first track of pictures, VCODEC_*; VCODEC_UNKNOWN when
/// the bytes do not show it.
///
/// BEHAVIOR:
/// The bytes are read as an MP4 - media.library's kind - box by box, to
/// its index (`moov`) and in it the first track of pictures, whose first
/// sample entry names the codec. An MP4 whose index lies behind the bytes
/// given - at its end, as a film written in one go has it - shows
/// nothing: VCODEC_UNKNOWN, though OpenVideoStream reads its index
/// wherever it is. A Matroska file (SINCE 1.2) is read element by element
/// to its tracks, which muxers put near the front, and the first track of
/// pictures names the codec by its ID; VP8, VP9 and AV1 are
/// VCODEC_UNKNOWN. media.library's IdentifyMedia says whether the bytes
/// begin a film at all.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Locks: none.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// The bytes are the caller's, only read.
///
/// NOTES:
/// A codec it names may still be one nothing here decodes: VCODEC_MPEG4V,
/// VCODEC_VP9 and VCODEC_AV1, for which there is no module; H.265 where
/// no module in LIBS:codecs/ decodes it - chip.vcodec on a board without
/// the chip.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenVideoStream`, media.library's `IdentifyMedia`
///
/// EXAMPLES:
/// ```zig
/// const got = dl.Read(fh, &head, head.len);
/// if (got > 0 and vcb.IdentifyVideo(&head, @intCast(got)) == vc.VCODEC_H264) {
///     // a film for the chip
/// }
/// ```
pub fn IdentifyVideo(_: *VideoCodecBase, bytes: [*]const u8, length: u32) u32 {
    return _identify.identify(bytes[0..length]);
}

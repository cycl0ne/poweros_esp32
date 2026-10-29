// SPDX-License-Identifier: MPL-2.0
//! VideoDecCodecs: which codecs the chip decodes.

const sdk = @import("sdk");
const base = @import("../videodec_base.zig");
const VideoDecBase = base.VideoDecBase;

/// Says which codecs the chip's decoder takes.
///
/// SYNOPSIS:
/// ```zig
/// fn VideoDecCodecs(vb: *VideoDecBase) u32
/// ```
///
/// SINCE: 1.0. LVO -4.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// A VDCODEC_* bit for each codec: VDCODEC_H264 | VDCODEC_H265 on the
/// JH7110. 0 when the board has no decoder, or it would not wake or its
/// firmware would not start.
///
/// BEHAVIOR:
/// Answered from what the board lists; the chip is not woken. Whether the
/// firmware is on the disk only the first OpenVideoDecoder finds out.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: yes.
/// - Locks: none taken. - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenVideoDecoder`
///
/// EXAMPLES:
/// ```zig
/// if (vb.VideoDecCodecs() & videodec.VDCODEC_H264 != 0) { ... }
/// ```
pub fn VideoDecCodecs(vb: *VideoDecBase) u32 {
    if (vb.vpu == 0 or vb.state == base.STATE_DEAD) return 0;
    return vb.codecs;
}

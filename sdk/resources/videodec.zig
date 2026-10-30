// SPDX-License-Identifier: MIT
//! videodec.resource: the chip's video decoder - the JH7110's WAVE511 on
//! the VisionFive 2. A machine without one has no videodec.resource.
//!
//! A decoder is opened for a codec (OpenVideoDecoder), fed the stream a
//! picture at a time (FeedVideoDecoder) and asked for its frames in the
//! order they are shown (DecodeVideoFrame); each frame is the decoder's
//! own buffer, lent until ReleaseVideoFrame gives it back. FlushVideoDecoder
//! drops what was fed and not yet decoded, for a seek; CloseVideoDecoder
//! ends it. A decoder is used by one task at a time; several may be open
//! at once, and the chip takes their pictures in turn.
//!
//! **What is fed**: a codec's elementary stream in Annex B form - each
//! unit after a start code (00 00 01 or 00 00 00 01) - one picture per
//! call, with its parameter sets (H.264's SPS and PPS, H.265's VPS, SPS
//! and PPS) in front of the first picture and wherever the stream repeats
//! them. A container's packets (MP4's length-prefixed units) are turned
//! into that before they are fed; videocodec.library does it.
//!
//! **What comes out**: 8-bit 4:2:0 frames as two planes, NV12 - a plane
//! of brightness, then one of the two colour differences side by side,
//! Cb first, at half the size each way - in memory below 4 GiB. The chip
//! decodes H.264 (baseline, main, high) and H.265 (main), 4K at its best
//! speed; 10-bit streams are not taken.
//!
//! Get its base with OpenResource(VIDEODECNAME); its functions are in
//! sdk/interface/videodec.zig.

const utility = @import("../libs/utility/utility.zig");

/// The resource's name, for OpenResource.
pub const VIDEODECNAME = "videodec.resource";

/// The codecs, as VideoDecCodecs answers them and OpenVideoDecoder takes
/// one: a bit each.
pub const VDCODEC_H264: u32 = 1 << 0;
pub const VDCODEC_H265: u32 = 1 << 1;

/// What the calls answer.
pub const VDERR_OK: u32 = 0;
/// DecodeVideoFrame: the decoder has nothing to show until it is fed more.
pub const VDERR_NEED_DATA: u32 = 1;
/// DecodeVideoFrame: every frame of a stream fed to its end
/// (VDFEED_END) has been handed out.
pub const VDERR_END: u32 = 2;
/// FeedVideoDecoder: the stream's buffer has no room for the picture;
/// take frames first, which makes room.
pub const VDERR_FULL: u32 = 3;
/// The stream says something its codec does not allow, or the chip
/// stopped on it, or did not finish in time.
pub const VDERR_CORRUPT: u32 = 4;
/// OpenVideoDecoder: the chip has no such decoder, or cannot be used -
/// no firmware, or it would not wake.
pub const VDERR_NO_ENGINE: u32 = 5;
/// A codec, a stream or a frame the decoder does not take: another
/// codec, 10-bit H.264, a size too large, a size that changes within
/// the stream.
pub const VDERR_UNSUPPORTED: u32 = 6;
/// No memory for the decoder or its frames.
pub const VDERR_NO_MEMORY: u32 = 7;
/// OpenVideoDecoder: as many decoders are open as the chip runs.
pub const VDERR_BUSY: u32 = 8;

/// FeedVideoDecoder's flags.
/// The stream ends with this call - `length` may be 0 - so the frames the
/// decoder still holds back come out.
pub const VDFEED_END: u32 = 1 << 0;

/// The form of a frame's pixels: NV12, as above.
pub const VDFMT_NV12: u32 = 1;

/// OpenVideoDecoder's tags.
pub const VDA_Dummy = utility.TAG_USER + 0x60B00;
/// How many bytes of the stream the decoder keeps fed and not yet
/// decoded: at least one picture's worth. 2 MiB by default.
pub const VDA_StreamSize = VDA_Dummy + 0x01;
/// How many frames the caller holds at once, handed out and not yet
/// released: the decoder keeps as many buffers more than it needs. 2 by
/// default, at most 16.
pub const VDA_HeldFrames = VDA_Dummy + 0x02;

/// A decoder, as OpenVideoDecoder gives it: the resource's.
pub const VideoDecoder = opaque {};

/// A frame DecodeVideoFrame handed out: `width` x `height` pixels - the
/// picture as it is shown, its cropping taken off - in `format`, `y` and
/// `cbcr` its planes, `pitch` bytes from one row to the next in both.
/// `time` is the time it was fed with, `number` its place in the order
/// frames are shown, from 0. The rest is the resource's, for
/// ReleaseVideoFrame.
pub const VideoDecFrame = extern struct {
    y: ?[*]const u8 = null,
    cbcr: ?[*]const u8 = null,
    pitch: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = 0,
    time: u64 align(4) = 0,
    number: u32 = 0,
    private: [3]u32 = @splat(0),
};

/// What GetVideoDecoderInfo says of a stream: the picture as shown, the
/// size it is coded at and where the shown part starts in it, its bit
/// depth (8, or 10 for H.265 Main10 - whose frames come out in 8 bits
/// all the same; SINCE 1.1), its codec's profile number (H.264's profile_idc, H.265's
/// general_profile_idc), its frames a second as `rate_num` / `rate_den`
/// (both 0 when the stream does not say), and how many frame buffers the
/// decoder made.
pub const VideoDecInfo = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    coded_width: u32 = 0,
    coded_height: u32 = 0,
    left: u32 = 0,
    top: u32 = 0,
    bit_depth: u32 = 0,
    profile: u32 = 0,
    rate_num: u32 = 0,
    rate_den: u32 = 0,
    frames: u32 = 0,
};

/// The resource's base, with its functions.
pub const VideoDecBase = @import("../interface/videodec.zig").VideoDecBase;

// SPDX-License-Identifier: MIT
//! GetVideoStreamInfo: what a film is.

const sdk = @import("sdk");
const vc = sdk.videocodec;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _stream = @import("_stream.zig");
const chip = @import("../chip/_chip.zig");

/// Says what a film is: its pictures, its length, its sound, its title.
///
/// SYNOPSIS:
/// ```zig
/// fn GetVideoStreamInfo(base: *VideoCodecBase, stream: *vc.VideoStream, info: *vc.VideoStreamInfo) void
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `stream`: what OpenVideoStream made.
/// - `info`: where it goes.
///
/// RESULT:
/// None; `info` is filled in.
///
/// BEHAVIOR:
/// The pictures' codec and size and the number of them come from the
/// film's index; their rate from it too - the frames a second on average,
/// to a thousandth - or else from the stream, once the chip's decoder has
/// read it. Where the chip's decoder has read the stream, its size as
/// shown - cropped - is the one given. The length is the picture track's,
/// or the film's. The sound is audiocodec's stream on the film's sound
/// track: its codec, rate and channels, as DecodeVideoSound hands it out.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// `info` is the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenVideoStream`, `GetVideoStreamAttrs`
///
/// EXAMPLES:
/// ```zig
/// var info: vc.VideoStreamInfo = .{};
/// vcb.GetVideoStreamInfo(film, &info);
/// ```
pub fn GetVideoStreamInfo(_: *VideoCodecBase, stream: *vc.VideoStream, info: *vc.VideoStreamInfo) void {
    const s = _stream.of(stream);
    const track = &s.picture;
    info.* = .{
        .codec = s.codec,
        .width = track.width,
        .height = track.height,
        .duration = if (track.duration != 0) track.duration else s.file_info.duration,
        .frames = track.packets,
        .seekable = s.file_info.seekable,
        .title = s.file_info.title,
    };
    if (track.frame_rate != 0) {
        const common = gcd(track.frame_rate, 1000);
        info.rate_num = track.frame_rate / common;
        info.rate_den = 1000 / common;
    }
    if (s.engine == .chip) chip.streamInfo(s, info);
    if (s.sound != null) {
        info.sound_codec = s.sound_info.codec;
        info.sound_rate = s.sound_info.rate;
        info.sound_channels = s.sound_info.channels;
    }
}

fn gcd(a: u32, b: u32) u32 {
    var x = a;
    var y = b;
    while (y != 0) {
        const rest = x % y;
        x = y;
        y = rest;
    }
    return x;
}

// SPDX-License-Identifier: MIT
//! GetAudioStreamInfo: what a stream is.

const sdk = @import("sdk");
const ac = sdk.audiocodec;
const AudioCodecBase = @import("../audiocodec_base.zig").AudioCodecBase;
const _stream = @import("_stream.zig");

/// Says what a stream is.
///
/// SYNOPSIS:
/// ```zig
/// fn GetAudioStreamInfo(base: *AudioCodecBase, stream: *ac.AudioStream, info: *ac.AudioStreamInfo) void
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `stream`: an open stream.
/// - `info`: filled in.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The kind, the rate and channels of the samples DecodeAudio hands out,
/// the bits a sample has in the file, the bit rate, whether the stream can
/// seek, the length in frames, and the title, artist and album its tags
/// name. An MP3's length is exact when its encoder wrote it down (a Xing
/// or Info frame), worked out from its bit rate and the file's size
/// otherwise, and 0 for a stream read through a function without that
/// frame. A FLAC's is its STREAMINFO's. An Ogg Vorbis file's is its last
/// page's position, exact; read through a function it is 0. The bit rate
/// of a FLAC is the average its size and length give, of a Vorbis the
/// one its header names.
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
/// `OpenAudioStream`, `DecodeAudio`
///
/// EXAMPLES:
/// ```zig
/// var info: ac.AudioStreamInfo = .{};
/// acb.GetAudioStreamInfo(stream, &info);
/// // a stream of AUDIO_S16 for audio.device at info.rate, info.channels
/// ```
pub fn GetAudioStreamInfo(_: *AudioCodecBase, stream: *ac.AudioStream, info: *ac.AudioStreamInfo) void {
    info.* = _stream.streamOf(stream).info;
}

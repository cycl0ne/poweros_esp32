// SPDX-License-Identifier: MIT
//! SeekAudio: a stream moved to another frame.

const sdk = @import("sdk");
const ac = sdk.audiocodec;
const AudioCodecBase = @import("../audiocodec_base.zig").AudioCodecBase;
const _stream = @import("_stream.zig");
const wav = @import("../wav/_wav.zig");
const mp3 = @import("../mp3/_mp3.zig");
const flac = @import("../flac/_flac.zig");
const vorbis = @import("../vorbis/_vorbis.zig");

/// Moves a stream to a frame.
///
/// SYNOPSIS:
/// ```zig
/// fn SeekAudio(base: *AudioCodecBase, stream: *ac.AudioStream, frame: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `stream`: an open stream on a file.
/// - `frame`: the frame to go on from, counted from 0.
///
/// RESULT:
/// 0, or an ACERR_*: ACERR_NOSEEK for a stream read through a function.
///
/// BEHAVIOR:
/// A WAV, a FLAC and an Ogg Vorbis file go to the frame exactly: a FLAC
/// from its seek table's point before it, or a frame a search halving the
/// file finds, an Ogg Vorbis from the page a like search finds, decoding
/// on to the frame. An MP3 goes to the frame its encoder's
/// table of contents points to, or the bit rate when it has none - exact
/// for a constant rate, near for a variable one - and the frame or two
/// after it may be left out, until the reservoir of bits they reach back
/// into is filled again. Frame 0 is exact for every kind: an MP3 starts
/// again where its encoder said the music begins (SINCE 1.3).
///
/// CONTEXT:
/// - Waits: yes, on the file.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a task will do: the one that has the stream - the one that
///   opened it, or one it was handed to (SINCE 1.3) - never two at once.
///
/// OWNERSHIP:
/// None.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DecodeAudio`, `GetAudioStreamInfo`
///
/// EXAMPLES:
/// ```zig
/// _ = acb.SeekAudio(stream, info.rate * 30); // half a minute in
/// ```
pub fn SeekAudio(_: *AudioCodecBase, public: *ac.AudioStream, frame: u32) i32 {
    const stream = _stream.streamOf(public);
    if (stream.info.seekable == 0) return ac.ACERR_NOSEEK;
    stream.pcm_start = 0;
    stream.pcm_stop = 0;
    return switch (stream.codec) {
        .wav => |*state| wav.seek(stream, state, frame),
        .mp3 => |*state| mp3.seek(stream, state, frame),
        .flac => |*state| flac.seek(stream, state, frame),
        .vorbis => |*state| vorbis.seek(stream, state, frame),
        .none => ac.ACERR_NOSEEK,
    };
}

// SPDX-License-Identifier: MIT
//! DecodeAudio: the next frames of a stream, as 16-bit samples.

const sdk = @import("sdk");
const ac = sdk.audiocodec;
const AudioCodecBase = @import("../audiocodec_base.zig").AudioCodecBase;
const _stream = @import("_stream.zig");
const wav = @import("../wav/_wav.zig");
const mp3 = @import("../mp3/_mp3.zig");

/// Decodes the next frames of a stream.
///
/// SYNOPSIS:
/// ```zig
/// fn DecodeAudio(base: *AudioCodecBase, stream: *ac.AudioStream, buffer: [*]i16, frames: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `stream`: an open stream.
/// - `buffer`: room for `frames` frames: a sample a channel, the channels
///   interleaved, left first.
/// - `frames`: how many frames are wanted.
///
/// RESULT:
/// How many frames went into `buffer`: `frames` until the end comes, then
/// fewer, then 0. Below 0 an ACERR_* - the source would not be read.
///
/// BEHAVIOR:
/// The samples are signed 16-bit, at the rate and channels
/// GetAudioStreamInfo gives, whatever the file holds: a WAV's samples
/// brought to 16 bits, an MP3's frames decoded one at a time and handed
/// out across calls. An MP3 is cut where its encoder said the music begins
/// and ends, so a song played after another follows it without a gap.
///
/// CONTEXT:
/// - Waits: yes, on the source when the read-ahead runs low.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the task that opened the stream.
///
/// OWNERSHIP:
/// `buffer` is the caller's.
///
/// NOTES:
/// An MP3 frame is 1152 frames of samples at 32 kHz and up, 576 below; a
/// buffer of a few thousand frames costs the fewest calls. Decoding an
/// MP3 takes about a tenth of a core at 44.1 kHz in stereo.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenAudioStream`, `SeekAudio`, `GetAudioStreamInfo`
///
/// EXAMPLES:
/// ```zig
/// var samples: [4096 * 2]i16 = undefined;
/// const got = acb.DecodeAudio(stream, &samples, 4096);
/// if (got <= 0) return; // the end, or an error
/// ```
pub fn DecodeAudio(_: *AudioCodecBase, public: *ac.AudioStream, buffer: [*]i16, frames: u32) i32 {
    const stream = _stream.streamOf(public);
    return switch (stream.codec) {
        .wav => |*state| wav.decode(stream, state, buffer, frames),
        .mp3 => |*state| mp3.decode(stream, state, buffer, frames),
        .none => 0,
    };
}

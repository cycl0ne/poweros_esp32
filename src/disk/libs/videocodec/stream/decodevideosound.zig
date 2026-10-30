// SPDX-License-Identifier: MIT
//! DecodeVideoSound: the next piece of a film's sound.

const sdk = @import("sdk");
const vc = sdk.videocodec;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _stream = @import("_stream.zig");

/// Hands out the film's sound as 16-bit samples, as DecodeAudio does.
///
/// SYNOPSIS:
/// ```zig
/// fn DecodeVideoSound(base: *VideoCodecBase, stream: *vc.VideoStream, buffer: [*]i16, frames: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `stream`: what OpenVideoStream made.
/// - `buffer`: room for `frames` frames: `frames` times the channels the
///   info gives, 16-bit samples, the channels interleaved.
/// - `frames`: how many frames are wanted.
///
/// RESULT:
/// How many frames it put there - as many as asked until the end - 0 at
/// the end of the sound, or below 0: VCERR_NOSOUND for a film without
/// sound, VCERR_CORRUPT, VCERR_READ, VCERR_NOMEMORY.
///
/// BEHAVIOR:
/// audiocodec.library's stream on the film's sound track decodes it: the
/// samples are those DecodeAudio hands out, at the rate and in the
/// channels GetVideoStreamInfo says, the encoder's priming left out, so
/// the first frame is the one at the start of what the film presents.
///
/// CONTEXT:
/// - Waits: yes, on the file.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process: the file is read.
///
/// OWNERSHIP:
/// `buffer` is the caller's. The sound is decoded by one task at a time,
/// which may be another than the one that decodes the pictures, at the
/// same time.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DecodeVideoFrame`, `SeekVideo`, audiocodec's `DecodeAudio`
///
/// EXAMPLES:
/// ```zig
/// var samples: [2048 * 2]i16 = undefined;
/// const got = vcb.DecodeVideoSound(film, &samples, 2048);
/// ```
pub fn DecodeVideoSound(_: *VideoCodecBase, stream: *vc.VideoStream, buffer: [*]i16, frames: u32) i32 {
    const s = _stream.of(stream);
    const sound = s.sound orelse return vc.VCERR_NOSOUND;
    s.sys.ObtainSemaphore(&s.sound_lock);
    defer s.sys.ReleaseSemaphore(&s.sound_lock);
    // audiocodec's errors are the library's, number for number.
    return s.acb.?.DecodeAudio(sound, buffer, frames);
}

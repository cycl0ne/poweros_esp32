// SPDX-License-Identifier: MIT
//! SeekVideo: a film moved to a key frame, its sound with it.

const sdk = @import("sdk");
const media = sdk.media;
const vc = sdk.videocodec;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _stream = @import("_stream.zig");
const chip = @import("../chip/_chip.zig");

/// Moves a film's pictures to the key frame at or before a time, and its
/// sound to that frame's time.
///
/// SYNOPSIS:
/// ```zig
/// fn SeekVideo(base: *VideoCodecBase, stream: *vc.VideoStream, time: i64) i64
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `stream`: what OpenVideoStream made.
/// - `time`: where to, in microseconds from the start of what the film
///   presents.
///
/// RESULT:
/// The time of the key frame it moved to, 0 or more; below 0 a VCERR_*:
/// VCERR_NOSEEK for a film read through VCA_ReadFunc, VCERR_READ,
/// VCERR_CORRUPT.
///
/// BEHAVIOR:
/// The picture track is moved to the key frame at or before `time` - the
/// first, before the first - where a decoder can start; the chip's
/// decoder drops what it was fed and not yet shown. The next frame
/// DecodeVideoFrame hands out is that key frame, `number` 0: frames due
/// before it are passed over. The sound is moved to the key frame's time,
/// so the next samples DecodeVideoSound hands out go with it.
///
/// CONTEXT:
/// - Waits: yes, on the file - and for a piece of sound being decoded by
///   another task to be done.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process: the file is read.
///
/// OWNERSHIP:
/// Called by the task that decodes the pictures. The frames lent stay
/// lent, and are given back as before.
///
/// NOTES:
/// A film's key frames are often seconds apart; a program that wants a
/// later frame decodes on to it, and shows from there.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DecodeVideoFrame`, `DecodeVideoSound`
///
/// EXAMPLES:
/// ```zig
/// const landed = vcb.SeekVideo(film, 60 * 1_000_000);
/// if (landed >= 0) clock.restartAt(landed);
/// ```
pub fn SeekVideo(_: *VideoCodecBase, stream: *vc.VideoStream, time: i64) i64 {
    const s = _stream.of(stream);
    if (s.file_info.seekable == 0) return vc.VCERR_NOSEEK;
    const moved = s.mb.SeekMedia(s.file, s.track, time);
    if (moved != media.MERR_OK) return _stream.fromMedia(moved);
    // The key packet read, to know where it landed: it is decoded first.
    s.peeked = false;
    var landed: i64 = 0;
    const read = s.mb.ReadMediaPacket(s.file, s.track, &s.packet);
    if (read == media.MERR_OK) {
        s.peeked = true;
        landed = @max(s.packet.pts, 0);
    } else if (read != media.MERR_END) {
        return _stream.fromMedia(read);
    }
    if (s.engine == .chip) chip.flush(s);
    s.shown_from = landed;
    s.number = 0;
    if (s.sound) |sound| {
        const rate: i64 = s.sound_info.rate;
        s.sys.ObtainSemaphore(&s.sound_lock);
        _ = s.acb.?.SeekAudio(sound, @intCast(@divTrunc(landed * rate, 1_000_000)));
        s.sys.ReleaseSemaphore(&s.sound_lock);
    }
    return landed;
}

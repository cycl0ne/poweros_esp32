// SPDX-License-Identifier: MIT
//! GetVideoTrack: a film's track, what decodes it and whether it is chosen.

const sdk = @import("sdk");
const media = sdk.media;
const vc = sdk.videocodec;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _stream = @import("_stream.zig");

/// Says what one of a film's tracks is, whether something here decodes
/// it, and whether it is the one being played or shown.
///
/// SYNOPSIS:
/// ```zig
/// fn GetVideoTrack(base: *VideoCodecBase, stream: *vc.VideoStream, number: u32, track: *media.MediaTrack) i32
/// ```
///
/// SINCE: 1.3. LVO -60.
///
/// INPUTS:
/// - `stream`: what OpenVideoStream made.
/// - `number`: the track, from 0, as media.library's GetMediaTrack
///   numbers them.
/// - `track`: where what it is goes.
///
/// RESULT:
/// 0 or more, its flags: `VTRK_DECODED` - the chip or the library
/// decodes its pictures, audiocodec.library its sound, the library its
/// subtitles - and `VTRK_CHOSEN` - its pictures are being decoded, its
/// sound is DecodeVideoSound's, its subtitles GetVideoSubtitle's; or
/// VCERR_END past the last track.
///
/// BEHAVIOR:
/// `track` is filled in as GetMediaTrack fills it: its kind, codec,
/// language and name. Of the pictures only the track being decoded is
/// VTRK_DECODED. A sound track is when the stream has audiocodec.library
/// - it was opened with sound, from a file - and the library's version
/// decodes its codec: AAC since 1.6, MP3, FLAC and Vorbis since 1.7,
/// AC-3 and E-AC-3 since 1.8. Subtitles are when they are SubRip's,
/// SubStation Alpha's, timed text or a Blu-ray's pictures (PGS), and the
/// stream was opened from a file.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// `track` is the caller's; the setup and name it points to are the
/// film's, good until the stream is closed.
///
/// NOTES:
/// A program lists the tracks from 0 until VCERR_END - for a menu of the
/// sound and the subtitles, by language and name.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SelectVideoTrack`, `GetVideoSubtitle`, media.library's `GetMediaTrack`
///
/// EXAMPLES:
/// ```zig
/// var number: u32 = 0;
/// var track: media.MediaTrack = .{};
/// while (true) : (number += 1) {
///     const flags = vcb.GetVideoTrack(film, number, &track);
///     if (flags < 0) break;
///     if (track.kind == media.MTRACK_AUDIO and flags & vc.VTRK_DECODED != 0) addSoundItem(number, &track);
/// }
/// ```
pub fn GetVideoTrack(_: *VideoCodecBase, stream: *vc.VideoStream, number: u32, track: *media.MediaTrack) i32 {
    const s = _stream.of(stream);
    if (s.mb.GetMediaTrack(s.file, number, track) != media.MERR_OK) return vc.VCERR_END;
    var flags: u32 = 0;
    if (_stream.decodes(s, number, track)) flags |= vc.VTRK_DECODED;
    if (number == s.track or number == s.sound_track or number == s.sub_track) flags |= vc.VTRK_CHOSEN;
    return @intCast(flags);
}

// SPDX-License-Identifier: MIT
//! SelectVideoTrack: another sound track, or other subtitles, while a
//! film plays.

const sdk = @import("sdk");
const media = sdk.media;
const ac = sdk.audiocodec;
const vc = sdk.videocodec;
const utility = sdk.utility;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _stream = @import("_stream.zig");
const subtitle = @import("../subtitle/_subtitle.zig");

/// Chooses another of a film's sound tracks, or its subtitles - or none.
///
/// SYNOPSIS:
/// ```zig
/// fn SelectVideoTrack(base: *VideoCodecBase, stream: *vc.VideoStream, track: u32, time: i64) i32
/// ```
///
/// SINCE: 1.3. LVO -64.
///
/// INPUTS:
/// - `stream`: what OpenVideoStream made.
/// - `track`: a sound or a text track, numbered as GetVideoTrack numbers
///   them - or `VIDEO_NO_TRACK`, the subtitles off.
/// - `time`: where the film is, in microseconds: the sound starts there,
///   and the subtitles are read from there.
///
/// RESULT:
/// VCERR_OK; or VCERR_NOCODEC for a track nothing here decodes,
/// VCERR_UNSUPPORTED for a track of pictures, VCERR_NOSOUND for sound on
/// a stream opened without it, VCERR_NOSEEK for a film read through
/// VCA_ReadFunc, VCERR_END for a track past the last, VCERR_NOMEMORY -
/// and what was chosen stays.
///
/// BEHAVIOR:
/// A sound track is opened with audiocodec.library on the film, moved to
/// `time`, and takes the place of the one DecodeVideoSound decoded, which
/// is closed: the next samples are the new track's, at its rate and in
/// its channels, which GetVideoStreamInfo then says. A text track is read
/// from `time` by the subtitles' process - started now if none was
/// chosen - and what GetVideoSubtitle hands out is from it. The track
/// already chosen is left as it is.
///
/// CONTEXT:
/// - Waits: yes, on the file - and for a piece of sound being decoded by
///   another task to be done.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process: the file is read.
///
/// OWNERSHIP:
/// Called by the task that decodes the pictures. A program that plays the
/// sound on a task of its own stops it first - the rate and the channels
/// may change - and starts it again after.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetVideoTrack`, `GetVideoSubtitle`, `DecodeVideoSound`, `VCA_SoundTrack`,
/// `VCA_Subtitles`
///
/// EXAMPLES:
/// ```zig
/// sound.stop();
/// if (vcb.SelectVideoTrack(film, chosen, clock.now()) == vc.VCERR_OK) {
///     vcb.GetVideoStreamInfo(film, &info);
/// }
/// sound.restart(&info);
/// ```
pub fn SelectVideoTrack(_: *VideoCodecBase, stream: *vc.VideoStream, track: u32, time: i64) i32 {
    const s = _stream.of(stream);
    const at = @max(time, 0);
    if (track == vc.VIDEO_NO_TRACK) {
        if (s.subtitles) |reader| subtitle.move(reader, vc.VIDEO_NO_TRACK, at);
        s.sub_track = vc.VIDEO_NO_TRACK;
        return vc.VCERR_OK;
    }
    var info: media.MediaTrack = .{};
    if (s.mb.GetMediaTrack(s.file, track, &info) != media.MERR_OK) return vc.VCERR_END;
    if (info.kind != media.MTRACK_AUDIO and info.kind != media.MTRACK_TEXT) return vc.VCERR_UNSUPPORTED;
    if (s.file_info.seekable == 0) return vc.VCERR_NOSEEK;
    if (info.kind == media.MTRACK_AUDIO) return sound(s, track, &info, at);
    if (!_stream.decodes(s, track, &info)) return vc.VCERR_NOCODEC;
    if (track == s.sub_track) return vc.VCERR_OK;
    if (s.subtitles) |reader| {
        subtitle.move(reader, track, at);
    } else {
        s.subtitles = _stream.startSubtitles(s, track, at, true) orelse return vc.VCERR_NOMEMORY;
    }
    s.sub_track = track;
    return vc.VCERR_OK;
}

/// Another sound track opened, moved to `at`, and put in the old one's
/// place.
fn sound(s: *_stream.Stream, track: u32, info: *const media.MediaTrack, at: i64) i32 {
    const acb = s.acb orelse return vc.VCERR_NOSOUND;
    if (!_stream.decodes(s, track, info)) return vc.VCERR_NOCODEC;
    if (track == s.sound_track and s.sound != null) return vc.VCERR_OK;
    var err: i32 = ac.ACERR_OK;
    const opened = acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_Media, .data = @intFromPtr(s.file) },
        .{ .tag = ac.ACA_MediaTrack, .data = track },
        .{},
    }, &err) orelse return if (err == ac.ACERR_NOMEMORY) vc.VCERR_NOMEMORY else vc.VCERR_NOCODEC;
    var opened_info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(opened, &opened_info);
    if (at > 0) _ = acb.SeekAudio(opened, @intCast(@divTrunc(at * opened_info.rate, 1_000_000)));
    s.sys.ObtainSemaphore(&s.sound_lock);
    const old = s.sound;
    s.sound = opened;
    s.sound_info = opened_info;
    s.sound_track = track;
    s.sys.ReleaseSemaphore(&s.sound_lock);
    if (old) |closing| acb.CloseAudioStream(closing);
    return vc.VCERR_OK;
}

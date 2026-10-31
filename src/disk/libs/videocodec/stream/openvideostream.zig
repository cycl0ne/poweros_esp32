// SPDX-License-Identifier: MIT
//! OpenVideoStream: a film opened, a decoder found for its pictures and
//! its sound, and its subtitles read.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const media = sdk.media;
const ac = sdk.audiocodec;
const vc = sdk.videocodec;
const utility = sdk.utility;
const MediaBase = sdk.interface.media.MediaBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _stream = @import("_stream.zig");
const Stream = _stream.Stream;
const _codec = @import("../codec/_codec.zig");

/// Opens a film and finds a decoder for its pictures and one for its
/// sound - and reads its subtitles.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenVideoStream(base: *VideoCodecBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*vc.VideoStream
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `tags`: where the bytes come from - one of `VCA_Name` (a file to
///   open), `VCA_FileHandle` (a file the program has open, the film
///   beginning where it is) or `VCA_ReadFunc` with `VCA_ReadData` (a
///   function of the program's) - and `VCA_Sound` FALSE for the pictures
///   alone; `VCA_SoundTrack` and `VCA_Subtitles` choose the tracks
///   (SINCE 1.3).
/// - `err`: where why it failed goes (VCERR_*), or null.
///
/// RESULT:
/// The stream, or null - and `err` says why: VCERR_OPEN without a source,
/// when the file would not open or media.library could not be;
/// VCERR_UNKNOWN for bytes that are not a container media.library knows,
/// or a film with no pictures; VCERR_NOCODEC when no codec module
/// decodes its pictures here; VCERR_BUSY when the chip's decoders are all
/// in use and no other module takes them;
/// VCERR_UNSUPPORTED, VCERR_READ, VCERR_CORRUPT, VCERR_NOMEMORY.
///
/// BEHAVIOR:
/// The film is opened with media.library, which finds out what it is and
/// reads its index - an MP4's, a Matroska file's header (SINCE 1.2). Its
/// first track of pictures - of a Matroska file the first it marks to be
/// played - is taken, and a decoder for it found among the codec modules
/// in LIBS:codecs/ whose tags name its codec (SINCE 1.4): a chip's before
/// software, the higher priority first; the first that opens a decoder
/// for the track decodes it - chip.vcodec H.264 and H.265 on the chip
/// (videodec.resource), reading the track's parameter sets; mjpeg.vcodec
/// Motion JPEG. Its first track of sound - in a Matroska file the
/// marked one, or `VCA_SoundTrack`'s - is opened with audiocodec.library
/// 1.6 or later, on the same file (`ACA_Media`) - AAC, with 1.7 MP3, FLAC
/// and Vorbis, with 1.8 AC-3 and E-AC-3 - unless `VCA_Sound` is FALSE or
/// the film is read through a function. A sound track nothing decodes
/// leaves the film without sound - `sound_codec` 0 in the info - rather
/// than unopened. The subtitles the film marks to be shown - in a
/// Matroska file the track marked forced and default, else default
/// (media.library 1.3's `MDA_Subtitles`) - or `VCA_Subtitles`' are read
/// from the start by a process of the library's, for GetVideoSubtitle
/// (SINCE 1.3); none from a film read through a function. The first frame
/// and the first samples are those at the start of what the film
/// presents.
///
/// CONTEXT:
/// - Waits: yes, on the file, LIBS:codecs/ and the chip.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process: the file and the modules' tags are read, a
///   module is loaded, and the chip's decoder reads its firmware's file.
///
/// OWNERSHIP:
/// The stream is the caller's, given back with `CloseVideoStream`. A file
/// opened with VCA_Name is closed with it; a handle given with
/// VCA_FileHandle stays the program's, and must stay open until then.
///
/// NOTES:
/// It takes the film's index in memory (media.library's), the chip's
/// stream buffer of 2 MiB or four of the largest packets - 8 MiB for a
/// Matroska file, which says not its largest - and audiocodec's stream;
/// Motion JPEG takes a frame's planes for each frame lent. A module's tag
/// is read again only when its file changed; a module newer on the disk
/// than in memory is loaded anew once no film has the old one. media.library
/// reads a Matroska file's tracks ahead, 256 KiB at a time each.
/// Subtitles take about 12 KiB, a process with a stack of 32 KiB, and
/// what they read ahead: up to ten seconds of lines, or a picture.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseVideoStream`, `GetVideoStreamInfo`, `DecodeVideoFrame`,
/// `DecodeVideoSound`, `IdentifyVideo`, `GetVideoTrack`
///
/// EXAMPLES:
/// ```zig
/// var err: i32 = 0;
/// const film = vcb.OpenVideoStream(&[_]utility.TagItem{
///     .{ .tag = vc.VCA_Name, .data = @intFromPtr("SD0:Films/trip.mp4") },
///     .{},
/// }, &err) orelse {
///     _ = Printf(dl, "%s\n", .{vcb.VideoErrorText(err)});
///     return;
/// };
/// defer vcb.CloseVideoStream(film);
/// ```
pub fn OpenVideoStream(base: *VideoCodecBase, tags: ?[*]const utility.TagItem, err: ?*i32) ?*vc.VideoStream {
    var code: i32 = vc.VCERR_OK;
    const stream = open(base, tags, &code);
    if (err) |out| out.* = code;
    return stream;
}

fn open(base: *VideoCodecBase, tags: ?[*]const utility.TagItem, code: *i32) ?*vc.VideoStream {
    const sys = base.sys_base;
    const ub = base.utility_base;
    const name = ub.GetTagData(vc.VCA_Name, 0, tags);
    const handle = ub.GetTagData(vc.VCA_FileHandle, 0, tags);
    const read_fn = ub.GetTagData(vc.VCA_ReadFunc, 0, tags);
    const read_data = ub.GetTagData(vc.VCA_ReadData, 0, tags);
    const want_sound = ub.GetTagData(vc.VCA_Sound, 1, tags) != 0;

    const source: utility.TagItem = if (name != 0)
        .{ .tag = media.MDA_Name, .data = name }
    else if (handle != 0)
        .{ .tag = media.MDA_FileHandle, .data = handle }
    else if (read_fn != 0)
        .{ .tag = media.MDA_ReadFunc, .data = read_fn }
    else {
        code.* = vc.VCERR_OPEN;
        return null;
    };
    const media_lib = sys.OpenLibrary(media.MEDIANAME, 1) orelse {
        code.* = vc.VCERR_OPEN;
        return null;
    };
    const mb: *MediaBase = @ptrCast(media_lib);
    var merr: i32 = media.MERR_OK;
    const file = mb.OpenMedia(&[_]utility.TagItem{
        source,
        .{ .tag = media.MDA_ReadData, .data = read_data },
        .{},
    }, &merr) orelse {
        sys.CloseLibrary(media_lib);
        code.* = _stream.fromMedia(merr);
        return null;
    };
    var file_info: media.MediaInfo = .{};
    mb.GetMediaInfo(file, &file_info);
    var picture: media.MediaTrack = .{};
    if (file_info.video == ~@as(u32, 0) or mb.GetMediaTrack(file, file_info.video, &picture) != media.MERR_OK) {
        mb.CloseMedia(file);
        sys.CloseLibrary(media_lib);
        code.* = vc.VCERR_UNKNOWN;
        return null;
    }

    // Cleared: every field of a stream starts at zero.
    const memory = sys.AllocVec(@sizeOf(Stream), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        mb.CloseMedia(file);
        sys.CloseLibrary(media_lib);
        code.* = vc.VCERR_NOMEMORY;
        return null;
    };
    const s: *Stream = @ptrCast(@alignCast(memory));
    s.base = base;
    s.sys = sys;
    s.media_lib = media_lib;
    s.mb = mb;
    s.file = file;
    s.file_info = file_info;
    s.track = file_info.video;
    s.picture = picture;
    s.codec = _stream.codecOf(picture.codec);
    sys.InitSemaphore(&s.sound_lock);

    const opened = _codec.open(s);
    if (opened != vc.VCERR_OK) {
        _stream.destroy(s);
        code.* = opened;
        return null;
    }
    s.sound_track = vc.VIDEO_NO_TRACK;
    s.sub_track = vc.VIDEO_NO_TRACK;
    const sound_track: u32 = @truncate(ub.GetTagData(vc.VCA_SoundTrack, file_info.audio, tags));
    if (want_sound and read_fn == 0) openSound(s, sound_track);

    // The subtitles the film marks; media.library before 1.3 says none.
    var marked: u32 = vc.VIDEO_NO_TRACK;
    _ = mb.GetMediaAttrs(file, &[_]utility.TagItem{
        .{ .tag = media.MDA_Subtitles, .data = @intFromPtr(&marked) },
        .{},
    });
    const sub_track: u32 = @truncate(ub.GetTagData(vc.VCA_Subtitles, marked, tags));
    var sub_info: media.MediaTrack = .{};
    if (sub_track != vc.VIDEO_NO_TRACK and mb.GetMediaTrack(file, sub_track, &sub_info) == media.MERR_OK and
        sub_info.kind == media.MTRACK_TEXT and _stream.decodes(s, sub_track, &sub_info))
    {
        s.subtitles = _stream.startSubtitles(s, sub_track, 0, false);
        if (s.subtitles != null) s.sub_track = sub_track;
    }
    return _stream.publicOf(s);
}

/// audiocodec.library opened for the film - 1.6 or later, which decodes
/// a track of a film - and kept, for SelectVideoTrack; then sound track
/// `track` opened with it on the same file. Without the library, or with
/// a track that is not sound or that it does not decode, the film has no
/// sound.
fn openSound(s: *Stream, track: u32) void {
    const lib = s.sys.OpenLibrary(ac.AUDIOCODECNAME, 1) orelse return;
    if (lib.version == 1 and lib.revision < 6) {
        s.sys.CloseLibrary(lib);
        return;
    }
    const acb: *AudioCodecBase = @ptrCast(lib);
    s.sound_lib = lib;
    s.acb = acb;
    var info: media.MediaTrack = .{};
    if (track == vc.VIDEO_NO_TRACK or s.mb.GetMediaTrack(s.file, track, &info) != media.MERR_OK or info.kind != media.MTRACK_AUDIO) return;
    var err: i32 = ac.ACERR_OK;
    const sound = acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_Media, .data = @intFromPtr(s.file) },
        .{ .tag = ac.ACA_MediaTrack, .data = track },
        .{},
    }, &err) orelse return;
    s.sound = sound;
    s.sound_track = track;
    acb.GetAudioStreamInfo(sound, &s.sound_info);
}

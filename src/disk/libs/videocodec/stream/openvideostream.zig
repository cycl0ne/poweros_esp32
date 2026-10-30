// SPDX-License-Identifier: MIT
//! OpenVideoStream: a film opened, a decoder found for its pictures and
//! its sound.

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
const chip = @import("../chip/_chip.zig");
const mjpeg = @import("../mjpeg/_mjpeg.zig");

/// Opens a film and finds a decoder for its pictures and one for its
/// sound.
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
///   alone.
/// - `err`: where why it failed goes (VCERR_*), or null.
///
/// RESULT:
/// The stream, or null - and `err` says why: VCERR_OPEN without a source,
/// when the file would not open or media.library could not be;
/// VCERR_UNKNOWN for bytes that are not a container media.library knows,
/// or a film with no pictures; VCERR_NOCODEC when nothing here decodes
/// its pictures; VCERR_BUSY when the chip's decoders are all in use;
/// VCERR_UNSUPPORTED, VCERR_READ, VCERR_CORRUPT, VCERR_NOMEMORY.
///
/// BEHAVIOR:
/// The film is opened with media.library, which finds out what it is and
/// reads its index. Its first track of pictures is taken: H.264 and H.265
/// go to the chip's decoder (videodec.resource), which is opened for the
/// stream and reads the track's parameter sets; Motion JPEG to the
/// library's own. Its first track of sound is opened with
/// audiocodec.library 1.6 or later, on the same file (`ACA_Media`), unless
/// `VCA_Sound` is FALSE or the film is read through a function. A sound
/// track nothing decodes leaves the film without sound - `sound_codec` 0
/// in the info - rather than unopened. The first frame and the first
/// samples are those at the start of what the film presents.
///
/// CONTEXT:
/// - Waits: yes, on the file and the chip.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process: the file is read, and the chip's decoder reads
///   its firmware's file.
///
/// OWNERSHIP:
/// The stream is the caller's, given back with `CloseVideoStream`. A file
/// opened with VCA_Name is closed with it; a handle given with
/// VCA_FileHandle stays the program's, and must stay open until then.
///
/// NOTES:
/// It takes the film's index in memory (media.library's), the chip's
/// stream buffer of 2 MiB or four of the largest packets, and audiocodec's
/// stream; Motion JPEG takes a frame's planes for each frame lent.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseVideoStream`, `GetVideoStreamInfo`, `DecodeVideoFrame`,
/// `DecodeVideoSound`, `IdentifyVideo`
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
    s.engine = .{ .mjpeg = .{} };
    sys.InitSemaphore(&s.sound_lock);

    const opened = switch (s.codec) {
        vc.VCODEC_H264, vc.VCODEC_H265 => chip.open(s),
        vc.VCODEC_MJPEG => mjpeg.open(s),
        else => vc.VCERR_NOCODEC,
    };
    if (opened != vc.VCERR_OK) {
        _stream.destroy(s);
        code.* = opened;
        return null;
    }
    if (want_sound and read_fn == 0 and file_info.audio != ~@as(u32, 0)) openSound(s);
    return _stream.publicOf(s);
}

/// The film's sound track opened with audiocodec.library on the same
/// file - 1.6 or later, which decodes a track of a film. Without it, or
/// with a track it does not decode, the film has no sound.
fn openSound(s: *Stream) void {
    const lib = s.sys.OpenLibrary(ac.AUDIOCODECNAME, 1) orelse return;
    if (lib.version == 1 and lib.revision < 6) {
        s.sys.CloseLibrary(lib);
        return;
    }
    const acb: *AudioCodecBase = @ptrCast(lib);
    var err: i32 = ac.ACERR_OK;
    const sound = acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_Media, .data = @intFromPtr(s.file) },
        .{ .tag = ac.ACA_MediaTrack, .data = s.file_info.audio },
        .{},
    }, &err) orelse {
        s.sys.CloseLibrary(lib);
        return;
    };
    s.sound_lib = lib;
    s.acb = acb;
    s.sound = sound;
    acb.GetAudioStreamInfo(sound, &s.sound_info);
}

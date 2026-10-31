// SPDX-License-Identifier: MIT
//! A stream opened: the film media.library has open, its picture track
//! and the decoder for it, the frames lent out, and the sound - an
//! audiocodec.library stream on the same file.
//!
//! **The pictures** are decoded by a codec module from LIBS:codecs/
//! (`codec/`: the chip's, chip.vcodec, or software), which is sent the
//! track's packets read through `nextPacket` - which hands out first the
//! packet a seek read to find where it landed. A frame lent out has a slot
//! of the `VIDEO_HELD_FRAMES`; its number is in the frame's `private`,
//! which ReleaseVideoFrame reads back.
//!
//! **The sound** is decoded by whichever task calls DecodeVideoSound
//! while the pictures are decoded by another; `sound_lock` keeps a seek
//! from moving the sound while a piece of it is being decoded.
//!
//! **The subtitles** (SINCE 1.3) are read by a reader of their own
//! (`subtitle/`), on a process, once a text track is chosen.
//!
//! The stream is one allocation, cleared; the decoder's memory is its
//! module's, given back with it.

const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const ac = sdk.audiocodec;
const vc = sdk.videocodec;
const ExecBase = sdk.interface.exec.ExecBase;
const MediaBase = sdk.interface.media.MediaBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _codec = @import("../codec/_codec.zig");
const subtitle = @import("../subtitle/_subtitle.zig");

pub const held_frames = vc.VIDEO_HELD_FRAMES;

/// What a frame's `private[1]` holds, so a frame that is not one of the
/// stream's is passed by.
pub const frame_mark: u32 = 0x5644_4652; // "VDFR"

pub const Stream = struct {
    base: *VideoCodecBase,
    sys: *ExecBase,
    media_lib: *exec.Library,
    mb: *MediaBase,
    file: *media.MediaFile,
    file_info: media.MediaInfo,
    /// The picture track: its number, what it is, its codec (VCODEC_*).
    track: u32,
    picture: media.MediaTrack,
    codec: u32,
    decoder: _codec.Decoder,
    /// A packet read and not yet decoded: the key packet a seek read.
    peeked: bool,
    packet: media.MediaPacket,
    /// Frames due before it are passed over: 0 from the start - a film's
    /// pictures before what it presents - and the key frame's time after
    /// a seek.
    shown_from: i64,
    /// Frames handed out since the stream was opened or moved.
    number: u32,
    /// Which slots hold a frame lent out.
    held: [held_frames]bool,
    /// The sound, when there is one: audiocodec.library opened for it,
    /// the stream on the file's sound track, and what it is.
    sound_lib: ?*exec.Library,
    acb: ?*AudioCodecBase,
    sound: ?*ac.AudioStream,
    sound_info: ac.AudioStreamInfo,
    sound_lock: exec.SignalSemaphore,
    /// The tracks chosen: the sound's, the subtitles' - VIDEO_NO_TRACK for
    /// none - and the reader of the subtitles, once there have been any.
    sound_track: u32,
    sub_track: u32,
    subtitles: ?*subtitle.Reader,
};

pub fn of(stream: *vc.VideoStream) *Stream {
    return @ptrCast(@alignCast(stream));
}

pub fn publicOf(s: *Stream) *vc.VideoStream {
    return @ptrCast(s);
}

/// The track's next packet: the one a seek read first, if there is one.
/// 0, or an MERR_*.
pub fn nextPacket(s: *Stream, packet: *media.MediaPacket) i32 {
    if (s.peeked) {
        s.peeked = false;
        packet.* = s.packet;
        return media.MERR_OK;
    }
    return s.mb.ReadMediaPacket(s.file, s.track, packet);
}

/// A slot no frame lent out holds.
pub fn freeSlot(s: *const Stream) ?u32 {
    for (s.held, 0..) |taken, slot| {
        if (!taken) return @intCast(slot);
    }
    return null;
}

/// The slot a frame was handed out in; null for one that is not the
/// stream's, or was given back.
pub fn slotOf(s: *const Stream, frame: *const vc.VideoFrame) ?u32 {
    if (frame.private[1] != frame_mark) return null;
    const slot = frame.private[0];
    if (slot == 0 or slot > held_frames or !s.held[slot - 1]) return null;
    return slot - 1;
}

/// A media.library error as the library's.
pub fn fromMedia(code: i32) i32 {
    return switch (code) {
        media.MERR_OK => vc.VCERR_OK,
        media.MERR_NOMEMORY => vc.VCERR_NOMEMORY,
        media.MERR_OPEN => vc.VCERR_OPEN,
        media.MERR_UNKNOWN, media.MERR_NOTRACK => vc.VCERR_UNKNOWN,
        media.MERR_UNSUPPORTED => vc.VCERR_UNSUPPORTED,
        media.MERR_READ => vc.VCERR_READ,
        media.MERR_NOSEEK => vc.VCERR_NOSEEK,
        media.MERR_END => vc.VCERR_END,
        else => vc.VCERR_CORRUPT,
    };
}

/// The pictures' codec, by the container's.
pub fn codecOf(codec: u32) u32 {
    return switch (codec) {
        media.MCODEC_H264 => vc.VCODEC_H264,
        media.MCODEC_H265 => vc.VCODEC_H265,
        media.MCODEC_MJPEG => vc.VCODEC_MJPEG,
        media.MCODEC_MPEG4V => vc.VCODEC_MPEG4V,
        else => vc.VCODEC_UNKNOWN,
    };
}

/// Whether something here decodes track `number`: the pictures being
/// decoded; sound audiocodec.library's version takes, when the stream has
/// it; subtitles of a kind the reader knows, from a file.
pub fn decodes(s: *const Stream, number: u32, track: *const media.MediaTrack) bool {
    return switch (track.kind) {
        media.MTRACK_VIDEO => number == s.track,
        media.MTRACK_AUDIO => soundDecodes(s, track.codec),
        media.MTRACK_TEXT => s.file_info.seekable != 0 and switch (track.codec) {
            media.MCODEC_SRT, media.MCODEC_ASS, media.MCODEC_TEXT, media.MCODEC_PGS => true,
            else => false,
        },
        else => false,
    };
}

/// Whether the stream's audiocodec.library decodes `codec`: AAC since
/// 1.6, MP3, FLAC and Vorbis since 1.7, AC-3 and E-AC-3 since 1.8.
fn soundDecodes(s: *const Stream, codec: u32) bool {
    const lib = s.sound_lib orelse return false;
    const since: u16 = switch (codec) {
        media.MCODEC_AAC => 6,
        media.MCODEC_MP3, media.MCODEC_FLAC, media.MCODEC_VORBIS => 7,
        media.MCODEC_AC3, media.MCODEC_EAC3 => 8,
        else => return false,
    };
    return lib.version > 1 or lib.revision >= since;
}

/// A reader of the subtitles on `track`, from `time`.
pub fn startSubtitles(s: *Stream, track: u32, time: i64, seek: bool) ?*subtitle.Reader {
    return subtitle.create(s.sys, s.base.dos_base, s.mb, s.file, &s.picture, track, time, seek);
}

/// Everything the stream holds given back: the subtitles' reader, the
/// sound, the decoder with the frames still lent, the film, the
/// libraries, the stream.
pub fn destroy(s: *Stream) void {
    const sys = s.sys;
    if (s.subtitles) |reader| subtitle.destroy(reader);
    if (s.sound) |sound| s.acb.?.CloseAudioStream(sound);
    if (s.sound_lib) |lib| sys.CloseLibrary(lib);
    _codec.close(s);
    s.mb.CloseMedia(s.file);
    sys.CloseLibrary(s.media_lib);
    sys.FreeVec(s);
}

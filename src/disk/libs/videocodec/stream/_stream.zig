// SPDX-License-Identifier: MIT
//! A stream opened: the film media.library has open, its picture track
//! and the decoder for it, the frames lent out, and the sound - an
//! audiocodec.library stream on the same file.
//!
//! **The pictures** are decoded by an engine: the chip's (`chip/`) or the
//! library's own Motion JPEG decoder (`mjpeg/`). Each takes the track's
//! packets through `nextPacket`, which hands out first the packet a seek
//! read to find where it landed. A frame lent out has a slot of the
//! `VIDEO_HELD_FRAMES`; its number is in the frame's `private`, which
//! ReleaseVideoFrame reads back.
//!
//! **The sound** is decoded by whichever task calls DecodeVideoSound
//! while the pictures are decoded by another; `sound_lock` keeps a seek
//! from moving the sound while a piece of it is being decoded.
//!
//! The stream is one allocation, cleared; the engines' buffers are memory
//! of their own, given back with it.

const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const ac = sdk.audiocodec;
const vc = sdk.videocodec;
const ExecBase = sdk.interface.exec.ExecBase;
const MediaBase = sdk.interface.media.MediaBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const chip = @import("../chip/_chip.zig");
const mjpeg = @import("../mjpeg/_mjpeg.zig");

pub const held_frames = vc.VIDEO_HELD_FRAMES;

/// What a frame's `private[1]` holds, so a frame that is not one of the
/// stream's is passed by.
pub const frame_mark: u32 = 0x5644_4652; // "VDFR"

/// The decoder of the pictures.
pub const Engine = union(enum) {
    chip: chip.Chip,
    mjpeg: mjpeg.Mjpeg,
};

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
    engine: Engine,
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

/// Everything the stream holds given back: the sound, the decoder with
/// the frames still lent, the film, the libraries, the stream.
pub fn destroy(s: *Stream) void {
    const sys = s.sys;
    if (s.sound) |sound| s.acb.?.CloseAudioStream(sound);
    if (s.sound_lib) |lib| sys.CloseLibrary(lib);
    switch (s.engine) {
        .chip => chip.close(s),
        .mjpeg => mjpeg.close(s),
    }
    s.mb.CloseMedia(s.file);
    sys.CloseLibrary(s.media_lib);
    sys.FreeVec(s);
}

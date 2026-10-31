//! videocodec.library's structures and constants: the stream a program
//! plays a film from, the tags it is opened with, what it is, the frames
//! it hands out, and the error codes. The calls are in
//! `sdk.interface.videocodec`.
//!
//! A program opens a stream on a film - a file by its name, a file it has
//! open, or bytes a function of its own hands over - and the library
//! opens it with media.library, takes its first track of pictures and
//! its first of sound, and finds a decoder for each: a codec module in
//! LIBS:codecs/ for the pictures (SINCE 1.4; `sdk.vcodec`) - chip.vcodec
//! H.264 and H.265 on the chip (videodec.resource, where the board has
//! one), h264.vcodec H.264, vp8.vcodec VP8 and mjpeg.vcodec Motion JPEG
//! in software - and audiocodec.library for the sound. `GetVideoStreamInfo`
//! says what the film is: the pictures' codec, size and rate, how long it
//! lasts, and the sound's rate and channels.
//!
//! **The pictures**: `DecodeVideoFrame` hands out the next frame in the
//! order frames are shown, with the time it is due. A frame is the
//! decoder's own memory - no copy is made - and is lent until
//! `ReleaseVideoFrame` gives it back; up to `VIDEO_HELD_FRAMES` are lent
//! at once. Its `picture` is an `rtg.RtgYuv`, which graphics'
//! `WriteYUVPixelArray` and `ScaleYUVPixelArray` put into a window as it
//! is.
//!
//! **The sound**: `DecodeVideoSound` hands out the sound track as
//! `DecodeAudio` does - 16-bit samples, the channels interleaved - for
//! audio.device as they are. The pictures and the sound may each be
//! decoded by a task of its own at the same time, as a player does it:
//! the sound on a process that keeps audio.device fed, the pictures where
//! they are shown. Each half is used by one task at a time.
//!
//! **Times** are in microseconds from the start of what the film
//! presents. `SeekVideo` moves both halves to the key frame at or before
//! a time - where a decoder can start - and says where that is; the sound
//! goes to the same time, so they stay together.
//!
//! **Tracks** (SINCE 1.3): a film may hold several sound tracks - other
//! languages, a commentary - and subtitles. `GetVideoTrack` lists them,
//! with what decodes each and which are chosen; `VCA_SoundTrack` and
//! `VCA_Subtitles` choose at the start - by default the ones the film
//! marks - and `SelectVideoTrack` while it plays. `GetVideoSubtitle`
//! says what is shown at a time: SubRip's and SubStation Alpha's text -
//! its dialogue; signs placed on the picture and drawings are left out -
//! or a Blu-ray's pictures (PGS). The subtitles are read ahead by a
//! process of the library's, so asking never waits on the file.
//!
//! The tags a film carries - its title, a cover, the chapters - are
//! media.library's, and `GetVideoStreamAttrs` answers its `MDA_*` tags.

const utility = @import("../utility/utility.zig");
const rtg = @import("../rtg/rtg.zig");

pub const VIDEOCODECNAME = "videocodec.library";

/// A film being played: the library's own, opened by OpenVideoStream and
/// given back with CloseVideoStream.
pub const VideoStream = opaque {};

// --- the codecs -------------------------------------------------------------------

/// Not a codec the library knows, or no pictures.
pub const VCODEC_UNKNOWN: u32 = 0;
/// H.264 (AVC) and H.265 (HEVC): chip.vcodec, the chip's decoder through
/// videodec.resource.
pub const VCODEC_H264: u32 = 1;
pub const VCODEC_H265: u32 = 2;
/// Motion JPEG - each frame a JPEG picture whole - decoded in software
/// by mjpeg.vcodec: baseline pictures, grey or with their colour at full
/// size or halved.
pub const VCODEC_MJPEG: u32 = 3;
/// MPEG-4 Part 2 video: known, and nothing decodes it.
pub const VCODEC_MPEG4V: u32 = 4;
/// VP8 (SINCE 1.5): vp8.vcodec, in software.
pub const VCODEC_VP8: u32 = 5;
/// VP9 and AV1 (SINCE 1.5): known, and nothing decodes them yet.
pub const VCODEC_VP9: u32 = 6;
pub const VCODEC_AV1: u32 = 7;

/// How many bytes `IdentifyVideo` is best given: an MP4 says what its
/// pictures are in its index, which is often within them, at the front;
/// a Matroska file in its tracks, which are.
pub const VIDEO_IDENTIFY_BYTES: u32 = 64 * 1024;

/// How many frames a program may hold at once, handed out and not yet
/// released: one on the screen, one waiting its turn, one more.
pub const VIDEO_HELD_FRAMES: u32 = 3;

// --- OpenVideoStream's tags -------------------------------------------------------

pub const VCA_Dummy = utility.TAG_USER + 0x60D00;
/// `[*:0]const u8`: a file to open and read; closed with the stream.
pub const VCA_Name = VCA_Dummy + 0x01;
/// `*FileHandle`: a file the program has open, read from where it is. Not
/// closed with the stream.
pub const VCA_FileHandle = VCA_Dummy + 0x02;
/// `ReadFn`: a function of the program's that hands the bytes over, for
/// a film that is not a file. Such a film is read once, front to back:
/// it cannot seek, its index must come before its packets, and only its
/// pictures are decoded - its sound lies among them and is passed by.
pub const VCA_ReadFunc = VCA_Dummy + 0x03;
/// What `VCA_ReadFunc` is given each time.
pub const VCA_ReadData = VCA_Dummy + 0x04;
/// Bool: the sound track is opened too, for `DecodeVideoSound`. TRUE by
/// default; FALSE for the pictures alone.
pub const VCA_Sound = VCA_Dummy + 0x05;
/// `u32`: the sound track to play, numbered as media.library's
/// `GetMediaTrack` numbers the film's tracks - by default the one the
/// film marks to be played. One that is not sound, or that nothing here
/// decodes, leaves the film without sound (SINCE 1.3).
pub const VCA_SoundTrack = VCA_Dummy + 0x06;
/// `u32`: the subtitles `GetVideoSubtitle` hands out - a text track,
/// numbered so - or `VIDEO_NO_TRACK` for none. By default the track the
/// film marks to be shown (media.library's `MDA_Subtitles`), else none
/// (SINCE 1.3).
pub const VCA_Subtitles = VCA_Dummy + 0x07;

/// No track: `VCA_Subtitles` and `SelectVideoTrack` for subtitles off.
pub const VIDEO_NO_TRACK: u32 = 0xFFFF_FFFF;

/// Up to `length` bytes into `buffer`: how many it put there, 0 at the
/// end, below 0 when it cannot read. Fewer than asked are fine. As
/// media.library's.
pub const ReadFn = *const fn (data: ?*anyopaque, buffer: [*]u8, length: u32) callconv(.c) i32;

// --- what a film is ---------------------------------------------------------------

/// What GetVideoStreamInfo fills in.
pub const VideoStreamInfo = extern struct {
    /// The pictures: VCODEC_*, their size in pixels as shown, how many a
    /// second as `rate_num` / `rate_den` (both 0 when the film does not
    /// say).
    codec: u32 = VCODEC_UNKNOWN,
    width: u32 = 0,
    height: u32 = 0,
    rate_num: u32 = 0,
    rate_den: u32 = 0,
    /// How long it lasts, in microseconds; 0 when not known.
    duration: u64 align(4) = 0,
    /// How many pictures it has; 0 when not known.
    frames: u32 = 0,
    /// Whether SeekVideo can move it: a file, read where it lies.
    seekable: u32 = 0,
    /// The sound: audiocodec's ACODEC_* - ACODEC_UNKNOWN (0) when the
    /// film has none, it was not asked for, or nothing decodes it - its
    /// frames a second and its channels, as DecodeVideoSound hands it out.
    sound_codec: u32 = 0,
    sound_rate: u32 = 0,
    sound_channels: u32 = 0,
    /// What its tags name it, NUL-terminated, cut at 63 characters; empty
    /// when it has none.
    title: [64]u8 = @splat(0),
};

/// A frame DecodeVideoFrame handed out.
pub const VideoFrame = extern struct {
    /// Its planes, their pitches, their layout and how their numbers
    /// stand for colours: for graphics' WriteYUVPixelArray and
    /// ScaleYUVPixelArray as it is, and for rtg's ShowVideoFrame - since
    /// 1.1 every frame is where a display's video layer reads it, with
    /// nothing of it left in the caches. The decoder's memory, lent until
    /// ReleaseVideoFrame.
    picture: rtg.RtgYuv = .{ .y = undefined, .cb = undefined, .y_pitch = 0, .c_pitch = 0 },
    /// The picture as it is shown, in pixels.
    width: u32 = 0,
    height: u32 = 0,
    /// When it is due, in microseconds from the start of what the film
    /// presents.
    time: i64 align(4) = 0,
    /// Its place among the frames handed out since the stream was opened
    /// or last moved, from 0.
    number: u32 = 0,
    /// The library's, for ReleaseVideoFrame.
    private: [3]u32 = @splat(0),
};

// --- the tracks and the subtitles (SINCE 1.3) ------------------------------------

/// What `GetVideoTrack` says of a track: something here decodes it - the
/// chip or the library its pictures, audiocodec.library its sound, the
/// library its subtitles - and it is the one being played or shown.
pub const VTRK_DECODED: u32 = 1 << 0;
pub const VTRK_CHOSEN: u32 = 1 << 1;

/// What a `VideoSubtitle` holds: lines of text, or a picture - and the
/// text is in italics.
pub const VSUB_TEXT: u32 = 1 << 0;
pub const VSUB_BITMAP: u32 = 1 << 1;
pub const VSUB_ITALIC: u32 = 1 << 2;

/// What GetVideoSubtitle fills in: the subtitle shown at a time.
pub const VideoSubtitle = extern struct {
    /// VSUB_TEXT or VSUB_BITMAP, and VSUB_ITALIC.
    flags: u32 = 0,
    /// When it is shown from, and up to, in microseconds as frames' times
    /// are: while both are the same, so is what it shows. `end` is
    /// `maxInt(i64)` while the track has not said - a picture shows until
    /// the next.
    start: i64 align(4) = 0,
    end: i64 align(4) = 0,
    /// The text: UTF-8, NUL-terminated, its lines apart by `\n`; the
    /// codes of SubStation Alpha and SubRip's tags taken out.
    text: ?[*:0]const u8 = null,
    /// The picture: `width` by `height` pixels, each a `u32` 0xAARRGGBB,
    /// row after row - its alpha 0 where nothing is drawn - to be laid at
    /// (`x`, `y`) of the frame, in the picture's pixels.
    pixels: ?[*]const u32 = null,
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// The library's.
    private: [2]u32 = @splat(0),
};

// --- errors -----------------------------------------------------------------------

pub const VCERR_OK: i32 = 0;
/// No memory for the stream, its decoder or its frames.
pub const VCERR_NOMEMORY: i32 = -1;
/// The file could not be opened, or no source was given; media.library
/// could not be opened.
pub const VCERR_OPEN: i32 = -2;
/// Not a container media.library knows, or one with no pictures.
pub const VCERR_UNKNOWN: i32 = -3;
/// A container it knows, in a form it does not read - an MP4 in
/// fragments, one whose index lies behind its packets read through a
/// function - or pictures the decoder does not take: 10-bit H.264, too large,
/// a JPEG that is progressive or sampled another way. SelectVideoTrack of
/// a track of pictures (SINCE 1.3).
pub const VCERR_UNSUPPORTED: i32 = -4;
/// The source would not give its bytes.
pub const VCERR_READ: i32 = -5;
/// The bytes are not what their kind says they should be, or the decoder
/// stopped on a picture. DecodeVideoFrame can be called again: it goes
/// on with the next.
pub const VCERR_CORRUPT: i32 = -6;
/// SeekVideo - or SelectVideoTrack (SINCE 1.3) - on a film read through
/// VCA_ReadFunc.
pub const VCERR_NOSEEK: i32 = -7;
/// DecodeVideoFrame: every frame has been handed out. GetVideoTrack and
/// SelectVideoTrack: past the last track; GetVideoSubtitle: nothing shows
/// (SINCE 1.3).
pub const VCERR_END: i32 = -8;
/// Nothing here decodes the pictures' codec - no module in LIBS:codecs/
/// opens a decoder for it: H.264 or H.265 on a machine without the chip's
/// decoder, MPEG-4 Part 2, a codec unknown - or the
/// codec of the track SelectVideoTrack is given (SINCE 1.3).
pub const VCERR_NOCODEC: i32 = -9;
/// The decoder is busy: as many are open as the chip runs
/// (OpenVideoStream), or VIDEO_HELD_FRAMES frames are held and none was
/// given back (DecodeVideoFrame).
pub const VCERR_BUSY: i32 = -10;
/// DecodeVideoSound on a stream without sound; SelectVideoTrack of sound
/// on one opened without it (SINCE 1.3).
pub const VCERR_NOSOUND: i32 = -11;
/// A codec module's decoder wants a packet before it hands out another
/// frame (ReceiveVCodecFrame). Never a program's (SINCE 1.4).
pub const VCERR_NEED_DATA: i32 = -12;
/// A codec module's decoder has no room for the packet yet: a frame is
/// to be taken first, and the packet sent again (SendVCodecPacket). Never
/// a program's (SINCE 1.4).
pub const VCERR_FULL: i32 = -13;

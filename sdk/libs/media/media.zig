//! media.library's structures and constants: a container file opened,
//! its tracks, the packets they are cut into, the tags it is opened with,
//! and the error codes. The calls are in `sdk.interface.media`.
//!
//! A container holds the coded tracks of a film or a song side by side -
//! a picture in H.264, its sound in AAC - each cut into packets, a
//! picture or a piece of sound each, with the time it is due. A program
//! opens the file (`OpenMedia`) - by its name, a file it has open, or
//! bytes a function of its own hands over - and the library finds out
//! what it is by its first bytes: MP4 (and QuickTime's MOV, which it
//! comes from; `.mp4`, `.m4a`, `.m4v`, `.mov`). `GetMediaInfo` says what
//! the file is and how long, `GetMediaTrack` what each track is - its
//! kind, its codec, its size or its rate, and the setup bytes its decoder
//! needs - and `ReadMediaPacket` hands out a track's packets one after
//! the other, as coded: the library decodes nothing. `SeekMedia` moves a
//! track to a packet a decoder can start from.
//!
//! Each track is read by itself, at its own pace: the sound by one task,
//! the picture by another, as a player does it. Two tasks may read two
//! tracks of one file at once; the library takes turns at the file. One
//! track is read by one task at a time.
//!
//! The times are in microseconds from the start of what the file
//! presents. A track may begin with packets that are due before it: an
//! encoder's priming, which a sound decoder needs to begin with and does
//! not play. Their times are below 0.
//!
//! The tags a song carries - its title, its artist, its cover - are given
//! by `GetMediaAttrs`, as audiocodec.library gives a sound file's.
const utility = @import("../utility/utility.zig");

pub const MEDIANAME = "media.library";

/// A container file opened: the library's own, opened by `OpenMedia` and
/// given back with `CloseMedia`.
pub const MediaFile = opaque {};

// --- what a file is ---------------------------------------------------------------

/// Not a container the library knows.
pub const MEDIA_UNKNOWN: u32 = 0;
/// ISO's base media file format: MP4, and QuickTime's MOV.
pub const MEDIA_MP4: u32 = 1;

/// How many bytes `IdentifyMedia` wants to be sure.
pub const MEDIA_IDENTIFY_BYTES: u32 = 64;

// --- a track ----------------------------------------------------------------------

/// A track the library does not know the kind of.
pub const MTRACK_OTHER: u32 = 0;
/// Pictures.
pub const MTRACK_VIDEO: u32 = 1;
/// Sound.
pub const MTRACK_AUDIO: u32 = 2;
/// Text: subtitles, the names of chapters.
pub const MTRACK_TEXT: u32 = 3;

/// A codec the library does not know: its packets are handed out all
/// the same.
pub const MCODEC_UNKNOWN: u32 = 0;
/// H.264 (AVC): the setup is the avcC record - the sizes of the lengths
/// in front of each piece, the SPS and PPS.
pub const MCODEC_H264: u32 = 1;
/// H.265 (HEVC): the setup is the hvcC record.
pub const MCODEC_H265: u32 = 2;
/// Motion JPEG: each packet a JPEG picture whole - QuickTime's `jpeg`
/// entry and its kin, or MPEG-4's `mp4v` naming JPEG (SINCE 1.1).
pub const MCODEC_MJPEG: u32 = 3;
/// MPEG-4 Part 2 video.
pub const MCODEC_MPEG4V: u32 = 4;
/// AAC: the setup is the AudioSpecificConfig - the object type, the rate,
/// the channels.
pub const MCODEC_AAC: u32 = 16;
/// MPEG audio, MP3: each packet a frame whole, header and all.
pub const MCODEC_MP3: u32 = 17;
/// Apple's lossless codec (ALAC): the setup is its magic cookie.
pub const MCODEC_ALAC: u32 = 18;
/// AC-3 and E-AC-3.
pub const MCODEC_AC3: u32 = 19;
pub const MCODEC_EAC3: u32 = 20;
/// Opus: the setup is its dOps box.
pub const MCODEC_OPUS: u32 = 21;
/// FLAC: the setup is its STREAMINFO.
pub const MCODEC_FLAC: u32 = 22;
/// Timed text (3GPP, QuickTime's): each packet a length and the text.
pub const MCODEC_TEXT: u32 = 32;

/// What `GetMediaTrack` fills in about a track.
pub const MediaTrack = extern struct {
    /// MTRACK_*, MCODEC_*.
    kind: u32 = MTRACK_OTHER,
    codec: u32 = MCODEC_UNKNOWN,
    /// The track's number in the container, as it names it.
    id: u32 = 0,
    /// How many packets it has, 0 when that is not known.
    packets: u32 = 0,
    /// The ticks a second the track counts its times in: its packets', and
    /// `delay` and `length`.
    timescale: u32 = 0,
    /// The ticks of the track before what is presented - an encoder's
    /// priming, which a decoder starts with and does not play - and how
    /// many ticks are presented: the track's whole length, 0 when not
    /// known. For a sound track counted in its rate, as it mostly is,
    /// these are frames of samples.
    delay: u32 = 0,
    length: u64 align(4) = 0,
    /// How long it lasts, in microseconds.
    duration: u64 align(4) = 0,
    /// Pictures: their size in pixels, and how many a second times 1000 -
    /// 29970 for NTSC's - from the track's packets on average; 0 when not
    /// known.
    width: u32 = 0,
    height: u32 = 0,
    frame_rate: u32 = 0,
    /// Sound: frames a second, channels, the bits a sample is coded in
    /// where the codec says (0 for a lossy codec).
    rate: u32 = 0,
    channels: u32 = 0,
    bits: u32 = 0,
    /// Bits a second it is coded at, on average; 0 when not known.
    bitrate: u32 = 0,
    /// The largest packet, in bytes; 0 when not known.
    max_packet: u32 = 0,
    /// The setup a decoder of its codec wants before the first packet
    /// (MCODEC_* says what it is), the file's own, good until it is
    /// closed; null when the codec has none.
    config: ?[*]const u8 = null,
    config_size: u32 = 0,
    /// Its language, ISO 639-2, NUL-terminated: "eng", "deu"; "und" when
    /// not said.
    language: [4]u8 = @splat(0),
    /// Its name, as the container gives it, NUL-terminated; empty when it
    /// has none.
    name: [64]u8 = @splat(0),
};

/// A packet as `ReadMediaPacket` hands it out.
pub const MediaPacket = extern struct {
    /// Its bytes: the library's, good until the next ReadMediaPacket or
    /// SeekMedia on the same track, or the file is closed.
    data: ?[*]const u8 = null,
    size: u32 = 0,
    /// MPKT_*.
    flags: u32 = 0,
    /// When it is due - shown, heard - and when it is decoded, in
    /// microseconds from the start of what the file presents. Below 0 for
    /// a packet before it: priming.
    pts: i64 align(4) = 0,
    dts: i64 align(4) = 0,
    /// How long it lasts, in microseconds.
    duration: u32 = 0,
    /// Its number in its track, 0 for the first.
    index: u32 = 0,
    /// When it is decoded in the track's own ticks (`MediaTrack.timescale`),
    /// counted from the track's first packet: exact, where microseconds
    /// are rounded.
    ticks: u64 align(4) = 0,
};

/// MediaPacket.flags: a decoder can start at it - a picture that needs no
/// other; every packet of sound.
pub const MPKT_KEY: u32 = 1 << 0;

// --- what a file is, in full ------------------------------------------------------

/// What GetMediaInfo fills in.
pub const MediaInfo = extern struct {
    /// MEDIA_*.
    kind: u32 = MEDIA_UNKNOWN,
    /// How many tracks it has; `GetMediaTrack` numbers them from 0.
    tracks: u32 = 0,
    /// How long it lasts, in microseconds: its longest track.
    duration: u64 align(4) = 0,
    /// Whether SeekMedia can move its tracks: a file, read where it lies.
    seekable: u32 = 0,
    /// The first track of pictures and of sound, as GetMediaTrack numbers
    /// them; ~0 when it has none.
    video: u32 = ~@as(u32, 0),
    audio: u32 = ~@as(u32, 0),
    /// What its tags name it, NUL-terminated, cut at 63 characters; empty
    /// when it has none.
    title: [64]u8 = @splat(0),
    artist: [64]u8 = @splat(0),
    album: [64]u8 = @splat(0),
};

// --- OpenMedia's tags -------------------------------------------------------------

pub const MDA_Dummy = utility.TAG_USER + 0x60C00;
/// `[*:0]const u8`: a file to open and read; closed with it.
pub const MDA_Name = MDA_Dummy + 0x01;
/// `*FileHandle`: a file the program has open, read from where it is. Not
/// closed with it.
pub const MDA_FileHandle = MDA_Dummy + 0x02;
/// `ReadFn`: a function of the program's that hands the bytes over, for a
/// file that is not one. With it nothing can seek, and the file is read
/// once, front to back: a track's packets are handed out only while they
/// lie ahead, so one track is read, of a file whose index comes before
/// its packets.
pub const MDA_ReadFunc = MDA_Dummy + 0x03;
/// What `MDA_ReadFunc` is given each time.
pub const MDA_ReadData = MDA_Dummy + 0x04;
/// `u32`: the kind (MEDIA_*) the bytes are, rather than finding out.
pub const MDA_Kind = MDA_Dummy + 0x05;
/// Bool: the picture the tags hold - a cover - is kept, for
/// `MDA_Picture`. Without it a picture is passed over.
pub const MDA_KeepPicture = MDA_Dummy + 0x06;

// --- GetMediaAttrs's tags ---------------------------------------------------------
// Each tag's data is where the answer goes. A text is the file's own,
// NUL-terminated, Latin-1 - a character past it is a `?` - and empty when
// the tags do not say; it is good until the file is closed.

/// `*[*:0]const u8`: the title, the artist, the album at full length, the
/// album's own artist, the composer, the genre by its name, a comment.
pub const MDA_Title = MDA_Dummy + 0x20;
pub const MDA_Artist = MDA_Dummy + 0x21;
pub const MDA_Album = MDA_Dummy + 0x22;
pub const MDA_AlbumArtist = MDA_Dummy + 0x23;
pub const MDA_Composer = MDA_Dummy + 0x24;
pub const MDA_Genre = MDA_Dummy + 0x25;
pub const MDA_Comment = MDA_Dummy + 0x26;
/// `*u32`: the year; the track's number and how many the album has. 0
/// when the tags do not say.
pub const MDA_Year = MDA_Dummy + 0x27;
pub const MDA_Track = MDA_Dummy + 0x28;
pub const MDA_Tracks = MDA_Dummy + 0x29;
/// `*?*const MediaPicture`: the picture kept with `MDA_KeepPicture`, or
/// null when there is none or it was not kept.
pub const MDA_Picture = MDA_Dummy + 0x2A;
/// `*u32`: how many chapters the file marks, and `*?[*]const
/// MediaChapter`: them, in order, or null when there are none.
pub const MDA_Chapters = MDA_Dummy + 0x2B;
pub const MDA_ChapterList = MDA_Dummy + 0x2C;

/// A chapter: where it starts and ends, and its title. As audiocodec's
/// `AudioChapter`.
pub const MediaChapter = extern struct {
    /// Milliseconds from the start of what the file presents.
    start: u32,
    end: u32,
    /// NUL-terminated, Latin-1; empty when it has none.
    title: [96]u8,
};

/// A picture the tags hold: the bytes of an image file as it is stored -
/// a JPEG or a PNG - and what it is. As audiocodec's `AudioPicture`.
pub const MediaPicture = extern struct {
    data: [*]const u8,
    size: u32,
    /// What it is a picture of, numbered as ID3 numbers them: 3 the front
    /// cover, which is what an MP4's cover is.
    kind: u32,
    /// Its MIME type, "image/jpeg" or "image/png"; empty when not said.
    mime: [32]u8,
};

/// Up to `length` bytes into `buffer`: how many it put there, 0 at the
/// end, below 0 when it cannot read. Fewer than asked are fine.
pub const ReadFn = *const fn (data: ?*anyopaque, buffer: [*]u8, length: u32) callconv(.c) i32;

// --- errors -----------------------------------------------------------------------

pub const MERR_OK: i32 = 0;
/// No memory.
pub const MERR_NOMEMORY: i32 = -1;
/// The file could not be opened, or no source was given.
pub const MERR_OPEN: i32 = -2;
/// Not a container the library knows.
pub const MERR_UNKNOWN: i32 = -3;
/// A container it knows, in a form it does not read: an MP4 in fragments,
/// one whose index lies behind its packets read through a function, a
/// track encrypted.
pub const MERR_UNSUPPORTED: i32 = -4;
/// The source would not give its bytes.
pub const MERR_READ: i32 = -5;
/// The bytes are not what the container says they should be.
pub const MERR_CORRUPT: i32 = -6;
/// SeekMedia, or a packet behind what was read, on a file read through
/// MDA_ReadFunc.
pub const MERR_NOSEEK: i32 = -7;
/// The track has no more packets.
pub const MERR_END: i32 = -8;
/// No track of that number.
pub const MERR_NOTRACK: i32 = -9;

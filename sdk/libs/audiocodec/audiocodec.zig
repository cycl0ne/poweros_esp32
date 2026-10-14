//! audiocodec.library's structures and constants: the stream a program
//! decodes, the tags it is opened with, what it is, and the error codes.
//! The calls are in `sdk.interface.audiocodec`.
//!
//! A program opens a stream on sound - a file by its name, a file it has
//! open, or bytes a function of its own hands over (a download, a network
//! stream) - and the library finds out what it is by its first bytes:
//! WAV, MP3, FLAC, Vorbis in Ogg. Then `DecodeAudio` hands out the sound
//! as 16-bit samples, one frame after the other (a sample a channel, the
//! channels interleaved, left first), until the end - as much at a time
//! as the program asks for, so a song is never decoded whole.
//! `GetAudioStreamInfo` says what the sound is: its rate and channels, its
//! length where it is known, and the title, artist and album its tags
//! name. `GetAudioStreamAttrs` gives the rest of the tags - the names at
//! full length, the year, the track, the genre, a comment, the chapters a
//! mix or a book is marked in - and the picture they hold, a cover, when
//! the stream was opened with `ACA_KeepPicture`. `SeekAudio` moves to a
//! frame where the stream can be read from anywhere.
//!
//! The samples go to audio.device as they are: a stream of `AUDIO_S16`
//! at the rate and channels the info gives.

const utility = @import("../utility/utility.zig");

pub const AUDIOCODECNAME = "audiocodec.library";

/// A stream being decoded: the library's own, opened by OpenAudioStream
/// and given back with CloseAudioStream.
pub const AudioStream = opaque {};

// --- what a stream is -------------------------------------------------------------

/// Not a kind the library knows.
pub const ACODEC_UNKNOWN: u32 = 0;
/// RIFF WAVE: PCM of 8 to 32 bits, or 32-bit float.
pub const ACODEC_WAV: u32 = 1;
/// MPEG audio Layer III - MP3: MPEG-1, 2 and 2.5.
pub const ACODEC_MP3: u32 = 2;
/// FLAC: lossless, 4 to 24 bits a sample (SINCE 1.2).
pub const ACODEC_FLAC: u32 = 3;
/// Vorbis in Ogg pages - an .ogg or .oga file (SINCE 1.2).
pub const ACODEC_VORBIS: u32 = 4;

/// How many bytes `IdentifyAudio` wants to be sure: enough for a WAV's
/// header and for several MP3 frames after a short tag.
pub const AUDIO_IDENTIFY_BYTES: u32 = 4096;

// --- OpenAudioStream's tags -------------------------------------------------------

pub const ACA_Dummy = utility.TAG_USER + 0x60600;
/// `[*:0]const u8`: a file to open and read; closed with the stream.
pub const ACA_Name = ACA_Dummy + 0x01;
/// `*FileHandle`: a file the program has open, read from where it is. Not
/// closed with the stream.
pub const ACA_FileHandle = ACA_Dummy + 0x02;
/// `ReadFn`: a function of the program's that hands the bytes over, for
/// sound that is not a file. With it the stream cannot seek.
pub const ACA_ReadFunc = ACA_Dummy + 0x03;
/// What `ACA_ReadFunc` is given each time.
pub const ACA_ReadData = ACA_Dummy + 0x04;
/// `u32`: the kind (ACODEC_*) the bytes are, rather than finding out.
pub const ACA_Codec = ACA_Dummy + 0x05;
/// Bool: the picture the tags hold - a cover - is kept, for
/// `ACA_Picture`. Without it a picture is passed over, which costs
/// nothing however large it is.
pub const ACA_KeepPicture = ACA_Dummy + 0x06;

// --- GetAudioStreamAttrs's tags ---------------------------------------------------

// Each tag's data is where the answer goes. A text is the stream's own,
// NUL-terminated, Latin-1 - a character past it is a `?` - and empty when
// the tags do not say; it is good until the stream is closed.

/// `*[*:0]const u8`: the title, the artist, the album - at full length,
/// where the info's are cut at 63 characters - the album's own artist,
/// the composer.
pub const ACA_Title = ACA_Dummy + 0x20;
pub const ACA_Artist = ACA_Dummy + 0x21;
pub const ACA_Album = ACA_Dummy + 0x22;
pub const ACA_AlbumArtist = ACA_Dummy + 0x23;
pub const ACA_Composer = ACA_Dummy + 0x24;
/// `*[*:0]const u8`: the genre by its name - one given as an ID3v1 number
/// is named as ID3 names it.
pub const ACA_Genre = ACA_Dummy + 0x25;
/// `*[*:0]const u8`: a comment: one with no description of its own,
/// rather than one a program wrote for itself.
pub const ACA_Comment = ACA_Dummy + 0x26;
/// `*u32`: the year; the track's number and how many the album has. 0
/// when the tags do not say.
pub const ACA_Year = ACA_Dummy + 0x27;
pub const ACA_Track = ACA_Dummy + 0x28;
pub const ACA_Tracks = ACA_Dummy + 0x29;
/// `*?*const AudioPicture`: the picture kept with `ACA_KeepPicture`, or
/// null when there is none or it was not kept.
pub const ACA_Picture = ACA_Dummy + 0x2A;
/// `*u32`: how many chapters the tags mark - the tracks of a mix, the
/// chapters of a book - and `*?[*]const AudioChapter`: them, in the order
/// the tags give them, or null when there are none.
pub const ACA_Chapters = ACA_Dummy + 0x2B;
pub const ACA_ChapterList = ACA_Dummy + 0x2C;

/// A chapter the tags mark: where it starts and ends in the sound, and
/// its title.
pub const AudioChapter = extern struct {
    /// Milliseconds from the start of the sound.
    start: u32,
    end: u32,
    /// NUL-terminated, Latin-1; empty when it has none.
    title: [96]u8,
};

/// A picture the tags hold: the bytes of an image file as it is stored -
/// a JPEG or a PNG, which datatypes.library reads - and what it shows.
pub const AudioPicture = extern struct {
    data: [*]const u8,
    size: u32,
    /// ACPIC_*: what it is a picture of, as ID3 numbers them.
    kind: u32,
    /// Its MIME type, "image/jpeg" or "image/png"; empty when not said.
    mime: [32]u8,
};

/// `AudioPicture.kind`: what the picture shows. The front cover is the
/// one kept where there are several.
pub const ACPIC_OTHER: u32 = 0;
pub const ACPIC_FRONTCOVER: u32 = 3;
pub const ACPIC_BACKCOVER: u32 = 4;

/// Up to `length` bytes into `buffer`: how many it put there, 0 at the
/// end, below 0 when it cannot read.
pub const ReadFn = *const fn (data: ?*anyopaque, buffer: [*]u8, length: u32) callconv(.c) i32;

// --- errors -----------------------------------------------------------------------

pub const ACERR_OK: i32 = 0;
/// No memory for the stream.
pub const ACERR_NOMEMORY: i32 = -1;
/// The file could not be opened, or no source was given.
pub const ACERR_OPEN: i32 = -2;
/// Not a kind of sound the library knows.
pub const ACERR_UNKNOWN: i32 = -3;
/// A kind it knows, in a form it does not decode: an MP3 of layer I or II,
/// a WAV that is not PCM or float, a FLAC of more than 24 bits or carried
/// in Ogg, a Vorbis floor of type 0, more than two channels.
pub const ACERR_UNSUPPORTED: i32 = -4;
/// The source would not give its bytes.
pub const ACERR_READ: i32 = -5;
/// The bytes are not what their kind says they should be.
pub const ACERR_CORRUPT: i32 = -6;
/// SeekAudio on a stream that cannot seek: one read through ACA_ReadFunc.
pub const ACERR_NOSEEK: i32 = -7;

// --- what a stream is, in full ----------------------------------------------------

/// What GetAudioStreamInfo fills in.
pub const AudioStreamInfo = extern struct {
    /// ACODEC_*.
    codec: u32 = ACODEC_UNKNOWN,
    /// Frames a second, and channels a frame (1 or 2): the samples
    /// DecodeAudio hands out.
    rate: u32 = 0,
    channels: u32 = 0,
    /// How long it is, in frames; 0 when that is not known before the end.
    frames: u32 = 0,
    /// Bits a second it is coded at - an average for a variable rate; 0
    /// when not known.
    bitrate: u32 = 0,
    /// The bits a sample has in the file, before it is handed out as 16.
    bits: u32 = 0,
    /// Whether SeekAudio can move it: a file, read where it lies.
    seekable: u32 = 0,
    /// What its tags name it - ID3 for an MP3, the INFO list for a WAV,
    /// Vorbis comments for a FLAC or an Ogg Vorbis stream -
    /// NUL-terminated, empty when it has none.
    title: [64]u8 = @splat(0),
    artist: [64]u8 = @splat(0),
    album: [64]u8 = @splat(0),
};

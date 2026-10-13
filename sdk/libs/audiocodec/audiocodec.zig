//! audiocodec.library's structures and constants: the stream a program
//! decodes, the tags it is opened with, what it is, and the error codes.
//! The calls are in `sdk.interface.audiocodec`.
//!
//! A program opens a stream on sound - a file by its name, a file it has
//! open, or bytes a function of its own hands over (a download, a network
//! stream) - and the library finds out what it is by its first bytes:
//! WAV, MP3. Then `DecodeAudio` hands out the sound as 16-bit samples, one
//! frame after the other (a sample a channel, the channels interleaved,
//! left first), until the end - as much at a time as the program asks
//! for, so a song is never decoded whole. `GetAudioStreamInfo` says what
//! the sound is: its rate and channels, its length where it is known, and
//! the title, artist and album its tags name. `SeekAudio` moves to a frame
//! where the stream can be read from anywhere.
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
/// a WAV that is not PCM or float, more than two channels.
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
    /// What its tags name it - ID3 for an MP3, the INFO list for a WAV -
    /// NUL-terminated, empty when it has none.
    title: [64]u8 = @splat(0),
    artist: [64]u8 = @splat(0),
    album: [64]u8 = @splat(0),
};

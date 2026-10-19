//! audio.device: sound out of the board, as streams mixed together.
//!
//! **A stream per open.** Each OpenDevice of unit 0 is a stream of its
//! own, and up to `AUDIO_MAX_STREAMS` play at once, mixed by the device:
//! a program that wants a tune and a click at the same time opens twice.
//! Nothing is allocated or taken away from anyone.
//!
//! **A stream has a format**, given in the request at OpenDevice and
//! changed with `AUDIOCMD_SETPARAMS`: signed 8-, 16- or 32-bit samples
//! (`AUDIO_S8`, `AUDIO_S16`, `AUDIO_S32`, in the machine's own byte
//! order), one channel or two interleaved (left first), at any rate from
//! 1 Hz to `AUDIO_MAX_RATE` frames a second - the device converts it to
//! the rate the output runs at - with a volume (`AUDIO_VOLUME_UNITY` is
//! as recorded, up to four times that) and a pan from
//! `-AUDIO_PAN_FULL` (left only) to `AUDIO_PAN_FULL` (right only).
//!
//! **CMD_WRITE plays a buffer**: `std.data` and `std.length` in bytes,
//! whole frames, played `loops` times over (0 until it is flushed or
//! aborted). Writes queue without a limit and follow each other without a
//! gap; each is replied when its last frame has been played, with
//! `std.actual` the bytes it played. A program streams sound - music
//! decoded as it goes - with two or three buffers, writing each again as
//! it comes back. The memory is the program's until the write is replied.
//!
//! The other commands, on the stream the request was opened on:
//!
//!   CMD_STOP, CMD_START   hold the stream where it is, and go on
//!   CMD_FLUSH             every write answered IOERR_ABORTED, silence
//!   CMD_RESET             as CMD_FLUSH, and the stream started again
//!   AUDIOCMD_SETPARAMS    the format, rate, volume and pan of the request
//!                         from now on: the rate, volume and pan at once,
//!                         the format for the writes sent after it - each
//!                         write keeps the format it was sent in
//!   AUDIOCMD_QUERY        an `AudioInfo` written to `std.data` (when it
//!                         is not null) - as much of it as `std.length`
//!                         holds, `std.actual` saying how much - and
//!                         `position`: the frames this stream has played
//!                         since it was opened
//!   AUDIOCMD_MASTER       how loud everything is, from `volume`: the
//!                         device's, every stream's
//!   AUDIOCMD_NEXTOUTPUT   the output after the one `output` names (0:
//!                         the first), its number in `output` and its
//!                         `AudioOutputInfo` to `std.data`, as much as
//!                         `std.length` holds; AUDIOERR_NOOUTPUT past
//!                         the last
//!   AUDIOCMD_SETOUTPUT    the device plays through the output `output`
//!                         names from now on (0: the first on the list);
//!                         every stream goes on where it was
//!   AUDIOCMD_GETOUTPUT    the output played through: its number in
//!                         `output`, its `AudioOutputInfo` to `std.data`
//!
//! AbortIO takes a write back: one that waits, or the one that plays,
//! which stops, the next going on.
//!
//! **What the board has** is the query's answer: the rate the output runs
//! at, whether it is one speaker or a codec that plays one side
//! (`channels` 1) or two speakers (2) - a stereo stream on one speaker is
//! heard as its two sides together - and how many frames lie between a
//! write and its being heard. Unit 1, the way in, is the number a
//! recording stream will open; until a board's input is driven it is
//! refused (`AUDIOERR_NOINPUT`).
//!
//! **A machine may have several outputs** - a jack and a speaker, a DAC
//! plugged in - and the device plays through one at a time: the first on
//! the list until it is told another. Each has a number that stays the
//! same from one boot to the next, which is how a program or a
//! preference names it. The output commands read `output`, a field an
//! IOAudio of version 2 had not got: a request smaller than the whole is
//! refused them with IOERR_BADLENGTH, and opens as before.

const exec = @import("../libs/exec/exec.zig");
const IOStdReq = exec.IOStdReq;

/// The device's name, for OpenDevice.
pub const AUDIONAME = "audio.device";

/// The units: what is played, and - once a board's input is driven -
/// what is recorded.
pub const AUDIO_UNIT_PLAY: u32 = 0;
pub const AUDIO_UNIT_RECORD: u32 = 1;

/// How many streams play at once.
pub const AUDIO_MAX_STREAMS: u32 = 16;

/// The highest rate a stream may have, in frames a second.
pub const AUDIO_MAX_RATE: u32 = 192_000;

/// A sample's form in memory: signed, in the machine's own byte order. A
/// 24-bit sample is a 32-bit one with its low byte zero.
pub const AUDIO_S8: u8 = 1;
pub const AUDIO_S16: u8 = 2;
pub const AUDIO_S32: u8 = 3;

/// A stream's volume as recorded; it goes up to four times that.
pub const AUDIO_VOLUME_UNITY: u32 = 0x10000;
pub const AUDIO_VOLUME_MAX: u32 = 4 * AUDIO_VOLUME_UNITY;

/// The pan's ends: all to the left, all to the right; 0 is the middle.
pub const AUDIO_PAN_FULL: i32 = 0x10000;

// --- commands ---------------------------------------------------------------------

pub const AUDIOCMD_SETPARAMS: u16 = exec.CMD_NONSTD + 0;
pub const AUDIOCMD_QUERY: u16 = exec.CMD_NONSTD + 1;
pub const AUDIOCMD_MASTER: u16 = exec.CMD_NONSTD + 2;
/// Since version 3.
pub const AUDIOCMD_NEXTOUTPUT: u16 = exec.CMD_NONSTD + 3;
pub const AUDIOCMD_SETOUTPUT: u16 = exec.CMD_NONSTD + 4;
pub const AUDIOCMD_GETOUTPUT: u16 = exec.CMD_NONSTD + 5;

// --- errors -----------------------------------------------------------------------

/// A format, a channel count or a rate the device does not take.
pub const AUDIOERR_BADFORMAT: i8 = -10;
/// Every stream is playing already.
pub const AUDIOERR_NOSTREAM: i8 = -11;
/// There is no way in on this board, or the device does not drive it yet.
pub const AUDIOERR_NOINPUT: i8 = -12;
/// No output of that number, none after it, or one that would not start.
pub const AUDIOERR_NOOUTPUT: i8 = -13;

/// What a command to audio.device is written in. The first fields are an
/// IOStdReq, so it is one.
pub const IOAudio = extern struct {
    /// io_Data, io_Length (bytes, whole frames) and io_Actual (bytes
    /// played).
    std: IOStdReq = .{},
    /// The stream's samples: AUDIO_S8, AUDIO_S16 or AUDIO_S32, and one
    /// channel or two. Read at OpenDevice and by AUDIOCMD_SETPARAMS.
    format: u8 = AUDIO_S16,
    channels: u8 = 2,
    pad: u16 = 0,
    /// Frames a second, 1 to AUDIO_MAX_RATE.
    rate: u32 = 48_000,
    /// How loud: AUDIO_VOLUME_UNITY as recorded, up to AUDIO_VOLUME_MAX.
    /// AUDIOCMD_MASTER reads the device's from here.
    volume: u32 = AUDIO_VOLUME_UNITY,
    /// Where between the speakers: -AUDIO_PAN_FULL left only, 0 both
    /// alike, AUDIO_PAN_FULL right only. On a stereo stream it weighs the
    /// two sides against each other.
    pan: i32 = 0,
    /// CMD_WRITE: how many times the buffer plays; 0 until stopped.
    loops: u32 = 1,
    /// AUDIOCMD_QUERY: the frames this stream has played since it was
    /// opened, counted round at 2^32.
    position: u32 = 0,
    /// The output commands: an output's number (`AudioOutputInfo.id`);
    /// 0 for the first. Since version 3.
    output: u32 = 0,
};

/// The fewest bytes a request given to OpenDevice may have: an IOAudio up
/// to `output`, as version 2 knew it.
pub const AUDIO_MIN_REQUEST: usize = @offsetOf(IOAudio, "output");

/// What AUDIOCMD_QUERY writes about the device and the board.
pub const AudioInfo = extern struct {
    /// The output: the rate it runs at, how many sides it plays (1 for one
    /// speaker or a codec with one output, 2 for two speakers), and bits a
    /// sample.
    rate: u32 = 0,
    channels: u32 = 0,
    bits: u32 = 0,
    /// Frames between a write's first frame being mixed and its being
    /// heard: the buffers the output runs through.
    latency: u32 = 0,
    /// Streams open now, and how many may be.
    streams: u32 = 0,
    max_streams: u32 = AUDIO_MAX_STREAMS,
    /// The device's volume (AUDIOCMD_MASTER).
    master: u32 = AUDIO_VOLUME_UNITY,
    /// Whether unit 1 records on this board.
    has_input: u32 = 0,
    /// The part the sound comes out of, as the board names it.
    output: ?[*:0]const u8 = null,
    /// Buffers the output played again because the device had not mixed
    /// the next in time - each one a gap heard - since its driver made it.
    underruns: u32 = 0,
    /// The output's number (`AudioOutputInfo.id`), 0 for none. Since
    /// version 3.
    output_id: u32 = 0,
};

/// How many of an output's rates `AudioOutputInfo` holds.
pub const AUDIO_MAX_RATES = 8;
/// How long an output's name may be, its NUL included.
pub const AUDIO_NAME_LEN = 32;

/// What AUDIOCMD_NEXTOUTPUT and AUDIOCMD_GETOUTPUT write about an output.
pub const AudioOutputInfo = extern struct {
    /// Its number: the same from one boot to the next, never 0.
    id: u32 = 0,
    /// AUDIOOF_*
    flags: u32 = 0,
    /// The most sides any of its modes plays: 1 or 2.
    channels: u32 = 0,
    /// The rates it runs at, `rate_count` of them, lowest first.
    rate_count: u32 = 0,
    rates: [AUDIO_MAX_RATES]u32 = @splat(0),
    /// Its name, as the board names the part, NUL-terminated.
    name: [AUDIO_NAME_LEN]u8 = @splat(0),
};

/// AudioOutputInfo.flags
/// The first on the list: what the device plays through until it is told
/// another.
pub const AUDIOOF_DEFAULT: u32 = 1 << 0;
/// The one the device plays through now.
pub const AUDIOOF_CURRENT: u32 = 1 << 1;

/// Bytes a frame takes in `format` with `channels` channels; 0 for a
/// format the device does not know.
pub fn frameBytes(format: u8, channels: u8) u32 {
    const sample: u32 = switch (format) {
        AUDIO_S8 => 1,
        AUDIO_S16 => 2,
        AUDIO_S32 => 4,
        else => return 0,
    };
    return if (channels == 1 or channels == 2) sample * channels else 0;
}

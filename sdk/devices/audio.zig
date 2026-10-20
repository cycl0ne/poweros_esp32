//! audio.device: sound out of the board, as streams mixed together.
//!
//! **A stream per open.** Each OpenDevice of unit 0 (`AUDIO_UNIT_PLAY`)
//! is a stream of its own, and up to `AUDIO_MAX_STREAMS` play at once, mixed by the device:
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
//!   AUDIOCMD_TRIGGER      a sound played at once, on a voice of its own:
//!                         `std.data` and `std.length` in the request's
//!                         own format, channels, rate, volume and pan,
//!                         `loops` times over; replied when it has played
//!
//! AbortIO takes a write back: one that waits, or the one that plays,
//! which stops, the next going on. It takes a trigger back the same way.
//!
//! **A sound for a moment** - a click, a beep - is a trigger: no stream is
//! fed for it and nothing waits on a timer for it. It plays on one of
//! `AUDIO_MAX_TRIGGERS` voices of its own, beside the streams, so it never
//! takes a stream's place and a stream is never cut for it. When every
//! one is playing, a new trigger takes the voice of the one of lowest
//! priority - the `pri` of the request's message node - and of those the
//! one that has played longest, so long as that priority is not above its
//! own; the one that gives way is answered IOERR_ABORTED, and a trigger no
//! voice gives way to AUDIOERR_NOVOICE. The samples are the program's
//! until the trigger is replied. An open with `AUDIOF_TRIGGER` in its
//! flags is for triggers alone and takes no stream: of the commands it
//! takes AUDIOCMD_TRIGGER, the query and the output and master commands.
//! A trigger plays on when the open it was sent on is closed.
//!
//! **What the board has** is the query's answer: the rate the output runs
//! at, whether it is one speaker or a codec that plays one side
//! (`channels` 1) or two speakers (2) - a stereo stream on one speaker is
//! heard as its two sides together - and how many frames lie between a
//! write and its being heard; whether the board has a way in, and which.
//!
//! **Unit 1 records** (`AUDIO_UNIT_RECORD`): the board's way in - a
//! codec's microphone input - heard as one recording stream, one open at
//! a time (a second is refused AUDIOERR_NOSTREAM, and an open on a board
//! with no way in AUDIOERR_NOINPUT). The request at OpenDevice gives its
//! form and rate, as a playing stream's, and its volume, a gain on what
//! is heard; the device converts from the rate the way in runs at. A way
//! in of the same part as the output - the two halves of one codec - runs
//! at the output's rate.
//!
//! **CMD_READ records into a buffer**: `std.data` and `std.length` in
//! bytes, whole frames. Reads queue without a limit and follow each other
//! without a gap; each is replied when it is full, `std.actual` the bytes
//! recorded. What is heard while no read waits is lost - a program keeps
//! two or three reads out, sending each again as it comes back - and once
//! a read comes after it, the query counts it in `overruns`. The way in starts with the first read
//! and stops at the close. The memory is the program's again once the
//! read is replied. On the recording:
//!
//!   CMD_STOP, CMD_START   hold the recording - what is heard meanwhile
//!                         is not recorded - and go on
//!   CMD_FLUSH             every read answered IOERR_ABORTED, with the
//!                         bytes it holds in `std.actual`
//!   CMD_RESET             as CMD_FLUSH, and the recording started again
//!   AUDIOCMD_SETPARAMS    the form for the reads sent after it, the rate
//!                         and volume at once
//!   AUDIOCMD_QUERY        the `AudioInfo`, and `position`: the frames
//!                         recorded since the open
//!
//! AbortIO takes a read back with the bytes it holds. The output and
//! master commands and AUDIOCMD_TRIGGER work on the recording's request
//! as on a stream's.
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

/// The units: what is played, and what is recorded (since version 5).
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
/// Since version 4.
pub const AUDIOCMD_TRIGGER: u16 = exec.CMD_NONSTD + 6;

/// OpenDevice's flags: an open for triggers alone, which takes no stream.
/// Since version 4.
pub const AUDIOF_TRIGGER: u32 = 1 << 0;

/// How many sounds play by trigger at once, beside the streams.
pub const AUDIO_MAX_TRIGGERS: u32 = 8;

// --- errors -----------------------------------------------------------------------

/// A format, a channel count or a rate the device does not take.
pub const AUDIOERR_BADFORMAT: i8 = -10;
/// Every stream is playing already, or the recording is someone's.
pub const AUDIOERR_NOSTREAM: i8 = -11;
/// There is no way in on this board, or it would not start.
pub const AUDIOERR_NOINPUT: i8 = -12;
/// No output of that number, none after it, or one that would not start.
pub const AUDIOERR_NOOUTPUT: i8 = -13;
/// Every trigger voice plays a sound of a higher priority.
pub const AUDIOERR_NOVOICE: i8 = -14;

/// What a command to audio.device is written in. The first fields are an
/// IOStdReq, so it is one.
pub const IOAudio = extern struct {
    /// io_Data, io_Length (bytes, whole frames) and io_Actual (bytes
    /// played, or recorded).
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
    /// CMD_WRITE and AUDIOCMD_TRIGGER: how many times the samples play; 0
    /// until stopped.
    loops: u32 = 1,
    /// AUDIOCMD_QUERY: the frames this stream has played - the recording
    /// recorded - since it was opened, counted round at 2^32.
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
    /// Whether unit 1 records on this board: 1 when it has a way in.
    has_input: u32 = 0,
    /// The part the sound comes out of, as the board names it.
    output: ?[*:0]const u8 = null,
    /// Buffers the output played again because the device had not mixed
    /// the next in time - each one a gap heard - since its driver made it.
    underruns: u32 = 0,
    /// The output's number (`AudioOutputInfo.id`), 0 for none. Since
    /// version 3.
    output_id: u32 = 0,
    /// Sounds playing by trigger now, and how many may. Since version 4.
    triggers: u32 = 0,
    max_triggers: u32 = AUDIO_MAX_TRIGGERS,
    /// The way in recorded from - or that a recording would be - as the
    /// board names the part, and its number; null and 0 for none. Since
    /// version 5.
    input: ?[*:0]const u8 = null,
    input_id: u32 = 0,
    /// The most sides any of its modes hears: 1 for one microphone, 2 for
    /// two.
    input_channels: u32 = 0,
    /// The rate it runs at while a recording runs, else 0.
    input_rate: u32 = 0,
    /// Buffers of it lost - filled while the one before had not been
    /// taken, or heard while no read waited between two reads: each a gap
    /// in a recording - since its driver made it.
    overruns: u32 = 0,
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

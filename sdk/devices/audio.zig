// SPDX-License-Identifier: MIT
//! audio.device: four channels of sound, allocated and written to.
//!
//! A channel is asked for rather than taken: `ADCMD_ALLOCATE` - or an
//! OpenDevice with `data` and `length` - is given the combinations that
//! would do and a precedence (`ln_Pri`), and answers with the one it got
//! in `channels`: free channels if it can, else those of the lowest
//! precedence below its own, which it steals - their writes come back
//! IOERR_ABORTED. Without `ADIOF_NOWAIT` it waits until it can be had;
//! a locked channel (`ADCMD_LOCK`) makes even that one wait, and tells
//! the lock `ADIOERR_CHANNELSTOLEN`. `alloc_key` says which allocation
//! the channels belong to: a command on a channel whose key has moved on
//! is refused (`ADIOERR_NOALLOCATION`), which is how a program finds out
//! that its channels were stolen. `ADCMD_SETPREC` changes the
//! precedence, `ADCMD_FREE` - and CloseDevice, for every channel of the
//! key - gives the channels back.
//!
//! `CMD_WRITE` plays `data` on one channel - the lowest the request
//! names, and `channels` says afterwards which: `length` bytes of signed
//! 8-bit samples, a sample every `period` ticks of the machine's audio
//! clock, at `volume` of 64, `cycles` times over (0 for ever). Writes on
//! a channel queue without a limit and follow each other without a gap,
//! so a program can stream sound as a pair of buffers, one playing while
//! it fills the other. A write is replied when its last sample has gone;
//! with `ADIOF_WRITEMESSAGE`, `write_msg` is replied when it starts. A
//! sound for both sides is a write to a channel of each, kept in step by
//! `CMD_STOP` on both, the writes, and `CMD_START` on both.
//!
//! The other commands: `CMD_READ` answers the write playing (in `data`),
//! `ADCMD_PERVOL` changes period and volume, `ADCMD_FINISH` ends the
//! write playing, `ADCMD_WAITCYCLE` is replied when the cycle playing
//! ends - each now or, with `ADIOF_SYNCCYCLE`, at the end of the cycle -
//! and `CMD_FLUSH` and `CMD_RESET` throw everything away. A command for
//! several channels serves those that are the caller's and leaves the
//! rest out of `channels`.
//!
//! The flags - `ADIOF_PERVOL`, `ADIOF_SYNCCYCLE`, `ADIOF_NOWAIT`,
//! `ADIOF_WRITEMESSAGE` - are the command's and reach the device through
//! DoIO and SendIO; a request used again keeps the ones it was last
//! given, so they are set for each command.
//!
//! This machine has one output and no four-channel hardware, so the
//! device mixes the channels itself: 0 and 3 to the left, 1 and 2 to the
//! right, as the hardware they are named for did. Where the board's
//! output is mono - one speaker or one jack - both sides are played on
//! it together, so a program that writes a left and a right channel is
//! heard whole on every board.

const exec = @import("../libs/exec/exec.zig");
const nodes = @import("../libs/exec/nodes.zig");
const IORequest = exec.IORequest;
const Message = exec.Message;

/// The device's name, for OpenDevice.
pub const AUDIONAME = "audio.device";

/// How many channels there are.
pub const ADHARD_CHANNELS: u32 = 4;

/// The range a precedence may take.
pub const ADALLOC_MINPREC: i8 = -128;
pub const ADALLOC_MAXPREC: i8 = 127;

/// The clock a period is counted in: a period of `n` plays a sample every
/// `n` ticks of it, so the rate is this over the period.
pub const AUDIO_CLOCK: u32 = 3_579_545;
/// The shortest period this machine makes sense of, which is one sample
/// per output frame at the rate the hardware runs.
pub const AUDIO_MINPERIOD: u16 = 64;

/// The loudest a channel is written at.
pub const ADVOLUME_MAX: u16 = 64;

// --- commands ---------------------------------------------------------------------

pub const ADCMD_FREE: u16 = exec.CMD_NONSTD + 0;
pub const ADCMD_SETPREC: u16 = exec.CMD_NONSTD + 1;
pub const ADCMD_FINISH: u16 = exec.CMD_NONSTD + 2;
pub const ADCMD_PERVOL: u16 = exec.CMD_NONSTD + 3;
pub const ADCMD_LOCK: u16 = exec.CMD_NONSTD + 4;
pub const ADCMD_WAITCYCLE: u16 = exec.CMD_NONSTD + 5;
pub const ADCMD_ALLOCATE: u16 = 32;

// --- io_Flags ---------------------------------------------------------------------

/// The period and the volume in this request are used; without it the
/// channel keeps what it had.
pub const ADIOB_PERVOL: u32 = 4;
pub const ADIOF_PERVOL: u8 = 1 << 4;
/// ADCMD_PERVOL and ADCMD_FINISH at the end of the cycle the channel is
/// in, rather than at once.
pub const ADIOB_SYNCCYCLE: u32 = 5;
pub const ADIOF_SYNCCYCLE: u8 = 1 << 5;
/// An allocation that cannot be made comes back refused rather than
/// waiting for the channels - unless a lock is what stands in the way.
pub const ADIOB_NOWAIT: u32 = 6;
pub const ADIOF_NOWAIT: u8 = 1 << 6;
/// `write_msg` is replied when the write starts to play.
pub const ADIOB_WRITEMESSAGE: u32 = 7;
pub const ADIOF_WRITEMESSAGE: u8 = 1 << 7;

// --- errors -----------------------------------------------------------------------

/// The channels this request names are not the caller's: they were never
/// allocated, or they were stolen and the key has moved on.
pub const ADIOERR_NOALLOCATION: i8 = -10;
/// No combination of channels could be had.
pub const ADIOERR_ALLOCFAILED: i8 = -11;
/// The channels were taken by something of higher precedence.
pub const ADIOERR_CHANNELSTOLEN: i8 = -12;

/// What a command to audio.device is written in. The first fields are an
/// IORequest, so it is one.
pub const IOAudio = extern struct {
    req: IORequest = .{},
    /// Which allocation the channels belong to. ADCMD_ALLOCATE fills it
    /// in; every later command on those channels carries it back.
    alloc_key: i16 = 0,
    pad: i16 = 0,
    /// Channels, one bit each: those an allocation got, those a command
    /// names - and, when it is done, those it acted on. A set of bits is
    /// not a unit, so it has a field of its own.
    channels: u32 = 0,
    /// The samples: signed 8-bit, one a period.
    data: ?[*]const i8 = null,
    length: u32 = 0,
    /// Ticks of AUDIO_CLOCK between samples, and how loud, of 64.
    period: u16 = 0,
    volume: u16 = 0,
    /// How many times over; 0 plays until something stops it.
    cycles: u16 = 0,
    pad2: u16 = 0,
    /// Replied when the write starts to play, for a write that asked
    /// (ADIOF_WRITEMESSAGE).
    write_msg: Message = .{},
};

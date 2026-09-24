// SPDX-License-Identifier: MIT
//! audio.device: four channels of sound, allocated and written to.
//!
//! A channel is asked for rather than taken: `ADCMD_ALLOCATE` is given the
//! combinations that would do and a precedence, and answers with the ones
//! it got - stealing them from anything of lower precedence, or waiting
//! until they are free. What comes back in `io_Unit` is the bits of the
//! channels allocated, and `ioa_AllocKey` says which allocation they
//! belong to: a command on a channel whose key has moved on is refused
//! (`ADIOERR_NOALLOCATION`), which is how a program finds out that its
//! channels were stolen.
//!
//! `CMD_WRITE` plays `ioa_Data` on those channels: `ioa_Length` bytes of
//! signed 8-bit samples, a sample every `ioa_Period` ticks of the
//! machine's audio clock, at `ioa_Volume` of 64, `ioa_Cycles` times over
//! (0 for ever). It is replied when the last sample has gone, or, with
//! `ADIOF_WRITEMESSAGE`, `ioa_WriteMsg` is replied then and the request
//! when the one after it starts.
//!
//! This machine has one stereo output and no four-channel hardware, so the
//! device mixes the channels itself: 0 and 3 to the left, 1 and 2 to the
//! right, as the hardware they are named for did.

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
/// Start at the end of the cycle the channel is in, rather than at once.
pub const ADIOB_SYNCCYCLE: u32 = 5;
pub const ADIOF_SYNCCYCLE: u8 = 1 << 5;
/// An allocation that cannot be made comes back refused rather than
/// waiting for the channels.
pub const ADIOB_NOWAIT: u32 = 6;
pub const ADIOF_NOWAIT: u8 = 1 << 6;
/// `ioa_WriteMsg` is replied when the write's last sample has gone, and
/// the request itself when the next write starts.
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
    /// Which channels were allocated, one bit each. ADCMD_ALLOCATE fills
    /// it in and every later command names its channels with it. (The
    /// hardware's own device put this in `io_Unit`; a set of bits is not
    /// a unit, and this machine's requests say what they mean.)
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
    /// Replied when the last sample has gone, for a write that asked
    /// (ADIOF_WRITEMESSAGE).
    write_msg: Message = .{},
};

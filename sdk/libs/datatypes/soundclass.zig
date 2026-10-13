// SPDX-License-Identifier: MIT
//! sound.datatype: what every sound is, whatever file it came out of -
//! the attributes a format's class sets, how it hands its samples over,
//! and playing it.
//!
//! A format's class is a subclass. In `OM_NEW` it reads the file far
//! enough to say what the sound is - `SDTA_SampleRate`, `SDTA_Channels`,
//! `SDTA_Frames` - and from then on sound.datatype plays it: on a process
//! of its own, through a stream of audio.device, asking the subclass for
//! the next piece with `SDTM_DECODE` as each buffer comes back and moving
//! it with `SDTM_SEEK`. A song is decoded as it is heard, never whole.
//!
//! A sound that is in memory already - a short sample a program made, a
//! file small enough to read whole - is handed over as `SDTA_Sample`
//! instead, in any of audio.device's forms (`SDTA_SampleType`), and the
//! superclass plays it from there; a subclass then answers no
//! `SDTM_DECODE` of its own.
//!
//! A program plays, pauses and stops a sound with `DTM_TRIGGER`
//! (`STM_PLAY`, `STM_PAUSE`, `STM_STOP`, `STM_RESUME`, `STM_LOCATE` with
//! a frame, `STM_FASTFORWARD` and `STM_REWIND` ten seconds), reads where
//! it is with `SDTA_Position`, and is told when it has played out by the
//! signal `SDTA_SignalTask` and `SDTA_SignalBit` name. `DTA_Immediate`
//! plays it as soon as it is laid out, `DTA_Repeat` plays it again and
//! again. In a window the object shows the sound's names, how long it is
//! and how far it has played, and a press on it plays or pauses it.

const classusr = @import("../intuition/classusr.zig");
const dtc = @import("datatypesclass.zig");

/// The class library, and the class it holds.
pub const SOUND_LIBRARY = "datatypes/sound.datatype";
pub const SOUNDDTCLASS = "sound.datatype";

pub const SDTA_Dummy = dtc.DTA_Dummy + 500;
/// `[*]const u8`: the whole sound in memory, `SDTA_SampleLength` frames
/// of `SDTA_SampleType`, the channels interleaved, left first. The
/// caller's, read until the object goes. Made and set.
pub const SDTA_Sample = SDTA_Dummy + 2;
/// u32: how many frames `SDTA_Sample` holds.
pub const SDTA_SampleLength = SDTA_Dummy + 3;
/// u32: how loud: `AUDIO_VOLUME_UNITY` is as recorded, up to
/// `AUDIO_VOLUME_MAX`. Made, set at once while it plays, and read.
pub const SDTA_Volume = SDTA_Dummy + 5;
/// u32: how many times it plays through (1); 0 again and again, as
/// `DTA_Repeat`.
pub const SDTA_Cycles = SDTA_Dummy + 6;
/// `*Task` and i32: the task signalled, and its signal's number, when the
/// sound has played out. -1 (the bit's default) signals nothing.
pub const SDTA_SignalTask = SDTA_Dummy + 7;
pub const SDTA_SignalBit = SDTA_Dummy + 8;
/// u32: `SDTA_Sample`'s form - `AUDIO_S8`, `AUDIO_S16` or `AUDIO_S32`
/// (`AUDIO_S16` unless given).
pub const SDTA_SampleType = SDTA_Dummy + 30;
/// u32: frames a second.
pub const SDTA_SampleRate = SDTA_Dummy + 31;
/// u32: channels a frame, 1 or 2.
pub const SDTA_Channels = SDTA_Dummy + 32;
/// u32: how long the sound is, in frames; 0 when that is not known.
pub const SDTA_Frames = SDTA_Dummy + 33;
/// u32: the frame being heard. Set, the sound goes there (as
/// `STM_LOCATE`).
pub const SDTA_Position = SDTA_Dummy + 34;
/// i32: where it is heard, `-AUDIO_PAN_FULL` left to `AUDIO_PAN_FULL`
/// right (0).
pub const SDTA_Pan = SDTA_Dummy + 35;
/// Bool (get only): whether it is playing.
pub const SDTA_Playing = SDTA_Dummy + 50;

/// The methods.
pub const SDTM_Dummy: classusr.MethodID = 0x720;
/// Asked of the subclass, on the player process: the next frames of the
/// sound, as 16-bit samples, the channels interleaved. It answers how
/// many it wrote, 0 at the end.
pub const SDTM_DECODE: classusr.MethodID = 0x721;
/// Asked of the subclass, on the player process: the next `SDTM_DECODE`
/// from `frame` on. It answers 1 when it moved there, 0 when it cannot.
pub const SDTM_SEEK: classusr.MethodID = 0x722;

/// `SDTM_DECODE`.
pub const SdtDecode = extern struct {
    method_id: classusr.MethodID = SDTM_DECODE,
    /// Where the samples go, room for `frames` frames.
    samples: [*]i16,
    frames: u32,
};

/// `SDTM_SEEK`.
pub const SdtSeek = extern struct {
    method_id: classusr.MethodID = SDTM_SEEK,
    frame: u32 = 0,
};

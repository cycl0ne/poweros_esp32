// SPDX-License-Identifier: MIT
//! videocodec.datatype: what every film is - the group `movi` - whatever
//! file it came out of: the attributes a program reads and sets, and what
//! it can be told to do.
//!
//! **One class reads every film there is.** media.library knows the
//! containers and videocodec.library picks the decoder for the pictures
//! and the sound, so a kind of film the system learns needs only a
//! descriptor in `DEVS:DataTypes` that names `BASE=videocodec` - as a
//! kind of sound needs one that names `BASE=audiocodec`. There is no
//! format class under this one to write, and so no `movie.datatype`
//! superclass over it: what such a superclass would hold, videocodec.library
//! already is.
//!
//! **The film plays itself.** The object opens the film in `OM_NEW` and
//! plays it on a process of its own from the moment it is laid out: that
//! process decodes the pictures, keeps the sound fed through audio.device
//! (the module `filmsound`, which SYS:Programs/Movie plays with too) and
//! shows each picture when what is heard has come to its time, and
//! `GM_RENDER` does nothing but put the picture that is up into the
//! window. A film without sound is kept in time by timer.device instead.
//!
//! **It takes the room it is given**, as a model does: `DTA_TotalVert` is
//! `DTA_VisibleVert` and the room's height, and the same across, so a
//! window shows no scroll bars for it. The picture is drawn as large as
//! fits with its shape kept, in the middle, black where it does not
//! reach - which is how a film is watched, and not how a picture is
//! looked at. Its own size is what it asks for (`DTA_NominalHoriz`), so a
//! window opened for it opens at the film's size.
//!
//! `DTA_Immediate` plays it as soon as it is laid out - what MultiView
//! asks for - `DTA_Repeat` plays it again when it ends, and `DTM_TRIGGER`
//! drives it as it drives a sound: `STM_PLAY`, `STM_PAUSE` (which turns
//! over), `STM_STOP`, `STM_LOCATE` with a time in milliseconds,
//! `STM_FASTFORWARD` and `STM_REWIND` ten seconds. A press on the picture
//! pauses it and a second goes on. The object lists the five
//! (`DTA_TriggerMethods`), so a program offers them without knowing it
//! holds a film.
//!
//! What the film says it is - its title, its tracks, its chapters - is
//! media.library's to tell (`GetVideoStreamAttrs`); the title is set on
//! the object as `DTA_ObjName`. A program that wants to choose among
//! several sound tracks, or to show subtitles, opens videocodec.library
//! on the file itself: a film object plays the tracks the film marks.

const classusr = @import("../intuition/classusr.zig");
const dtc = @import("datatypesclass.zig");

/// The class library every film object is of, and the class in it.
pub const VIDEOCODEC_LIBRARY = "datatypes/videocodec.datatype";
pub const VIDEOCODECDTCLASS = "videocodec.datatype";

pub const VDTA_Dummy = dtc.DTA_Dummy + 800;
/// u32 (get): the picture's size in pixels, as it is shown.
pub const VDTA_Width = VDTA_Dummy + 1;
pub const VDTA_Height = VDTA_Dummy + 2;
/// u32 (get): how many pictures a second the film says, rounded; 0 when
/// it does not say.
pub const VDTA_FramesPerSecond = VDTA_Dummy + 3;
/// u32 (get): how many pictures it holds; 0 when that is not known.
pub const VDTA_Frames = VDTA_Dummy + 4;
/// u32 (get): how long it lasts, in milliseconds - not microseconds,
/// which 32 bits hold only 71 minutes of; 0 when the film does not say.
pub const VDTA_Duration = VDTA_Dummy + 5;
/// u32: where it is, in milliseconds from the start of what it presents.
/// Set, the film moves to the key frame at or before that time, as
/// `STM_LOCATE` does; read, it is the time of the picture that is up -
/// which on a machine the film is too much for lags behind what is
/// heard, the pictures being what it counts.
pub const VDTA_Position = VDTA_Dummy + 6;
/// u32 (get): the pictures' codec, `videocodec`'s `VCODEC_*`.
pub const VDTA_Codec = VDTA_Dummy + 7;
/// u32 (get): the sound's codec, `audiocodec`'s `ACODEC_*`, and the rate
/// and channels it is played in. All 0 for a film with no sound, or whose
/// sound nothing on this machine decodes.
pub const VDTA_SoundCodec = VDTA_Dummy + 8;
pub const VDTA_SoundRate = VDTA_Dummy + 9;
pub const VDTA_SoundChannels = VDTA_Dummy + 10;
/// u32: how loud the sound is, in percent of as recorded (100), as
/// Movie's `VOLUME` is and up to the same 100. It is not
/// `SDTA_Volume`'s `AUDIO_VOLUME_UNITY` scale: a film's sound is driven
/// in percent from end to end, and a number that came back off a
/// perceptual curve it went up would not be the one that was set.
pub const VDTA_Volume = VDTA_Dummy + 11;
/// Bool (get): whether the film can be moved at all - a file can, a film
/// read through a function cannot.
pub const VDTA_Seekable = VDTA_Dummy + 12;
/// Bool (get): whether it is playing.
pub const VDTA_Playing = VDTA_Dummy + 13;

/// What it can be told to do, for a program to offer: `DTM_TRIGGER` with
/// `STM_PLAY`, `STM_PAUSE`, `STM_STOP`, `STM_FASTFORWARD`, `STM_REWIND`
/// and `STM_LOCATE`, whose `data` is a time in milliseconds.
pub const VDTM_Dummy: classusr.MethodID = 0x730;

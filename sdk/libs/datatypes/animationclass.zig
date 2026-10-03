// SPDX-License-Identifier: MIT
//! animation.datatype: what every moving picture is, whatever file it
//! came out of - the attributes a format's class sets, the methods that
//! play it, and the message a frame is asked for with.
//!
//! A format's class is a subclass. In `OM_NEW` it reads the file far
//! enough to know the animation's size and how many frames it has, and
//! tells its superclass (`ADTA_Width`, `ADTA_Height`, `ADTA_Frames`,
//! `ADTA_FramesPerSecond`). From then on animation.datatype plays it:
//! it asks the subclass for one frame at a time with `ADTM_LOADFRAME`,
//! on a process of its own and a few frames ahead, and shows each when
//! its time comes, on motion.library's clock. The subclass draws the
//! frame into a buffer the superclass hands it - one 32-bit pen a pixel,
//! as picture.datatype keeps a picture - and says how long it is shown.
//!
//! A program plays, pauses and stops an animation with `DTM_TRIGGER`
//! (`STM_PLAY`, `STM_PAUSE`, `STM_STOP`, `STM_RESUME`, `STM_LOCATE`) or
//! the `ADTM_` methods, and finds out where it is with `ADTA_Frame`.
//! `DTA_Immediate` starts it as soon as it is laid out, and it plays
//! round and round until it is stopped.

const classusr = @import("../intuition/classusr.zig");
const graphics = @import("../graphics/graphics.zig");
const dtc = @import("datatypesclass.zig");

/// The class library, and the class it holds.
pub const ANIMATION_LIBRARY = "datatypes/animation.datatype";
pub const ANIMATIONDTCLASS = "animation.datatype";

pub const ADTA_Dummy = dtc.DTA_Dummy + 600;
/// u32: the frames' width and height, in pixels. A subclass sets them in
/// `OM_NEW`; a program reads them.
pub const ADTA_Width = ADTA_Dummy + 1;
pub const ADTA_Height = ADTA_Dummy + 2;
/// u32: always 32 - a frame is kept as pens.
pub const ADTA_Depth = ADTA_Dummy + 3;
/// u32: how many frames there are.
pub const ADTA_Frames = ADTA_Dummy + 4;
/// u32: the frame shown now. Set, the animation goes there (as
/// `STM_LOCATE`).
pub const ADTA_Frame = ADTA_Dummy + 5;
/// u32: frames a second, for a frame whose subclass gives it no duration
/// of its own (10).
pub const ADTA_FramesPerSecond = ADTA_Dummy + 6;
/// u32: how many frames `STM_FASTFORWARD` and `STM_REWIND` move (10).
pub const ADTA_FrameIncrement = ADTA_Dummy + 7;
/// Bool (get only): whether it is playing.
pub const ADTA_Playing = ADTA_Dummy + 50;

/// The methods.
pub const ADTM_Dummy: classusr.MethodID = 0x700;
/// Asked of the subclass, on the loader process: draw a frame.
pub const ADTM_LOADFRAME: classusr.MethodID = 0x701;
/// Told to the subclass when a frame's buffer is taken back; a subclass
/// that keeps nothing per frame passes it by.
pub const ADTM_UNLOADFRAME: classusr.MethodID = 0x702;
/// Play from `frame`.
pub const ADTM_START: classusr.MethodID = 0x703;
/// Stop where it is; `ADTM_START` from `ADTA_Frame` goes on.
pub const ADTM_PAUSE: classusr.MethodID = 0x704;
/// Stop and go back to the first frame.
pub const ADTM_STOP: classusr.MethodID = 0x705;
/// Show `frame`, playing or not.
pub const ADTM_LOCATE: classusr.MethodID = 0x706;

/// `ADTM_LOADFRAME` and `ADTM_UNLOADFRAME`.
pub const AdtFrame = extern struct {
    method_id: classusr.MethodID = ADTM_LOADFRAME,
    /// The frame wanted, from 0.
    frame: u32 = 0,
    /// Where it goes: `ADTA_Height` rows of `ADTA_Width` pens,
    /// `bytes_per_row` apart, 0xAARRGGBB each as `graphics.Pen` is.
    /// Cleared before every frame unless `keep` is set.
    pens: [*]graphics.Pen,
    bytes_per_row: u32,
    /// The superclass hands the same buffer back for the frame after the
    /// one it last held, so a subclass that builds each frame on the one
    /// before may draw only what changed: true when that is so.
    keep: bool = false,
    pad: [3]u8 = @splat(0),
    /// Filled in by the subclass: how long the frame is shown, in
    /// milliseconds; 0 for 1000 / `ADTA_FramesPerSecond`.
    duration: u32 = 0,
    /// The subclass's, handed back with `ADTM_UNLOADFRAME`.
    user_data: ?*anyopaque = null,
};

/// `ADTM_START`, `ADTM_PAUSE`, `ADTM_STOP`, `ADTM_LOCATE`.
pub const AdtStart = extern struct {
    method_id: classusr.MethodID = ADTM_START,
    frame: u32 = 0,
};

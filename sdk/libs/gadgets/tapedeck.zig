// SPDX-License-Identifier: MIT
//! tapedeck.gadget: the buttons of a tape deck, or of an animation player.
//!
//! As a tape deck (`TDECK_Tape`) it has rewind, play, fast forward, stop
//! and pause: a press on one of the first four makes it the mode, which
//! stays shown pressed; pause turns over on its own. The press ends at
//! once, and the window's `IDCMP_GADGETUP` code is the mode, with
//! `TDECK_PAUSED_CODE` added while paused.
//!
//! As an animation control (the default) it has rewind, play and fast
//! forward, and a frame slider in the rest of its width. Rewind and fast
//! forward are the mode while they are held, and stop when let go; play
//! stays, and a press on it while playing stops. The code when a button
//! is let go is the mode; when the slider is let go, the frame with
//! `TDECK_FRAME_CODE` added. The right button while holding puts the mode
//! and the frame back as they were.
//!
//! Either way the target hears `TDECK_Mode`, `TDECK_Paused` and
//! `TDECK_CurrentFrame` with the gadget's `GA_ID` as they change.

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const TDECK_LIBRARY = "gadgets/tapedeck.gadget";
pub const TDECK_CLASS = "tapedeck.gadget";

pub const TDECK_Dummy = gadgets.GADGETS_Dummy + 11 * gadgets.GADGETS_Step;
/// The mode: `BUT_REWIND`, `BUT_PLAY`, `BUT_FORWARD` or `BUT_STOP`; set to
/// `BUT_PAUSE`, pause turns over. Made, set and read.
pub const TDECK_Mode = TDECK_Dummy + 1;
/// Bool: paused. Made, set and read.
pub const TDECK_Paused = TDECK_Dummy + 2;
/// Bool, made only: a tape deck rather than an animation control.
pub const TDECK_Tape = TDECK_Dummy + 3;
/// How many frames the animation has; 10 unless given. Made, set and read.
pub const TDECK_Frames = TDECK_Dummy + 11;
/// The frame shown, from 0. Made, set and read.
pub const TDECK_CurrentFrame = TDECK_Dummy + 12;

/// `TDECK_Mode`'s values, and what a button is.
pub const BUT_REWIND: u32 = 0;
pub const BUT_PLAY: u32 = 1;
pub const BUT_FORWARD: u32 = 2;
pub const BUT_STOP: u32 = 3;
pub const BUT_PAUSE: u32 = 4;
pub const BUT_BEGIN: u32 = 5;
pub const BUT_FRAME: u32 = 6;
pub const BUT_END: u32 = 7;

/// Added to a tape deck's code while it is paused.
pub const TDECK_PAUSED_CODE: u32 = 0x1000;
/// Added to the frame when an animation control's slider is let go.
pub const TDECK_FRAME_CODE: u32 = 0x8000;

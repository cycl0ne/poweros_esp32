// SPDX-License-Identifier: MIT
//! media.image: the pictures of a player's controls - play, pause, stop,
//! wind on and back, the song before and after, shuffle, repeat, the
//! speaker and its sound off - and the note that stands for music where a
//! song has no cover, drawn and not painted, so each is sharp at every
//! size, from a menu's 16 pixels to a large button's 48 and past it.
//!
//! Which picture an image is, is `MEDIA_Glyph`. The buttons of a tape
//! deck and the note are signs and stand on the ground as letters do: in
//! the screen's text pen, so they read on a light screen and on a dark
//! one. Shuffle
//! and repeat are blue arrows, the speaker is metal with blue waves, and
//! its sound off a red badge with a white cross - each with a darker rim,
//! shaded from light at the top, with a gloss and a soft shadow, in the
//! palette of `gadgets.shapes`. Under 20 pixels there is no shading,
//! gloss or shadow, only the colours and their rims.
//!
//! Drawn selected (`IDS_SELECTED`, `IDS_INACTIVESELECTED`) - on a pressed
//! button filled with the screen's fill pen, as a tape deck's is - the
//! signs are in the fill-text pen. Drawn disabled (`IDS_DISABLED`,
//! `IDS_INACTIVEDISABLED`, `IDS_SELECTEDDISABLED`), every colour is its
//! grey, faded into the ground.
//!
//! `IM_DRAWFRAME` draws the picture in the largest square that fits the
//! box, in its middle; `IM_DRAW` in the image's own box, 24 by 24 unless
//! `IA_Width` and `IA_Height` say otherwise. Both draw over what is there
//! and change nothing round the picture.
//!
//!   const shuffle = ib.NewObjectTagList(null, media.MEDIA_CLASS, &.{
//!       .{ .tag = media.MEDIA_Glyph, .data = media.MEDIA_SHUFFLE },
//!       .{},
//!   }) orelse return;
//!   defer ib.DisposeObject(shuffle);
//!   const button = ib.NewObjectTagList(null, tb.TOOLBUTTON_CLASS, &.{
//!       .{ .tag = gc.GA_Text, .data = @intFromPtr("_Shuffle") },
//!       .{ .tag = tb.TOOLBUTTON_Image, .data = @intFromPtr(shuffle) },
//!       .{ .tag = tb.TOOLBUTTON_Size, .data = tb.TBSIZE_SMALL },
//!       .{ .tag = tb.TOOLBUTTON_Kind, .data = tb.TBKIND_TOGGLE },
//!       .{},
//!   });

const images = @import("images.zig");

/// What a program opens, and the class it then asks for.
pub const MEDIA_LIBRARY = "images/media.image";
pub const MEDIA_CLASS = "media.image";

pub const MEDIA_Dummy = images.IMAGES_Dummy + 1 * images.IMAGES_Step;
/// `MEDIA_`: which picture. Made, set and read; `MEDIA_NONE`, which draws
/// nothing, without. A number past the last is none.
pub const MEDIA_Glyph = MEDIA_Dummy + 0x01;

/// `MEDIA_Glyph`.
pub const MEDIA_NONE: u32 = 0;
/// A triangle pointing on, in the text pen.
pub const MEDIA_PLAY: u32 = 1;
/// Two bars standing side by side.
pub const MEDIA_PAUSE: u32 = 2;
/// A square.
pub const MEDIA_STOP: u32 = 3;
/// Two triangles pointing back.
pub const MEDIA_REWIND: u32 = 4;
/// Two triangles pointing on.
pub const MEDIA_FORWARD: u32 = 5;
/// A bar and a triangle pointing back at it: the song before.
pub const MEDIA_PREVIOUS: u32 = 6;
/// A triangle pointing on at a bar: the song after.
pub const MEDIA_NEXT: u32 = 7;
/// Two blue arrows crossing.
pub const MEDIA_SHUFFLE: u32 = 8;
/// Two blue arrows going round.
pub const MEDIA_REPEAT: u32 = 9;
/// The same with a blue 1 in the middle: the one song again.
pub const MEDIA_REPEAT_ONE: u32 = 10;
/// A metal speaker with two blue waves before it.
pub const MEDIA_SPEAKER: u32 = 11;
/// The speaker with a red badge and a white cross: its sound off.
pub const MEDIA_MUTE: u32 = 12;
/// Two notes joined by a beam: music, where a song has no picture of its
/// own. Since 1.1.
pub const MEDIA_NOTE: u32 = 13;
/// The last picture there is.
pub const MEDIA_LAST: u32 = MEDIA_NOTE;

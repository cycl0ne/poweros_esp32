// SPDX-License-Identifier: MPL-2.0
//! The sets of programs and files this board's disk holds
//! (`src/disk/build.zig`'s `Set`), which the build reads; `-Dsets=` names
//! others for one build.
//!
//! The base system and no more: the board boots into a shell, in
//! English, drawn in the ROM's fonts. Everything else - the fonts, the
//! desktop, the network, cards and sticks, USB, sound, the languages -
//! is built for the chip all the same, and is the developer's to add:
//! `-Dsets=` for the flash, or installed apart from it.

pub const sets = "base";

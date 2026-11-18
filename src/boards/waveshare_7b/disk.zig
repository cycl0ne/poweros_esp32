// SPDX-License-Identifier: MPL-2.0
//! The sets of programs and files this board's disk holds
//! (`src/disk/build.zig`'s `Set`), which the build reads; `-Dsets=` names
//! others for one build.
//!
//! What the board starts with and no more: the shell, the network over
//! the chip's radio, cards and sticks, and USB. The desktop, sound, the
//! languages besides English and the rest go onto the card in the slot
//! as packages; the flash holds what boots the board and fetches them.

pub const sets = "base,net,wifi,storage,usb";

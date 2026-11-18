// SPDX-License-Identifier: MPL-2.0
//! The sets of programs and files this board's disk holds
//! (`src/disk/build.zig`'s `Set`), which the build reads; `-Dsets=` names
//! others for one build.
//!
//! The image the test programs are run from, and the ESP32-S3's desktop
//! with them: everything but the radio, which the emulated machine has no
//! part for, what draws in three dimensions, and - for the flash to hold
//! the desktop beside the test programs - sound and film, the languages
//! besides English, and Git.

pub const sets = "base,gui,net,storage,usb,modbus,commodities,tests";

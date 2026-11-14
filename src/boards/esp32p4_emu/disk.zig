// SPDX-License-Identifier: MPL-2.0
//! The sets of programs and files this board's disk holds
//! (`src/disk/build.zig`'s `Set`), which the build reads; `-Dsets=` names
//! others for one build.
//!
//! Everything but the radio's drivers, which the emulated machine has no
//! port for, and what draws in three dimensions, which it has no screen
//! for: this is the image the ESP32-P4's test programs are run from.

pub const sets = "base,gui,net,media,storage,usb,modbus,commodities,dev,tests";

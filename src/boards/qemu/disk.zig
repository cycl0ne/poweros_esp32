// SPDX-License-Identifier: MPL-2.0
//! The sets of programs and files this board's disk holds
//! (`src/disk/build.zig`'s `Set`), which the build reads; `-Dsets=` names
//! others for one build.
//!
//! Everything but what the emulated machine has no part for - the radio -
//! and what draws in three dimensions: this is the image the test
//! programs are run from.

pub const sets = "base,gui,net,media,storage,usb,modbus,commodities,dev,tests";

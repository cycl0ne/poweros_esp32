// SPDX-License-Identifier: MPL-2.0
//! The sets of programs and files this board's disk holds
//! (`src/disk/build.zig`'s `Set`), which the build reads; `-Dsets=` names
//! others for one build.
//!
//! The image the test programs are run from: everything but the radio,
//! which the emulated machine has no part for, what draws in three
//! dimensions, and Git, which the flash has no room for beside the test
//! programs.

pub const sets = "base,gui,net,media,storage,usb,modbus,commodities,tests";

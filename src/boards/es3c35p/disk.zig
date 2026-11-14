// SPDX-License-Identifier: MPL-2.0
//! The sets of programs and files this board's disk holds
//! (`src/disk/build.zig`'s `Set`), which the build reads; `-Dsets=` names
//! others for one build.
//!
//! The desktop, the network over the chip's radio, sound, cards and sticks,
//! and Modbus over the network. The test programs and the developer's
//! tools are left off: they are run from an emulator's image.

pub const sets = "base,gui,net,wifi,media,storage,usb,modbus,commodities";

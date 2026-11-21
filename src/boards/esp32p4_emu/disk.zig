// SPDX-License-Identifier: MPL-2.0
//! The sets of programs and files this board's disk holds
//! (`src/disk/build.zig`'s `Set`), which the build reads; `-Dsets=` names
//! others for one build.
//!
//! The base system and no more, as on the boards: the emulated machine
//! boots into a shell, in English, drawn in the ROM's fonts. A build
//! that runs the test programs names them for itself
//! (`-Dsets=base,tests`).

pub const sets = "base";

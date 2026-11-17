// SPDX-License-Identifier: MPL-2.0
//! The sets of programs and files this board's disk holds
//! (`src/disk/build.zig`'s `Set`), which the build reads; `-Dsets=` names
//! others for one build.
//!
//! Every set: this machine's disk is in RAM or on a medium with room for
//! all of them.

pub const sets = "all";

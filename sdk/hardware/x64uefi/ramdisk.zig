// SPDX-License-Identifier: MIT
//! The disk image the stub read off the boot partition and left in RAM,
//! which flash.device serves as its chip: where it is and how many bytes,
//! 0 if there is none. The kernel sets it from the handover as it starts,
//! and keeps it out of exec's memory.

pub var base: usize = 0;
pub var size: usize = 0;

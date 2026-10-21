// SPDX-License-Identifier: MIT
//! The disk image the loader put in RAM beside the kernel - QEMU's
//! -initrd, the Pi firmware's initramfs - which flash.device serves as
//! its chip: where it is and how many bytes, 0 if there is none. The
//! kernel sets it from the device tree as it starts, and keeps it out of
//! exec's memory.

pub var base: usize = 0;
pub var size: usize = 0;

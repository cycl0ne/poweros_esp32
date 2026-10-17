// SPDX-License-Identifier: MPL-2.0
//! The other cores: none yet. The firmware keeps every hart but the boot
//! hart stopped (SBI HSM), and starting one is `sbi.hartStart` with
//! where it goes and its stack; that comes with the kernel's second core.

/// How many cores the kernel was built to run on; the kernel sets it.
pub var cores: u32 = 1;

/// Whether core 1 is running: not yet.
pub fn isUp() bool {
    return false;
}

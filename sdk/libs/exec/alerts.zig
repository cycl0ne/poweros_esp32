// SPDX-License-Identifier: MIT
//! Alert numbers (exec/alerts.h).

/// Alert types: dead end (the system can't go on) or recoverable.
pub const AT_DeadEnd: u32 = 0x8000_0000;
pub const AT_Recovery: u32 = 0x0000_0000;
/// CPU exception alerts (ACPU_*) are AT_DeadEnd | exception number, the
/// number being the Xtensa EXCCAUSE.
pub const ACPU_Base: u32 = AT_DeadEnd;
/// Released a semaphore that the task does not hold.
pub const AN_SemCorrupt: u32 = 0x0100_0008;
/// A Zig panic in the kernel (exec.kernelPanic), past exec's other codes,
/// which end at 0x0100000F.
pub const AN_KernelPanic: u32 = 0x0100_0100;
/// General alert: a library could not be made.
pub const AG_MakeLib: u32 = 0x0002_0000;

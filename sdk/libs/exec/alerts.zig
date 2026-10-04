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
/// A task's stack ran past its end: its guard at the bottom was written
/// over, or its stack pointer is outside it.
pub const AN_StackProbe: u32 = 0x0100_000E;
/// A Zig panic in the kernel (exec.kernelPanic), past exec's other codes,
/// which end at 0x0100000F.
pub const AN_KernelPanic: u32 = 0x0100_0100;
/// A Zig panic in a program, library, device or handler loaded from disk
/// (the SDK's panic handler, `sdk.exec.panic`).
pub const AN_ProgramPanic: u32 = 0x0100_0101;
/// A spinlock's rule broken (sdk/libs/exec/locks.zig): taken out of the
/// lock order, a plain one taken in an interrupt, Wait called while one
/// is held, or one released that the core does not hold. The text names
/// the locks.
pub const AN_LockRule: u32 = 0x0100_0102;
/// A spinlock taken again on the core that holds it: it would spin for
/// good.
pub const AN_LockDeadlock: u32 = AT_DeadEnd | 0x0100_0103;
/// General alert: a library could not be made.
pub const AG_MakeLib: u32 = 0x0002_0000;

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
/// FreeMem given a block that is not in use: freed already, or its
/// MemBlock written over. The block is left as it is.
pub const AN_FreeTwice: u32 = 0x0100_0009;
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
/// lock order, a plain one taken in an interrupt, or one released that the
/// core does not hold. The text names the locks. Wait called while one is
/// held comes with `AT_DeadEnd`: the machine cannot go on from it.
pub const AN_LockRule: u32 = 0x0100_0102;
/// A spinlock taken again on the core that holds it: it would spin for
/// good.
pub const AN_LockDeadlock: u32 = AT_DeadEnd | 0x0100_0103;
/// FreeMem told a size that is not the block's. The block is left
/// allocated: freeing either size could give away memory still in use.
pub const AN_BadFreeSize: u32 = 0x0100_0104;
/// FreeMem found a block's wall written over: the block's owner wrote
/// past its end (memory debugging, `s3> memdebug`). The block is freed all
/// the same: its MemBlock is whole.
pub const AN_MemWall: u32 = 0x0100_0105;
/// General alert: a library could not be made.
pub const AG_MakeLib: u32 = 0x0002_0000;

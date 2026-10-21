// SPDX-License-Identifier: MIT
//! The PSCI firmware's calls, as the Power State Coordination Interface
//! (Arm DEN 0022) has them and the SMC Calling Convention carries them:
//! the function's id in x0, the arguments in x1 to x3, the answer in x0.
//! Which instruction reaches the firmware is the device tree's (`/psci`'s
//! `method`): SMC where it runs at EL3 (the Pi's Trusted Firmware, QEMU
//! with `virtualization=on`), HVC where it stands in for a hypervisor
//! (QEMU without EL2). The kernel sets `conduit` before the first call.

pub const Conduit = enum { hvc, smc };

/// How the firmware is reached.
pub var conduit: Conduit = .hvc;

/// The functions, by id: the 64-bit ones where an argument is an address.
pub const VERSION: u32 = 0x8400_0000;
pub const CPU_OFF: u32 = 0x8400_0002;
pub const CPU_ON: u32 = 0xC400_0003;
pub const AFFINITY_INFO: u32 = 0xC400_0004;
pub const SYSTEM_OFF: u32 = 0x8400_0008;
pub const SYSTEM_RESET: u32 = 0x8400_0009;

/// What a call answers.
pub const SUCCESS: i64 = 0;
pub const NOT_SUPPORTED: i64 = -1;
pub const INVALID_PARAMETERS: i64 = -2;
pub const DENIED: i64 = -3;
pub const ALREADY_ON: i64 = -4;
pub const ON_PENDING: i64 = -5;
pub const INTERNAL_FAILURE: i64 = -6;
pub const NOT_PRESENT: i64 = -7;
pub const DISABLED: i64 = -8;
pub const INVALID_ADDRESS: i64 = -9;

/// The call itself. The firmware may change x0 to x17 (SMCCC 1.0).
pub fn call(function: u32, arg1: u64, arg2: u64, arg3: u64) i64 {
    return switch (conduit) {
        .hvc => asm volatile ("hvc #0"
            : [ret] "={x0}" (-> i64),
            : [fid] "{x0}" (@as(u64, function)),
              [a1] "{x1}" (arg1),
              [a2] "{x2}" (arg2),
              [a3] "{x3}" (arg3),
            : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true }),
        .smc => asm volatile ("smc #0"
            : [ret] "={x0}" (-> i64),
            : [fid] "{x0}" (@as(u64, function)),
              [a1] "{x1}" (arg1),
              [a2] "{x2}" (arg2),
              [a3] "{x3}" (arg3),
            : .{ .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true }),
    };
}

/// The specification's version the firmware implements: major in bits
/// 16-31, minor in 0-15.
pub fn version() u32 {
    return @truncate(@as(u64, @bitCast(call(VERSION, 0, 0, 0))));
}

/// The core whose MPIDR affinity is `mpidr` started at `entry`, at the
/// exception level the firmware starts cores in (EL2 or EL1), its MMU
/// and caches off, x0 `context`.
pub fn cpuOn(mpidr: u64, entry: u64, context: u64) i64 {
    return call(CPU_ON, mpidr, entry, context);
}

/// This core stopped; answers only if the firmware refused.
pub fn cpuOff() i64 {
    return call(CPU_OFF, 0, 0, 0);
}

/// Where the core `mpidr` is: 0 on, 1 off, 2 on its way.
pub fn affinityInfo(mpidr: u64) i64 {
    return call(AFFINITY_INFO, mpidr, 0, 0);
}

/// The machine off, or reset; neither answers unless the firmware
/// refused.
pub fn systemOff() void {
    _ = call(SYSTEM_OFF, 0, 0, 0);
}

pub fn systemReset() void {
    _ = call(SYSTEM_RESET, 0, 0, 0);
}

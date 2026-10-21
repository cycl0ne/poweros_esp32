// SPDX-License-Identifier: MIT
//! An AArch64 machine run at EL1 under PSCI firmware, as one chip: QEMU's
//! `virt` with Cortex-A76 cores, and the Raspberry Pi CM5's BCM2712. Both
//! give the kernel the same view: the cores' generic timer, a GICv2
//! interrupt controller (the BCM2712's GIC-400), a PL011 console, the
//! PSCI calls for the cores' start and stop and the machine's reset, and
//! a device tree that says where RAM is.
//!
//! What differs between them - where the GIC and the console are, the
//! console's clock and interrupt, which call the firmware answers (HVC or
//! SMC), the memory - is the board's: the kernel sets it here as it
//! starts (`uart.console`, `gic.dist_base`, `psci.conduit`, `ramdisk`),
//! before anything uses it.

pub const intbits = @import("intbits.zig");
pub const mmio = @import("mmio.zig");
pub const map = @import("map.zig");
pub const system = @import("system.zig");
pub const uart = @import("uart.zig");
pub const cpu = @import("cpu.zig");
pub const psci = @import("psci.zig");
pub const gic = @import("gic.zig");
pub const systimer = @import("systimer.zig");
pub const ramdisk = @import("ramdisk.zig");
pub const rng = @import("rng.zig");

/// A data cache line, in bytes: the Cortex-A76's, and QEMU's as CTR_EL0
/// reports it. The kernel checks it against CTR_EL0 as it starts.
pub const DCACHE_LINE_SIZE = 64;

// SPDX-License-Identifier: MIT
//! A RISC-V 64 machine run in supervisor mode under SBI firmware
//! (OpenSBI), as one chip: QEMU's `virt` and the StarFive JH7110 of the
//! VisionFive 2. The two put the platform interrupt controller (PLIC) and
//! the first UART, a 16550, at the same addresses, and give supervisor
//! mode the same view: the SBI calls for the timer, the other harts'
//! interrupts and their start, no machine-mode register and no CLINT.
//!
//! What differs between them - how the console's registers are spaced and
//! read, its clock and interrupt, which PLIC context is which hart's, the
//! timer's rate, the memory - is the board's: the kernel sets it here as
//! it starts (`uart.console`, `plic.contexts`, `ramdisk`), before anything
//! uses it.

pub const intbits = @import("intbits.zig");
pub const mmio = @import("mmio.zig");
pub const map = @import("map.zig");
pub const system = @import("system.zig");
pub const uart = @import("uart.zig");
pub const cpu = @import("cpu.zig");
pub const sbi = @import("sbi.zig");
pub const plic = @import("plic.zig");
pub const systimer = @import("systimer.zig");
pub const ramdisk = @import("ramdisk.zig");
pub const rng = @import("rng.zig");
pub const trng = @import("trng.zig");
pub const ccache = @import("ccache.zig");

/// A data cache line, in bytes: the U74's, and QEMU's as it reports one.
pub const DCACHE_LINE_SIZE = 64;

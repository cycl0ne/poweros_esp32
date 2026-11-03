// SPDX-License-Identifier: MIT
//! An x86-64 machine started by UEFI firmware, as one chip: QEMU's q35,
//! and a PC. What the kernel sees of either is the same: the core's
//! timestamp counter as the clock, a local interrupt controller per core
//! with the machine's I/O controller in front of it, a 16550 console in
//! the I/O port space, the firmware's tables where the other chips have a
//! device tree, and whatever is behind the PCI bridge.
//!
//! What differs from machine to machine - where the controllers are, where
//! the console is, how much memory there is and where, how many cores - is
//! not written here: the stub gathers it from the firmware and the kernel
//! sets it as it starts (`uart.console`, `systimer.timebase_hz`,
//! `ramdisk`, `system.firmware_reset`), from the handover and the board's
//! description. Almost nothing about this machine is fixed, which is why
//! `map.zig` is as short as it is.

pub const intbits = @import("intbits.zig");
pub const mmio = @import("mmio.zig");
pub const map = @import("map.zig");
pub const system = @import("system.zig");
pub const uart = @import("uart.zig");
pub const cpu = @import("cpu.zig");
pub const systimer = @import("systimer.zig");
pub const ramdisk = @import("ramdisk.zig");
pub const rng = @import("rng.zig");

/// A data cache line, in bytes. The architecture keeps the cores' caches
/// and the devices' view of memory the same, so nothing in the system has
/// to write a line back or drop one; this is here because the other chips
/// have it, and because a copy loop that knows the line's width is kinder
/// to the cache than one that does not.
pub const DCACHE_LINE_SIZE = 64;

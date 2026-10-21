// SPDX-License-Identifier: MIT
//! The generic interrupt controller, version 2 (Arm IHI 0048B; the
//! BCM2712's GIC-400, QEMU's `gic-version=2`), by its registers: the
//! distributor, one for the machine, with an enable bit, a priority, a
//! target and a trigger per interrupt ID; and a CPU interface per core,
//! banked at one address, which answers the highest pending interrupt
//! (IAR) and is told when it is done (EOIR).
//!
//! IDs 0 to 15 are the software-generated interrupts (SGIs) one core
//! raises on others (SGIR), 16 to 31 each core's own (PPIs: its timers),
//! whose registers each core sees banked; 32 up are shared (SPIs), the
//! devices'. Under firmware with the security extensions (the Pi's) the
//! kernel sees the non-secure view, where the bits it writes are the same.
//!
//! Where the two blocks are is the board's; the kernel sets them before
//! anything uses them.

const map = @import("map.zig");
const reg = @import("mmio.zig").reg;
const reg8 = @import("mmio.zig").reg8;

pub var dist_base: usize = map.GICD;
pub var cpu_base: usize = map.GICC;

// The distributor's registers.
pub const GICD_CTLR = 0x000;
pub const GICD_TYPER = 0x004;
pub const GICD_ISENABLER = 0x100;
pub const GICD_ICENABLER = 0x180;
pub const GICD_ISPENDR = 0x200;
pub const GICD_ICPENDR = 0x280;
pub const GICD_ICACTIVER = 0x380;
pub const GICD_IPRIORITYR = 0x400;
pub const GICD_ITARGETSR = 0x800;
pub const GICD_ICFGR = 0xC00;
pub const GICD_SGIR = 0xF00;

// The CPU interface's.
pub const GICC_CTLR = 0x000;
pub const GICC_PMR = 0x004;
pub const GICC_BPR = 0x008;
pub const GICC_IAR = 0x00C;
pub const GICC_EOIR = 0x010;

/// GICD_CTLR, GICC_CTLR: on (group 1's bit in the non-secure view, the
/// only group's without the security extensions).
pub const CTLR_ENABLE: u32 = 1 << 0;

/// What IAR answers when nothing is pending.
pub const SPURIOUS: u32 = 1023;
/// IAR: the interrupt ID, and for an SGI the core that raised it, which
/// EOIR wants back as it was.
pub const IAR_ID: u32 = 0x3FF;

/// SGIR's filter: the cores in the target list, or only the one writing.
pub const SGIR_TO_LIST: u32 = 0b00 << 24;
pub const SGIR_TO_SELF: u32 = 0b10 << 24;

fn dist(offset: usize) *volatile u32 {
    return reg(dist_base + offset);
}

fn cpuReg(offset: usize) *volatile u32 {
    return reg(cpu_base + offset);
}

/// How many interrupt IDs the distributor has: 32 per ITLinesNumber + 1.
pub fn lines() u32 {
    return 32 * ((dist(GICD_TYPER).* & 0x1F) + 1);
}

pub fn setDistributor(on: bool) void {
    dist(GICD_CTLR).* = if (on) CTLR_ENABLE else 0;
}

/// `id` let through to the cores, or held back.
pub fn setEnabled(id: u32, on: bool) void {
    const word = 4 * @as(usize, id / 32);
    const bit = @as(u32, 1) << @intCast(id % 32);
    const offset: usize = if (on) GICD_ISENABLER else GICD_ICENABLER;
    dist(offset + word).* = bit;
}

pub fn isEnabled(id: u32) bool {
    return dist(GICD_ISENABLER + 4 * @as(usize, id / 32)).* & (@as(u32, 1) << @intCast(id % 32)) != 0;
}

/// `id`'s pending state cleared.
pub fn clearPending(id: u32) void {
    dist(GICD_ICPENDR + 4 * @as(usize, id / 32)).* = @as(u32, 1) << @intCast(id % 32);
}

/// `id`'s active state cleared.
pub fn clearActive(id: u32) void {
    dist(GICD_ICACTIVER + 4 * @as(usize, id / 32)).* = @as(u32, 1) << @intCast(id % 32);
}

/// `id`'s priority: lower is more urgent; the non-secure view keeps the
/// upper bits.
pub fn setPriority(id: u32, priority: u8) void {
    reg8(dist_base + GICD_IPRIORITYR + id).* = priority;
}

/// The CPU interfaces a shared interrupt goes to, a bit each.
pub fn setTargets(id: u32, interfaces: u8) void {
    reg8(dist_base + GICD_ITARGETSR + id).* = interfaces;
}

/// The bit of the CPU interface of the core this runs on: what the
/// banked ITARGETSR of its first SGIs reads. Not the core's number.
pub fn ownInterface() u8 {
    const word = dist(GICD_ITARGETSR).*;
    return @truncate(word | word >> 8 | word >> 16 | word >> 24);
}

/// `id` taken on its edge rather than its level.
pub fn setEdge(id: u32, edge: bool) void {
    const cell = dist(GICD_ICFGR + 4 * @as(usize, id / 16));
    const bit = @as(u32, 2) << @intCast(2 * (id % 16));
    if (edge) cell.* |= bit else cell.* &= ~bit;
}

/// SGI `id` raised on the cores whose interfaces are set in `targets`.
pub fn raiseSgi(id: u32, targets: u8) void {
    dist(GICD_SGIR).* = SGIR_TO_LIST | @as(u32, targets) << 16 | id;
}

/// SGI `id` raised on the core this runs on.
pub fn raiseSgiSelf(id: u32) void {
    dist(GICD_SGIR).* = SGIR_TO_SELF | id;
}

/// This core's CPU interface on, letting through what is more urgent than
/// `mask`.
pub fn cpuInterfaceOn(mask: u8) void {
    cpuReg(GICC_PMR).* = mask;
    cpuReg(GICC_BPR).* = 0;
    cpuReg(GICC_CTLR).* = CTLR_ENABLE;
}

/// The highest pending interrupt, acknowledged: its IAR, whose ID is
/// SPURIOUS when nothing is.
pub fn acknowledge() u32 {
    return cpuReg(GICC_IAR).*;
}

/// The interrupt `iar` acknowledged is done with.
pub fn endOfInterrupt(iar: u32) void {
    cpuReg(GICC_EOIR).* = iar;
}

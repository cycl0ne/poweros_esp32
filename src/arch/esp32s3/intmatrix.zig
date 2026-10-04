// SPDX-License-Identifier: MPL-2.0
//! The ESP32-S3 interrupt matrix as exec's interrupt hardware. An exec
//! interrupt number is a peripheral interrupt source (0-98), routed to one
//! of the CPU's twelve level-1 lines.
//!
//! A source gets a line of its own while there is one free, so the CPU
//! says exactly which source fired. When none is, a source that has only
//! servers joins the line with fewest sources that also has only servers,
//! and when that line fires every source on it has its chain run: a server
//! looks at its own hardware and answers "not mine" when it is idle, which
//! is what a chain is for. So twelve lines carry any number of servers.
//! A source with a handler (SetIntVector) keeps a line to itself, since a
//! handler need not check. The matrix's own status registers would say
//! which source it was, but QEMU does not emulate them, so a shared line
//! asks every chain instead.
//!
//! Every device source goes to core 0. Each core has a matrix of its own
//! (core 1's 0x800 above core 0's), and core 1's routes nothing but its
//! cross-core interrupt: line 18 on both cores is kept for that, the
//! source `FROM_CPU_INTR<n>` raising it on core n (`raiseCrossCore`).
//! A core's own lines are enabled only from that core, so core 0's device
//! lines are all enabled once at init, routed or not - a line nothing is
//! routed to never fires - and adding a source from either core is then a
//! write to the matrix alone.

const cpu = @import("cpu.zig");
const intbits = @import("sdk").hardware.intbits;
const exec = @import("../../rom/libs/exec/exec.zig");
const reg = @import("sdk").hardware.mmio.reg;
const trap = @import("trap.zig");
const rendezvous = @import("rendezvous.zig");

/// INTERRUPT_CORE0: one map register per source, holding its CPU line;
/// core 1's the same, 0x800 above.
const matrix = @import("sdk").hardware.map.INTERRUPT_MATRIX;
const core1_matrix = matrix + 0x800;
const system = @import("sdk").hardware.system;
/// How many sources the matrix routes.
const source_count = 99;
/// Routing a source to the CPU's internal timer line disconnects it
/// (ESP-IDF's ETS_INVALID_INUM).
const disconnected = 6;

/// The CPU's level-1, level-triggered external lines for devices.
const lines = [_]u5{ 0, 1, 2, 3, 4, 5, 8, 9, 12, 13, 17 };
/// The line the cross-core interrupt comes in on, on either core.
pub const cross_core_line: u5 = 18;
/// The most sources one line carries.
const per_line = 8;
/// The sources on each CPU line, and whether one of them has a handler
/// and so keeps the line to itself.
var line_sources: [32][per_line]u32 = undefined;
var line_count: [32]u8 = @splat(0);
var line_exclusive: [32]bool = @splat(false);

pub const hardware: exec.InterruptHardware = .{
    .enable_source = enableSource,
    .disable_source = disableSource,
    .disable = disable,
    .restore = restore,
    .cause_softint = causeSoftInt,
    .hold_others = rendezvous.holdOther,
    .release_others = rendezvous.releaseOther,
    .park_if_asked = rendezvous.parkIfAsked,
    .poke_core = raiseCrossCore,
};

/// Hook the CPU's software interrupt line up to exec's software interrupts,
/// core 0's cross-core interrupt to its line, and every device line to
/// its dispatch, enabled.
pub fn init() void {
    for (0..source_count) |source| reg(matrix + 4 * source).* = disconnected;
    trap.setHandler(trap.software_line, onSoftInt);
    cpu.enableInterrupt(trap.software_line);
    for (lines) |line| {
        trap.setHandler(line, onLine);
        cpu.enableInterrupt(line);
    }
    routeCrossCore(matrix, 0);
}

/// Core 1's matrix and lines, on core 1: every source disconnected but
/// its cross-core interrupt, and the software interrupt line.
pub fn initCore1() void {
    for (0..source_count) |source| reg(core1_matrix + 4 * source).* = disconnected;
    trap.setHandler(trap.software_line, onSoftInt);
    cpu.enableInterrupt(trap.software_line);
    routeCrossCore(core1_matrix, 1);
}

fn routeCrossCore(core_matrix: usize, core: u32) void {
    const source = intbits.INTB_FROM_CPU_INTR0 + core;
    trap.setHandler(cross_core_line, onCrossCore);
    reg(core_matrix + 4 * @as(usize, source)).* = cross_core_line;
    cpu.enableInterrupt(cross_core_line);
}

/// Each core counts its cross-core interrupts.
pub var cross_core_count: [2]u32 = @splat(0);

/// The cross-core interrupt raised on `core`.
pub fn raiseCrossCore(core: u32) void {
    reg(system.CPU_INTR_FROM_CPU_0 + 4 * @as(usize, core)).* = 1;
}

fn onCrossCore(_: u5) void {
    const core = cpu.coreId();
    reg(system.CPU_INTR_FROM_CPU_0 + 4 * @as(usize, core)).* = 0;
    cross_core_count[core] +%= 1;
    // Held by the other core: parked until it lets go.
    rendezvous.parkIfAsked();
    // Otherwise poked: the dispatcher looks again at the exit.
    if (exec.initialized) exec.crossCorePoke(exec.SysBase);
}

fn causeSoftInt() void {
    cpu.setIntset(@as(u32, 1) << trap.software_line);
}

fn onSoftInt(_: u5) void {
    // Clear first: a Cause while the queues run raises it again.
    cpu.setIntclear(@as(u32, 1) << trap.software_line);
    exec.dispatchSoftInts(exec.SysBase);
}

fn enableSource(source: u32, shareable: bool) bool {
    // A line of its own, while there is one.
    for (lines) |line| {
        if (line_count[line] != 0) continue;
        line_sources[line][0] = source;
        line_count[line] = 1;
        line_exclusive[line] = !shareable;
        reg(matrix + 4 * @as(usize, source)).* = line;
        return true;
    }
    if (!shareable) return false;
    // Otherwise the least crowded line of servers.
    var best: ?u5 = null;
    for (lines) |line| {
        if (line_exclusive[line] or line_count[line] >= per_line) continue;
        if (best == null or line_count[line] < line_count[best.?]) best = line;
    }
    const line = best orelse return false;
    line_sources[line][line_count[line]] = source;
    line_count[line] += 1;
    reg(matrix + 4 * @as(usize, source)).* = line;
    return true;
}

fn disableSource(source: u32) void {
    const line = lineOf(source) orelse return;
    reg(matrix + 4 * @as(usize, source)).* = disconnected;
    const n = line_count[line];
    for (0..n) |i| {
        if (line_sources[line][i] != source) continue;
        line_sources[line][i] = line_sources[line][n - 1];
        line_count[line] = n - 1;
        break;
    }
    if (line_count[line] == 0) line_exclusive[line] = false;
}

/// Every source on the line, its chain run in turn. Counted before the
/// loop, since a server may remove itself.
fn onLine(line: u5) void {
    const n = line_count[line];
    var copy: [per_line]u32 = undefined;
    for (0..n) |i| copy[i] = line_sources[line][i];
    for (copy[0..n]) |source| exec.dispatchInterrupt(exec.SysBase, source);
}

/// Disable: mask levels 1-3 (all interrupts the kernel uses).
fn disable() u32 {
    return cpu.setIntlevel(3);
}

fn restore(state: u32) void {
    cpu.restorePs(state);
}

/// CPU line `source` is routed to, if any.
pub fn lineOf(source: u32) ?u5 {
    for (lines) |line| {
        for (line_sources[line][0..line_count[line]]) |s| {
            if (s == source) return line;
        }
    }
    return null;
}

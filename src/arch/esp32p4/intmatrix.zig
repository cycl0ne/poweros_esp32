// SPDX-License-Identifier: MPL-2.0
//! The ESP32-P4's interrupt controller (CLIC) and interrupt matrix as
//! exec's interrupt hardware. An exec interrupt number is a peripheral
//! interrupt source (0-127); the matrix routes it to one of the CLIC's
//! lines on one core, and the line comes to the trap entry with its number
//! in mcause.
//!
//! Each core has a CLIC of its own - the same addresses on each core, the
//! other core's 0x10000 above - and a matrix of its own (core 1's 0x800
//! above core 0's). Lines 16 to 47 are the matrix's; this kernel takes 16
//! for the software interrupt (exec's Cause), 17 for the cross-core
//! interrupt and 18 for the tick, on each core, and 19 to 47 for device
//! sources on core 0. Every line is at one level, level-triggered and not
//! hardware-vectored, so all of them come to the one trap entry, and
//! masking mstatus.MIE holds all of them off.
//!
//! A source gets a line of its own while there is one free, so the line
//! says exactly which source fired. When none is, a source that has only
//! servers joins the line with fewest sources that also has only servers,
//! and when that line fires every source on it has its chain run: a server
//! looks at its own hardware and answers "not mine" when it is idle. A
//! source with a handler (SetIntVector) keeps a line to itself.
//!
//! The software interrupt and the cross-core interrupt are the matrix's
//! FROM_CPU sources, raised by a register of HP_SYSTEM: FROM_CPU_INTR<n>
//! is the cross-core interrupt of core n, FROM_CPU_INTR<2 + n> core n's
//! software interrupt.

const cpu = @import("cpu.zig");
const hardware = @import("sdk").hardware;
const intbits = hardware.intbits;
const exec = @import("../../rom/libs/exec/exec.zig");
const reg = hardware.mmio.reg;
const trap = @import("trap.zig");
const rendezvous = @import("rendezvous.zig");

/// The matrix: one map register per source, holding its CLIC line, 0 for
/// none; core 1's 0x800 above core 0's.
const core0_matrix = hardware.map.INTERRUPT_CORE0;
const core1_matrix = hardware.map.INTERRUPT_CORE1;
const disconnected = 0;

/// This core's CLIC: the threshold register, and a control word per line -
/// pending (bits 0-7), enabled (8-15), attributes (16-23) and level
/// (24-31).
const clic_base: usize = 0x2080_0000;
const clic_threshold = clic_base + 0x8;
const clic_control = clic_base + 0x1000;
/// ATTR: machine mode, level-triggered, not hardware-vectored.
const attr_machine: u32 = 0xC0 << 16;
/// CTL: level 1 of 8 (the top three bits), the rest set as the CLIC asks.
const level_one: u32 = 0x3F << 24;
const enabled: u32 = 1 << 8;

/// The device lines, core 0's.
const device_lines = blk: {
    var lines: [trap.line_count - trap.first_device_line]u6 = undefined;
    for (&lines, 0..) |*line, index| line.* = trap.first_device_line + index;
    break :blk lines;
};

/// The most sources one line carries.
const per_line = 8;
/// The sources on each line, and whether one of them has a handler and so
/// keeps the line to itself.
var line_sources: [trap.line_count][per_line]u32 = undefined;
var line_count: [trap.line_count]u8 = @splat(0);
var line_exclusive: [trap.line_count]bool = @splat(false);

/// HP_SYSTEM's CPU_INT_FROM_CPU_0..3: writing 1 raises the source, 0
/// lowers it.
const from_cpu = hardware.map.HP_SYS + 0x10;

pub const interrupt_hardware: exec.InterruptHardware = .{
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

/// Core 0's CLIC and matrix: every source disconnected, every line at one
/// level and off, then the software, cross-core and device lines on - a
/// line nothing is routed to never fires, so routing a source later is a
/// write to the matrix alone, from either core.
pub fn init() void {
    initCore(core0_matrix);
    for (device_lines) |line| {
        trap.setHandler(line, onLine);
        enableLine(line);
    }
}

/// Core 1's, on core 1: its software and cross-core lines only.
pub fn initCore1() void {
    initCore(core1_matrix);
}

fn initCore(matrix: usize) void {
    for (0..intbits.INTB_COUNT) |source| reg(matrix + 4 * source).* = disconnected;
    reg(clic_threshold).* = 0;
    for (16..trap.line_count) |line| reg(clic_control + 4 * line).* = level_one | attr_machine;
    const core = cpu.coreId();
    trap.setHandler(trap.software_line, onSoftInt);
    reg(matrix + 4 * @as(usize, intbits.INTB_FROM_CPU_INTR2 + core)).* = trap.software_line;
    enableLine(trap.software_line);
    trap.setHandler(trap.cross_core_line, onCrossCore);
    reg(matrix + 4 * @as(usize, intbits.INTB_FROM_CPU_INTR0 + core)).* = trap.cross_core_line;
    enableLine(trap.cross_core_line);
}

/// `line` of this core taken.
pub fn enableLine(line: u6) void {
    reg(clic_control + 4 * @as(usize, line)).* = level_one | attr_machine | enabled;
}

/// `line` of this core no longer taken.
pub fn disableLine(line: u6) void {
    reg(clic_control + 4 * @as(usize, line)).* = level_one | attr_machine;
}

/// `source` routed to `line` of core `core`.
pub fn route(core: u32, source: u32, line: u6) void {
    const matrix = if (core == 0) core0_matrix else core1_matrix;
    reg(matrix + 4 * @as(usize, source)).* = line;
}

/// Each core counts its cross-core interrupts.
pub var cross_core_count: [2]u32 = @splat(0);

/// The cross-core interrupt raised on `core`.
pub fn raiseCrossCore(core: u32) void {
    reg(from_cpu + 4 * @as(usize, core)).* = 1;
}

fn onCrossCore(_: u6) void {
    const core = cpu.coreId();
    reg(from_cpu + 4 * @as(usize, core)).* = 0;
    cross_core_count[core] +%= 1;
    // Held by the other core: parked until it lets go.
    rendezvous.parkIfAsked();
    // Otherwise poked: the dispatcher looks again at the exit.
    if (exec.initialized) exec.crossCorePoke(exec.SysBase);
}

fn causeSoftInt() void {
    reg(from_cpu + 4 * @as(usize, 2 + cpu.coreId())).* = 1;
}

fn onSoftInt(_: u6) void {
    // Lowered first: a Cause while the queues run raises it again.
    reg(from_cpu + 4 * @as(usize, 2 + cpu.coreId())).* = 0;
    exec.dispatchSoftInts(exec.SysBase);
}

fn enableSource(source: u32, shareable: bool) bool {
    // A line of its own, while there is one.
    for (device_lines) |line| {
        if (line_count[line] != 0) continue;
        line_sources[line][0] = source;
        line_count[line] = 1;
        line_exclusive[line] = !shareable;
        route(0, source, line);
        return true;
    }
    if (!shareable) return false;
    // Otherwise the least crowded line of servers.
    var best: ?u6 = null;
    for (device_lines) |line| {
        if (line_exclusive[line] or line_count[line] >= per_line) continue;
        if (best == null or line_count[line] < line_count[best.?]) best = line;
    }
    const line = best orelse return false;
    line_sources[line][line_count[line]] = source;
    line_count[line] += 1;
    route(0, source, line);
    return true;
}

fn disableSource(source: u32) void {
    const line = lineOf(source) orelse return;
    route(0, source, disconnected);
    const count = line_count[line];
    for (0..count) |index| {
        if (line_sources[line][index] != source) continue;
        line_sources[line][index] = line_sources[line][count - 1];
        line_count[line] = count - 1;
        break;
    }
    if (line_count[line] == 0) line_exclusive[line] = false;
}

/// Every source on the line, its chain run in turn. Copied before the
/// loop, since a server may remove itself.
fn onLine(line: u6) void {
    const count = line_count[line];
    var copy: [per_line]u32 = undefined;
    for (0..count) |index| copy[index] = line_sources[line][index];
    for (copy[0..count]) |source| {
        const began = cpu.ccount();
        exec.dispatchInterrupt(exec.SysBase, source);
        source_longest[source] = @max(source_longest[source], cpu.ccount() -% began);
    }
}

/// The longest each device source's chain ran, in cycles.
pub var source_longest: [intbits.INTB_COUNT]u32 = @splat(0);

/// Disable: this core's interrupts masked.
fn disable() u32 {
    return cpu.disableInterrupts();
}

fn restore(state: u32) void {
    cpu.restoreInterrupts(state);
}

/// The line `source` is routed to, if any.
pub fn lineOf(source: u32) ?u6 {
    for (device_lines) |line| {
        for (line_sources[line][0..line_count[line]]) |routed| {
            if (routed == source) return line;
        }
    }
    return null;
}

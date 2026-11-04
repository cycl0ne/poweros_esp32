// SPDX-License-Identifier: MPL-2.0
//! The interrupt controllers as exec's interrupt hardware: the machine's
//! lines for the devices, two vectors of the kernel's own for exec's Cause
//! and for the cross-core interrupt, and each core's own timer for the tick.
//!
//! An exec interrupt source on this machine is one of the machine's
//! interrupt lines, as the firmware's tables number them
//! (`sdk.hardware.intbits`), or one of the messages a PCI function sends
//! above them, or one of the kernel's alarms on the timer after those -
//! which timer.zig raises and nothing here has to switch on.
//!
//! **A source is routed by giving it a vector.** The architecture's 256
//! vectors are the kernel's to hand out: the first 32 are the core's
//! exceptions, the next sixteen the kernel's own, and a source gets the one
//! at `VECTOR_SOURCE_FIRST` + its number. So a vector says which source it
//! is without a search, and a PCI function that is told a vector is told a
//! source. Everything goes to the boot core at one priority, so masking a
//! core's interrupts holds all of them off.
//!
//! **Where a line is taken on its level and where on its edge** is the
//! machine's, not this kernel's: the old lines of a PC are edge-triggered
//! and active high, a line a PCI device shares is level-triggered and
//! active low, and the firmware's tables name the ones that are neither
//! (`line_flags`, which the kernel fills from them).
//!
//! **The old interrupt controllers** are masked off and moved out of the
//! way of the exceptions' vectors before anything else: every line comes
//! through the I/O controller.

const cpu = @import("cpu.zig");
const hardware = @import("sdk").hardware;
const intbits = hardware.intbits;
const apic = hardware.apic;
const exec = @import("../../rom/libs/exec/exec.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const trap = @import("trap.zig");
const rendezvous = @import("rendezvous.zig");

const max_cores = cpu.max_cores;

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

/// The kernel's own vectors, as lines of trap.zig's: the tick, exec's
/// Cause, the poke from another core. The syscall's is trap.zig's own.
pub const LINE_TICK: u6 = 0;
pub const LINE_SOFTINT: u6 = 1;
pub const LINE_CROSS_CORE: u6 = 2;

pub const VECTOR_TICK: u8 = trap.own_first + LINE_TICK;
pub const VECTOR_SOFTINT: u8 = trap.own_first + LINE_SOFTINT;
pub const VECTOR_CROSS_CORE: u8 = trap.own_first + LINE_CROSS_CORE;

/// The first vector a source gets: above the kernel's own.
pub const VECTOR_SOURCE_FIRST: u32 = trap.own_first + trap.line_count;

/// The vector the local controller sends when it has nothing to send, and
/// the one the old controllers are moved to: the top of the range, where
/// no source of ours is.
pub const VECTOR_SPURIOUS: u8 = 0xFF;
const OLD_CONTROLLER_BASE: u8 = 0xF0;

comptime {
    // Every source has a vector of its own below the spurious one.
    if (VECTOR_SOURCE_FIRST + intbits.INTB_SOURCE_COUNT > VECTOR_SPURIOUS) {
        @compileError("more interrupt sources than there are vectors to give them");
    }
}

/// How a line is taken, as the machine has it wired.
pub const LineFlags = struct {
    /// Level-triggered: it stays raised while the device holds it down.
    level: bool,
    /// Active low.
    low_active: bool,
};

/// What the machine's lines are: the old lines of a PC are edge-triggered
/// and active high, everything above them level-triggered and active low
/// (what a PCI device's line is), and the kernel overwrites the ones the
/// firmware's tables name.
pub var line_flags: [intbits.INTB_GSI_COUNT]LineFlags = blk: {
    var flags: [intbits.INTB_GSI_COUNT]LineFlags = undefined;
    for (&flags, 0..) |*line, number| {
        line.* = if (number < 16) .{ .level = false, .low_active = false } else .{ .level = true, .low_active = true };
    }
    break :blk flags;
};

/// Each core's software interrupts, by what they carry.
var softint_pending: [max_cores]u32 = @splat(0);
var cross_core_pending: [max_cores]u32 = @splat(0);

/// Where a PCI function's message goes to reach core `core`: the address
/// the local controllers answer at, with that core's controller in it.
/// The message carries the vector it is to raise as its data
/// (`vectorOf`), so a function told where to write and what to write is
/// told everything - there is no controller input in the way, and nothing
/// to switch on.
pub fn messageAddress(core: u32) usize {
    return apic.lapic_base | (@as(usize, cpu.lapic_ids[core]) << 12);
}

/// The vector of source `source`.
pub fn vectorOf(source: u32) u8 {
    return @intCast(VECTOR_SOURCE_FIRST + source);
}

/// The source vector `vector` was given, or null if it is none of theirs.
pub fn sourceOf(vector: u32) ?u32 {
    if (vector < VECTOR_SOURCE_FIRST) return null;
    const source = vector - VECTOR_SOURCE_FIRST;
    return if (source < intbits.INTB_SOURCE_COUNT) source else null;
}

/// The machine's: the old controllers out of the way and masked, every
/// line of the I/O controllers held back and pointed at the spurious
/// vector, and this core's own controller on.
pub fn init() void {
    apic.oldControllersOff(OLD_CONTROLLER_BASE);
    apic.countIoLines();
    apic.maskAllLines(VECTOR_SPURIOUS);
    initCore();
    trap.source_handler = &onSource;
    trap.end_of_interrupt = &endOfInterrupt;
    trap.spurious_vector = VECTOR_SPURIOUS;
}

/// The controller told that an interrupt is over, as the trap's exit
/// calls it. The part's own call is inline, and a pointer wants a
/// function of its own.
fn endOfInterrupt() void {
    apic.endOfInterrupt();
}

/// Another core's, on that core.
pub fn initCore1() void {
    initCore();
}

/// The core's own: its controller on with every priority let through, and
/// the handlers for the two vectors it raises on itself or another core
/// raises on it.
fn initCore() void {
    apic.localOn(VECTOR_SPURIOUS);
    cpu.takeCore(cpu.coreId(), apic.ownId());
    trap.setHandler(LINE_SOFTINT, onSoftInt);
    trap.setHandler(LINE_CROSS_CORE, onCrossCoreLine);
}

/// Each core counts its cross-core interrupts.
pub var cross_core_count: [max_cores]u32 = @splat(0);

/// The cross-core interrupt raised on `core`: its flag, and the vector to
/// its controller. The flag is out before the vector is - this
/// architecture does not reorder stores, so nothing has to be said about
/// the order beyond writing it this way round.
pub fn raiseCrossCore(core: u32) void {
    @atomicStore(u32, &cross_core_pending[core], 1, .release);
    apic.raise(cpu.lapic_ids[core], VECTOR_CROSS_CORE);
}

fn causeSoftInt() void {
    @atomicStore(u32, &softint_pending[cpu.coreId()], 1, .release);
    apic.raiseSelf(VECTOR_SOFTINT);
}

fn onSoftInt(_: u6) void {
    const core = cpu.coreId();
    if (@atomicRmw(u32, &softint_pending[core], .Xchg, 0, .acquire) != 0) exec.dispatchSoftInts(exec.SysBase);
}

fn onCrossCoreLine(_: u6) void {
    const core = cpu.coreId();
    if (@atomicRmw(u32, &cross_core_pending[core], .Xchg, 0, .acquire) == 0) return;
    cross_core_count[core] +%= 1;
    // Another core changed an alarm: core 0's comparator set again.
    if (core == 0) @import("timer.zig").rethinkIfAsked();
    // Held by the other core: parked until it lets go.
    rendezvous.parkIfAsked();
    // Otherwise poked: the dispatcher looks again at the exit.
    if (exec.initialized) exec.crossCorePoke(exec.SysBase);
}

/// A device's interrupt: the source its vector stands for, and its chain
/// run. A vector no source of ours has is reported once and let go - the
/// old controllers can still send one, masked or not.
fn onSource(vector: u32) void {
    const core = cpu.coreId();
    const source = sourceOf(vector) orelse {
        if (!reported[core]) {
            reported[core] = true;
            exec.kprintf("\n[trap] vector %d on core %d belongs to no source\n", .{ vector, core });
        }
        return;
    };
    trap.last_line[core] = 0;
    dispatch(source);
}

var reported: [max_cores]bool = @splat(false);

/// `source`'s chain run, and how long it took kept.
pub fn dispatch(source: u32) void {
    const began = cpu.ccount();
    exec.dispatchInterrupt(exec.SysBase, source);
    source_longest[source] = @max(source_longest[source], cpu.ccount() -% began);
}

/// The longest each source's chain ran, in cycles.
pub var source_longest: [intbits.INTB_COUNT]u32 = @splat(0);

fn isAlarm(source: u32) bool {
    return source >= intbits.INTB_ALARM0 and source < intbits.INTB_COUNT;
}

fn isLine(source: u32) bool {
    return source < intbits.INTB_GSI_COUNT;
}

fn isMessage(source: u32) bool {
    return source >= intbits.INTB_MSI_FIRST and source < intbits.INTB_SOURCE_COUNT;
}

fn enableSource(source: u32, _: bool) bool {
    if (isAlarm(source)) return true;
    // A message carries its vector: the function that sends it was told
    // which, and there is no controller input to switch on.
    if (isMessage(source)) return true;
    if (!isLine(source)) return false;
    if (apic.inputOf(source) == null) return false;
    const flags = line_flags[source];
    apic.route(source, vectorOf(source), cpu.lapic_ids[0], flags.level, flags.low_active, true);
    return true;
}

fn disableSource(source: u32) void {
    if (!isLine(source)) return;
    apic.setLineEnabled(source, false);
}

/// A source taken on its edge rather than its level, before it is switched
/// on: a message signalled interrupt, and a line the firmware's tables say
/// is one.
pub fn setEdge(source: u32, edge: bool) void {
    if (isLine(source)) line_flags[source].level = !edge;
}

/// Disable: this core's interrupts masked.
fn disable() u32 {
    return cpu.disableInterrupts();
}

fn restore(state: u32) void {
    cpu.restoreInterrupts(state);
}

/// What `source` comes in on, if it is switched on: its vector. There is
/// one vector per source on this machine, so this is the whole answer and
/// not a line several share.
pub fn lineOf(source: u32) ?u8 {
    if (isAlarm(source)) return VECTOR_TICK;
    if (isMessage(source)) return vectorOf(source);
    if (!isLine(source)) return null;
    return if (apic.isLineEnabled(source)) vectorOf(source) else null;
}

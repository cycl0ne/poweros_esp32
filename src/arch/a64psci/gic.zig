// SPDX-License-Identifier: MPL-2.0
//! The GIC as exec's interrupt hardware: the shared interrupts for the
//! devices, two software-generated ones (SGIs) for exec's Cause and for
//! the cross-core interrupt, and each core's virtual timer for the tick.
//!
//! An exec interrupt number is a GIC interrupt ID (32 up, the devices';
//! sdk.hardware.intbits), or one of the kernel's alarms on the generic
//! timer after them, which timer.zig raises and nothing here has to
//! switch on. Every shared interrupt goes to core 0's CPU interface, at
//! one priority, so masking a core's IRQs holds all of them off.
//!
//! **The CPU interface's number is not the core's.** A shared interrupt's
//! target and an SGI's are a bit per CPU interface, and which bit is a
//! core's the GIC says only to that core: each reads its own from the
//! banked target register of its SGIs as it starts (`interfaces`).
//!
//! **An IRQ** acknowledges the highest pending interrupt (IAR), runs what
//! it is for and says it is done (EOIR, with the IAR as it was: an SGI's
//! carries the core that raised it), until nothing is pending. A spurious
//! answer (1023) has no end of its own.
//!
//! SGI 0 is exec's Cause, which a core raises on itself; SGI 1 the
//! cross-core interrupt, which another core raises on it. Each carries a
//! flag of its own per core as well, taken after the SGI is acknowledged,
//! so one raised meanwhile comes again.
//!
//! **A board's interrupt bridge** (`boards.interrupt_bridge`: the CM5's
//! RP1) raises shared interrupts of its own as messages: those are taken
//! on their edge, the bridge is set up once the distributor is on, a
//! source is switched on and off at the bridge as at the GIC, and the
//! bridge is told when a source's servers have run, before the GIC is.

const cpu = @import("cpu.zig");
const hardware = @import("sdk").hardware;
const intbits = hardware.intbits;
const gic = hardware.gic;
const exec = @import("../../rom/libs/exec/exec.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const trap = @import("trap.zig");
const rendezvous = @import("rendezvous.zig");
const boards = @import("../../boards/boards.zig");

const max_cores = exec_base.max_cores;

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

/// The SGIs, by what they carry.
pub const SGI_CAUSE: u32 = 0;
pub const SGI_CROSS_CORE: u32 = 1;

/// The priority every interrupt has, and the mask that lets them through.
const PRIORITY: u8 = 0xA0;
const MASK: u8 = 0xF0;

/// Each core's CPU interface, as its target bit.
pub var interfaces: [max_cores]u8 = @splat(0);

/// Each core's software interrupts, by what they carry.
var softint_pending: [max_cores]u32 = @splat(0);
var cross_core_pending: [max_cores]u32 = @splat(0);

/// Core 0's: the distributor off while every shared interrupt is
/// disabled, cleared, given the one priority and core 0's interface, and
/// taken on its level - the bridge's on their edge; then on again, core
/// 0's own interface on, and the bridge set up.
pub fn init() void {
    const count = @min(gic.lines(), intbits.INTB_GIC_COUNT);
    gic.setDistributor(false);
    var id: u32 = intbits.INTB_SPI_FIRST;
    while (id < count) : (id += 1) {
        gic.setEnabled(id, false);
        gic.clearPending(id);
        gic.clearActive(id);
    }
    initCore();
    id = intbits.INTB_SPI_FIRST;
    while (id < count) : (id += 1) {
        gic.setPriority(id, PRIORITY);
        gic.setTargets(id, interfaces[0]);
        gic.setEdge(id, bridged(id) != null);
    }
    gic.setDistributor(true);
    trap.irq_handler = &onIrq;
    if (boards.interrupt_bridge) |bridge| bridge.init();
}

/// Another core's, on that core.
pub fn initCore1() void {
    initCore();
}

/// The core's own: its interface's bit, its SGIs and its timer's PPI at
/// the one priority, the SGIs on, and its CPU interface on.
fn initCore() void {
    const core = cpu.coreId();
    const own = gic.ownInterface();
    // A GIC with one CPU interface reads none: that one is it.
    interfaces[core] = if (own == 0) 1 else own;
    var id: u32 = 0;
    while (id < intbits.INTB_SPI_FIRST) : (id += 1) gic.setPriority(id, PRIORITY);
    gic.setEnabled(SGI_CAUSE, true);
    gic.setEnabled(SGI_CROSS_CORE, true);
    trap.setHandler(SGI_CAUSE, onSoftware);
    trap.setHandler(SGI_CROSS_CORE, onSoftware);
    gic.cpuInterfaceOn(MASK);
}

/// A core's own interrupt (a PPI: its timer's) on, on the core this runs
/// on.
pub fn enablePrivate(id: u32) void {
    gic.setEnabled(id, true);
}

/// Each core counts its cross-core interrupts.
pub var cross_core_count: [max_cores]u32 = @splat(0);

/// The cross-core interrupt raised on `core`: its flag, and SGI 1 to its
/// interface. The flag is out before the SGI is.
pub fn raiseCrossCore(core: u32) void {
    @atomicStore(u32, &cross_core_pending[core], 1, .release);
    asm volatile ("dsb ish" ::: .{ .memory = true });
    gic.raiseSgi(SGI_CROSS_CORE, interfaces[core]);
}

fn causeSoftInt() void {
    @atomicStore(u32, &softint_pending[cpu.coreId()], 1, .release);
    asm volatile ("dsb ish" ::: .{ .memory = true });
    gic.raiseSgiSelf(SGI_CAUSE);
}

fn onSoftware(_: u6) void {
    const core = cpu.coreId();
    if (@atomicRmw(u32, &cross_core_pending[core], .Xchg, 0, .acquire) != 0) onCrossCore(core);
    if (@atomicRmw(u32, &softint_pending[core], .Xchg, 0, .acquire) != 0) exec.dispatchSoftInts(exec.SysBase);
}

fn onCrossCore(core: u32) void {
    cross_core_count[core] +%= 1;
    // Another core changed an alarm: core 0's comparator set again.
    if (core == 0) @import("timer.zig").rethinkIfAsked();
    // Held by the other core: parked until it lets go.
    rendezvous.parkIfAsked();
    // Otherwise poked: the dispatcher looks again at the exit.
    if (exec.initialized) exec.crossCorePoke(exec.SysBase);
}

/// The IRQ: every pending interrupt acknowledged, served and ended, until
/// none is left. An SGI or PPI goes to the core's handler for it, a
/// shared one to exec's chain.
fn onIrq() void {
    const core = cpu.coreId();
    while (true) {
        const iar = gic.acknowledge();
        const id = iar & gic.IAR_ID;
        if (id >= gic.SPURIOUS - 3) break;
        if (id < intbits.INTB_SPI_FIRST) {
            trap.last_line[core] = @as(u32, 1) << @intCast(id);
            // An SGI is ended before it is served, so one raised while it
            // runs comes again; a PPI - the timer's level - after, once
            // its handler has lowered it.
            const sgi = id < 16;
            if (sgi) gic.endOfInterrupt(iar);
            const served = trap.dispatchLine(@intCast(id));
            if (!sgi) gic.endOfInterrupt(iar);
            if (!served) {
                gic.setEnabled(id, false);
                exec.kprintf("\n[trap] spurious interrupt %d on core %d, disabled\n", .{ id, core });
            }
            continue;
        }
        if (id < intbits.INTB_GIC_COUNT) dispatch(id);
        if (bridged(id)) |bridge| bridge.end(id);
        gic.endOfInterrupt(iar);
    }
}

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

fn isShared(source: u32) bool {
    return source >= intbits.INTB_SPI_FIRST and source < intbits.INTB_GIC_COUNT;
}

/// The board's bridge, if `source` is one of its.
fn bridged(source: u32) ?*const boards.InterruptBridge {
    const bridge = boards.interrupt_bridge orelse return null;
    return if (source >= bridge.first and source - bridge.first < bridge.count) bridge else null;
}

fn enableSource(source: u32, _: bool) bool {
    if (isAlarm(source)) return true;
    if (!isShared(source)) return false;
    gic.setEnabled(source, true);
    if (bridged(source)) |bridge| bridge.enable(source);
    return true;
}

fn disableSource(source: u32) void {
    if (!isShared(source)) return;
    if (bridged(source)) |bridge| bridge.disable(source);
    gic.setEnabled(source, false);
}

/// A shared interrupt taken on its edge rather than its level: a message
/// signalled one, as a PCI device's MSI is.
pub fn setEdge(source: u32, edge: bool) void {
    if (isShared(source)) gic.setEdge(source, edge);
}

/// Disable: this core's interrupts masked.
fn disable() u32 {
    return cpu.disableInterrupts();
}

fn restore(state: u32) void {
    cpu.restoreInterrupts(state);
}

/// What every shared interrupt comes on, as `lineOf` says: the IRQ
/// exception, its vector's number after the synchronous one's.
pub const irq_line: u6 = 1;

/// What `source` comes on, if it is enabled: the IRQ, or the timer's PPI
/// for an alarm.
pub fn lineOf(source: u32) ?u6 {
    if (isAlarm(source)) return @intCast(@import("timer.zig").tick_irq);
    if (!isShared(source)) return null;
    return if (gic.isEnabled(source)) irq_line else null;
}

// SPDX-License-Identifier: MPL-2.0
//! Supervisor mode's interrupts as exec's interrupt hardware: the PLIC
//! for the devices, the software interrupt for exec's Cause and for the
//! cross-core interrupt.
//!
//! An exec interrupt number is a PLIC source (1 up; sdk.hardware.intbits),
//! or one of the kernel's alarms on the SBI timer after them, which
//! timer.zig raises and nothing here has to switch on.
//! The PLIC gives every source a priority and an enable bit per context,
//! so a source never shares anything with another: enabling one is its
//! priority raised to 1 and its bit set in core 0's supervisor context,
//! and the external interrupt (scause 9) claims each pending source in
//! turn, runs its chain and completes it. All sources are at one priority
//! and the threshold is 0, so masking sstatus.SIE holds all of them off.
//!
//! The software interrupt (sip.SSIP, scause 1) carries two things, each
//! with a flag of its own per core: exec's Cause, which the core raises
//! on itself by setting SSIP, and the cross-core interrupt, which another
//! core raises through the SBI firmware's IPI. The handler lowers SSIP
//! first and then takes the flags, so one raised meanwhile comes again.

const cpu = @import("cpu.zig");
const hardware = @import("sdk").hardware;
const intbits = hardware.intbits;
const plic = hardware.plic;
const sbi = hardware.sbi;
const exec = @import("../../rom/libs/exec/exec.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const trap = @import("trap.zig");
const rendezvous = @import("rendezvous.zig");

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

/// Each core's software interrupt, by what it carries.
var softint_pending: [max_cores]u32 = @splat(0);
var cross_core_pending: [max_cores]u32 = @splat(0);

/// Core 0's: every source off in its context and at priority 0, its
/// threshold 0, and its software and external interrupts on. The
/// devices' sources are core 0's.
pub fn init() void {
    const context = plic.supervisorContext(cpu.hartId());
    for (1..intbits.INTB_PLIC_COUNT) |source| {
        plic.setEnabled(context, @intCast(source), false);
        plic.setPriority(@intCast(source), 0);
    }
    plic.setThreshold(context, 0);
    trap.setHandler(trap.external_line, onExternal);
    initCore();
    cpu.enableInterruptKinds(cpu.SIE_SEIE);
}

/// Another core's, on that core: its software interrupt only.
pub fn initCore1() void {
    initCore();
}

fn initCore() void {
    trap.setHandler(trap.software_line, onSoftware);
    cpu.enableInterruptKinds(cpu.SIE_SSIE);
}

/// Each core counts its cross-core interrupts.
pub var cross_core_count: [max_cores]u32 = @splat(0);

/// The cross-core interrupt raised on `core`: its flag, and the SBI's IPI
/// to its hart.
pub fn raiseCrossCore(core: u32) void {
    @atomicStore(u32, &cross_core_pending[core], 1, .release);
    _ = sbi.sendIpi(1, cpu.hartids[core]);
}

fn causeSoftInt() void {
    @atomicStore(u32, &softint_pending[cpu.coreId()], 1, .release);
    cpu.raiseSoftware();
}

fn onSoftware(_: u6) void {
    // Lowered first: a Cause or a poke from here on raises it again.
    cpu.clearSoftware();
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

/// Every pending source claimed, its chain run and completed, until none
/// is left.
fn onExternal(_: u6) void {
    const context = plic.supervisorContext(cpu.hartId());
    while (true) {
        const source = plic.claim(context);
        if (source == 0) break;
        if (source < intbits.INTB_PLIC_COUNT) dispatch(source);
        plic.complete(context, source);
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

fn enableSource(source: u32, _: bool) bool {
    if (isAlarm(source)) return true;
    if (source == 0 or source >= intbits.INTB_PLIC_COUNT) return false;
    plic.setPriority(source, 1);
    plic.setEnabled(plic.supervisorContext(cpu.hartids[0]), source, true);
    return true;
}

fn disableSource(source: u32) void {
    if (source == 0 or source >= intbits.INTB_PLIC_COUNT) return;
    plic.setEnabled(plic.supervisorContext(cpu.hartids[0]), source, false);
    plic.setPriority(source, 0);
}

/// Disable: this core's interrupts masked.
fn disable() u32 {
    return cpu.disableInterrupts();
}

fn restore(state: u32) void {
    cpu.restoreInterrupts(state);
}

/// The interrupt `source` comes on, if it is enabled: the external one,
/// or the timer's for an alarm.
pub fn lineOf(source: u32) ?u6 {
    if (isAlarm(source)) return trap.tick_line;
    if (source == 0 or source >= intbits.INTB_PLIC_COUNT) return null;
    return if (plic.isEnabled(plic.supervisorContext(cpu.hartids[0]), source)) trap.external_line else null;
}

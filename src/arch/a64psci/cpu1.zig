// SPDX-License-Identifier: MPL-2.0
//! The other cores: started by core 0 once exec and the tick exist, each
//! on a stack core 0 sets aside for it.
//!
//! The firmware keeps every core but the boot core off (PSCI), or waiting
//! on a spin table: the Raspberry Pi 4's, which has no PSCI, keeps each
//! one in a loop at EL2 that reads an address in RAM - the device tree's
//! `cpu-release-addr` - until it is not 0, and then jumps there. The
//! cores the kernel may use are the device tree's (fdt.zig), by their
//! MPIDR affinity, and it uses as many as the board's SYSTAG_Cores and
//! exec's max_cores let it. Core 0 numbers the others in the tree's order
//! (`takeCores`), makes each one's idle task (exec's `prepareCore`) and
//! starts it with PSCI's CPU_ON at `_start_other` (start.S), the core's
//! number its context - or, on a spin table, writes `_start_spin`'s
//! address where the core reads it, the core's number where
//! `_start_spin` reads it, and wakes it with `sev`. That sets the core up as `_start` set up core 0
//! and calls `kmain_other`, which starts the core's interrupt interface
//! and tick, has it take tasks (`coreStarted`) and says it is up. Core 0
//! waits for that before it starts the next: exec counts the cores that
//! run, so they come up in their order.

const exec = @import("../../rom/libs/exec/exec.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const cpu = @import("cpu.zig");
const gic = @import("gic.zig");
const mmu = @import("mmu.zig");
const timer = @import("timer.zig");
const hardware = @import("sdk").hardware;
const psci = hardware.psci;

const max_cores = cpu.max_cores;

extern fn _start_other() callconv(.c) void;
extern fn _start_spin() callconv(.c) void;
/// The core `_start_spin` is: start.S's, a cache line of its own.
extern var a64_spin_core: u64;

/// How many cores the kernel was built to run on; the kernel sets it.
pub var cores: u32 = 1;

/// How many cores there are for it, core 0's included (`takeCores`).
pub var found: u32 = 1;

/// Each core's stack top, for `_start_other` to load.
export var a64_core_stacks: [max_cores]usize = @splat(0);

/// How many of the other cores have said they are up.
var up_count: u32 = 0;

/// Where each core is let go on a spin table, by its number here; 0 for
/// a core PSCI starts.
var releases: [max_cores]u64 = @splat(0);

/// What PSCI's CPU_ON last answered, for the boot's line about a core
/// that did not start; `spun` for a core let go on a spin table.
pub var last_answer: i64 = 0;
const spun: i64 = 1;

/// Whether another core is running.
pub fn isUp() bool {
    return @atomicLoad(u32, &up_count, .acquire) != 0;
}

/// The cores the device tree names, the boot core left out, made cores 1
/// on - as many as exec keeps state for - with where each is let go
/// (`fdt.Facts.coreReleases`).
pub fn takeCores(ids: []const u64, spin: []const u64, boot: u64) void {
    for (ids, spin) |id, release| {
        if (id == boot) continue;
        if (found == max_cores) break;
        cpu.mpidrs[found] = id;
        releases[found] = release;
        found += 1;
    }
}

/// Whether the cores are let go on spin tables, not started by PSCI.
pub fn spinTables() bool {
    for (releases[1..found]) |release| {
        if (release != 0) return true;
    }
    return false;
}

/// A line of memory written back and dropped from the caches, so that a
/// core reading with its caches off reads what was written.
fn pushOut(address: usize) void {
    asm volatile (
        \\dc civac, %[at]
        \\dsb sy
        :
        : [at] "r" (address),
        : .{ .memory = true });
}

/// Core `core` let go from its spin table at `_start_spin`: its number
/// where `_start_spin` reads it, then the address where the core waits
/// for it - in page 0 on the Pi, mapped for the write alone - both pushed
/// past the caches, and every waiting core woken to look.
fn letGo(core: u32) void {
    a64_spin_core = core;
    pushOut(@intFromPtr(&a64_spin_core));
    const slot = releases[core];
    if (slot < 4096) mmu.pageZero(true);
    @as(*volatile u64, @ptrFromInt(slot)).* = @intFromPtr(&_start_spin);
    pushOut(slot);
    if (slot < 4096) mmu.pageZero(false);
    asm volatile ("sev" ::: .{ .memory = true });
}

/// Core `core` started on the stack that ends at `stack_top` (16-byte
/// aligned), its idle task prepared. True once it says it is up; false
/// when the firmware will not start it, or it never says so within a
/// tenth of a second.
pub fn start(core: u32, stack_top: usize) bool {
    @atomicStore(usize, &a64_core_stacks[core], stack_top, .release);
    // The stack's address is in memory before the core reads it, which it
    // does with its caches on.
    asm volatile ("dsb ish" ::: .{ .memory = true });
    if (releases[core] != 0) {
        last_answer = spun;
        letGo(core);
    } else {
        last_answer = psci.cpuOn(cpu.mpidrs[core], @intFromPtr(&_start_other), core);
        if (last_answer != psci.SUCCESS and last_answer != psci.ON_PENDING) return false;
    }
    const since = timer.uptimeUs();
    while (@atomicLoad(u32, &up_count, .acquire) < core) {
        if (timer.uptimeUs() - since > 100_000) return false;
    }
    return true;
}

/// What a CPU_ON answer means, for the boot's line.
pub fn answerName(answer: i64) [*:0]const u8 {
    return switch (answer) {
        spun => "let go from its spin table, it never said it was up",
        psci.SUCCESS => "started",
        psci.INVALID_PARAMETERS => "no such core",
        psci.DENIED => "denied",
        psci.ALREADY_ON => "already on",
        psci.ON_PENDING => "on its way",
        psci.INTERNAL_FAILURE => "the firmware failed",
        psci.INVALID_ADDRESS => "an entry the firmware refused",
        else => "not supported",
    };
}

/// Where another core comes to from `_start_other`, with its interrupts
/// masked: its cycle counter on, its interrupt interface and its tick set
/// up, it takes tasks from here, says it is up, and goes on as its idle
/// task.
export fn kmain_other(core: u32) callconv(.c) noreturn {
    _ = core;
    cpu.identifyHere();
    hardware.cpu.startCycleCounter();
    @import("debugexc.zig").init();
    gic.initCore1();
    timer.initCore1();
    exec.coreStarted(exec.SysBase);
    _ = @atomicRmw(u32, &up_count, .Add, 1, .release);
    cpu.enableInterrupts();
    exec.idleHere(exec.SysBase);
}

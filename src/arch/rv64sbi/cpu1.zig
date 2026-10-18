// SPDX-License-Identifier: MPL-2.0
//! The other cores: started by core 0 once exec and the tick exist, each
//! on a stack core 0 sets aside for it.
//!
//! The firmware keeps every hart but the boot hart stopped (SBI HSM). The
//! harts the kernel may use are the device tree's (fdt.zig) - on the
//! VisionFive 2 the U74s, 1 to 4, of which the firmware booted one - and
//! it uses as many as the board's SYSTAG_Cores and exec's max_cores let
//! it. Core 0 numbers the others in the tree's order (`takeHarts`), makes
//! each one's idle task (exec's `prepareCore`) and starts its hart with
//! SBI's hart_start at `_start_other` (start.S), the core's number its
//! opaque value. That sets the hart up as `_start` set up core 0 and
//! calls `kmain_other`, which starts the core's software interrupt and
//! tick, has it take tasks (`coreStarted`) and says it is up. Core 0 waits
//! for that before it starts the next: exec counts the cores that run, so
//! they come up in their order.

const exec = @import("../../rom/libs/exec/exec.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const cpu = @import("cpu.zig");
const plic = @import("plic.zig");
const timer = @import("timer.zig");
const sbi = @import("sdk").hardware.sbi;

const max_cores = exec_base.max_cores;

extern fn _start_other() callconv(.c) void;

/// How many cores the kernel was built to run on; the kernel sets it.
pub var cores: u32 = 1;

/// How many cores there are harts for, core 0's included (`takeHarts`).
pub var found: u32 = 1;

/// Each core's stack top, for `_start_other` to load.
export var riscv_core_stacks: [max_cores]usize = @splat(0);

/// How many of the other cores have said they are up.
var up_count: u32 = 0;

/// Whether another core is running.
pub fn isUp() bool {
    return @atomicLoad(u32, &up_count, .acquire) != 0;
}

/// The harts the device tree names, the boot hart left out, made cores 1
/// on - as many as exec keeps state for.
pub fn takeHarts(ids: []const usize, boot: usize) void {
    for (ids) |id| {
        if (id == boot) continue;
        if (found == max_cores) break;
        cpu.hartids[found] = id;
        found += 1;
    }
}

/// Core `core` started on the stack that ends at `stack_top` (16-byte
/// aligned), its idle task prepared. True once it says it is up; false
/// when the firmware will not start its hart, or it never says so within
/// a tenth of a second.
pub fn start(core: u32, stack_top: usize) bool {
    @atomicStore(usize, &riscv_core_stacks[core], stack_top, .release);
    if (sbi.hartStart(cpu.hartids[core], @intFromPtr(&_start_other), core) != 0) return false;
    const since = timer.uptimeUs();
    while (@atomicLoad(u32, &up_count, .acquire) < core) {
        if (timer.uptimeUs() - since > 100_000) return false;
    }
    return true;
}

/// Where another core comes to from `_start_other`, with its interrupts
/// masked: its software interrupt and its tick set up, it takes tasks from
/// here, says it is up, and goes on as its idle task.
export fn kmain_other(core: u32) callconv(.c) noreturn {
    _ = core;
    plic.initCore1();
    timer.initCore1();
    exec.coreStarted(exec.SysBase);
    _ = @atomicRmw(u32, &up_count, .Add, 1, .release);
    cpu.enableInterrupts();
    exec.idleHere(exec.SysBase);
}

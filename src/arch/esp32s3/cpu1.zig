// SPDX-License-Identifier: MPL-2.0
//! The second core: let go once exec exists, on a stack core 0 sets aside
//! for it.
//!
//! Core 1 sits in the ROM's reset code, stalled and with its clock off,
//! until core 0 lets it go - as ESP-IDF does: its software stall cleared,
//! its clock on and a reset pulse, and the ROM told where to send it
//! (`ets_set_appcpu_boot_addr`). It comes out at `_start_cpu1` (start.S),
//! which sets the core up as `_start` does core 0 and calls
//! `kmain_cpu1`. Core 0 waits until it says it is up.
//!
//! Both cores share the caches; their buses to them were opened for both
//! when the flash and the PSRAM were mapped, so core 1 runs the kernel's
//! code in flash like core 0.
//!
//! Core 0 makes core 1's idle task before it lets it go (exec's
//! `prepareCore`): the code core 1 starts in becomes that task, as the
//! boot code became the first task on core 0. From `coreStarted` on core 1
//! takes tasks; its dispatcher runs at its own exception exits.

const hardware = @import("sdk").hardware;
const exec = @import("../../rom/libs/exec/exec.zig");
const cpu = @import("cpu.zig");
const intmatrix = @import("intmatrix.zig");
const timer = @import("timer.zig");
const reg = hardware.mmio.reg;
const system = hardware.system;
const rtc_cntl = hardware.rtc_cntl;

/// The ROM's `ets_set_appcpu_boot_addr`: where core 1 goes from its
/// reset code. ESP-IDF's esp32s3.rom.ld has it at this address.
const ets_set_appcpu_boot_addr: *const fn (address: u32) callconv(.c) void = @ptrFromInt(0x4000_0720);

extern fn _start_cpu1() callconv(.c) void;

/// How many cores the kernel was built to run on; the kernel sets it.
pub var cores: u32 = 1;

/// The top of core 1's stack, for `_start_cpu1` to load.
export var cpu1_stack_top: usize = 0;

/// Core 1 says it is up.
var up: u32 = 0;

/// Whether core 1 is running.
pub fn isUp() bool {
    return @as(*volatile u32, &up).* != 0;
}

/// Core 1 let go, on the stack that ends at `stack_top` (internal memory,
/// 16-byte aligned). True once it says it is up; false if it never does
/// within about a tenth of a second.
pub fn start(stack_top: usize) bool {
    cpu1_stack_top = stack_top;
    // Its software stall cleared: either half of the 0x86 lets it run.
    reg(rtc_cntl.OPTIONS0).* &= ~rtc_cntl.OPTIONS0_SW_STALL_APPCPU_C0;
    reg(rtc_cntl.SW_CPU_STALL).* &= ~rtc_cntl.SW_STALL_APPCPU_C1;
    // Its clock on and a reset pulse, unless a debugger did that already
    // and may have set breakpoints a reset would clear.
    const control = reg(system.CORE_1_CONTROL_0);
    if (control.* & system.CORE_1_CLKGATE_EN == 0) {
        control.* |= system.CORE_1_CLKGATE_EN;
        control.* &= ~system.CORE_1_RUNSTALL;
        control.* |= system.CORE_1_RESETING;
        control.* &= ~system.CORE_1_RESETING;
    }
    ets_set_appcpu_boot_addr(@intCast(@intFromPtr(&_start_cpu1)));
    var spins: u32 = 0;
    while (!isUp()) : (spins += 1) {
        if (spins > 24_000_000) return false;
    }
    return true;
}

/// Where core 1 comes to from `_start_cpu1`, with its interrupts masked:
/// its matrix and its tick set up, it takes tasks from here, says it is
/// up, and goes on as its idle task.
export fn kmain_cpu1() callconv(.c) noreturn {
    intmatrix.initCore1();
    timer.initCore1();
    exec.coreStarted(exec.SysBase);
    @as(*volatile u32, &up).* = 1;
    cpu.enableInterrupts();
    exec.idleHere(exec.SysBase);
}

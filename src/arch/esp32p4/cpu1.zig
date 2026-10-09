// SPDX-License-Identifier: MPL-2.0
//! The second core: let go once exec exists, on a stack core 0 sets aside
//! for it.
//!
//! Core 1 comes up held in reset with its clock off, and its ROM code,
//! once it runs, waits for an address to go to. Core 0 lets it go as
//! ESP-IDF does: its software stall cleared, its clock on, out of reset,
//! and the ROM told where to send it (`ets_set_appcpu_boot_addr`). It
//! comes out at `_start_cpu1` (start.S), which sets the core up as
//! `_start` does core 0 and calls `kmain_cpu1`. Core 0 waits until it says
//! it is up.
//!
//! Core 0 makes core 1's idle task before it lets it go (exec's
//! `prepareCore`): the code core 1 starts in becomes that task, as the
//! boot code became the first task on core 0. From `coreStarted` on core 1
//! takes tasks; its dispatcher runs at its own trap exits.

const hardware = @import("sdk").hardware;
const exec = @import("../../rom/libs/exec/exec.zig");
const cpu = @import("cpu.zig");
const intmatrix = @import("intmatrix.zig");
const timer = @import("timer.zig");
const reg = hardware.mmio.reg;

/// The ROM's `ets_set_appcpu_boot_addr`: where core 1 goes from its
/// reset code, through the ROM's table of entry points.
const ets_set_appcpu_boot_addr: *const fn (address: u32) callconv(.c) void = @ptrFromInt(0x4FC0_00A8);

/// PMU_CPU_SW_STALL: core 1's stall code in bits 16-23; 0x86 stalls it,
/// anything else lets it run.
const pmu_cpu_sw_stall = hardware.map.PMU + 0x200;
const core1_stall_code_shift = 16;
/// HP_SYS_CLKRST: core 1's clock (SOC_CLK_CTRL0 bit 4) and its reset
/// (HP_RST_EN0 bit 8, set from power-on).
const soc_clk_ctrl0 = hardware.map.HP_SYS_CLKRST + 0x014;
const core1_cpu_clk_en: u32 = 1 << 4;
const hp_rst_en0 = hardware.map.HP_SYS_CLKRST + 0x0C0;
const rst_en_core1_global: u32 = 1 << 8;

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

/// Core 1 let go, on the stack that ends at `stack_top` (16-byte
/// aligned). True once it says it is up; false if it never does within
/// about a tenth of a second.
pub fn start(stack_top: usize) bool {
    cpu1_stack_top = stack_top;
    const stall = reg(pmu_cpu_sw_stall);
    stall.* = (stall.* & ~(@as(u32, 0xFF) << core1_stall_code_shift)) | (@as(u32, 0xFF) << core1_stall_code_shift);
    // Its clock on and out of reset, unless a debugger did that already
    // and may have set breakpoints a reset would clear.
    if (reg(soc_clk_ctrl0).* & core1_cpu_clk_en == 0) reg(soc_clk_ctrl0).* |= core1_cpu_clk_en;
    if (reg(hp_rst_en0).* & rst_en_core1_global != 0) reg(hp_rst_en0).* &= ~rst_en_core1_global;
    ets_set_appcpu_boot_addr(@intCast(@intFromPtr(&_start_cpu1)));
    const since = timer.uptimeUs();
    while (!isUp()) {
        if (timer.uptimeUs() - since > 100_000) return false;
    }
    return true;
}

/// Where core 1 comes to from `_start_cpu1`, with its interrupts masked:
/// its interrupt controller and its tick set up, it takes tasks from here,
/// says it is up, and goes on as its idle task.
export fn kmain_cpu1() callconv(.c) noreturn {
    intmatrix.initCore1();
    timer.initCore1();
    exec.coreStarted(exec.SysBase);
    @as(*volatile u32, &up).* = 1;
    cpu.enableInterrupts();
    exec.idleHere(exec.SysBase);
}

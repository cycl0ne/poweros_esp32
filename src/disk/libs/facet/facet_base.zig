// SPDX-License-Identifier: MIT
//! facet.library's base: exec's Library header and what the library
//! keeps beside it. There is one base, shared by every opener; what a
//! program makes - its instance, its devices and all made from them - is
//! the program's, and hangs off none of it.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const TimerBase = sdk.interface.timer.TimerBase;

/// The driver modules from LIBS:facet/ kept open at most.
pub const most_modules = 3;

pub const FacetBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back by the Expunge.
    seg_list: ?*anyopaque = null,
    /// The instances not yet destroyed: while there are any the library
    /// stays, whoever has closed it.
    instances: u32 = 0,
    /// Set by the host tests, whose exec runs no task but theirs: a
    /// queue's work is played by the task that submits it, and a device
    /// starts no task.
    inline_queues: bool = false,
    /// What the V3D's driver keeps while any device has it, and what guards
    /// its coming and going.
    v3d: ?*anyopaque = null,
    v3d_lock: exec.SignalSemaphore = .{},
    /// timer.device, for the E-clock a wait for several fences is timed by.
    /// The host tests have none.
    clock: timer.TimeRequest = .{},
    clock_open: bool = false,
    /// The driver modules (driver/_driver.zig), open until the library goes,
    /// their tables, and what guards the looking for them.
    modules_lock: exec.SignalSemaphore = .{},
    modules_read: bool = false,
    module_count: u32 = 0,
    modules: [most_modules]?*exec.Library = @splat(null),
    module_ops: [most_modules]?*const anyopaque = @splat(null),
};

pub fn facetBase(lib: *exec.Library) *FacetBase {
    return @fieldParentPtr("lib", lib);
}

/// Now on the E-clock, in microseconds: 0 without timer.device.
pub fn now(base: *FacetBase) u64 {
    if (!base.clock_open) return 0;
    const timer_base: *TimerBase = @ptrCast(@alignCast(base.clock.node.device.?));
    var value: timer.EClockVal = .{};
    const rate = timer_base.ReadEClock(&value);
    if (rate == 0) return 0;
    const ticks = value.toTicks();
    return ticks / rate * 1_000_000 + ticks % rate * 1_000_000 / rate;
}

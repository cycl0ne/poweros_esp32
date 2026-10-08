// SPDX-License-Identifier: MIT
//! filter.library's base, shared by every opener: exec's Library header,
//! what it was loaded from, utility.library and timer.device, the rule
//! set in force, the exchanges noted, and the two hooks bsdsocket.library
//! calls - the one shown what comes in, the one shown what goes out.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const TimerBase = sdk.interface.timer.TimerBase;
const RuleSet = @import("rules/_rules.zig").RuleSet;
const Table = @import("flows/_flows.zig").Table;

pub const FilterBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    utility_base: *UtilityBase,
    /// timer.device, for the E-clock the exchanges are timed by; and the
    /// time, for the host tests, which have no timer.device: used when
    /// not 0.
    clock: timer.TimeRequest = .{},
    clock_open: u8 = 0,
    pad0: [3]u8 = .{ 0, 0, 0 },
    fixed_time: u64 align(4) = 0,
    /// The rule set in force, or null; and the exchanges. The hooks read
    /// them under the stack's lock, a load swaps them on its caller's
    /// task: both under `lock`, a spinlock, since a hook may not wait.
    lock: exec.Lock = .{},
    rules: ?*RuleSet = null,
    flows: Table = .{},
    /// The hooks, and whether they are in bsdsocket.library's chains.
    in_hook: utility.Hook = .{},
    out_hook: utility.Hook = .{},
    hooked: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
};

pub fn filterBase(lib: *exec.Library) *FilterBase {
    return @fieldParentPtr("lib", lib);
}

/// Now on the E-clock, in microseconds: never set back, as the system
/// time may be.
pub fn now(base: *FilterBase) u64 {
    if (base.fixed_time != 0 or base.clock_open == 0) return base.fixed_time;
    const timer_base: *TimerBase = @ptrCast(@alignCast(base.clock.node.device.?));
    var value: timer.EClockVal = .{};
    const rate = timer_base.ReadEClock(&value);
    if (rate == 0) return 0;
    const ticks = value.toTicks();
    return ticks / rate * 1_000_000 + ticks % rate * 1_000_000 / rate;
}

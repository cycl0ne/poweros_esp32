// SPDX-License-Identifier: MPL-2.0
//! power.resource's base: what this machine can do about its own power,
//! the hardware its power button is reported on, who asked to hear about
//! it, and the task that turns the machine off when nobody did.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const acpipm = @import("source/acpipm.zig");

pub const PowerBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// POWERF_*, worked out once at init: what this machine can do.
    abilities: u32 = 0,
    /// The power management the board described, and whether it was
    /// started - its event block is read and written only while it was.
    hardware: acpipm.Hardware = .{},
    started: bool = false,
    /// The interrupt source its press comes in on, and the server on it.
    source: u32 = 0,
    server: exec.Interrupt = .{},
    hooked: bool = false,
    /// Who asked to hear about a press, under `lock`. While this list has
    /// anything in it the machine is theirs to turn off.
    notify: exec.List = .{},
    lock: exec.SignalSemaphore = .{},
    /// The task that stops the drives and turns the machine off, the
    /// signal the server wakes it with, and its stack: none on a machine
    /// with no button.
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    press_signal: u32 = 0,
    /// Who started the task, and the signal it is told with that the task
    /// is up: both only until it is.
    starter: ?*exec.Task = null,
    start_signal: u32 = 0,
};

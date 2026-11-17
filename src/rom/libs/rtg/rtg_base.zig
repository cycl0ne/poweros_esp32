// SPDX-License-Identifier: MPL-2.0
//! rtg.library as a library: its base, and the Expunge vector that keeps
//! it in memory.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const PCIBase = sdk.interface.pci.PCIBase;
const DosBase = sdk.interface.dos.DosBase;

/// The base: the drivers, the devices they are offered, the boards they
/// made of them, and the libraries it calls.
pub const RtgBase = extern struct {
    lib: exec.Library,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// utility.library, opened by the init and kept: the tag calls are
    /// its, and a driver reaches them through this library so that it need
    /// open nothing else.
    utility_base: *UtilityBase,
    /// expansion.library, opened by the init where the machine has it and
    /// kept: every driver's node carries it, for the board's parts a
    /// driver asks about. Null on a machine without it.
    expansion_base: ?*ExpansionBase,
    /// The drivers, highest priority first, and the semaphore that holds
    /// the list still while it is walked.
    drivers: exec.List,
    driver_lock: exec.SignalSemaphore,
    /// The devices, in the order they were found, and the semaphore held
    /// while the list changes and while a device is offered to the
    /// drivers. It is taken before the driver list's and the board
    /// list's.
    devices: exec.List,
    device_lock: exec.SignalSemaphore,
    /// Whether the machine's own devices - its panel parts, its display
    /// functions on PCI - are on the list: put there once, at the first
    /// bind.
    devices_listed: bool,
    /// How many devices of the part kind were made, for naming the next
    /// ("panel.1").
    panel_serial: u32,
    /// pci.library, opened when the machine's devices are listed, where
    /// the machine has it, and kept: the devices on PCI are its
    /// functions.
    pci_base: ?*PCIBase,
    /// The boards, highest priority first, and the transports alive.
    boards: exec.List,
    transports: exec.List,
    board_lock: exec.SignalSemaphore,
    /// The tasks that asked to be told when something about the boards
    /// changes (`AddRtgNotify`), and the semaphore held while the list
    /// changes and while they are told.
    notifies: exec.List,
    notify_lock: exec.SignalSemaphore,
    /// The task that looks at a board's connector when its driver says
    /// the monitor changed (`monitor/_monitor.zig`): made with the first
    /// board that has one, null until then.
    monitor_task: ?*exec.Task,
    /// The settings (`settings/_settings.zig`): the outputs' lines and the
    /// devices', as `display.prefs` has them, and the semaphore held
    /// while they are read or changed. It is the last lock taken.
    output_lines: exec.List,
    device_lines: exec.List,
    settings_lock: exec.SignalSemaphore,
    /// dos.library, opened the first time a settings file is read or
    /// written, and kept. Null until then.
    dos_base: ?*DosBase,
    /// timer.device's request on its microsecond unit, opened by the init:
    /// what a wait with a time limit copies, with a reply port of the
    /// waiting task's own, so any task may wait. Its device is null where
    /// there is no timer.device, and a wait that needs a limit is then
    /// refused.
    timer_io: timer.TimeRequest,

    /// This library as a caller sees it, to call its own functions through
    /// the jump table.
    ///
    /// INPUTS:
    /// - `rb` - the library's base.
    pub fn iface(rb: *RtgBase) *sdk.interface.rtg.RtgBase {
        return @ptrCast(rb);
    }

    /// This library as a driver sees it, to call the functions of its
    /// second interface through the jump table.
    ///
    /// INPUTS:
    /// - `rb` - the library's base.
    pub fn driverIface(rb: *RtgBase) *sdk.interface.rtgdriver.RtgDriverBase {
        return @ptrCast(rb);
    }
};

/// LibExpunge: a ROM module stays.
pub fn expunge(_: *exec.Library) callconv(.c) ?*anyopaque {
    return null;
}

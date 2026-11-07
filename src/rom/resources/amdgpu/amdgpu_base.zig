// SPDX-License-Identifier: MPL-2.0
//! amdgpu.resource's base: the device's function, as it was claimed, what
//! is answered about it, the table of its blocks it was read from, the
//! power manager its mailbox reaches, and the device's own memory with
//! what of it is handed out.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const PCIDevice = sdk.pci.PCIDevice;
const PCIBase = sdk.interface.pci.PCIBase;
const ExecBase = sdk.interface.exec.ExecBase;
const Arena = @import("memory/_arena.zig").Arena;

pub const AMDGPUBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// The function, claimed, and pci.library as it was opened and as it
    /// is called; all null on a machine without the device.
    device: ?*PCIDevice = null,
    pci_lib: ?*exec.Library = null,
    pci: ?*PCIBase = null,
    /// What GetGPUInfo answers; its `registers` 0 while there is no
    /// device.
    info: amdgpu.GPUInfo = .{},
    /// Where the table of blocks can be read: the copy in `table_room`
    /// where it was read out of the device's memory, or where it lies;
    /// 0 when there is none.
    table: usize = 0,
    table_room: ?*anyopaque = null,
    /// The power manager, where it is one whose messages are known, and
    /// the lock one message at a time is sent under.
    power: amdgpu.GPUBlock = .{},
    power_known: bool = false,
    mailbox_lock: exec.SignalSemaphore,
    /// The device's own memory as the memory hub places it: where it
    /// starts to the device and in the machine, and how long it is - all
    /// 0 where the hub is one whose registers are not known. What of it
    /// is handed out, under its lock, and whether the CPU writes that part
    /// gathered (write-combining) rather than word by word.
    memory_device: u64 = 0,
    memory_machine: u64 = 0,
    memory_bytes: u64 = 0,
    memory_gathered: bool = false,
    arena: Arena = .{},
    arena_lock: exec.SignalSemaphore,
};

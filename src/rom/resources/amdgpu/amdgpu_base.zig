// SPDX-License-Identifier: MPL-2.0
//! amdgpu.resource's base: the device's function, as it was claimed, what
//! is answered about it, the table of its blocks it was read from, the
//! power manager its mailbox reaches, the device's own memory with what
//! of it is handed out, the security processor's ring with the
//! protected region it was given, and the interrupt block's ring with the
//! servers its entries are handed to.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const PCIDevice = sdk.pci.PCIDevice;
const PCIBase = sdk.interface.pci.PCIBase;
const ExecBase = sdk.interface.exec.ExecBase;
const Arena = @import("memory/_arena.zig").Arena;
const _interrupt = @import("interrupt/_interrupt.zig");

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
    /// The security processor, where it is one whose ring and commands
    /// are known; the piece its ring, command page and fence are in, and
    /// the number of the last command put on it. Whether the ring is
    /// made, whether the processor is ready to load firmware, and whether
    /// it failed to answer - after which nothing more is asked of it.
    /// The protected region it was given, and the lock every command is
    /// sent under.
    security: amdgpu.GPUBlock = .{},
    security_known: bool = false,
    security_ring: amdgpu.GPUMemory = .{},
    security_sequence: u32 = 0,
    security_made: bool = false,
    security_ready: bool = false,
    security_dead: bool = false,
    protected: amdgpu.GPUMemory = .{},
    security_lock: exec.SignalSemaphore,
    /// The interrupt block, where it is one whose ring is known; the piece
    /// its ring is in, and where the next entry is read from. Whether the
    /// ring runs, and whether it failed to start - after which it is not
    /// tried again. The servers the entries are handed to, the message's
    /// own server, the entries read and the overflows seen, and the lock
    /// the ring is started under.
    interrupts: amdgpu.GPUBlock = .{},
    interrupts_known: bool = false,
    ih_ring: amdgpu.GPUMemory = .{},
    ih_read: u32 = 0,
    ih_running: bool = false,
    ih_failed: bool = false,
    servers: [_interrupt.servers_max]_interrupt.Server = @splat(.{}),
    ih_vector: exec.Interrupt = .{},
    ih_entries: u32 = 0,
    ih_overflows: u32 = 0,
    interrupt_lock: exec.SignalSemaphore,
};

// SPDX-License-Identifier: MPL-2.0
//! amdgpu.resource's base: the device's function, as it was claimed, what
//! is answered about it, the table of its blocks it was read from, the
//! power manager its mailbox reaches, the device's own memory with what
//! of it is handed out, the security processor's ring with the
//! protected region it was given, the interrupt block's ring with the
//! servers its entries are handed to, the graphics block with its memory
//! hub's page table, its DMA engine's queue, and its compute engine's
//! queue with the scheduler that maps it.

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
    /// The doorbell window: where the CPU and the device reach it - the
    /// same address on this machine - and how many bytes it is; 0 where
    /// the function has none.
    doorbells: u64 = 0,
    doorbells_bytes: u64 = 0,
    /// The device's video BIOS image, where the firmware kept one; its
    /// `image` null where not.
    bios: amdgpu.GPUBios = .{},
    /// The connectors the image lists, as GetGPUConnector answers them.
    connectors: [amdgpu.GPUCONNECTORS_MAX]amdgpu.GPUConnector = @splat(.{}),
    connector_count: u32 = 0,
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
    /// The bus block's register that flushes the device's host data path
    /// - which the CPU's reads and writes in the memory window pass - and
    /// the one read after it, so that the flush is posted: 0 where the bus
    /// block is not one whose registers are known.
    host_flush: usize = 0,
    host_posted: usize = 0,
    arena: Arena = .{},
    arena_lock: exec.SignalSemaphore,
    /// The security processor, where it is one whose ring and commands
    /// are known; the piece its ring, command page and fence are in, and
    /// the number of the last command put on it. Whether the ring is
    /// made, whether the processor is ready to load firmware, and whether
    /// it failed to answer - after which nothing more is asked of it -
    /// and whether the graphics block's firmware is loaded and the block
    /// started (StartGPUGraphics). The protected region it was given, and
    /// the lock every command is sent under.
    security: amdgpu.GPUBlock = .{},
    security_known: bool = false,
    security_ring: amdgpu.GPUMemory = .{},
    security_sequence: u32 = 0,
    security_made: bool = false,
    security_ready: bool = false,
    security_dead: bool = false,
    graphics_started: bool = false,
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
    /// The graphics block, where it is one whose registers are known, and
    /// whether it failed to come up once its firmware was loaded - after
    /// which nothing more is asked of it. Its memory hub's page table for
    /// its first context, and the page a stray address of its engines
    /// lands on; where the range that table maps begins in the device's
    /// addresses, and how long it is; what of the range is mapped
    /// (MapGPUMemory), offsets into it, and the lock it is mapped and
    /// unmapped under. The page its RLC is given the graphics pipe's
    /// clear state in.
    graphics: amdgpu.GPUBlock = .{},
    graphics_known: bool = false,
    graphics_failed: bool = false,
    gart: amdgpu.GPUMemory = .{},
    graphics_scratch: amdgpu.GPUMemory = .{},
    gart_start: u64 = 0,
    gart_bytes: u64 = 0,
    gart_arena: Arena = .{},
    gart_lock: exec.SignalSemaphore,
    clear_state: amdgpu.GPUMemory = .{},
    /// The DMA engine's queue: the piece its ring and what the engine
    /// writes back are in; whether it runs, and whether it failed to start
    /// - after which it is not tried again. How many bytes have been
    /// written into the ring since it started, the number of the last job
    /// put on it, the interrupts the engine raised at the ends of jobs,
    /// the waitable those interrupts signal and their server; the lock
    /// jobs are put on the queue under, and the one a task waits under.
    dma_ring: amdgpu.GPUMemory = .{},
    dma_running: bool = false,
    dma_failed: bool = false,
    dma_written: u64 = 0,
    dma_sent: u32 = 0,
    dma_traps: u32 = 0,
    dma_trap: exec.Waitable = .{},
    dma_trap_int: exec.Interrupt = .{},
    dma_lock: exec.SignalSemaphore,
    dma_wait_lock: exec.SignalSemaphore,
    /// The scheduler's two pipes' first instruction, from their files'
    /// headers as StartGPUGraphics loaded them.
    scheduler_start: [2]u64 = .{ 0, 0 },
    /// The compute engine's queue: the piece its rings, their queue
    /// descriptions and what the engines write back are in; whether it
    /// runs, and whether it failed to start - after which it is not tried
    /// again. The words written into each of the three rings since it
    /// started - the scheduler's own, the pipe that maps queues for it,
    /// and the queue's - and the number of the last call made of the
    /// scheduler. The scheduler's firmware versions. The number of the
    /// last job put on the queue, the interrupts the engine raised at the
    /// ends of jobs, the waitable those interrupts signal and their
    /// server; the slot of arguments a kernel's next dispatch takes, and
    /// the job each slot was last taken by; the lock jobs are put on the
    /// queue under, and the one a task waits under.
    compute: amdgpu.GPUMemory = .{},
    compute_running: bool = false,
    compute_failed: bool = false,
    scheduler_written: u64 = 0,
    mapper_written: u64 = 0,
    compute_written: u64 = 0,
    scheduler_calls: u32 = 0,
    scheduler_version: u32 = 0,
    mapper_version: u32 = 0,
    compute_sent: u32 = 0,
    compute_ends: u32 = 0,
    compute_end: exec.Waitable = .{},
    compute_end_int: exec.Interrupt = .{},
    compute_slot: u32 = 0,
    compute_slot_jobs: [compute_slots]u32 = @splat(0),
    /// The graphics block's shader engines and compute units, as the
    /// device's table says; 0 where it does not.
    shader_engines: u32 = 0,
    compute_units: u32 = 0,
    /// The compute engine's scratch, under the queue's lock: the piece of
    /// the device's memory its kernels' waves keep their private memory
    /// in, the bytes each wave has of it and how many waves it holds - all
    /// 0 until a kernel needs one.
    scratch: amdgpu.GPUMemory = .{},
    scratch_wave_bytes: u32 = 0,
    scratch_waves: u32 = 0,
    compute_lock: exec.SignalSemaphore,
    compute_wait_lock: exec.SignalSemaphore,
};

/// The slots of arguments the compute queue's kernels are handed theirs
/// in.
pub const compute_slots = 64;

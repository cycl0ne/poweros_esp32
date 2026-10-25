// SPDX-License-Identifier: MIT
//! nvme.device's shared parts: the base, a controller and its queues, a
//! unit, and the ways to the controller's registers and to memory it
//! reads and writes.
//!
//! **A unit is a namespace**: the controllers in pci.library's order,
//! each one's active namespaces in the order of their IDs, unit 0 the
//! first of all. Its size and block size are known once the device is
//! up, so what a handler asks of them is answered at once.
//!
//! **A controller** has two pairs of queues, the admin queues and one I/O
//! pair, and `slots` commands of its own out on the I/O pair at once:
//! each slot has its list page and its head and tail pages (prp.zig), and
//! its number is its command's identifier.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const td = sdk.devices.trackdisk;
const timer = sdk.devices.timer;
const automount = sdk.devices.automount;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const PCIBase = sdk.interface.pci.PCIBase;
const regs = @import("regs.zig");
const dsm = @import("dsm.zig");

pub const DEVICE_NAME = "nvme.device";

/// Its units, `NV0:` to `NV7:`.
pub const max_units = 8;
pub const max_controllers = 4;
/// The commands one controller has out on its I/O queues at once.
pub const slots = 8;
/// The entries of the admin queues, and of the I/O queues where the
/// controller takes that many.
pub const admin_entries: u16 = 8;
pub const io_entries: u16 = 32;
/// The memory page the controller is told to use.
pub const page: u32 = 4096;
/// The most one command moves, where the controller allows it.
pub const max_transfer: u32 = 512 * 1024;

/// How the controller's interrupt reaches the device.
pub const Signalling = enum(u8) { polled, intx, vector };

pub const Queue = struct {
    id: u16 = 0,
    entries: u16 = 0,
    commands: [*]regs.Command = undefined,
    completions: [*]volatile regs.Completion = undefined,
    tail: u16 = 0,
    head: u16 = 0,
    /// The phase a new completion carries.
    phase: u1 = 1,
    /// The doorbells, as the processor reaches them.
    tail_doorbell: usize = 0,
    head_doorbell: usize = 0,
};

/// A command of the controller's out, or not.
pub const Slot = struct {
    busy: bool = false,
    done: bool = false,
    status: u15 = 0,
    pages: [3]usize = .{ 0, 0, 0 },
};

pub const Controller = struct {
    base: *NvmeBase,
    sys: *ExecBase,
    pb: *PCIBase,
    function: *pci.PCIDevice,
    /// Its registers, from BAR 0.
    regs: usize = 0,
    stride: u32 = 4,
    ready_ms: u32 = 0,
    /// The most bytes one of its commands moves.
    max_transfer: u32 = page,
    volatile_cache: bool = false,
    /// It has Dataset Management, for TDCMD_TRIM, and what one of those
    /// commands takes at most.
    deallocates: bool = false,
    trim_limits: dsm.Limits = .{},
    /// Whether what it reads and writes in memory sees the processors'
    /// caches (PCIDevice.dma_coherent): then nothing is written back or
    /// dropped for it.
    coherent: bool = false,
    signalling: Signalling = .polled,
    /// The admin queues, and the I/O pair.
    admin: Queue = .{},
    io: Queue = .{},
    /// The admin command out, while one is: its identifier, then its
    /// answer.
    admin_id: u16 = 0,
    admin_done: bool = false,
    admin_status: u15 = 0,
    admin_result: u32 = 0,
    /// A page for what Identify answers.
    identify: [*]u8 = undefined,
    slots: [slots]Slot = @splat(.{}),
    /// Its interrupt's server, which wakes the device's task.
    int: exec.Interrupt = .{},
    task: ?*exec.Task = null,
    int_signal: u32 = 0,
    /// Whether it works: false once it failed and could not be brought
    /// back, and then for good - it is given up, and its units have no
    /// medium.
    alive: bool = false,
    number: u8 = 0,
    serial: [20]u8 = @splat(' '),
    model: [40]u8 = @splat(' '),
    firmware: [8]u8 = @splat(' '),
};

pub const Unit = extern struct {
    /// The unit as exec has it: io_Unit points here.
    unit: exec.Unit = .{},
    number: u32 = 0,
    nsid: u32 = 0,
    controller: ?*Controller = null,
    /// Its block size, as a power of two, and its blocks.
    block_shift: u8 = 9,
    pad: [7]u8 = @splat(0),
    blocks: u64 = 0,
    /// Its drives, made once by the mount process (mount.zig).
    medium: automount.MediumNode = .{},

    pub fn blockBytes(unit: *const Unit) u32 {
        return @as(u32, 1) << @intCast(unit.block_shift);
    }

    /// Whether its medium has gone: its controller was given up.
    pub fn gone(unit: *const Unit) bool {
        const c = unit.controller orelse return false;
        return !c.alive;
    }
};

pub const NvmeBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    pci_base: ?*PCIBase = null,
    /// For the mount process: null when dos could not be opened.
    dos_base: ?*DosBase = null,
    /// The task that serves every unit, and its stack.
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// Its ports: the units' requests, the timer's.
    requests: ?*exec.MsgPort = null,
    timer_port: ?*exec.MsgPort = null,
    timer_io: timer.TimeRequest = .{},
    /// The timer is out, for this long.
    ticking: bool = false,
    pad: [3]u8 = .{ 0, 0, 0 },
    tick_us: u32 = 0,
    int_signal: u32 = 0,
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad2: [3]u8 = .{ 0, 0, 0 },
    controller_count: u32 = 0,
    unit_count: u32 = 0,
    controllers: [max_controllers]?*Controller = @splat(null),
    units: [max_units]Unit = @splat(.{}),
};

pub fn nvmeBase(dev: *exec.Device) *NvmeBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

pub fn unitOf(io: *exec.IORequest) *Unit {
    return @alignCast(@fieldParentPtr("unit", io.unit.?));
}

pub fn baseOf(io: *exec.IORequest) *NvmeBase {
    return nvmeBase(io.device.?);
}

pub fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @alignCast(@fieldParentPtr("req", io));
}

pub fn requestOf(msg: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", msg);
}

/// A unit's geometry: a run of blocks that stays.
pub fn geometry(unit: *const Unit, into: *td.DriveGeometry) void {
    const size = unit.blockBytes();
    into.* = .{
        .sector_size = size,
        .total_sectors = unit.blocks,
        .cylinders = @truncate(unit.blocks),
        .cyl_sectors = 1,
        .heads = 1,
        .track_sectors = 1,
        .buf_mem_type = exec.MEMF_ANY,
        .device_type = td.DG_DIRECT_ACCESS,
        .flags = 0,
        .erase_size = 0,
        .write_size = size,
        .map_base = 0,
    };
}

/// Whether `length` bytes from `offset` are whole blocks of the unit,
/// and on it.
pub fn inside(unit: *const Unit, offset: u64, length: u64) bool {
    const size: u64 = unit.blockBytes();
    if (offset % size != 0 or length % size != 0) return false;
    const total = unit.blocks * size;
    return offset <= total and length <= total - offset;
}

// --- the controller's registers ---------------------------------------------------------

/// What was written to memory and to the controller before, seen by the
/// controller before what is written after: a queue's entry before its
/// doorbell.
pub fn barrier() void {
    sdk.hardware.barrier.full();
}

/// What the controller wrote read in order: a completion's phase before
/// the rest of it.
pub fn readBarrier() void {
    sdk.hardware.barrier.reads();
}

pub fn reg(c: *const Controller, offset: usize) *volatile u32 {
    return @ptrFromInt(c.regs + offset);
}

/// A 64-bit register, as two 32-bit halves: the low one first, as the
/// specification has a controller take them.
pub fn read64(c: *const Controller, offset: usize) u64 {
    const low: u64 = reg(c, offset).*;
    const high: u64 = reg(c, offset + 4).*;
    return low | high << 32;
}

pub fn write64(c: *const Controller, offset: usize, value: u64) void {
    reg(c, offset).* = @truncate(value);
    reg(c, offset + 4).* = @truncate(value >> 32);
}

// --- memory the controller reads and writes ---------------------------------------------

/// What the processor wrote in [address, address + bytes) put in memory,
/// for the controller to read - where it does not see the caches. Where
/// it does, nothing is needed here: every such write is followed by
/// `submit`, whose `barrier` orders it before the doorbell, as Linux's
/// writel does.
pub fn toDevice(c: *const Controller, address: usize, bytes: usize) void {
    if (bytes == 0 or c.coherent) return;
    var length: u32 = @intCast(bytes);
    _ = c.sys.CachePreDMA(@ptrFromInt(address), &length, 0);
}

/// The caches' copy of [address, address + bytes) dropped, so what the
/// controller wrote there is read - where it does not see the caches.
/// Where it does, nothing is needed here: every such read comes after a
/// completion's phase and `readBarrier`, as Linux's dma_rmb has it, and
/// the barrier's clobber keeps the compiler from reading it earlier.
pub fn fromDevice(c: *const Controller, address: usize, bytes: usize) void {
    if (bytes == 0 or c.coherent) return;
    var length: u32 = @intCast(bytes);
    c.sys.CachePostDMA(@ptrFromInt(address), &length, 0);
}

/// `bytes` of memory for the controller, on a page and zeroed, out of
/// the caches; never given back - the device stays.
pub fn allocPages(c: *const Controller, bytes: usize) ?usize {
    const memory = c.sys.AllocMem(@intCast(bytes + page), exec.MEMF_DMA | exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    const address = std.mem.alignForward(usize, @intFromPtr(memory), page);
    toDevice(c, address, bytes);
    return address;
}

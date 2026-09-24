// SPDX-License-Identifier: MIT
//! sd.device's own state: the base, the block of internal memory the
//! controller's DMA and its interrupt reach, and the small conversions
//! between what the controller says and what a caller is told.
//!
//! **Why a second block of memory.** A device's base is allocated where
//! exec's MakeLibrary puts it, which on this board is the external memory
//! - and the controller's DMA cannot reach external memory at all, nor
//! may an interrupt reach for something the cache might have to fetch. So
//! everything the DMA or the interrupt touches lives in one block the
//! init allocates internal, and the base points at it.
//!
//! The block also holds the buffer every transfer passes through. A
//! caller's buffer is wherever the caller's memory came from, and that is
//! usually external; copying through a buffer the DMA can reach costs one
//! pass over the bytes and makes every address the controller sees a
//! known-good one.

const sdk = @import("sdk");
const exec = sdk.exec;
const td = sdk.devices.trackdisk;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const sdmmc = @import("sdmmc.zig");
const card = @import("card.zig");

pub const DEVICE_NAME = "sd.device";

/// The blocks one transfer moves at a time. A file system asks in
/// clusters, and a card of 4 to 32 GB is formatted with 32 KiB ones, so
/// such a cluster takes two rounds. The second round costs a command -
/// tens of microseconds against the milliseconds the data takes - and a
/// buffer twice the size would cost 16 KiB of internal memory, which is
/// worth more than that.
pub const chunk_blocks: u32 = 32;
pub const chunk_bytes: u32 = chunk_blocks * @as(u32, @intCast(card.block_bytes));
/// One descriptor per 4096 bytes of it.
pub const descriptors: u32 = chunk_bytes / sdmmc.dma_buffer_max;

/// How long a command may take before the card is given up on. A card may
/// stall for a quarter of a second over a write it has to erase for, so
/// the allowance is generous; what matters is that it ends.
pub const command_timeout_us: u32 = 1_000_000;
/// How long a card may take to power up. Its specification asks for a
/// second, and cards take longer than that; three seconds is what a card
/// that is slow but sound needs.
pub const identify_timeout_us: u32 = 3_000_000;

/// The block the DMA and the interrupt reach: internal memory, aligned
/// for the cache, and never moved once the init has it.
pub const Work = extern struct {
    /// The interrupt server, whose data points back at the base.
    int: exec.Interrupt = .{},
    /// What the controller and its DMA have said since the task last
    /// looked. The server adds to these and the task takes them.
    status: u32 = 0,
    dma_status: u32 = 0,
    /// The chain the controller's DMA runs.
    chain: [descriptors]sdmmc.Descriptor = @splat(.{}),
    /// Every transfer's bytes on their way through.
    buffer: [chunk_bytes]u8 align(64) = @splat(0),
};

/// The device's base. One unit, whose port is the task's work queue.
pub const SdBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    unit: exec.Unit,
    /// The task every command runs on: a transfer waits, and BeginIO may
    /// be called from anywhere.
    task: exec.Task,
    /// Its stack, as AllocMem gave it.
    stack: ?*anyopaque = null,
    /// The block the DMA and the interrupt reach, as AllocMem gave it and
    /// aligned for use.
    work: ?*Work = null,
    work_memory: ?*anyopaque = null,
    /// The card in the slot, if one answered.
    card: card.Card = .{},
    /// Whether a card is in and identified.
    present: u8 = 0,
    /// Whether the interrupt server is hooked up.
    hooked: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    /// How often the card has been identified afresh, which is what
    /// TD_CHANGENUM counts.
    change_num: u32 = 0,
    /// The task's signal the controller's interrupt raises.
    int_mask: u32 = 0,
    /// The task's own port, for the timer it waits on.
    port: ?*exec.MsgPort = null,
    timer_io: timer.TimeRequest = .{},
    /// The task that started this one, and the signal it waits on until
    /// the slot has been looked at. Cleared once that is done.
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    started: u8 = 0,
    /// Whether the board has a slot, and its pads as the board's card-slot
    /// part gave them (`no_pin`: no such line).
    has_slot: u8 = 0,
    pad2: [1]u8 = .{0},
    slot: Slot = .{},
    /// What the device was loaded from, for its expunge to hand back.
    seg_list: ?*anyopaque = null,
};

/// A line the slot does not have.
pub const no_pin: u8 = 0xFF;

/// The slot's pads, as the board wired them.
pub const Slot = extern struct {
    clock: u8 = 0,
    command: u8 = 0,
    data: [4]u8 = .{ 0, 0, 0, 0 },
    detect: u8 = 0xFF,
    write_protect: u8 = 0xFF,
};

pub fn sdBase(dev: *exec.Device) *SdBase {
    return @fieldParentPtr("dev", dev);
}

/// The base of the request's unit.
pub fn baseOf(io: *exec.IORequest) *SdBase {
    const unit = io.unit.?;
    return @fieldParentPtr("unit", unit);
}

pub fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @alignCast(@fieldParentPtr("req", io));
}

/// The request a message on the unit's port belongs to.
pub fn requestOf(msg: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", msg);
}

// --- what the controller said ---------------------------------------------

/// The controller's complaints, in the card's terms.
pub fn faultOf(status: u32, dma_status: u32) card.Fault {
    return .{
        .no_answer = status & (sdmmc.int_response_timeout |
            sdmmc.int_data_read_timeout | sdmmc.int_host_timeout) != 0,
        .bad_checksum = status & (sdmmc.int_response_crc | sdmmc.int_data_crc |
            sdmmc.int_end_bit | sdmmc.int_start_bit) != 0,
        .other = status & (sdmmc.int_response_error | sdmmc.int_fifo_run |
            sdmmc.int_hardware_locked) != 0 or
            dma_status & (sdmmc.dma_int_bus_error | sdmmc.dma_int_no_descriptor) != 0,
    };
}

// --- the unit -------------------------------------------------------------

/// Whether a range of bytes is on the card, and whole blocks.
pub fn inside(sb: *SdBase, offset: u64, len: u64) bool {
    const block_bytes = card.block_bytes;
    if (offset % block_bytes != 0 or len % block_bytes != 0) return false;
    return sb.card.holds(offset / block_bytes, len / block_bytes);
}

pub fn geometry(sb: *SdBase, into: *td.DriveGeometry) void {
    const blocks = sb.card.csd.blocks;
    into.* = .{
        .sector_size = @intCast(card.block_bytes),
        .total_sectors = blocks,
        // A card has no geometry of its own: it is a run of blocks, and
        // saying so is truer than inventing heads and tracks for it.
        .cylinders = @truncate(blocks),
        .cyl_sectors = 1,
        .heads = 1,
        .track_sectors = 1,
        .buf_mem_type = exec.MEMF_ANY,
        .device_type = td.DG_DIRECT_ACCESS,
        .flags = td.DGF_REMOVABLE,
        // A card erases for itself, and nothing here can be read through
        // the address space.
        .erase_size = 0,
        .write_size = @intCast(card.block_bytes),
        .map_base = 0,
    };
}

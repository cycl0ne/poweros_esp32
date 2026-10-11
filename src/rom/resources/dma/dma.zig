// SPDX-License-Identifier: MPL-2.0
//! dma.resource: the chip's DMA engines, their channels handed out to one
//! owner each. AllocDMAChannel claims a channel under the resource's lock
//! and gives null, or the owner's name if it is taken; FreeDMAChannel
//! gives it back, and also stops and disconnects the channel. The ROM tag
//! is cold start at priority 70 and the functions start in the first slot
//! (sdk/fd/dma_lib.fd).
//!
//! **General channels**: the ESP32-S3's GDMA, the ESP32-P4's AHB and AXI
//! engines numbered as one (`esp32s3/channels.zig`,
//! `esp32p4/channels.zig`). The owner connects one (to a peripheral, or
//! memory to memory) and starts its sides on descriptor chains in internal
//! RAM. Its interrupts are exec's: the owner puts a server on
//! dmaIntNumber(channel, side) and clears what it handles.
//! ConnectDMAChannel refuses a peripheral another channel of the same
//! engine is connected to.
//!
//! **The 2D-DMA's channels** (the ESP32-P4's) are numbered after them. The
//! resource starts the 2D-DMA when it is made, hands its channels out and
//! stops one given back; its owner drives it through `sdk.hardware.dma2d`,
//! and the general calls refuse it.
//!
//! It builds against the SDK.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const vec = exec.vec;
const types = sdk.resources.dma;
/// The chip's channels: the general ones, the 2D-DMA's.
const chip = switch (sdk.hardware.chip) {
    .esp32s3 => @import("esp32s3/channels.zig"),
    .esp32p4 => @import("esp32p4/channels.zig"),
};
const general = chip.general;
const all_channels = general + chip.dma2d_channels;

pub const RESOURCE_NAME = types.DMANAME;
const RESOURCE_VERSION = 1;
const RESOURCE_REVISION = 1;
const BUILD_DATE = "10.10.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// Its functions, as the SDK has them (sdk/fd/dma_lib.fd).
pub const interface = sdk.interface.dma;
pub const LVO = interface.LVO;

// Every function in LVO is an lvo* function here, with the SDK's signature
// (after the base), in its slot.
comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("dma.resource's lvo" ++ d.name ++ " doesn't match the SDK's Fn." ++ d.name);
        }
        if (vectors[@divExact(-@field(LVO, d.name), exec.slot_size) - 1] != vec(f)) {
            @compileError("dma.resource's lvo" ++ d.name ++ " isn't in the slot of LVO." ++ d.name);
        }
    }
    if (types.DMA_CHANNELS != general) @compileError("the SDK's DMA_CHANNELS isn't the chip's");
    if (types.DMA2D_CHANNELS != chip.dma2d_channels) @compileError("the SDK's DMA2D_CHANNELS isn't the chip's");
    if (types.DMA_MAXPRI != chip.max_priority) @compileError("the SDK's DMA_MAXPRI isn't the chip's");
}

/// The base.
const DmaBase = extern struct {
    lib: exec.Library,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// Each channel's owner (the name given to AllocDMAChannel), or null:
    /// the general ones, then the 2D-DMA's.
    owner: [all_channels]?[*:0]const u8,
    /// The number each general channel is connected to on its engine, or
    /// no_peripheral.
    peri: [general]u8,
    /// The two tables above, and the connections they say: a spinlock,
    /// held for the test and the change.
    lock: exec.Lock,
};

fn dmaBase(lib: *exec.Library) *DmaBase {
    return @fieldParentPtr("lib", lib);
}

fn sideOf(side: u32) ?chip.Side {
    return switch (side) {
        types.DMA_IN => .in,
        types.DMA_OUT => .out,
        else => null,
    };
}

fn lvoAllocDMAChannel(db: *DmaBase, channel: u32, name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    if (channel >= all_channels) return "(no such channel)";
    db.sys_base.AcquireLock(&db.lock);
    defer db.sys_base.ReleaseLock(&db.lock);
    if (db.owner[channel]) |owner| return owner;
    db.owner[channel] = name;
    return null;
}

fn lvoFreeDMAChannel(db: *DmaBase, channel: u32) callconv(.c) void {
    if (channel >= all_channels) return;
    db.sys_base.AcquireLock(&db.lock);
    defer db.sys_base.ReleaseLock(&db.lock);
    if (channel < general) {
        chip.disconnect(channel);
        db.peri[channel] = chip.no_peripheral;
    } else {
        chip.stop2d(channel - general);
    }
    db.owner[channel] = null;
}

fn lvoDMAChannelOwner(db: *DmaBase, channel: u32) callconv(.c) ?[*:0]const u8 {
    if (channel >= all_channels) return null;
    return db.owner[channel];
}

/// Whether another channel of `channel`'s engine is connected to number
/// `id`. Two channels on one peripheral would both take its requests;
/// ESP-IDF's gdma_connect refuses that too.
fn peripheralTaken(db: *DmaBase, channel: u32, id: u8) bool {
    for (db.peri, 0..) |p, other| {
        if (other != channel and chip.sameEngine(@intCast(other), channel) and p == id) return true;
    }
    return false;
}

/// Memory to memory still needs a number on both sides, one no other
/// channel of the engine is connected to: the first free one the chip
/// offers.
fn freePeripheral(db: *DmaBase, channel: u32) ?u8 {
    for (chip.memoryIds(channel)) |id| {
        if (!peripheralTaken(db, channel, id)) return id;
    }
    return null;
}

fn lvoConnectDMAChannel(db: *DmaBase, channel: u32, peripheral: u32, flags: u32) callconv(.c) bool {
    if (channel >= general) return false;
    const mem_to_mem = peripheral == types.DMAPERI_MEMORY;
    const wanted: ?u8 = if (mem_to_mem) null else chip.peripheralId(channel, peripheral) orelse return false;
    db.sys_base.AcquireLock(&db.lock);
    defer db.sys_base.ReleaseLock(&db.lock);
    const id: u8 = wanted orelse freePeripheral(db, channel) orelse return false;
    if (peripheralTaken(db, channel, id)) return false;
    chip.connect(channel, id, mem_to_mem, flags & types.DMACF_BURST != 0, flags & types.DMACF_LOOP != 0, flags & types.DMACF_WIDE != 0);
    db.peri[channel] = id;
    return true;
}

fn lvoStartDMA(_: *DmaBase, channel: u32, side: u32, list: *types.DMADescriptor) callconv(.c) bool {
    const s = sideOf(side) orelse return false;
    if (channel >= general) return false;
    const addr = @intFromPtr(list);
    if (!chip.descriptorFits(channel, addr)) return false;
    chip.start(channel, s, @intCast(addr));
    return true;
}

fn lvoStopDMA(_: *DmaBase, channel: u32, side: u32) callconv(.c) void {
    const s = sideOf(side) orelse return;
    if (channel < general) chip.stop(channel, s);
}

fn lvoResetDMA(_: *DmaBase, channel: u32, side: u32) callconv(.c) void {
    const s = sideOf(side) orelse return;
    if (channel < general) chip.reset(channel, s);
}

fn lvoEnableDMAInts(_: *DmaBase, channel: u32, side: u32, mask: u32) callconv(.c) void {
    const s = sideOf(side) orelse return;
    if (channel < general) chip.setIntEnable(channel, s, mask);
}

fn lvoDMAIntStatus(_: *DmaBase, channel: u32, side: u32) callconv(.c) u32 {
    const s = sideOf(side) orelse return 0;
    return if (channel < general) chip.intStatus(channel, s) else 0;
}

fn lvoDMARawIntStatus(_: *DmaBase, channel: u32, side: u32) callconv(.c) u32 {
    const s = sideOf(side) orelse return 0;
    return if (channel < general) chip.rawIntStatus(channel, s) else 0;
}

fn lvoClearDMAInts(_: *DmaBase, channel: u32, side: u32, mask: u32) callconv(.c) void {
    const s = sideOf(side) orelse return;
    if (channel < general) chip.clearInts(channel, s, mask);
}

fn within(addr: usize, length: u32, start: usize, end: usize) bool {
    return addr >= start and addr < end and length <= end - addr;
}

fn lvoAllocDMAChain(db: *DmaBase, side: u32, buffer: ?*anyopaque, length: u32, flags: u32) callconv(.c) ?*types.DMADescriptor {
    if (sideOf(side) == null or length == 0) return null;
    const addr = @intFromPtr(buffer orelse return null);
    const chunk: u32 = if (within(addr, length, chip.internal_start, chip.internal_end))
        types.DMA_CHUNK
    else if (within(addr, length, chip.psram_start, chip.psram_end))
        types.DMA_CHUNK_PSRAM
    else
        return null;
    const count = (length + chunk - 1) / chunk;
    const block = db.sys_base.AllocVec(@as(usize, count) * @sizeOf(types.DMADescriptor), exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return null;
    const descs: [*]types.DMADescriptor = @ptrCast(@alignCast(block));
    const out = side == types.DMA_OUT;
    var done: u32 = 0;
    for (0..count) |i| {
        const n = @min(length - done, chunk);
        const last = i + 1 == count;
        const eof = if (out and last) types.DMADF_SUC_EOF else 0;
        descs[i] = .init(@ptrFromInt(addr + done), n, if (out) n else 0, eof | types.DMADF_OWNER);
        descs[i].next = if (!last) &descs[i + 1] else if (flags & types.DMACHF_LOOP != 0) &descs[0] else null;
        done += n;
    }
    // Out of the data cache, where it covers internal memory.
    var bytes: u32 = count * @sizeOf(types.DMADescriptor);
    _ = db.sys_base.CachePreDMA(block, &bytes, 0);
    return &descs[0];
}

fn lvoFreeDMAChain(db: *DmaBase, chain: ?*types.DMADescriptor) callconv(.c) void {
    db.sys_base.FreeVec(chain);
}

fn lvoDMAEOFDescriptor(_: *DmaBase, channel: u32, side: u32) callconv(.c) ?*types.DMADescriptor {
    const s = sideOf(side) orelse return null;
    if (channel >= general) return null;
    const addr = chip.eofDescriptor(channel, s);
    return if (addr == 0) null else @ptrFromInt(addr);
}

fn lvoSetDMAPriority(_: *DmaBase, channel: u32, side: u32, priority: u32) callconv(.c) bool {
    const s = sideOf(side) orelse return false;
    if (channel >= general or priority > chip.max_priority) return false;
    chip.setPriority(channel, s, priority);
    return true;
}

/// exec has copied the tag's name, version and ID string into the base.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const db = dmaBase(lib);
    lib.revision = RESOURCE_REVISION;
    db.sys_base = sys_base;
    sys_base.InitLock(&db.lock, RESOURCE_NAME, exec.LOCKORDER_DRIVER, 0);
    db.owner = @splat(null);
    db.peri = @splat(chip.no_peripheral);
    chip.init();
    return lib;
}

const vectors = [_]*const anyopaque{
    vec(lvoAllocDMAChannel),
    vec(lvoFreeDMAChannel),
    vec(lvoDMAChannelOwner),
    vec(lvoConnectDMAChannel),
    vec(lvoStartDMA),
    vec(lvoStopDMA),
    vec(lvoResetDMA),
    vec(lvoEnableDMAInts),
    vec(lvoDMAIntStatus),
    vec(lvoDMARawIntStatus),
    vec(lvoClearDMAInts),
    vec(lvoAllocDMAChain),
    vec(lvoFreeDMAChain),
    vec(lvoDMAEOFDescriptor),
    vec(lvoSetDMAPriority),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(DmaBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

export const dma_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &dma_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 70,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};

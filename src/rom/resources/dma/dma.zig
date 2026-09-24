// SPDX-License-Identifier: MPL-2.0
//! dma.resource: the chip's general DMA engine (GDMA, sdk/hardware/gdma.zig),
//! its 5 channels handed out to one owner each. AllocDMAChannel claims a
//! channel under Forbid and gives null, or the owner's name if it is taken;
//! FreeDMAChannel gives it back, and also stops and disconnects the
//! channel. The ROM tag is cold start at priority 70 and the functions
//! start in the first slot (sdk/fd/dma_lib.fd).
//!
//! The owner connects the channel (to a peripheral, or memory to memory)
//! and starts its sides on descriptor chains in internal RAM. Its
//! interrupts are exec's: the owner puts a server on dmaIntNumber(channel,
//! side) and clears what it handles. ConnectDMAChannel refuses a
//! peripheral another channel is connected to. Open points: docs/dma.md.
//!
//! It builds against the SDK.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const gdma = sdk.hardware.gdma;
const vec = exec.vec;
const types = sdk.resources.dma;

pub const RESOURCE_NAME = types.DMANAME;
const RESOURCE_VERSION = 1;
const RESOURCE_REVISION = 0;
const BUILD_DATE = "15.9.2026";
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
    if (types.DMA_CHANNELS != gdma.channels) @compileError("the SDK's DMA_CHANNELS isn't the GDMA's");
    if (types.DMA_MAXPRI != gdma.max_priority) @compileError("the SDK's DMA_MAXPRI isn't the GDMA's");
}

/// The base.
const DmaBase = extern struct {
    lib: exec.Library,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// Each channel's owner (the name given to AllocDMAChannel), or null.
    owner: [gdma.channels]?[*:0]const u8,
    /// The peripheral ID each channel is connected to, or no_peripheral.
    peri: [gdma.channels]u8,
};

fn dmaBase(lib: *exec.Library) *DmaBase {
    return @fieldParentPtr("lib", lib);
}

/// The highest peripheral ID (RMT).
const max_peripheral = types.DMAPERI_RMT;

/// Where descriptors may be: the internal data RAM the GDMA reaches
/// (ESP-IDF's SOC_DMA_LOW/HIGH), which LINK's 20 address bits can name.
const dma_ram_start = 0x3FC8_8000;
const dma_ram_end = 0x3FD0_0000;

fn sideOf(side: u32) ?gdma.Side {
    return switch (side) {
        types.DMA_IN => .in,
        types.DMA_OUT => .out,
        else => null,
    };
}

fn lvoAllocDMAChannel(db: *DmaBase, channel: u32, name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    if (channel >= gdma.channels) return "(no such channel)";
    db.sys_base.Forbid();
    defer db.sys_base.Permit();
    if (db.owner[channel]) |owner| return owner;
    db.owner[channel] = name;
    return null;
}

fn lvoFreeDMAChannel(db: *DmaBase, channel: u32) callconv(.c) void {
    if (channel >= gdma.channels) return;
    db.sys_base.Forbid();
    defer db.sys_base.Permit();
    gdma.disconnect(channel);
    db.peri[channel] = gdma.no_peripheral;
    db.owner[channel] = null;
}

fn lvoDMAChannelOwner(db: *DmaBase, channel: u32) callconv(.c) ?[*:0]const u8 {
    if (channel >= gdma.channels) return null;
    return db.owner[channel];
}

/// Whether another channel is connected to peripheral `id`. Two channels
/// on one peripheral would both take its requests; ESP-IDF's gdma_connect
/// refuses that too.
fn peripheralTaken(db: *DmaBase, channel: u32, id: u8) bool {
    for (db.peri, 0..) |p, c| {
        if (c != channel and p == id) return true;
    }
    return false;
}

/// Memory to memory still needs a peripheral ID on both sides, one no other
/// channel is connected to. ESP-IDF's async_memcpy takes the lowest; this
/// takes the highest (RMT first), so the IDs drivers need (SPI, LCD) stay
/// free longer.
fn freePeripheral(db: *DmaBase, channel: u32) ?u8 {
    var id: u8 = max_peripheral + 1;
    while (id > 0) {
        id -= 1;
        if (!peripheralTaken(db, channel, id)) return id;
    }
    return null;
}

fn lvoConnectDMAChannel(db: *DmaBase, channel: u32, peripheral: u32, flags: u32) callconv(.c) bool {
    if (channel >= gdma.channels) return false;
    const mem_to_mem = peripheral == types.DMAPERI_MEMORY;
    if (!mem_to_mem and peripheral > max_peripheral) return false;
    db.sys_base.Forbid();
    defer db.sys_base.Permit();
    const id: u8 = if (mem_to_mem) freePeripheral(db, channel) orelse return false else @intCast(peripheral);
    if (peripheralTaken(db, channel, id)) return false;
    gdma.connect(channel, id, mem_to_mem, flags & types.DMACF_BURST != 0, flags & types.DMACF_LOOP != 0, flags & types.DMACF_WIDE != 0);
    db.peri[channel] = id;
    return true;
}

fn lvoStartDMA(_: *DmaBase, channel: u32, side: u32, list: *types.DMADescriptor) callconv(.c) bool {
    const s = sideOf(side) orelse return false;
    if (channel >= gdma.channels) return false;
    const addr = @intFromPtr(list);
    if (addr % 4 != 0 or addr < dma_ram_start or addr >= dma_ram_end) return false;
    gdma.start(channel, s, @intCast(addr));
    return true;
}

fn lvoStopDMA(_: *DmaBase, channel: u32, side: u32) callconv(.c) void {
    const s = sideOf(side) orelse return;
    if (channel < gdma.channels) gdma.stop(channel, s);
}

fn lvoResetDMA(_: *DmaBase, channel: u32, side: u32) callconv(.c) void {
    const s = sideOf(side) orelse return;
    if (channel < gdma.channels) gdma.reset(channel, s);
}

fn lvoEnableDMAInts(_: *DmaBase, channel: u32, side: u32, mask: u32) callconv(.c) void {
    const s = sideOf(side) orelse return;
    if (channel < gdma.channels) gdma.setIntEnable(channel, s, mask);
}

fn lvoDMAIntStatus(_: *DmaBase, channel: u32, side: u32) callconv(.c) u32 {
    const s = sideOf(side) orelse return 0;
    return if (channel < gdma.channels) gdma.intStatus(channel, s) else 0;
}

fn lvoDMARawIntStatus(_: *DmaBase, channel: u32, side: u32) callconv(.c) u32 {
    const s = sideOf(side) orelse return 0;
    return if (channel < gdma.channels) gdma.rawIntStatus(channel, s) else 0;
}

fn lvoClearDMAInts(_: *DmaBase, channel: u32, side: u32, mask: u32) callconv(.c) void {
    const s = sideOf(side) orelse return;
    if (channel < gdma.channels) gdma.clearInts(channel, s, mask);
}

/// Where the GDMA reaches PSRAM: the data bus (ESP-IDF's SOC_DMA_EXT).
const psram_start = 0x3C00_0000;
const psram_end = 0x3E00_0000;

fn within(addr: usize, length: u32, start: usize, end: usize) bool {
    return addr >= start and addr < end and length <= end - addr;
}

fn lvoAllocDMAChain(db: *DmaBase, side: u32, buffer: ?*anyopaque, length: u32, flags: u32) callconv(.c) ?*types.DMADescriptor {
    if (sideOf(side) == null or length == 0) return null;
    const addr = @intFromPtr(buffer orelse return null);
    const chunk: u32 = if (within(addr, length, dma_ram_start, dma_ram_end))
        types.DMA_CHUNK
    else if (within(addr, length, psram_start, psram_end))
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
    return &descs[0];
}

fn lvoFreeDMAChain(db: *DmaBase, chain: ?*types.DMADescriptor) callconv(.c) void {
    db.sys_base.FreeVec(chain);
}

fn lvoDMAEOFDescriptor(_: *DmaBase, channel: u32, side: u32) callconv(.c) ?*types.DMADescriptor {
    const s = sideOf(side) orelse return null;
    if (channel >= gdma.channels) return null;
    const addr = gdma.eofDescriptor(channel, s);
    return if (addr == 0) null else @ptrFromInt(addr);
}

fn lvoSetDMAPriority(_: *DmaBase, channel: u32, side: u32, priority: u32) callconv(.c) bool {
    const s = sideOf(side) orelse return false;
    if (channel >= gdma.channels or priority > gdma.max_priority) return false;
    gdma.setPriority(channel, s, priority);
    return true;
}

/// exec has copied the tag's name, version and ID string into the base.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const db = dmaBase(lib);
    lib.revision = RESOURCE_REVISION;
    db.sys_base = sys_base;
    db.owner = @splat(null);
    db.peri = @splat(gdma.no_peripheral);
    gdma.init();
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

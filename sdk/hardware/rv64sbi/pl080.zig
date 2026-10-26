// SPDX-License-Identifier: MIT
//! ARM's PrimeCell PL080 DMA controller - the one in the JH7110's
//! security block (CHIP_JH7110_SDMA), eight channels on sixteen request
//! lines, which feeds the crypto engine - as the owners of its channels
//! drive them. The channels are dma.resource's to hand out,
//! PL080_CHANNEL0 on (sdk/resources/dma.zig): the resource lets the
//! controller out of reset and turns it on, and stops a channel given
//! back. An owner finds the controller with `find`. The eight channels
//! share its interrupt, so a server asks its own channel (`raised`)
//! before it says the interrupt was its.
//!
//! **A transfer** is a list of items, each at most 4095 of its source's
//! accesses, linked by address. `fill` writes the list for a buffer to
//! or from a peripheral's FIFO, or from one buffer to another; `start`
//! loads its first item into the channel and turns the channel on, which
//! then fetches the rest itself and turns itself off after the last;
//! `running` and `failed` say where it got to. Only the last item counts
//! towards the channel's terminal count, so it raises the interrupt once.
//!
//! **Two AHB masters**, and which reaches what is the chip's: on the
//! JH7110 memory and the lists are reached over the first, the security
//! block's FIFO over the second (Linux's device tree: mem-bus-interface-
//! ahb1, lli-bus-interface-ahb1, the crypto engine's requests on AHB2).
//!
//! Addresses are 32 bits, so every buffer and item is below 4 GiB
//! (MEMF_DMA). The controller reads and writes memory behind the CPU's
//! caches: the owner writes items and outgoing buffers back before a
//! start, and drops what it holds of an incoming buffer after the end.
//!
//! After ARM's PL080 technical reference manual (DDI 0196) and Linux's
//! amba-pl08x. It keeps no state: every call is register writes at the
//! controller's address.

const st = @import("../../libs/expansion/systemtags.zig");
const parts = @import("parts.zig");
const reg = @import("mmio.zig").reg;

/// The channels a controller has: the PL080's eight (Linux's vendor data
/// for it; the JH7110's device tree names the PL080).
pub const channels: u32 = 8;

/// The board's controller: where its registers are, and its interrupt.
pub const Controller = struct {
    base: usize,
    irq: u32,
};

/// The board's controller, from its PARTKIND_DMA part, or null.
pub fn find() ?Controller {
    const part = parts.find(st.PARTKIND_DMA, st.CHIP_JH7110_SDMA) orelse return null;
    return .{
        .base = parts.value(part, st.PART_Address) orelse return null,
        .irq = @intCast(parts.value(part, st.PART_Irq) orelse return null),
    };
}

// The controller's registers, then a channel's every 0x20 from 0x100.
const INT_TC_STATUS = 0x004;
const INT_TC_CLEAR = 0x008;
const INT_ERROR_STATUS = 0x00C;
const INT_ERROR_CLEAR = 0x010;
const RAW_INT_TC = 0x014;
const RAW_INT_ERROR = 0x018;
const ENABLED_CHANNELS = 0x01C;
const CONFIGURATION = 0x030;
/// DMACConfiguration: the controller on, both masters little-endian.
const CONFIG_ENABLE: u32 = 1 << 0;

const CH_SRC = 0x00;
const CH_DST = 0x04;
const CH_LLI = 0x08;
const CH_CONTROL = 0x0C;
const CH_CONFIG = 0x10;

fn channelReg(base: usize, channel: u32, offset: usize) *volatile u32 {
    return reg(base + 0x100 + 0x20 * @as(usize, channel) + offset);
}

// A channel's control word: the transfers, both bursts and widths, which
// master each side is on, whether each side steps, and the terminal
// count's interrupt.
const CTL_SBSIZE_SHIFT: u5 = 12;
const CTL_DBSIZE_SHIFT: u5 = 15;
const CTL_SWIDTH_SHIFT: u5 = 18;
const CTL_DWIDTH_SHIFT: u5 = 21;
const CTL_SRC_MASTER2: u32 = 1 << 24;
const CTL_DST_MASTER2: u32 = 1 << 25;
const CTL_SRC_STEP: u32 = 1 << 26;
const CTL_DST_STEP: u32 = 1 << 27;
const CTL_TC_INT: u32 = 1 << 31;
/// The most accesses one item makes.
const transfers_max: u32 = 0xFFF;

// A channel's configuration word: on, the request lines, the flow, its
// interrupts let through to the controller's line, and halted.
const CFG_ENABLE: u32 = 1 << 0;
const CFG_SRC_REQUEST_SHIFT: u5 = 1;
const CFG_DST_REQUEST_SHIFT: u5 = 6;
const CFG_FLOW_SHIFT: u5 = 11;
const CFG_ERROR_INT: u32 = 1 << 14;
const CFG_TC_INT: u32 = 1 << 15;
const CFG_ACTIVE: u32 = 1 << 17;
const CFG_HALT: u32 = 1 << 18;

/// How wide each access to one side is.
pub const Width = enum(u32) { byte = 0, half = 1, word = 2 };

/// How many accesses a request moves: 1, 4, 8 ... 256.
pub const Burst = enum(u32) { one = 0, four = 1, eight = 2, sixteen = 3, thirty_two = 4, sixty_four = 5, one_twenty_eight = 6, two_fifty_six = 7 };

/// Who keeps the count: the controller always, moving memory to memory,
/// memory to a peripheral or a peripheral to memory.
pub const Flow = enum(u32) { memory_to_memory = 0, memory_to_peripheral = 1, peripheral_to_memory = 2 };

/// One side of a transfer: where, whether it steps through memory or
/// stays at one register, over which master (0 or 1), and how it is
/// accessed.
pub const End = struct {
    address: usize,
    step: bool = true,
    master: u1 = 0,
    width: Width = .word,
    burst: Burst = .four,
};

/// One item of a list, as the controller reads it: 16 bytes, on a word,
/// below 4 GiB. `next` is the next item's address, the master it is read
/// over in its lowest bit, or 0 after the last.
pub const Item = extern struct {
    src: u32,
    dst: u32,
    next: u32,
    control: u32,
};

comptime {
    if (@sizeOf(Item) != 16) @compileError("a PL080 list item is 16 bytes");
}

/// Bytes an item moves at the most, in whole 256-byte pieces so that
/// every item but the last ends on a burst of any size.
fn itemBytes(width: Width) u32 {
    const most = transfers_max << @intCast(@intFromEnum(width));
    return most & ~@as(u32, 255);
}

/// Items `bytes` from `from` to `to` take.
pub fn itemsFor(bytes: u32, from: Width) u32 {
    const each = itemBytes(from);
    return (bytes + each - 1) / each;
}

fn below4G(end: End, bytes: u32) bool {
    const reach: usize = if (end.step) bytes else 4;
    return end.address < (1 << 32) and reach <= (1 << 32) - end.address;
}

/// The list that moves `bytes` from `from` to `to`, written into
/// `items`, its items read over master `lists`: how many it took, or null
/// when `items` is too short, an address or an item is above 4 GiB, or
/// `bytes` is not a whole number of either side's accesses.
pub fn fill(items: []Item, from: End, to: End, bytes: u32, lists: u1) ?u32 {
    const src_unit = @as(u32, 1) << @intCast(@intFromEnum(from.width));
    const dst_unit = @as(u32, 1) << @intCast(@intFromEnum(to.width));
    if (bytes == 0 or bytes % src_unit != 0 or bytes % dst_unit != 0) return null;
    if (!below4G(from, bytes) or !below4G(to, bytes)) return null;
    const count = itemsFor(bytes, from.width);
    if (count > items.len) return null;
    const last_address = @intFromPtr(&items[count - 1]);
    if (last_address + @sizeOf(Item) > (1 << 32)) return null;
    const control_bits = @intFromEnum(from.burst) << CTL_SBSIZE_SHIFT |
        @intFromEnum(to.burst) << CTL_DBSIZE_SHIFT |
        @intFromEnum(from.width) << CTL_SWIDTH_SHIFT |
        @intFromEnum(to.width) << CTL_DWIDTH_SHIFT |
        (if (from.master == 1) CTL_SRC_MASTER2 else 0) |
        (if (to.master == 1) CTL_DST_MASTER2 else 0) |
        (if (from.step) CTL_SRC_STEP else 0) |
        (if (to.step) CTL_DST_STEP else 0);
    const each = itemBytes(from.width);
    var done: u32 = 0;
    for (0..count) |n| {
        const take = @min(bytes - done, each);
        const last = n + 1 == count;
        items[n] = .{
            .src = @intCast(from.address + if (from.step) done else 0),
            .dst = @intCast(to.address + if (to.step) done else 0),
            .next = if (last) 0 else @as(u32, @intCast(@intFromPtr(&items[n + 1]))) | lists,
            .control = control_bits | take / src_unit | (if (last) CTL_TC_INT else 0),
        };
        done += take;
    }
    return count;
}

/// The controller on. Its clock and reset are the chip's, and
/// dma.resource's.
pub fn enable(base: usize) void {
    reg(base + CONFIGURATION).* = CONFIG_ENABLE;
}

fn bit(channel: u32) u32 {
    return @as(u32, 1) << @intCast(channel);
}

/// Channel `channel` stopped: halted, so that it takes no more requests,
/// let finish what is in its FIFO, turned off, and its interrupts
/// cleared.
pub fn stop(base: usize, channel: u32) void {
    const config = channelReg(base, channel, CH_CONFIG);
    config.* |= CFG_HALT;
    var tries: u32 = 0;
    while (config.* & CFG_ACTIVE != 0 and tries < 100_000) : (tries += 1) {}
    config.* = 0;
    reg(base + INT_TC_CLEAR).* = bit(channel);
    reg(base + INT_ERROR_CLEAR).* = bit(channel);
}

/// The list at `items` (written back, below 4 GiB) run on channel
/// `channel` of the controller at `base`: its first item loaded into the
/// channel, which fetches the others itself. `src_request` and
/// `dst_request` are the peripherals' request lines, where a side is one.
/// With `interrupt` the channel raises the controller's line when it
/// finishes or fails; without, its owner watches it (`running`).
pub fn start(base: usize, channel: u32, items: [*]const Item, flow: Flow, src_request: u32, dst_request: u32, interrupt: bool) void {
    const first = items[0];
    reg(base + INT_TC_CLEAR).* = bit(channel);
    reg(base + INT_ERROR_CLEAR).* = bit(channel);
    channelReg(base, channel, CH_SRC).* = first.src;
    channelReg(base, channel, CH_DST).* = first.dst;
    channelReg(base, channel, CH_LLI).* = first.next;
    channelReg(base, channel, CH_CONTROL).* = first.control;
    channelReg(base, channel, CH_CONFIG).* = src_request << CFG_SRC_REQUEST_SHIFT |
        dst_request << CFG_DST_REQUEST_SHIFT |
        @intFromEnum(flow) << CFG_FLOW_SHIFT |
        (if (interrupt) CFG_ERROR_INT | CFG_TC_INT else 0) | CFG_ENABLE;
}

/// Whether channel `channel` is still on: it turns itself off after its
/// last item, or at an error.
pub fn running(base: usize, channel: u32) bool {
    return reg(base + ENABLED_CHANNELS).* & bit(channel) != 0;
}

/// Whether channel `channel` stopped at an error: an item or a buffer
/// it could not reach.
pub fn failed(base: usize, channel: u32) bool {
    return reg(base + RAW_INT_ERROR).* & bit(channel) != 0;
}

/// Whether channel `channel` finished its list: its terminal count.
pub fn finished(base: usize, channel: u32) bool {
    return reg(base + RAW_INT_TC).* & bit(channel) != 0;
}

/// What a channel raised the controller's line for.
pub const Raised = enum { nothing, finished, failed };

/// The interrupt's part: what channel `channel` raised the controller's
/// line for, which it then no longer does.
pub fn raised(base: usize, channel: u32) Raised {
    const mask = bit(channel);
    const failure = reg(base + INT_ERROR_STATUS).* & mask;
    const finish = reg(base + INT_TC_STATUS).* & mask;
    if (failure | finish == 0) return .nothing;
    reg(base + INT_TC_CLEAR).* = mask;
    reg(base + INT_ERROR_CLEAR).* = mask;
    return if (failure != 0) .failed else .finished;
}

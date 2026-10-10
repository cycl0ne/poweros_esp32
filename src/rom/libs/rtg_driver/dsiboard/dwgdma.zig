// SPDX-License-Identifier: MPL-2.0
//! The ESP32-P4's DW-GDMA, the AXI DMA controller that feeds the DSI and
//! CSI bridges, for the DSI board driver: one channel, which carries a
//! picture from PSRAM to the DSI bridge's FIFO, a block for each run of
//! lines that lies in one piece of memory.
//!
//! The channel works from a chain of linked-list items in memory: each a
//! source, a destination, a size, how to move it - 64-bit words, the
//! bridge asking for each burst by its hardware handshake - and the next
//! item. An item is the channel's while its VALID bit is set, and the
//! channel clears it once its block is done; a picture is sent again by
//! setting them again and restarting the channel, which is what the
//! transfer-done interrupt, at the chain's end, is for. The item is written through the uncached view of internal memory
//! (`uncached`), so the channel always reads what was written last.
//!
//! The controller's two masters: master 0 reaches the bridges, master 1
//! the memories, PSRAM among them. It keeps no state: every call is
//! register writes at `map.GDMA`. The values follow ESP-IDF v6.1's
//! dw_gdma.c, dw_gdma_ll.h and esp_lcd_panel_dpi.c.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const systimer = sdk.hardware.systimer;

const gdma = sdk.hardware.map.GDMA;

const cfg0 = gdma + 0x10;
const chen0 = gdma + 0x18;
const reset0 = gdma + 0x58;

/// CFG0: the controller on, its interrupt line on.
const dmac_en: u32 = 1 << 0;
const int_en: u32 = 1 << 1;

/// A channel's registers, the first channel's at 0x100.
fn channelReg(channel: u32, offset: usize) usize {
    return gdma + 0x100 + @as(usize, channel) * 0x100 + offset;
}
const ch_cfg_lo = 0x20;
const ch_cfg_hi = 0x24;
const ch_llp_lo = 0x28;
const ch_llp_hi = 0x2C;
const ch_intstatus_enable = 0x80;
const ch_intstatus = 0x88;
const ch_intsignal_enable = 0x90;
const ch_intclear = 0x98;

/// CH_CFG low: source and destination both from a linked list.
const cfg_linked_lists: u32 = 0xF;
/// CH_CFG high: memory to peripheral with the controller in charge of the
/// flow, hardware handshake on peripheral 0 (the DSI bridge), priority 1,
/// five reads and two writes outstanding at most.
const cfg_to_dsi: u32 = 0x0A02_0001;
/// CH_INTSTATUS: the block - here the picture - done.
pub const int_transfer_done: u32 = 1 << 1;

/// The linked-list item's CTL: from the memory master (1), incrementing,
/// to the bridge master (0), fixed, both 64 bits wide, bursts of 512 and
/// 256 words; AXI bursts of 16; then whether it is the chain's last item,
/// and valid.
const ctl_lo: u32 = 0x001E_1B41;
const ctl_hi: u32 = 0x0010_8840;
const ctl_hi_valid: u32 = 1 << 31;
const ctl_hi_last: u32 = 1 << 30;
/// LLP's LMS: items are read through master 1, the memories' master.
const llp_memory_master: u32 = 1;

/// A linked-list item: 64 bytes, on a 64-byte boundary.
pub const Item = extern struct {
    sar_lo: u32 = 0,
    sar_hi: u32 = 0,
    dar_lo: u32 = 0,
    dar_hi: u32 = 0,
    block_ts: u32 = 0,
    reserved: u32 = 0,
    llp_lo: u32 = 0,
    llp_hi: u32 = 0,
    ctl_lo: u32 = 0,
    ctl_hi: u32 = 0,
    status: [6]u32 = @splat(0),
};

/// The same memory without the data cache in front of it: internal
/// memory is mapped twice, the second time 1 GiB higher.
pub fn uncached(address: usize) usize {
    return address + 0x4000_0000;
}

/// The controller reset and on. False if the reset does not end.
pub fn start() bool {
    reg(reset0).* = 1;
    const since = systimer.uptimeUs();
    while (reg(reset0).* & 1 != 0) {
        if (systimer.uptimeUs() - since > 10_000) return false;
    }
    reg(cfg0).* = dmac_en | int_en;
    return true;
}

/// Channel `channel` set up to feed the DSI bridge, raising its
/// interrupt when a picture has gone.
pub fn setUpChannel(channel: u32) void {
    reg(channelReg(channel, ch_cfg_lo)).* = cfg_linked_lists;
    reg(channelReg(channel, ch_cfg_hi)).* = cfg_to_dsi;
    reg(channelReg(channel, ch_intstatus_enable)).* = 0xFFFF_FFFF;
    reg(channelReg(channel, ch_intsignal_enable)).* = 0;
    reg(channelReg(channel, ch_intclear)).* = 0xFFFF_FFFF;
    reg(channelReg(channel, ch_intsignal_enable)).* = int_transfer_done;
}

/// The item at `item` (its uncached view) made to send `bytes` from
/// `source` to `destination`, then go on to the item at `next` (its cached
/// address), or end the chain for 0; and handed to the channel.
pub fn fill(item: *volatile Item, source: usize, destination: u32, bytes: u32, next: usize) void {
    item.sar_lo = @intCast(source);
    item.sar_hi = 0;
    item.dar_lo = destination;
    item.dar_hi = 0;
    item.block_ts = bytes / 8 - 1;
    item.llp_lo = @as(u32, @intCast(next)) | llp_memory_master;
    item.llp_hi = 0;
    item.ctl_lo = ctl_lo;
    rearm(item, next == 0);
}

/// The item handed to the channel again: the channel cleared VALID when
/// it was done with it.
pub fn rearm(item: *volatile Item, last: bool) void {
    item.ctl_hi = ctl_hi | ctl_hi_valid | (if (last) ctl_hi_last else 0);
}

/// The channel started on the item at `item_address`, its cached
/// address, which is the one the channel is given.
pub fn run(channel: u32, item_address: usize) void {
    reg(channelReg(channel, ch_llp_lo)).* = @as(u32, @intCast(item_address & ~@as(usize, 0x3F))) | llp_memory_master;
    reg(channelReg(channel, ch_llp_hi)).* = 0;
    reg(chen0).* = @as(u32, 0x101) << @intCast(channel);
}

/// The channel stopped.
pub fn halt(channel: u32) void {
    reg(chen0).* = @as(u32, 0x100) << @intCast(channel);
}

/// What the channel raised, cleared.
pub fn takeInterrupts(channel: u32) u32 {
    const raised = reg(channelReg(channel, ch_intstatus)).*;
    reg(channelReg(channel, ch_intclear)).* = raised;
    return raised;
}

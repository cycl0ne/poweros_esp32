// SPDX-License-Identifier: MPL-2.0
//! The ESP32-P4's 2D-DMA, for the DSI board's engine: the DMA that moves
//! rectangles of pixels between memory and the PPA, or from memory to
//! memory.
//!
//! A transfer is a pair of channels: a send channel that reads memory and
//! a receive channel that writes it, each working from a descriptor. A 2D
//! descriptor names a picture (its width in pixels, which is also how its
//! rows are spaced, and its height), a block inside it (its width and
//! height) and where the block starts; the channel walks the block row by
//! row. A memory-to-memory copy is a send and a receive channel of the
//! same number, the receive one told to take what its sibling sends. A
//! fill is a receive channel alone, fed by the PPA; a blend two send
//! channels into the PPA - what is under, what goes over - and the
//! receive channel out of it. The PPA's scaler takes its blocks through
//! the descriptor port instead: it asks the send channel for the pixels
//! of each of its macro-blocks, and tells the receive channel where each
//! result goes, so the receive descriptor only names the picture.
//!
//! Send channels 0 and 1 and receive channel 0 are used, one transfer at
//! a time; its end is receive channel 0's interrupt, or read from its raw
//! bits. Each transfer sets its channels up afresh, as ESP-IDF v6.1's
//! dma2d.c does (`dma2d_connect`, `dma2d_set_transfer_ability`,
//! `dma2d_configure_dscr_port_mode`, `dma2d_start`).
//!
//! It keeps no state: every call is register writes at `map.DMA2D`.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const systimer = sdk.hardware.systimer;

const dma2d = sdk.hardware.map.DMA2D;

/// A send channel's registers, channel n's at n * 0x100; a receive
/// channel's at 0x500 + n * 0x100.
const out_ch0 = dma2d + 0x000;
const in_ch0 = dma2d + 0x500;
const out_channels = 2;

fn outChannel(channel: u32) usize {
    return out_ch0 + @as(usize, channel) * 0x100;
}

// The registers of both kinds of channel, as offsets.
const conf0 = 0x00;
const int_raw = 0x04;
const int_ena = 0x08;
const int_st = 0x0C;
const int_clr = 0x10;
const link_conf = 0x1C;
const link_addr = 0x20;
const state = 0x24;
const out_peri_sel = 0x38;
const in_peri_sel = 0x3C;
const out_color_convert = 0x48;
const in_color_convert = 0x4C;
/// A send channel's macro-block size for the descriptor port.
const out_dscr_port_blk = 0x6C;

const rst_conf = dma2d + 0xA04;
const out_arb_config = dma2d + 0xA18;
const in_arb_config = dma2d + 0xA1C;

/// CONF0: write the descriptor back (no), EOF when the data is out, burst
/// descriptor reads, check the owner bit (no), the data burst length
/// (4: 128 bytes), the macro-block size (3: none), stop at an AXI page
/// boundary, reorder (no), the channel's reset and its command gate. A
/// receive channel's bit 0 takes what its sibling send channel sends.
const conf_eof_mode: u32 = 1 << 1;
const conf_dscr_burst: u32 = 1 << 2;
const conf_burst_128: u32 = 4 << 6;
const conf_no_macro_block: u32 = 3 << 9;
const conf_page_bound: u32 = 1 << 12;
const conf_dscr_port: u32 = 1 << 11;
const conf_rst: u32 = 1 << 24;
const conf_cmd_disable: u32 = 1 << 25;
const conf_mem_trans: u32 = 1 << 0;
const conf_set: u32 = conf_eof_mode | conf_dscr_burst | conf_burst_128 | conf_no_macro_block | conf_page_bound;

/// LINK_CONF: stop, start - one bit higher on a receive channel, whose bit
/// 20 is AUTO_RET (the channel hands descriptors back itself).
const out_link_stop: u32 = 1 << 20;
const out_link_start: u32 = 1 << 21;
const in_link_stop: u32 = 1 << 21;
const in_link_start: u32 = 1 << 22;
/// STATE: the channel may be reset.
const out_reset_avail: u32 = 1 << 24;
const in_reset_avail: u32 = 1 << 23;
/// COLOR_CONVERT: no conversion.
const convert_off: u32 = 7 << 3;

/// A receive channel's interrupt bits: the block arrived, its
/// descriptor was wrong - every way a transfer ends.
const in_suc_eof: u32 = 1 << 1;
const in_err_eof: u32 = 1 << 2;
const in_dscr_err: u32 = 1 << 3;
pub const in_ended: u32 = in_suc_eof | in_err_eof | in_dscr_err;

/// RST_CONF: the AXI read and write sides' resets, the block's clock.
const axim_rd_rst: u32 = 1 << 0;
const axim_wr_rst: u32 = 1 << 1;
const rst_clk_en: u32 = 1 << 2;

/// What a channel feeds or is fed by: the PPA's scaler (both ways), its
/// blend unit (what is under and its output on 2, what goes over on 3),
/// and memory (a copy - any of 4 to 7 sending, 3 to 7 receiving).
pub const peri_ppa_srm: u32 = 1;
pub const peri_ppa_blend: u32 = 2;
pub const peri_ppa_blend_over: u32 = 3;
pub const peri_memory_out: u32 = 4;
pub const peri_memory_in: u32 = 3;
const peri_none: u32 = 7;

/// A descriptor: 24 bytes, on an 8-byte boundary.
pub const Descriptor = extern struct {
    /// Block height and width, then flags: 2D, last, the DMA's.
    block: u32 = 0,
    /// Picture height and width, and the bytes a pixel (pbyte).
    picture: u32 = 0,
    /// Where the block starts in the picture.
    origin: u32 = 0,
    buffer: u32 = 0,
    next: u32 = 0,
    pad: u32 = 0,
};

const block_2d: u32 = 1 << 29;
const block_suc_eof: u32 = 1 << 30;
const block_owner_dma: u32 = 1 << 31;
/// pbyte: one, two, three and four bytes a pixel.
pub const pbyte_1: u32 = 1;
pub const pbyte_2: u32 = 3;
pub const pbyte_3: u32 = 4;
pub const pbyte_4: u32 = 5;
/// What every 2D size and place holds at most.
pub const field_max: u32 = 0x3FFF;

/// A descriptor for one block: `width` x `height` pixels at (`x`, `y`) in
/// a picture `picture_width` x `picture_height` pixels at `buffer`, whose
/// pixels take `pbyte`.
pub fn describe(descriptor: *volatile Descriptor, buffer: usize, picture_width: u32, picture_height: u32, x: u32, y: u32, width: u32, height: u32, pbyte: u32) void {
    descriptor.block = height | width << 14 | block_2d | block_suc_eof | block_owner_dma;
    descriptor.picture = picture_height | picture_width << 14 | pbyte << 28;
    descriptor.origin = y | x << 14;
    descriptor.buffer = @intCast(buffer);
    descriptor.next = 0;
}

/// The 2D-DMA's own reset and clock, once its bus clock is on.
pub fn start() void {
    reg(rst_conf).* = rst_clk_en;
    reg(rst_conf).* = rst_clk_en | axim_rd_rst;
    reg(rst_conf).* = rst_clk_en;
    reg(rst_conf).* = rst_clk_en | axim_wr_rst;
    reg(rst_conf).* = rst_clk_en;
    reg(out_arb_config).* = 0;
    reg(in_arb_config).* = 0;
}

/// Send channel `channel` reset and connected to `peri`.
pub fn connectOut(channel: u32, peri: u32) bool {
    const at = outChannel(channel);
    reg(at + link_conf).* |= out_link_stop;
    if (!resetChannel(at, out_reset_avail)) return false;
    reg(at + out_peri_sel).* = peri;
    reg(at + conf0).* = conf_set | (if (peri == peri_ppa_srm) conf_dscr_port else 0);
    reg(at + out_color_convert).* = convert_off;
    reg(at + int_ena).* = 0;
    reg(at + int_clr).* = 0xFFFF_FFFF;
    return true;
}

/// The scaler's macro-blocks as send channel `channel` hands them over
/// the descriptor port: `width` x `height` pixels each.
pub fn portBlock(channel: u32, width: u32, height: u32) void {
    reg(outChannel(channel) + out_dscr_port_blk).* = width | height << 14;
}

/// Channel 0's receive side reset and connected to `peri`; `sibling`, it
/// takes what the send side of the same channel sends.
pub fn connectIn(peri: u32, sibling: bool) bool {
    // Stopped, and AUTO_RET off: the CPU hands descriptors back.
    reg(in_ch0 + link_conf).* = in_link_stop;
    if (!resetChannel(in_ch0, in_reset_avail)) return false;
    reg(in_ch0 + in_peri_sel).* = peri;
    reg(in_ch0 + conf0).* = conf_set | (if (sibling) conf_mem_trans else 0) |
        (if (peri == peri_ppa_srm) conf_dscr_port else 0);
    reg(in_ch0 + in_color_convert).* = convert_off;
    reg(in_ch0 + int_ena).* = 0;
    reg(in_ch0 + int_clr).* = 0xFFFF_FFFF;
    return true;
}

fn resetChannel(channel: usize, avail: u32) bool {
    reg(channel + conf0).* |= conf_cmd_disable;
    const since = systimer.uptimeUs();
    while (reg(channel + state).* & avail == 0) {
        if (systimer.uptimeUs() - since > 1000) return false;
    }
    reg(channel + conf0).* |= conf_rst;
    reg(channel + conf0).* &= ~conf_rst;
    reg(channel + conf0).* &= ~conf_cmd_disable;
    return true;
}

/// Send channel `channel` started on the descriptor at `address`.
pub fn runOut(channel: u32, address: usize) void {
    const at = outChannel(channel);
    reg(at + link_addr).* = @intCast(address);
    reg(at + link_conf).* |= out_link_start;
}

/// The receive side started on the descriptor at `address`.
pub fn runIn(address: usize) void {
    reg(in_ch0 + link_addr).* = @intCast(address);
    reg(in_ch0 + link_conf).* |= in_link_start;
}

/// The receive side's end raised as its interrupt (INTB_DMA2D_IN_CH0).
pub fn interruptWhenEnded() void {
    reg(in_ch0 + int_clr).* = 0xFFFF_FFFF;
    reg(in_ch0 + int_ena).* = in_ended;
}

/// How the receive side ended, as its interrupt reports it: taken, and
/// the interrupt off again. 0 for an interrupt that is not this.
pub fn takeEnded() u32 {
    const raised = reg(in_ch0 + int_st).* & in_ended;
    if (raised == 0) return 0;
    reg(in_ch0 + int_ena).* = 0;
    reg(in_ch0 + int_clr).* = raised;
    return raised;
}

/// Until the receive side has ended or `timeout_us` has gone: how it
/// ended, 0 for the timeout.
pub fn poll(timeout_us: u64) u32 {
    const since = systimer.uptimeUs();
    while (true) {
        const raised = reg(in_ch0 + int_raw).* & in_ended;
        if (raised != 0) return raised;
        if (systimer.uptimeUs() - since > timeout_us) return 0;
    }
}

/// The channels disconnected after a transfer that ended as `raised`
/// says: whether it ended well.
pub fn release(raised: u32) bool {
    reg(in_ch0 + int_ena).* = 0;
    reg(in_ch0 + int_clr).* = 0xFFFF_FFFF;
    reg(in_ch0 + in_peri_sel).* = peri_none;
    reg(in_ch0 + conf0).* &= ~(conf_mem_trans | conf_dscr_port);
    var channel: u32 = 0;
    while (channel < out_channels) : (channel += 1) {
        const at = outChannel(channel);
        reg(at + int_clr).* = 0xFFFF_FFFF;
        reg(at + out_peri_sel).* = peri_none;
        reg(at + conf0).* &= ~conf_dscr_port;
    }
    return raised & in_suc_eof != 0 and raised & (in_err_eof | in_dscr_err) == 0;
}

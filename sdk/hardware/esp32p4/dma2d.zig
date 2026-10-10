// SPDX-License-Identifier: MIT
//! The ESP32-P4's 2D-DMA: the DMA that moves rectangles of pixels between
//! memory and the PPA or the JPEG codec, or from memory to memory. Its
//! channels are dma.resource's to hand out (2D channel n is send channel
//! n and receive channel n where there is one); their owners set them up
//! and start them with the calls here.
//!
//! A transfer is a pair of channels: a send channel that reads memory and
//! a receive channel that writes it, each working from a descriptor. A 2D
//! descriptor names a picture (its width in pixels, which is also how its
//! rows are spaced, and its height), a block inside it (its width and
//! height) and where the block starts; the channel walks the block row by
//! row - or, in the multiple mode, the whole picture block after block. A
//! 1D descriptor is a run of bytes. A memory-to-memory copy is a send and
//! a receive channel of the same number, the receive one told to take
//! what its sibling sends. The PPA's scaler takes its blocks through the
//! descriptor port instead: it asks the send channel for the pixels of
//! each of its macro-blocks, and tells the receive channel where each
//! result goes, so the receive descriptor only names the picture.
//!
//! Receive channel 0 alone puts a peripheral's macro-blocks back into
//! rows (reorder) and converts colour on the way to memory - the JPEG
//! decoder needs both. The conversion is a 3x4 matrix the caller gives.
//!
//! Each transfer sets its channels up afresh, as ESP-IDF v6.1's dma2d.c
//! does (`dma2d_connect`, `dma2d_set_transfer_ability`,
//! `dma2d_configure_color_space_conversion`, `dma2d_start`); the registers
//! from soc/esp32p4/register/hw_ver1/soc/dma2d_struct.h.
//!
//! It keeps no state: every call is register writes at `map.DMA2D`.

const map = @import("map.zig");
const reg = @import("mmio.zig").reg;
const systimer = @import("systimer.zig");

const dma2d = map.DMA2D;

/// Send channels 0 to 2; receive channels 0 and 1.
pub const send_channels = 3;
pub const receive_channels = 2;

/// A send channel's registers, channel n's at n * 0x100; a receive
/// channel's at 0x500 + n * 0x100.
fn outChannel(channel: u32) usize {
    return dma2d + @as(usize, channel) * 0x100;
}

fn inChannel(channel: u32) usize {
    return dma2d + 0x500 + @as(usize, channel) * 0x100;
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
/// Receive channel 0's colour conversion, the order of its bytes after
/// it, and its matrix: a row for each of the three bytes it makes, two
/// words each.
const in_color_convert = 0x4C;
const in_scramble = 0x50;
const in_color_param = 0x54;
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
const conf_macro_block_shift = 9;
const conf_no_macro_block: u32 = 3 << conf_macro_block_shift;
const conf_page_bound: u32 = 1 << 12;
const conf_dscr_port: u32 = 1 << 11;
const conf_in_reorder: u32 = 1 << 16;
const conf_rst: u32 = 1 << 24;
const conf_cmd_disable: u32 = 1 << 25;
const conf_mem_trans: u32 = 1 << 0;
const conf_set: u32 = conf_eof_mode | conf_dscr_burst | conf_burst_128 | conf_page_bound;

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

/// What a channel feeds or is fed by: the JPEG codec (both ways), the
/// PPA's scaler (both ways), its blend unit (what is under and its output
/// on 2, what goes over on 3), and memory (a copy - any of 4 to 7 sending,
/// 3 to 7 receiving).
pub const peri_jpeg: u32 = 0;
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
    /// Where the block starts in the picture, and the mode (bit 28:
    /// block after block over the whole picture).
    origin: u32 = 0,
    buffer: u32 = 0,
    next: u32 = 0,
    pad: u32 = 0,
};

const block_2d: u32 = 1 << 29;
const block_suc_eof: u32 = 1 << 30;
const block_owner_dma: u32 = 1 << 31;
const origin_multiple: u32 = 1 << 28;
/// pbyte: one, two, three and four bytes a pixel.
pub const pbyte_1: u32 = 1;
pub const pbyte_2: u32 = 3;
pub const pbyte_3: u32 = 4;
pub const pbyte_4: u32 = 5;
/// What every 2D size and place holds at most.
pub const field_max: u32 = 0x3FFF;
/// The longest run a 1D descriptor holds.
pub const line_max: u32 = (1 << 28) - 1;

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

/// A descriptor over a whole picture, `picture_width` x `picture_height`
/// pixels at `buffer`, taken `block_width` x `block_height` at a time -
/// the order a peripheral that works in blocks hands them over. The end is
/// the peripheral's to say, not the descriptor's.
pub fn describeBlocks(descriptor: *volatile Descriptor, buffer: usize, picture_width: u32, picture_height: u32, block_width: u32, block_height: u32, pbyte: u32) void {
    descriptor.block = block_height | block_width << 14 | block_2d | block_owner_dma;
    descriptor.picture = picture_height | picture_width << 14 | pbyte << 28;
    descriptor.origin = origin_multiple;
    descriptor.buffer = @intCast(buffer);
    descriptor.next = 0;
}

/// A descriptor for `length` bytes at `buffer` (at most `line_max`), read
/// as they are. The end is the peripheral's to say.
pub fn describeLine(descriptor: *volatile Descriptor, buffer: usize, length: u32) void {
    const low = length & field_max;
    const high = length >> 14;
    descriptor.block = low | low << 14 | block_owner_dma;
    descriptor.picture = high | high << 14 | pbyte_1 << 28;
    descriptor.origin = 0;
    descriptor.buffer = @intCast(buffer);
    descriptor.next = 0;
}

/// The 2D-DMA's own reset and clock, once its bus clock is on: what
/// dma.resource does when it is made.
pub fn start() void {
    reg(rst_conf).* = rst_clk_en;
    reg(rst_conf).* = rst_clk_en | axim_rd_rst;
    reg(rst_conf).* = rst_clk_en;
    reg(rst_conf).* = rst_clk_en | axim_wr_rst;
    reg(rst_conf).* = rst_clk_en;
    reg(out_arb_config).* = 0;
    reg(in_arb_config).* = 0;
}

/// 2D channel `channel` stopped and off whatever it was connected to,
/// its interrupts off: what dma.resource does when it is given back.
pub fn stopChannel(channel: u32) void {
    if (channel < send_channels) {
        const at = outChannel(channel);
        reg(at + link_conf).* |= out_link_stop;
        _ = resetChannel(at, out_reset_avail);
        releaseOut(channel);
    }
    if (channel < receive_channels) {
        const at = inChannel(channel);
        reg(at + link_conf).* = in_link_stop;
        _ = resetChannel(at, in_reset_avail);
        releaseIn(channel);
    }
}

/// Send channel `channel` reset and connected to `peri`.
pub fn connectOut(channel: u32, peri: u32) bool {
    const at = outChannel(channel);
    reg(at + link_conf).* |= out_link_stop;
    if (!resetChannel(at, out_reset_avail)) return false;
    reg(at + out_peri_sel).* = peri;
    reg(at + conf0).* = conf_set | conf_no_macro_block | (if (peri == peri_ppa_srm) conf_dscr_port else 0);
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

/// The size of the macro-blocks a peripheral hands a receive channel, to
/// be put back into rows (receive channel 0 only).
pub const MacroBlock = enum(u32) { @"8x8" = 0, @"8x16" = 1, @"16x16" = 2 };

/// What a receive channel's colour conversion takes in: YUV with its
/// colour at half the size across (and down), or YUV whole.
pub const ConvertFrom = enum(u32) { yuv_halved = 0, yuv_whole = 2 };
/// What it hands on: RGB565, or three bytes as the matrix makes them.
pub const ConvertTo = enum(u32) { rgb565 = 0, three_bytes = 1 };

/// A conversion: from, to, and the matrix - for each of the three bytes
/// it makes, from the most significant down, the factors of the three it
/// takes (in 256ths, the first 10 bits unsigned, then 11 and 10 bits
/// signed) and what is added (18 bits signed, in 256ths).
pub const Convert = struct {
    from: ConvertFrom,
    to: ConvertTo,
    matrix: *const [3][4]i32,
};

/// How a receive channel is connected: to the send channel of its own
/// number (`sibling`), through the descriptor port (the scaler),
/// reordering macro-blocks, converting colour.
pub const Receive = struct {
    sibling: bool = false,
    reorder: ?MacroBlock = null,
    convert: ?Convert = null,
};

/// Receive channel `channel` reset and connected to `peri` as `how` says;
/// false where it cannot be (reordering or converting elsewhere than on
/// channel 0, or a channel that does not stop).
pub fn connectIn(channel: u32, peri: u32, how: Receive) bool {
    if (channel != 0 and (how.reorder != null or how.convert != null)) return false;
    const at = inChannel(channel);
    // Stopped, and AUTO_RET off: the CPU hands descriptors back.
    reg(at + link_conf).* = in_link_stop;
    if (!resetChannel(at, in_reset_avail)) return false;
    reg(at + in_peri_sel).* = peri;
    const macro_block: u32 = if (how.reorder) |size| @intFromEnum(size) << conf_macro_block_shift | conf_in_reorder else conf_no_macro_block;
    reg(at + conf0).* = conf_set | macro_block | (if (how.sibling) conf_mem_trans else 0) |
        (if (peri == peri_ppa_srm) conf_dscr_port else 0);
    if (channel == 0) {
        if (how.convert) |convert| {
            for (convert.matrix, 0..) |row, i| {
                const param = at + in_color_param + i * 8;
                reg(param).* = field(row[0], 10) | field(row[1], 11) << 10;
                reg(param + 4).* = field(row[2], 10) | field(row[3], 18) << 10;
            }
            reg(at + in_scramble).* = 0;
            reg(at + in_color_convert).* = @intFromEnum(convert.to) | 1 << 2 | @intFromEnum(convert.from) << 3;
        } else {
            reg(at + in_color_convert).* = convert_off;
        }
    }
    reg(at + int_ena).* = 0;
    reg(at + int_clr).* = 0xFFFF_FFFF;
    return true;
}

/// `value` as a field of `bits` bits, two's complement.
fn field(value: i32, comptime bits: u5) u32 {
    return @as(u32, @bitCast(value)) & ((@as(u32, 1) << bits) - 1);
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

/// Receive channel `channel` started on the descriptor at `address`.
pub fn runIn(channel: u32, address: usize) void {
    const at = inChannel(channel);
    reg(at + link_addr).* = @intCast(address);
    reg(at + link_conf).* |= in_link_start;
}

/// Receive channel `channel`'s end raised as its interrupt
/// (INTB_DMA2D_IN_CH0 + channel).
pub fn interruptWhenEnded(channel: u32) void {
    const at = inChannel(channel);
    reg(at + int_clr).* = 0xFFFF_FFFF;
    reg(at + int_ena).* = in_ended;
}

/// How receive channel `channel` ended, as its interrupt reports it:
/// taken, and the interrupt off again. 0 for an interrupt that is not
/// this.
pub fn takeEnded(channel: u32) u32 {
    const at = inChannel(channel);
    const raised = reg(at + int_st).* & in_ended;
    if (raised == 0) return 0;
    reg(at + int_ena).* = 0;
    reg(at + int_clr).* = raised;
    return raised;
}

/// Until receive channel `channel` has ended or `timeout_us` has gone:
/// how it ended, 0 for the timeout.
pub fn poll(channel: u32, timeout_us: u64) u32 {
    const at = inChannel(channel);
    const since = systimer.uptimeUs();
    while (true) {
        const raised = reg(at + int_raw).* & in_ended;
        if (raised != 0) return raised;
        if (systimer.uptimeUs() - since > timeout_us) return 0;
    }
}

/// Receive channel `channel` disconnected after a transfer, its
/// interrupts off.
pub fn releaseIn(channel: u32) void {
    const at = inChannel(channel);
    reg(at + int_ena).* = 0;
    reg(at + int_clr).* = 0xFFFF_FFFF;
    reg(at + in_peri_sel).* = peri_none;
    reg(at + conf0).* &= ~(conf_mem_trans | conf_dscr_port | conf_in_reorder);
    if (channel == 0) reg(at + in_color_convert).* = convert_off;
}

/// Send channel `channel` disconnected after a transfer.
pub fn releaseOut(channel: u32) void {
    const at = outChannel(channel);
    reg(at + int_ena).* = 0;
    reg(at + int_clr).* = 0xFFFF_FFFF;
    reg(at + out_peri_sel).* = peri_none;
    reg(at + conf0).* &= ~conf_dscr_port;
}

/// Whether a transfer whose receive side ended as `raised` says ended
/// well.
pub fn endedWell(raised: u32) bool {
    return raised & in_suc_eof != 0 and raised & (in_err_eof | in_dscr_err) == 0;
}

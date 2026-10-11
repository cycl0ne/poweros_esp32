// SPDX-License-Identifier: MPL-2.0
//! The ESP32-P4's JPEG codec as a decoder: its registers, the tables a
//! header gives written into them, and the 2D-DMA channel that feeds it
//! the scan and takes the picture away.
//!
//! **A decode**, as ESP-IDF v6.1's jpeg_decode.c does it: the codec reset
//! into decoding, its picture size zeroed (the codec needs that before a
//! new picture), the quantization tables and the frame - size, component
//! count, each component's number, sampling and table - the four code
//! tables and the restart interval written. Then the 2D-DMA's channel 0:
//! its send side reads the file from the scan's marker to the end as one
//! run, its receive side writes the picture back block by block - the
//! codec's 8x8, 8x16 or 16x16 macro-blocks put back into rows - through
//! the colour conversion. The codec starts last.
//!
//! **A code table** goes in as the codec looks codes up: for each length
//! 1 to 16, how many codes there are up to it and the first code of that
//! length, left-aligned in 16 bits (0xFFFF for a length with none) - a
//! FIFO write each; then the symbols, 16 of a DC table's and 256 of an
//! AC table's, the ones a table lacks as 0.
//!
//! **The colour**: the codec hands over brightness and two colour
//! differences; the receive channel's matrix turns them into red, green
//! and blue as JFIF defines them - full range, not the studio range
//! ESP-IDF's BT.601 table assumes - and writes them blue first.
//!
//! **The end** is the receive side's end of frame. The codec raises its
//! own interrupt for what it found wrong in the file; either ends the
//! wait (`Waiting`, the resource's two interrupt servers).
//!
//! From ESP-IDF v6.1's esp_driver_jpeg (jpeg_decode.c, jpeg_param.c),
//! esp_hal_jpeg (jpeg_hal.c, esp32p4/include/hal/jpeg_ll.h) and
//! soc/esp32p4/register/hw_ver1/soc/jpeg_reg.h.

const sdk = @import("sdk");
const hardware = sdk.hardware;
const reg = hardware.mmio.reg;
const map = hardware.map;
const dma2d = hardware.dma2d;
const _header = @import("../header/_header.zig");
const Header = _header.Header;

const base = map.JPEG;

const config = base + 0x00;
const dqt_info = base + 0x04;
const pic_size = base + 0x08;
const qnr = base + 0x10; // t0qnr; table n at qnr + 4n
const decode_conf = base + 0x20;
const component_reg = base + 0x24; // c0; component n at + 4n
const int_ena = base + 0x3C;
const int_st = base + 0x40;
const int_clr = base + 0x44;
/// The code tables' registers, [DC, AC][0, 1]: the running count, the
/// symbols, the first code of each length.
const totlen = [2][2]usize{ .{ base + 0x58, base + 0x68 }, .{ base + 0x60, base + 0x70 } };
const values = [2][2]usize{ .{ base + 0x5C, base + 0x6C }, .{ base + 0x64, base + 0x74 } };
const codemin = [2][2]usize{ .{ base + 0x78, base + 0x80 }, .{ base + 0x7C, base + 0x84 } };

/// CONFIG: start, the soft reset, decode (1) or encode.
const config_start: u32 = 1 << 1;
const config_soft_rst: u32 = 1 << 24;
const config_decode: u32 = 1 << 31;

/// The codec's interrupts for a file it cannot decode: a component, a
/// table or a restart marker not as the registers say, a scan where none
/// should be, a marker it does not know, too few or too many blocks, a
/// header it cannot read, no scan at all, and its own timeout.
pub const decode_errors: u32 = (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7) | (1 << 8) |
    (1 << 13) | (1 << 14) | (1 << 15) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 21) | (1 << 22) |
    (1 << 23) | (1 << 24);

/// The 2D-DMA channel the codec is fed through: send and receive 0, the
/// only receive channel that puts macro-blocks back and converts colour.
pub const channel = 0;

/// JFIF's YUV to RGB, in 256ths: for red, green and blue, the factors of
/// brightness, blue difference and red difference, and what is added -
/// the differences centred on 128, and half a step for rounding.
const jfif_matrix = [3][4]i32{
    .{ 256, 0, 359, -359 * 128 + 128 },
    .{ 256, -88, -183, (88 + 183) * 128 + 128 },
    .{ 256, 454, 0, -454 * 128 + 128 },
};

/// The two descriptors, in one cache line: the scan's, the picture's.
pub const Descriptors = struct {
    send: *volatile dma2d.Descriptor,
    receive: *volatile dma2d.Descriptor,
};

/// The codec reset into decoding: its other settings left at theirs.
fn reset() void {
    reg(config).* |= config_soft_rst;
    reg(config).* &= ~config_soft_rst;
    reg(config).* |= config_decode;
}

/// The codec reset into decoding, and the header's tables and frame
/// written into it.
pub fn load(h: *const Header) void {
    reset();
    reg(pic_size).* = 0;

    var table: u32 = 0;
    while (table < 4) : (table += 1) {
        if (h.quantization_given & (@as(u4, 1) << @intCast(table)) == 0) continue;
        const shift: u5 = @intCast(table * 8);
        reg(dqt_info).* = (reg(dqt_info).* & ~(@as(u32, 0xFF) << shift)) | table << shift;
        for (h.quantization[table]) |entry| reg(qnr + table * 4).* = entry;
    }

    reg(pic_size).* = h.padded_height | h.padded_width << 16;
    reg(decode_conf).* = (reg(decode_conf).* & ~@as(u32, 0xFF_FFFF)) | h.count << 16 | (h.restart & 0xFFFF);
    for (h.component[0..h.count], 0..) |c, n| {
        reg(component_reg + n * 4).* = c.table | @as(u32, c.down) << 8 | @as(u32, c.across) << 12 | @as(u32, c.id) << 16;
    }

    for (0..2) |class| {
        for (0..2) |number| codeTable(class, number, &h.code[class][number]);
    }
}

/// One code table into the codec's FIFOs.
fn codeTable(class: usize, number: usize, table: *const _header.CodeTable) void {
    var running: u32 = 0;
    var code: u32 = 0;
    for (table.counts, 0..) |count, i| {
        running += count;
        const first: u32 = if (count == 0) 0xFFFF else code << @intCast(15 - i);
        reg(totlen[class][number]).* = running;
        reg(codemin[class][number]).* = first;
        code = (code + count) << 1;
    }
    const symbols: usize = if (class == 0) 16 else 256;
    for (table.symbols[0..symbols]) |symbol| reg(values[class][number]).* = symbol;
}

/// The 2D-DMA's channel set up to feed the codec the scan - `scan_length`
/// bytes from `scan_at` - and to write the picture into `pixels`.
pub fn connect(h: *const Header, parts: Descriptors, scan_at: usize, scan_length: u32, pixels: usize) bool {
    if (!dma2d.connectOut(channel, dma2d.peri_jpeg)) return false;
    const colour = h.count == 3;
    const blocks: dma2d.MacroBlock = switch (h.sampling) {
        sdk.resources.jpeg.JPEGSAMP_422 => .@"8x16",
        sdk.resources.jpeg.JPEGSAMP_420 => .@"16x16",
        else => .@"8x8",
    };
    const how: dma2d.Receive = .{
        .reorder = blocks,
        .convert = if (colour) .{
            .from = if (h.sampling == sdk.resources.jpeg.JPEGSAMP_444) .yuv_whole else .yuv_halved,
            .to = .three_bytes,
            .matrix = &jfif_matrix,
        } else null,
    };
    if (!dma2d.connectIn(channel, dma2d.peri_jpeg, how)) return false;
    dma2d.describeLine(parts.send, scan_at, scan_length);
    // How many pixels across the receive side takes a block at: ESP-IDF's
    // dec_hb_tbl for RGB888 out, and for grey.
    const block_width: u32 = if (!colour) 96 else switch (h.sampling) {
        sdk.resources.jpeg.JPEGSAMP_444 => 40,
        else => 32,
    };
    dma2d.describeBlocks(parts.receive, pixels, h.padded_width, h.padded_height, block_width, h.mcu_height, if (colour) dma2d.pbyte_3 else dma2d.pbyte_1);
    return true;
}

/// The codec's error interrupts cleared and on.
pub fn armErrors() void {
    reg(int_clr).* = 0xFFFF_FFFF;
    reg(int_ena).* = decode_errors;
}

/// Both sides of the channel started, then the codec.
pub fn start(send_at: usize, receive_at: usize) void {
    dma2d.interruptWhenEnded(channel);
    dma2d.runOut(channel, send_at);
    dma2d.runIn(channel, receive_at);
    reg(config).* |= config_start;
}

/// What the codec raised, taken and cleared; 0 when it was not the codec.
pub fn takeErrors() u32 {
    const raised = reg(int_st).* & decode_errors;
    if (raised != 0) reg(int_clr).* = raised;
    return raised;
}

/// The codec's interrupts off, the channel let go, the codec reset.
pub fn finish() void {
    reg(int_ena).* = 0;
    reg(int_clr).* = 0xFFFF_FFFF;
    dma2d.releaseIn(channel);
    dma2d.releaseOut(channel);
    reset();
}

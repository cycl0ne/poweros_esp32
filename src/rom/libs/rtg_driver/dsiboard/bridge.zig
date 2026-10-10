// SPDX-License-Identifier: MPL-2.0
//! The ESP32-P4's DSI bridge, for the DSI board driver: the DPI side of
//! the DSI host. It takes the picture from a DMA engine into a FIFO and
//! hands it to the host a line at a time, with the timings the host's
//! video mode expects; DPI_CONFIG_UPDATE latches what was written.
//!
//! The DMA engine is the flow controller: it is told the frame's size and
//! the bridge only asks for more. The bridge's pixel format is the one in
//! memory and the one sent - this revision of the chip converts nothing.
//! A FIFO that runs dry mid-line is an underrun, which the bridge fills
//! with a colour of its own and reports.
//!
//! It keeps no state: every call is register writes at `map.DSI_BRG`.
//! The values follow ESP-IDF v6.1's esp_lcd_panel_dpi.c and
//! mipi_dsi_brg_ll.h.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;

const brg = sdk.hardware.map.DSI_BRG;

const en = brg + 0x04;
const dma_req_cfg = brg + 0x08;
const raw_num_cfg = brg + 0x0C;
const pixel_type = brg + 0x18;
const dpi_v_cfg0 = brg + 0x30;
const dpi_v_cfg1 = brg + 0x34;
const dpi_h_cfg0 = brg + 0x38;
const dpi_h_cfg1 = brg + 0x3C;
const dpi_misc_config = brg + 0x40;
const dpi_config_update = brg + 0x44;
const int_ena = brg + 0x50;
const int_clr = brg + 0x54;
const int_st = brg + 0x5C;
const dma_frame_interval = brg + 0x6C;
const host_ctrl = brg + 0x80;
const dma_flow_ctrl = brg + 0x88;
const raw_buf_almost_empty_thrd = brg + 0x8C;

/// Where the DMA engine writes the picture to: the bridge's FIFO.
pub const fifo: u32 = 0x5010_5000;

/// PIXEL_TYPE's RAW_TYPE: the pixel format in memory and on the link.
pub const raw_rgb565: u32 = 2;
pub const raw_rgb888: u32 = 0;

/// DPI_MISC_CONFIG: the DPI side on.
const dpi_en: u32 = 1 << 0;
/// RAW_NUM_CFG: the count is taken; it is not a whole number of 64-bit
/// words.
const raw_num_total_set: u32 = 1 << 31;
const unalign_64bit: u32 = 1 << 22;
/// DMA_FLOW_CTRL: the DMA engine controls the flow, one block a frame.
const flow_dma_one_block: u32 = 1 << 4;
/// DMA_FRAME_INTERVAL: more than one block a frame.
const multiblock: u32 = 1 << 28;
/// HOST_CTRL: the DSI host's configuration and reference clocks on.
const host_clocks: u32 = 1 << 0;
/// INT_*: the FIFO ran dry.
pub const int_underrun: u32 = 1 << 0;

/// How many 64-bit words the bridge asks the DMA engine for at once, and
/// how empty its 1024-word FIFO gets before it asks.
const burst_words = 256;
const fifo_words = 1024;

/// What the bridge needs: the picture's size, its timings in pixel clocks
/// and lines, its bits a pixel and its format.
pub const Frame = struct {
    width: u32,
    height: u32,
    hsync: u32,
    hbp: u32,
    hfp: u32,
    vsync: u32,
    vbp: u32,
    vfp: u32,
    bits_per_pixel: u32,
    raw_type: u32,
};

/// The bridge set up for `frame` and switched on, its DPI side still off.
pub fn setUp(frame: Frame) void {
    reg(host_ctrl).* |= host_clocks;
    const line = frame.hsync + frame.hbp + frame.width + frame.hfp;
    const lines = frame.vsync + frame.vbp + frame.height + frame.vfp;
    reg(dpi_h_cfg0).* = frame.width << 16 | line;
    reg(dpi_h_cfg1).* = frame.hsync << 16 | frame.hbp;
    reg(dpi_v_cfg0).* = frame.height << 16 | lines;
    reg(dpi_v_cfg1).* = frame.vsync << 16 | frame.vbp;
    const bits = @as(u64, frame.width) * frame.height * frame.bits_per_pixel;
    var raw = raw_num_total_set | @as(u32, @intCast((bits + 63) / 64));
    if (bits % 64 != 0) raw |= unalign_64bit;
    reg(raw_num_cfg).* = raw;
    reg(dpi_misc_config).* = frame.width << 4;
    reg(pixel_type).* = (reg(pixel_type).* & ~@as(u32, 0xF)) | frame.raw_type;
    reg(dma_flow_ctrl).* = flow_dma_one_block;
    reg(dma_frame_interval).* &= ~multiblock;
    reg(dma_req_cfg).* = (reg(dma_req_cfg).* & ~@as(u32, 0xFFF)) | burst_words;
    reg(raw_buf_almost_empty_thrd).* = fifo_words - burst_words;
    reg(en).* |= 1;
    reg(dpi_config_update).* = 1;
}

/// The DPI side on or off: on, it asks for the picture and sends it.
pub fn dpi(on: bool) void {
    if (on) reg(dpi_misc_config).* |= dpi_en else reg(dpi_misc_config).* &= ~dpi_en;
    reg(dpi_config_update).* = 1;
}

/// The underrun interrupt on or off.
pub fn underrunInterrupt(on: bool) void {
    reg(int_clr).* = int_underrun;
    reg(int_ena).* = if (on) int_underrun else 0;
}

/// What the bridge raised, cleared.
pub fn takeInterrupts() u32 {
    const raised = reg(int_st).*;
    reg(int_clr).* = raised;
    return raised;
}

/// The bridge off.
pub fn stop() void {
    reg(int_ena).* = 0;
    dpi(false);
    reg(en).* &= ~@as(u32, 1);
}

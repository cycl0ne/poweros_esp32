// SPDX-License-Identifier: MPL-2.0
//! The ESP32-P4's PPA, the pixel-processing accelerator, for the DSI
//! board's engine: here its blend unit's fill, which sends one colour as
//! a block of pixels to the 2D-DMA's receive channel.
//!
//! The colour is given as ARGB8888 whatever the block's format; the unit
//! drops the low bits to make RGB565. The block's size is the PPA's as
//! well as the descriptor's.
//!
//! It keeps no state: every call is register writes at `map.PPA`. The
//! sequence follows ESP-IDF v6.1's ppa_fill.c.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;

const ppa = sdk.hardware.map.PPA;

const blend_color_mode = ppa + 0x24;
const blend_trans_mode = ppa + 0x34;
const blend_tx_size = ppa + 0x3C;
const blend_fix_pixel = ppa + 0x4C;

/// BLEND_COLOR_MODE: the output's format in bits 8 to 11, RGB565 being 2.
const tx_cm_shift = 8;
const tx_cm_mask: u32 = 0xF << tx_cm_shift;
const cm_rgb565: u32 = 2;
/// BLEND_TRANS_MODE: the unit on, fill instead of blend, take the new
/// mode, the unit's reset.
const trans_blend_en: u32 = 1 << 0;
const trans_fill_en: u32 = 1 << 2;
const trans_update: u32 = 1 << 3;
const trans_rst: u32 = 1 << 4;

/// The blend unit back to idle, before its 2D-DMA channel is set up.
pub fn reset() void {
    reg(blend_trans_mode).* = trans_rst;
    reg(blend_trans_mode).* = 0;
}

/// A block `width` x `height` of `argb` sent out as RGB565: the receive
/// channel has to be running already.
pub fn fill(argb: u32, width: u32, height: u32) void {
    reg(blend_fix_pixel).* = argb;
    reg(blend_color_mode).* = (reg(blend_color_mode).* & ~tx_cm_mask) | cm_rgb565 << tx_cm_shift;
    reg(blend_tx_size).* = width | height << 14;
    // The mode first, then the unit on, then the update that takes them,
    // each its own write.
    reg(blend_trans_mode).* = trans_fill_en;
    reg(blend_trans_mode).* = trans_fill_en | trans_blend_en;
    reg(blend_trans_mode).* = trans_fill_en | trans_blend_en | trans_update;
}

/// An RGB565 colour as the fill takes it: each channel widened to eight
/// bits by its zero low bits, which the unit drops again.
pub fn argbOf(rgb565: u32) u32 {
    const red = (rgb565 >> 11) & 0x1F;
    const green = (rgb565 >> 5) & 0x3F;
    const blue = rgb565 & 0x1F;
    return 0xFF00_0000 | red << 19 | green << 10 | blue << 3;
}

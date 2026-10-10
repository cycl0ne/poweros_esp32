// SPDX-License-Identifier: MPL-2.0
//! The ESP32-P4's PPA, the pixel-processing accelerator, for the DSI
//! board's engine: its blend unit, which fills a block with one colour or
//! lays one block of pixels over another, and its scaler.
//!
//! **The blend unit** takes what is under from one send channel of the
//! 2D-DMA and what goes over from another, mixes each pair of pixels by
//! the coverage of the one over, and hands the result to the receive
//! channel. What goes over may carry its own coverage (ARGB8888), take a
//! fixed one, or have it multiplied by one; in the A8 format it is a
//! coverage alone, and its colour is the unit's fixed colour. Colours
//! come in as ARGB8888 whatever the format, and the low bits are dropped
//! to make RGB565. Its fill sends one colour as a block with no input at
//! all. The block's size is the PPA's as well as the descriptors'.
//!
//! **The scaler** works in macro-blocks of 16 x 16 pixels, which it takes
//! from its send channel through the descriptor port, 18 x 18 with the
//! border its mixing needs. Its factor each way is a whole number and
//! sixteenths, and it mixes the four pixels round each place it samples.
//!
//! It keeps no state: every call is register writes at `map.PPA`. The
//! sequences follow ESP-IDF v6.1's ppa_fill.c, ppa_blend.c and
//! ppa_srm.c.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;

const ppa = sdk.hardware.map.PPA;

const sr_color_mode = ppa + 0x20;
const blend_color_mode = ppa + 0x24;
const sr_byte_order = ppa + 0x28;
const blend_byte_order = ppa + 0x2C;
const blend_trans_mode = ppa + 0x34;
const sr_fix_alpha = ppa + 0x38;
const blend_tx_size = ppa + 0x3C;
const blend_fix_alpha = ppa + 0x40;
const blend_rgb = ppa + 0x48;
const blend_fix_pixel = ppa + 0x4C;
const ck_fg_low = ppa + 0x50;
const ck_fg_high = ppa + 0x54;
const ck_bg_low = ppa + 0x58;
const ck_bg_high = ppa + 0x5C;
const ck_default = ppa + 0x60;
const sr_scal_rotate = ppa + 0x64;

/// The colour modes, as both units name them.
pub const cm_argb8888: u32 = 0;
pub const cm_rgb888: u32 = 1;
pub const cm_rgb565: u32 = 2;
pub const cm_a8: u32 = 6;

/// BLEND_COLOR_MODE: what is under in bits 0 to 3, what goes over in 4
/// to 7, the output in 8 to 11.
const bg_cm_shift = 0;
const fg_cm_shift = 4;
const tx_cm_shift = 8;
const tx_cm_mask: u32 = 0xF << tx_cm_shift;
/// BLEND_BYTE_ORDER: red and blue exchanged in what goes over.
const fg_rgb_swap: u32 = 1 << 3;
/// BLEND_TRANS_MODE: the unit on, fill instead of blend, take the new
/// mode, the unit's reset.
const trans_blend_en: u32 = 1 << 0;
const trans_fill_en: u32 = 1 << 2;
const trans_update: u32 = 1 << 3;
const trans_rst: u32 = 1 << 4;
/// BLEND_FIX_ALPHA: the fixed coverage of what goes over (bits 8 to 15)
/// and what is done with it (18 and 19).
const fg_fix_shift = 8;
const fg_mod_shift = 18;

/// What becomes of the coverage of what goes over: kept, the fixed one
/// instead, or multiplied by the fixed one (taken as n/256).
pub const Coverage = enum(u32) { keep = 0, replace = 1, multiply = 2 };

/// SR_BYTE_ORDER: red and blue exchanged in the input; the macro-blocks'
/// reordering left out.
const sr_rgb_swap: u32 = 1 << 1;
const sr_macro_bypass: u32 = 1 << 2;
/// SR_COLOR_MODE: the input in bits 0 to 3, the output in 4 to 7.
const sr_tx_cm_shift = 4;
/// SR_SCAL_ROTATE: the factors' whole parts and sixteenths, the scaler's
/// reset, its start.
const sr_x_frag_shift = 8;
const sr_y_int_shift = 12;
const sr_y_frag_shift = 20;
const sr_rst: u32 = 1 << 26;
const sr_start: u32 = 1 << 27;

/// The scaler's macro-block, and the block it reads for one.
pub const macro_block = 16;
pub const port_block = 18;

/// The blend unit back to idle, before its 2D-DMA channels are set up.
pub fn reset() void {
    reg(blend_trans_mode).* = trans_rst;
    reg(blend_trans_mode).* = 0;
}

/// The mode taken in three writes - the mode, then the unit on, then the
/// update that takes them - which is how the unit wants it.
fn startBlendUnit(mode: u32) void {
    reg(blend_trans_mode).* = mode;
    reg(blend_trans_mode).* = mode | trans_blend_en;
    reg(blend_trans_mode).* = mode | trans_blend_en | trans_update;
}

/// A block `width` x `height` of `argb` sent out as RGB565: the receive
/// channel has to be running already.
pub fn fill(argb: u32, width: u32, height: u32) void {
    reg(blend_fix_pixel).* = argb;
    reg(blend_color_mode).* = (reg(blend_color_mode).* & ~tx_cm_mask) | cm_rgb565 << tx_cm_shift;
    reg(blend_tx_size).* = width | height << 14;
    startBlendUnit(trans_fill_en);
}

/// What goes over a blend: its colour mode, whether red and blue are
/// exchanged, what becomes of its coverage and the fixed coverage for
/// that, and the fixed colour of an A8 block (0xRRGGBB).
pub const Over = struct {
    cm: u32,
    swap: bool = false,
    coverage: Coverage = .keep,
    fixed: u32 = 0,
    color: u32 = 0,
};

/// A block `width` x `height` of `over` laid over an RGB565 block and
/// sent out as RGB565: the three channels have to be running already.
pub fn blend(over: Over, width: u32, height: u32) void {
    reg(blend_color_mode).* = cm_rgb565 << bg_cm_shift | over.cm << fg_cm_shift | cm_rgb565 << tx_cm_shift;
    reg(blend_byte_order).* = if (over.swap) fg_rgb_swap else 0;
    reg(blend_fix_alpha).* = over.fixed << fg_fix_shift | @intFromEnum(over.coverage) << fg_mod_shift;
    reg(blend_rgb).* = over.color & 0xFF_FFFF;
    // No colour keys: each range empty, its low end above its high one.
    reg(ck_fg_low).* = 0xFF_FFFF;
    reg(ck_fg_high).* = 0;
    reg(ck_bg_low).* = 0xFF_FFFF;
    reg(ck_bg_high).* = 0;
    reg(ck_default).* = 0;
    reg(blend_tx_size).* = width | height << 14;
    startBlendUnit(0);
}

/// The scaler back to idle.
pub fn resetScaler() void {
    reg(sr_scal_rotate).* = sr_rst;
    reg(sr_scal_rotate).* = 0;
}

/// A scale of a block `in_height` rows high, by `x16` and `y16`
/// sixteenths each way, from `in_cm` (red and blue exchanged when `swap`)
/// to ARGB8888, `out_width` pixels wide: both channels have to be
/// running already.
pub fn scale(in_cm: u32, swap: bool, x16: u32, y16: u32, in_height: u32, out_width: u32) void {
    reg(sr_color_mode).* = in_cm | cm_argb8888 << sr_tx_cm_shift;
    var order: u32 = if (swap) sr_rgb_swap else 0;
    if (macroOrderBypassed(y16, in_height, out_width)) order |= sr_macro_bypass;
    reg(sr_byte_order).* = order;
    reg(sr_fix_alpha).* = 0;
    const factors = (x16 >> 4) | (x16 & 0xF) << sr_x_frag_shift | (y16 >> 4) << sr_y_int_shift | (y16 & 0xF) << sr_y_frag_shift;
    reg(sr_scal_rotate).* = factors;
    reg(sr_scal_rotate).* = factors | sr_start;
}

/// Whether the scaler's output leaves out its macro-blocks' reordering:
/// when the job is more than one unit and its last unit fits the
/// 2D-DMA's buffer of 12 x 128 bits, for ARGB8888 out.
fn macroOrderBypassed(y16: u32, in_height: u32, out_width: u32) bool {
    const unit_width = 32;
    const width_left = if (out_width % unit_width == 0) unit_width else out_width % unit_width;
    const rows_in_left = if (in_height % macro_block == 0) macro_block else in_height % macro_block;
    const height_left = rows_in_left * y16 / 16;
    const several = out_width > unit_width or in_height > macro_block;
    return several and width_left * height_left * 32 < 12 * 128;
}

/// An RGB565 colour as the fill takes it: each channel widened to eight
/// bits by its zero low bits, which the unit drops again.
pub fn argbOf(rgb565: u32) u32 {
    const red = (rgb565 >> 11) & 0x1F;
    const green = (rgb565 >> 5) & 0x3F;
    const blue = rgb565 & 0x1F;
    return 0xFF00_0000 | red << 19 | green << 10 | blue << 3;
}
